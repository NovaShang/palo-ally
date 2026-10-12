import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import type { ApprovalManager } from "./approvals.ts";
import { firstLine } from "./ccSessions.ts";
import { ACTIVITY, describeActivity, describeInput, describeTool, friendlyError } from "./copy.ts";
import { readHead, readTail, transcriptPath } from "./handoffs.ts";
import type { HarnessDriver, HarnessEvent, MainSession, PermissionDecision, PermissionRequest } from "./harness/types.ts";
import { type PalLaunch, isHelperFailure, makeSpawner } from "./palLauncher.ts";
import { type PalMapOptions, TranscriptFollower, transcriptLastLine, transcriptModel, userEntryMessage } from "./palHistory.ts";
import { ASK_TOOL, type QuestionManager } from "./questions.ts";
import type { CardSource, ChatMessage, Pal, PalStatus } from "./types.ts";
import { newId, truncate } from "./util.ts";

// One Pal (docs/pals-prd.md §4, §7): one of the owner's Claude Code
// sessions, run by the host itself by resuming its transcript. What the owner
// types in its page goes in as the owner's own words; its replies stream to
// the app as `chat.delta` / `chat.message` carrying `pal`; its permission
// prompts and questions are the hub's ordinary cards, with the Pal as their
// source, always on the phone. It stays up so SendMessage always reaches it,
// and comes back by itself when its process ends without being asked to.
// Never two processes on one transcript: it doesn't start while another
// process holds the session, and it leaves as soon as one turns up.

export interface PalRecord {
  id: string;
  sessionId: string;
  name: string;
  cwd: string;
  createdBy: "owner" | "palo";
  createdAt: number;
  lastUsedAt: number;
  permissionMode: string;
  model?: string; // what it last ran on (from its transcript, then from Claude Code)
  duty?: string; // one the assistant opened: its handover, the first message
  dailyUsd?: number; // …and its daily spending limit
  stoppedFor?: "budget" | "failed" | "elsewhere";
  budgetDay?: string;
  note?: string; // why it's stopped
  pid?: number; // Claude Code's pid while the host runs it (an orphan after the host died)
}

/** Another process holding a session's transcript. */
export interface Holder {
  pid: number;
  bg: boolean; // Claude Code's background service runs it
  shortId?: string;
}

export class HeldElsewhere extends Error {}

export interface PalSessionDeps {
  driver: HarnessDriver;
  approvals: ApprovalManager;
  questions: QuestionManager;
  claudeDir: string;
  launch: () => Promise<PalLaunch>;
  helperFailed: (why: string) => void;
  /** Live processes holding the session, other than `own`. */
  holders: (sessionId: string, own?: number) => Promise<Holder[]>;
  emit: (event: "chat.message" | "chat.delta", data: unknown) => void;
  changed: () => void; // its line in the list changed
  save: () => void; // its record changed
  mapOptions: () => Omit<PalMapOptions, "pal">;
  appendPrompt: () => string;
  /** A card of its waits on the owner (the push, at most once per Pal every 10 minutes). */
  onWaiting: (pal: PalSession, body: string, ids: { approvalId?: string; questionId?: string }) => void;
  /** A turn ended (its spending is checked). */
  onTurnEnd: (pal: PalSession) => void;
  /** It stopped by itself for good (couldn't start again, or opened elsewhere). */
  onStopped: (pal: PalSession) => void;
  pidAlive: (pid: number) => boolean;
  kill: (pid: number, signal: NodeJS.Signals) => void;
  timing: { readyMs: number; restartMs: number[]; exitWaitMs: number };
  now: () => number;
  log: (s: string) => void;
}

const MAX_FAILURES = 5; // restarts within FAILURE_WINDOW_MS before it stays stopped
const FAILURE_WINDOW_MS = 10 * 60_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class PalSession {
  private proc: MainSession | null = null;
  private up = false; // the process answered and is ours to talk to
  private starting: Promise<void> | null = null;
  private restartTimer: ReturnType<typeof setTimeout> | null = null;
  private queued = false; // the host will start it in a moment (its own start)
  private closing = false;
  private exited: Promise<void> = Promise.resolve();
  private stderrTail = "";
  private failures: number[] = [];
  private turnOpen = false;
  private pendingUuids = new Set<string>();
  private interrupted = false;
  private activity = "";
  private streamId: string | null = null;
  private streamText = "";
  private replyTexts = new Map<string, string>(); // a reply's text so far, by its id (several blocks join)
  private emitted = new Set<string>(); // ids already sent to the app
  private follower: TranscriptFollower | null = null;
  private lastLine?: string;
  private updatedAt: number;
  model?: string;

  constructor(
    readonly rec: PalRecord,
    private d: PalSessionDeps,
  ) {
    this.updatedAt = rec.lastUsedAt;
    const tail = readTail(this.transcript, 512 * 1024);
    this.lastLine = transcriptLastLine(tail);
    // Its model entries are written when it starts: the beginning has one too.
    if (!rec.model) rec.model = transcriptModel([...readHead(this.transcript, 256 * 1024), ...tail]) ?? undefined;
    this.model = rec.model;
  }

  get id(): string {
    return this.rec.id;
  }

  get transcript(): string {
    return transcriptPath(this.d.claudeDir, this.rec.cwd, this.rec.sessionId);
  }

  /** Claude Code's pid while it runs. */
  get pid(): number | undefined {
    return this.up || this.starting ? this.rec.pid : undefined;
  }

  get running(): boolean {
    return this.up && !!this.proc && !this.proc.closed;
  }

  get busy(): boolean {
    return this.turnOpen || this.pendingUuids.size > 0;
  }

  // ---------------- the list ----------------

  source(): CardSource {
    return { kind: "pal", id: this.rec.id, name: this.rec.name };
  }

  private mine(s?: CardSource): boolean {
    return s?.kind === "pal" && s.id === this.rec.id;
  }

  pendingCards(): number {
    return this.d.approvals.listPending().filter((a) => this.mine(a.source)).length + this.d.questions.listPending().filter((q) => this.mine(q.source)).length;
  }

  status(): PalStatus {
    if (this.rec.stoppedFor) return "stopped";
    if (!this.up) return this.starting || this.restartTimer || this.queued ? "starting" : "stopped";
    if (this.pendingCards() > 0) return "waiting";
    return this.busy ? "busy" : "idle";
  }

  toWire(): Pal {
    const status = this.status();
    return {
      id: this.rec.id,
      name: this.rec.name,
      cwd: this.rec.cwd,
      sessionId: this.rec.sessionId,
      status,
      ...(status === "busy" ? { activity: this.activity || ACTIVITY.thinking } : {}),
      ...(status === "stopped" && this.rec.note ? { note: this.rec.note } : {}),
      ...(this.lastLine ? { lastLine: this.lastLine } : {}),
      pending: this.pendingCards(),
      ...(this.model ? { model: this.model } : {}),
      createdBy: this.rec.createdBy,
      updatedAt: Math.round(this.updatedAt),
    };
  }

  private touch(): void {
    this.updatedAt = this.d.now();
    this.d.changed();
  }

  // ---------------- the process ----------------

  /** The host starts it shortly (at its own start, a few seconds apart): it shows as starting. */
  queueStart(): void {
    this.queued = true;
  }

  /** Starts (or resumes) its process; resolves once Claude Code is up. */
  start(): Promise<void> {
    this.queued = false;
    if (this.running) return Promise.resolve();
    if (this.starting) return this.starting;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = null;
    this.closing = false;
    this.starting = this.doStart().finally(() => {
      this.starting = null;
      this.d.changed();
    });
    this.d.changed();
    return this.starting;
  }

  private async doStart(retry = false): Promise<void> {
    const { rec } = this;
    // Never two writers: a process of ours the host lost track of (it died
    // and left Claude Code running) is stopped; anyone else's means wait.
    let holders = await this.d.holders(rec.sessionId);
    const orphans = holders.filter((h) => h.pid === rec.pid);
    for (const o of orphans) {
      this.d.log(`pal ${rec.name}: stopping its old process ${o.pid}`);
      await this.killPid(o.pid);
    }
    if (orphans.length) holders = await this.d.holders(rec.sessionId);
    if (holders.length) throw new HeldElsewhere(`「${rec.name}」在别处开着（进程 ${holders.map((h) => h.pid).join("、")}），没有接着跑`);
    if (this.closing) throw new Error("已经关了");

    const launch = await this.d.launch();
    let exitDone!: () => void;
    const exited = new Promise<void>((r) => (exitDone = r));
    this.exited = Promise.resolve(); // nothing to wait for until a process is started
    this.stderrTail = "";
    rec.pid = undefined;
    const spawner = makeSpawner(launch.helper, {
      onPid: (pid) => {
        rec.pid = pid;
        this.d.save();
      },
      onExit: () => exitDone(),
      stderr: (s) => (this.stderrTail = (this.stderrTail + s).slice(-2000)),
    });
    const spawn: typeof spawner = (req) => {
      this.exited = exited;
      return spawner(req);
    };
    // A Pal the assistant opened has no transcript before its first message.
    const resume = existsSync(this.transcript);
    const proc: MainSession = this.d.driver.startPal({
      cwd: rec.cwd,
      ...(resume ? { resumeSessionId: rec.sessionId } : { sessionId: rec.sessionId }),
      model: rec.model,
      permissionMode: rec.permissionMode,
      appendSystemPrompt: this.d.appendPrompt(),
      name: rec.name,
      spawn,
      baseEnv: launch.env,
      ownerOrigin: true,
      canUseTool: (req) => this.canUseTool(req),
      onEvent: (e) => {
        if (proc === this.proc) this.onEvent(e);
      },
      onExit: (err) => this.onExit(proc, err),
      stderr: (s) => (this.stderrTail = (this.stderrTail + s).slice(-2000)),
    });
    this.proc = proc;
    this.up = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        proc.ready(),
        new Promise<never>((_, rej) => (timer = setTimeout(() => rej(new Error("Claude Code 没有按时起来")), this.d.timing.readyMs))),
      ]);
    } catch (e) {
      clearTimeout(timer);
      this.proc = null;
      proc.close();
      await this.waitExit();
      const why = `${e instanceof Error ? e.message : e}\n${this.stderrTail}`;
      if (launch.helper && !retry && isHelperFailure(why)) {
        this.d.helperFailed(firstLine(why.slice(why.indexOf("PaloAlly Helper:"))));
        return this.doStart(true);
      }
      throw new Error(startError(why));
    }
    clearTimeout(timer);
    if (this.closing || proc !== this.proc) {
      proc.close();
      throw new Error("已经关了");
    }
    this.up = true;
    this.follower?.stop();
    this.follower = new TranscriptFollower(this.transcript, (e) => this.onTranscript(e));
    this.follower.start();
    this.d.log(`pal ${rec.name}: up (pid ${rec.pid ?? "?"}, ${launch.helper ? "through PaloAlly Helper" : "direct"}${resume ? ", resumed" : ""})`);
  }

  private async waitExit(): Promise<void> {
    await Promise.race([this.exited, sleep(this.d.timing.exitWaitMs)]);
    const pid = this.rec.pid;
    if (pid && this.d.pidAlive(pid)) await this.killPid(pid);
  }

  private async killPid(pid: number): Promise<void> {
    try {
      this.d.kill(pid, "SIGTERM");
    } catch {
      return;
    }
    for (let i = 0; i < 30 && this.d.pidAlive(pid); i++) await sleep(100);
    if (this.d.pidAlive(pid)) {
      try {
        this.d.kill(pid, "SIGKILL");
      } catch {
        /* gone */
      }
      for (let i = 0; i < 20 && this.d.pidAlive(pid); i++) await sleep(100);
    }
  }

  // Its process ended without being asked to: back it comes (always on),
  // unless it keeps failing.
  private onExit(proc: MainSession, err?: string): void {
    if (proc !== this.proc || this.closing || !this.up) return;
    this.d.log(`pal ${this.rec.name}: its process ended (${err ?? "no error"})`);
    this.down("它的进程意外退出了");
    const now = this.d.now();
    this.failures = [...this.failures.filter((t) => now - t < FAILURE_WINDOW_MS), now];
    if (this.failures.length > MAX_FAILURES) {
      this.stopFor("failed", `接连 ${MAX_FAILURES} 次意外退出：${startError(err ?? this.stderrTail)}`);
      return;
    }
    const delays = this.d.timing.restartMs;
    const delay = delays[Math.min(this.failures.length - 1, delays.length - 1)] ?? 2_000;
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start().catch((e) => {
        if (e instanceof HeldElsewhere) this.stopFor("elsewhere", e.message);
        else this.onExitRetry(e);
      });
    }, delay);
    this.d.changed();
  }

  private onExitRetry(e: unknown): void {
    // Counted like an exit: try again later, give up after a few.
    const now = this.d.now();
    this.failures = [...this.failures.filter((t) => now - t < FAILURE_WINDOW_MS), now];
    if (this.failures.length > MAX_FAILURES) return this.stopFor("failed", startError(e instanceof Error ? e.message : String(e)));
    const delays = this.d.timing.restartMs;
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start().catch((err) => (err instanceof HeldElsewhere ? this.stopFor("elsewhere", err.message) : this.onExitRetry(err)));
    }, delays[Math.min(this.failures.length - 1, delays.length - 1)] ?? 2_000);
    this.d.changed();
  }

  // Not running any more: whatever was streaming is closed, its cards go.
  private down(why: string): void {
    this.up = false;
    this.proc = null;
    this.follower?.stop();
    this.follower = null;
    this.closeStream();
    const wasBusy = this.busy;
    this.turnOpen = false;
    this.pendingUuids.clear();
    this.activity = "";
    this.dropCards(why);
    if (wasBusy && !this.closing) this.notice("刚才这一轮被打断了（它的进程意外退出）。我会自动把它接上，再跟它说一次就行。");
  }

  private dropCards(by: string): void {
    this.d.approvals.denyFor(this.rec.id, by);
    this.d.questions.cancelFor(this.rec.id, by);
  }

  /** Stopped for good, with a reason the list shows; the owner's words bring it back. */
  stopFor(why: NonNullable<PalRecord["stoppedFor"]>, note: string): void {
    this.rec.stoppedFor = why;
    this.rec.note = note;
    this.d.save();
    void this.shutdown().then(() => {
      this.d.changed();
      this.d.onStopped(this);
    });
  }

  /** Stopped without a process to end (it never came up). */
  markStopped(why: NonNullable<PalRecord["stoppedFor"]>, note: string): void {
    this.rec.stoppedFor = why;
    this.rec.note = note;
    this.d.save();
    this.d.changed();
  }

  /** Clears a stop (the owner spoke to it, or a new day for its spending). */
  clearStop(): void {
    if (!this.rec.stoppedFor) return;
    this.rec.stoppedFor = undefined;
    this.rec.budgetDay = undefined;
    this.rec.note = undefined;
    this.failures = [];
    this.d.save();
  }

  /** Ends its process and waits until it's really gone (nothing writes its transcript after this). */
  async shutdown(): Promise<void> {
    this.closing = true;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = null;
    const starting = this.starting;
    const proc = this.proc;
    this.down("关掉了");
    proc?.close();
    if (starting) await starting.catch(() => {});
    await this.waitExit();
    this.rec.pid = undefined;
    this.d.save();
  }

  /** The reply being streamed right now (all its text so far), for a page opened mid-reply. */
  streaming(): { id: string; text: string } | null {
    return this.streamId && this.streamText ? { id: this.streamId, text: this.streamText } : null;
  }

  // ---------------- the owner's words ----------------

  /** The owner's words (or the assistant's handover, `from`), into the session as typed. */
  async send(text: string, o: { clientMsgId?: string; from?: string } = {}): Promise<ChatMessage> {
    const t = text.trim();
    if (!t) throw new Error("要说的话不能是空的");
    if (this.rec.stoppedFor) this.clearStop();
    try {
      await this.start();
    } catch (e) {
      // Still open somewhere else: it stays stopped, saying so.
      if (e instanceof HeldElsewhere) this.markStopped("elsewhere", e.message);
      throw e;
    }
    const proc = this.proc;
    if (!proc || !this.up) throw new Error(`「${this.rec.name}」现在没在跑`);
    const uuid = randomUUID();
    const ts = this.d.now();
    const msg: ChatMessage = {
      seq: ts,
      id: uuid,
      role: "user",
      kind: "text",
      text: t,
      channel: o.from ? "system" : "app",
      ts,
      pal: this.rec.id,
      ...(o.clientMsgId ? { clientMsgId: o.clientMsgId } : {}),
      ...(o.from ? { from: o.from } : {}),
    };
    this.emitted.add(uuid);
    this.d.emit("chat.message", msg);
    this.pendingUuids.add(uuid);
    this.rec.lastUsedAt = ts;
    this.d.save();
    proc.send(t, uuid);
    this.touch();
    return msg;
  }

  /** 停止: ends the current turn; its open cards are answered no. */
  async interrupt(by: string): Promise<void> {
    this.dropCards(`stop:${by}`);
    if (!this.busy || !this.proc) return;
    this.interrupted = true;
    await this.proc.interrupt();
    // Claude Code ends the turn with a result; if it doesn't, end it here.
    setTimeout(() => {
      if (this.interrupted && this.busy) this.endTurn();
    }, 5_000).unref?.();
  }

  // ---------------- what it says ----------------

  private chat(msg: Omit<ChatMessage, "seq" | "ts" | "pal" | "channel"> & { channel?: ChatMessage["channel"] }): void {
    const ts = this.d.now();
    this.d.emit("chat.message", { seq: ts, ts, channel: "app", ...msg, pal: this.rec.id });
  }

  private notice(text: string): void {
    this.chat({ id: newId("m_"), role: "system", kind: "notice", text, channel: "system" });
  }

  private beginTurn(): void {
    if (this.turnOpen) return;
    this.turnOpen = true;
    this.activity = "";
    this.touch();
  }

  private endTurn(): void {
    this.closeStream();
    this.turnOpen = false;
    this.pendingUuids.clear();
    this.interrupted = false;
    this.activity = "";
    this.touch();
  }

  // A reply cut off mid-stream still gets its final message, so the app
  // doesn't keep a half-written bubble open.
  private closeStream(): void {
    if (this.streamId && this.streamText.trim() && !this.replyTexts.has(this.streamId)) {
      this.chat({ id: this.streamId, role: "assistant", kind: "text", text: this.streamText });
    }
    this.streamId = null;
    this.streamText = "";
  }

  private setActivity(a: string | null): void {
    if (a === null || a === this.activity) return;
    this.activity = a;
    this.d.changed();
  }

  private onEvent(e: HarnessEvent): void {
    switch (e.type) {
      case "init":
        if (e.model && e.model !== this.model) {
          this.model = e.model;
          this.rec.model = e.model;
          this.d.save();
        }
        this.beginTurn();
        // A turn it started by itself is often another session's message: show it.
        setTimeout(() => this.follower?.poke(), 300).unref?.();
        break;
      case "text_delta": {
        this.beginTurn();
        const id = e.messageId ?? this.streamId ?? newId("m_");
        if (id !== this.streamId) {
          this.closeStream();
          this.streamId = id;
          // a second text block of the same reply goes on after a blank line
          if (this.replyTexts.has(id)) this.d.emit("chat.delta", { id, text: "\n\n", pal: this.rec.id });
        }
        this.streamText += e.text;
        this.d.emit("chat.delta", { id, text: e.text, pal: this.rec.id });
        this.setActivity(ACTIVITY.reply);
        break;
      }
      case "assistant_text": {
        if (e.parentToolUseId) break;
        this.beginTurn();
        const id = e.messageId ?? this.streamId ?? newId("m_");
        const before = this.replyTexts.get(id);
        const text = before ? `${before}\n\n${e.text}` : e.text;
        this.replyTexts.set(id, text);
        if (this.replyTexts.size > 50) this.replyTexts.delete(this.replyTexts.keys().next().value!);
        this.emitted.add(id);
        this.chat({ id, role: "assistant", kind: "text", text });
        if (id === this.streamId) {
          this.streamId = null;
          this.streamText = "";
        }
        this.lastLine = firstLine(e.text) || this.lastLine;
        this.touch();
        break;
      }
      case "tool_start":
      case "tool_use":
        if (e.parentToolUseId) break;
        this.beginTurn();
        this.setActivity(describeActivity(e.name));
        break;
      case "result": {
        for (const u of e.consumedUuids ?? [...this.pendingUuids]) this.pendingUuids.delete(u);
        if (e.isError && !this.interrupted && !e.startupFailure) this.notice(friendlyError(e.text, e.errorCategory));
        this.rec.lastUsedAt = this.d.now();
        if (this.pendingUuids.size) {
          this.closeStream();
          this.turnOpen = false;
          this.touch();
        } else this.endTurn();
        this.follower?.poke();
        this.d.onTurnEnd(this);
        break;
      }
      case "error":
        this.d.log(`pal ${this.rec.name}: ${e.message}`);
        break;
    }
  }

  // Lines that reach it without passing through the host: another session's
  // SendMessage (the assistant's too), shown as said by that session.
  private onTranscript(e: any): void {
    if (e?.type !== "user" || e.isSidechain) return;
    const m = userEntryMessage(
      { type: "user", uuid: String(e.uuid ?? ""), message: e.message, timestamp: e.timestamp, origin: e.origin, parent_tool_use_id: null },
      { ...this.d.mapOptions(), pal: this.rec.id },
    );
    if (!m || !m.id || this.emitted.has(m.id)) return;
    this.emitted.add(m.id);
    if (this.emitted.size > 500) this.emitted.delete(this.emitted.values().next().value!);
    this.d.emit("chat.message", m);
    this.touch();
  }

  // ---------------- its cards ----------------

  private async canUseTool(req: PermissionRequest): Promise<PermissionDecision> {
    const source = this.source();
    if (req.toolName === ASK_TOOL) {
      const asked = this.d.questions.ask(req, { source, notify: false });
      if (!asked) return { behavior: "deny", message: "问题格式不对，没法问主人" };
      this.d.changed();
      this.d.onWaiting(this, `问你：${asked.question.items[0]!.question}`, { questionId: asked.question.id });
      const r = await asked.result;
      this.d.changed();
      return r;
    }
    const input = req.input;
    // The whole command, never cut short.
    const detail = req.toolName === "Bash" && typeof input.command === "string" ? truncate(input.command, 100_000) : describeInput(req.toolName, input);
    const asked = this.d.approvals.ask(req, { source, notify: false, title: describeTool(req.toolName, input), detail });
    this.d.changed();
    const what = req.toolName === "Bash" && typeof input.command === "string" ? `想运行：${firstLine(input.command)}` : asked.approval.title;
    this.d.onWaiting(this, what, { approvalId: asked.approval.id });
    const r = await asked.result;
    this.d.changed();
    return r;
  }
}

// Claude Code's reason, in a line the owner can read.
export function startError(raw: string): string {
  const s = String(raw ?? "");
  if (/running in the background|session_held_by_background/i.test(s)) return "它还在后台跑着，先停掉它";
  if (/No conversation found|not found.*session|session.*not found/i.test(s)) return "找不到它的对话记录";
  if (/not logged in|authentication|401/i.test(s)) return "Claude Code 没登录";
  const line = s
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l && !/^at /.test(l));
  return truncate(line?.replace(/^Error:\s*/, "") ?? "没起来", 160);
}
