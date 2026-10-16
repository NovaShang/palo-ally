import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import type { ApprovalManager } from "./approvals.ts";
import { firstLine } from "./ccSessions.ts";
import { ACTIVITY, describeActivity, describeInput, describeTool, friendlyError } from "./copy.ts";
import { readHead, readTail, transcriptPath } from "./handoffs.ts";
import type { FilesRewound, HarnessDriver, HarnessEvent, MainSession, PermissionDecision, PermissionRequest } from "./harness/types.ts";
import { type PalLaunch, isHelperFailure, makeSpawner } from "./palLauncher.ts";
import { type PalMapOptions, TranscriptFollower, toPalMessages, transcriptLastLine, transcriptModel, userEntryMessage } from "./palHistory.ts";
import { ASK_TOOL, type QuestionManager } from "./questions.ts";
import { type ForkSession, type PendingRewind, REWIND_BUSY, REWIND_NOT_FOUND, REWIND_NO_FILES, beforeCompaction, chainTo, hasFileCheckpoint, leafOf, ownerText, readTranscript } from "./rewind.ts";
import { type StallRecovery, type StallTarget, transcriptHas } from "./stallWatch.ts";
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
// Idle a while, it's put to sleep (§12): its process ends, its record stays;
// the next word for it (or 叫醒) resumes the same session first. Words that
// come in meanwhile wait their turn and go in in the order they came.

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
  status?: "asleep"; // put to sleep (§12): no process until it's woken; absent = awake
  formerNames?: string[]; // what it was called before (§13): the assistant may still say one
  lastWakeUsd?: number; // what the first turn after its last wake cost
  costTotalUsd?: number; // Claude Code's running total for the session, as its last result said
  // 回到这里重来 (docs/rewind-prd.md §4.1): sessionId is a fork of `from` that
  // Claude Code hasn't written yet; each start forks it until it has.
  rewind?: PendingRewind;
  formerSessions?: string[]; // the sessions it was forked from (theirs too: not listed among the ended ones)
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
  /** It was asleep and is up again. */
  onWoke?: (pal: PalSession) => void;
  /** Right before its process starts: its name is read back from Claude Code's title (§13). */
  beforeStart?: (pal: PalSession) => Promise<void>;
  /** It stopped by itself for good (couldn't start again, or opened elsewhere). */
  onStopped: (pal: PalSession) => void;
  pidAlive: (pid: number) => boolean;
  kill: (pid: number, signal: NodeJS.Signals) => void;
  /** Copies a session up to one entry as a new one (a rewind past a compaction). */
  forkSession: ForkSession;
  timing: { readyMs: number; restartMs: number[]; exitWaitMs: number };
  now: () => number;
  log: (s: string) => void;
}

const MAX_FAILURES = 5; // restarts within FAILURE_WINDOW_MS before it stays stopped
const FAILURE_WINDOW_MS = 10 * 60_000;
const STOP_SETTLE_MS = 250; // a stopped turn not ended by Claude Code by then is ended here

/** What a Pal is told after the watchdog restarted it mid-turn. */
export const STALL_CONTINUE = "（PaloAlly：你的进程刚才卡住了，已经重启并续上。请接着做上一轮没做完的事；已经做完的话，简单说一句就好。）";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Words from another session (the assistant's pal_send), as Claude Code shows a SendMessage. */
export function peerWrap(name: string, text: string): string {
  return `<cross-session-message from="paloally" from-name="${name.replace(/"/g, "")}">\n${text}\n</cross-session-message>`;
}

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
  private pendingText = new Map<string, { text: string; from?: string }>(); // the owner's words not yet taken, by uuid
  private openTools = new Map<string, string>(); // tool calls without a result yet (subagents' too): id → name
  private turnTools = new Set<string>(); // …those of its own turn: none outlives the turn's end
  private lastEventAt = 0;
  private interrupted = false;
  private windingDown = false; // ended here after 停止: what's left of that turn doesn't make it busy again
  private turnEndWaiters: (() => void)[] = [];
  private activity = "";
  private streamId: string | null = null;
  private streamText = "";
  private replyTexts = new Map<string, string>(); // a reply's text so far, by its id (several blocks join)
  private emitted = new Set<string>(); // ids already sent to the app
  private follower: TranscriptFollower | null = null;
  // A fork's entries copied from the session it was forked from: history, not news.
  private inherited: Set<string> | null = null;
  private sleeping: Promise<void> | null = null; // being put to sleep: its process is ending
  private upAt = 0;
  private bgTasks = new Set<string>(); // its background tasks still running (a subagent in the background)
  private sendChain: Promise<unknown> = Promise.resolve(); // words go in one after another, in order
  private queuedSends = 0; // words waiting to go in (it's being woken for them)
  private wakeCost = false; // woken: the next turn's cost is what waking cost
  private priorTotal: number | undefined; // its running total when this process started
  private firstResult = true;
  private lastLine?: string;
  private updatedAt: number;
  /** The name its process started under: other sessions' SendMessage reaches it by that until it starts again. */
  spawnedAs?: string;
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

  /** Put to sleep: no process (its record is kept); being put to sleep counts. */
  get asleep(): boolean {
    return this.rec.status === "asleep" && !this.up && !this.starting;
  }

  /** It has a process, or one is coming up: what counts towards the five awake. */
  get awake(): boolean {
    return !this.asleep && !this.rec.stoppedFor && (this.up || !!this.starting || !!this.restartTimer || this.queued);
  }

  /**
   * Since when it's had nothing on: no turn, no words it hasn't taken (nor
   * any waiting to go in), no card on the owner, no tool or background task
   * open. null: it isn't idle (or isn't running).
   */
  idleSince(): number | null {
    if (!this.running || this.starting || this.sleeping) return null;
    if (this.turnOpen || this.windingDown || this.pendingUuids.size || this.queuedSends || this.openTools.size || this.bgTasks.size) return null;
    if (this.pendingCards() > 0) return null;
    return Math.max(this.lastEventAt, this.rec.lastUsedAt, this.upAt);
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
    if (!this.up) return this.starting || this.restartTimer || this.queued ? "starting" : this.rec.status === "asleep" ? "asleep" : "stopped";
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
      ...(typeof this.rec.lastWakeUsd === "number" ? { lastWakeUsd: this.rec.lastWakeUsd } : {}),
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
    // Being put to sleep: once its process is gone, it's woken.
    if (this.sleeping) return this.sleeping.then(() => this.start());
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
    // Renamed while it had no process (in a terminal, say): it starts under that name.
    await this.d.beforeStart?.(this).catch(() => {});

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
    // One gone back to an earlier message is forked from its old session
    // until Claude Code has written the new one (docs/rewind-prd.md §4.1).
    const fork = this.pendingRewind();
    const resume = !fork && existsSync(this.transcript);
    this.inherited = fork ? new Set(chainTo(readTranscript(this.transcriptOf(fork.from)), fork.at).map((e) => e.uuid)) : null;
    const proc: MainSession = this.d.driver.startPal({
      cwd: rec.cwd,
      ...(resume ? { resumeSessionId: rec.sessionId } : { sessionId: rec.sessionId }),
      ...(fork?.at ? { fork: { fromSessionId: fork.from, at: fork.at } } : {}),
      // Its files can go back to how they were before any of the owner's messages from now on.
      fileCheckpointing: true,
      model: rec.model,
      // so a turn's cost is its own, not the session's running total
      ...(typeof rec.costTotalUsd === "number" ? { priorCostUsd: rec.costTotalUsd } : {}),
      permissionMode: rec.permissionMode,
      appendSystemPrompt: this.d.appendPrompt(),
      name: (this.spawnedAs = rec.name),
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
    this.upAt = this.d.now();
    this.priorTotal = rec.costTotalUsd;
    this.firstResult = true;
    const woke = rec.status === "asleep";
    if (woke) {
      delete rec.status;
      this.wakeCost = true;
      this.d.save();
    }
    this.follower?.stop();
    this.follower = new TranscriptFollower(this.transcript, (e) => this.onTranscript(e));
    this.follower.start();
    if (woke) this.d.onWoke?.(this);
    this.d.log(`pal ${rec.name}: up (pid ${rec.pid ?? "?"}, ${launch.helper ? "through PaloAlly Helper" : "direct"}${resume ? ", resumed" : fork ? ", forked" : ""}${woke ? ", woken" : ""})`);
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
    this.pendingText.clear();
    this.openTools.clear();
    this.turnTools.clear();
    this.bgTasks.clear();
    this.wakeCost = false;
    this.activity = "";
    this.windingDown = false;
    for (const w of this.turnEndWaiters.splice(0)) w();
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

  /**
   * Puts it to sleep (§12): its process ends cleanly, its record stays,
   * marked asleep (also across the host's restarts); the next start wakes it.
   */
  sleep(): Promise<void> {
    if (this.sleeping) return this.sleeping;
    this.rec.status = "asleep";
    this.d.save();
    this.sleeping = this.shutdown().finally(() => {
      this.sleeping = null;
      this.d.changed();
    });
    this.d.changed();
    return this.sleeping;
  }

  /** Marked asleep without a process to end (the host's start, past five awake). */
  markAsleep(): void {
    this.rec.status = "asleep";
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

  /**
   * Retitles the session in its running process (Claude Code's own rename,
   * as a rename in an IDE is), so the process keeps the new title and
   * writes it, not the old one. False: there's no process to ask.
   */
  async renameLive(title: string): Promise<boolean> {
    const proc = this.proc;
    if (!this.running || !proc?.rename) return false;
    await proc.rename(title, this.rec.sessionId);
    return true;
  }

  /** The reply being streamed right now (all its text so far), for a page opened mid-reply. */
  streaming(): { id: string; text: string } | null {
    return this.streamId && this.streamText ? { id: this.streamId, text: this.streamText } : null;
  }

  // ---------------- the stall watchdog ----------------

  /** What the stall watchdog watches (stallWatch.ts). */
  stallTarget(): StallTarget {
    return {
      key: this.rec.id,
      name: this.rec.name,
      busy: () => this.running && this.busy,
      waiting: () => this.pendingCards() > 0,
      openTools: () => [...this.openTools.values()],
      lastActivity: () => Math.max(this.lastEventAt, this.proc?.lastActivity ?? 0),
      pid: () => this.pid,
      transcript: () => this.transcript,
      recover: () => this.recoverStall(),
    };
  }

  /**
   * Its process froze mid-work: it's ended (killed if it must be) and the
   * same session resumes. The owner's words it never took go in again (same
   * ids, so the app shows them once); a turn it was in is asked to go on.
   */
  async recoverStall(): Promise<StallRecovery> {
    const inTurn = this.turnOpen || this.pendingUuids.size > 0;
    const pending = [...this.pendingText];
    await this.shutdown();
    // Nothing writes its transcript now: what's in it was taken.
    const untaken = pending.filter(([uuid]) => !transcriptHas(this.transcript, uuid));
    this.d.log(`pal ${this.rec.name}: stalled; resuming it (${untaken.length} message(s) to send again)`);
    await this.start();
    const proc = this.proc;
    if (!proc || !this.up) throw new Error(`「${this.rec.name}」没能重新起来`);
    this.notice("刚才卡住了，PaloAlly 已经自动重启它并续上。");
    for (const [uuid, p] of untaken) {
      this.pendingUuids.add(uuid);
      this.pendingText.set(uuid, p);
      proc.send(p.text, uuid);
    }
    let continued = false;
    if (!untaken.length && inTurn) {
      await this.send(STALL_CONTINUE, { from: "PaloAlly" });
      continued = true;
    }
    this.touch();
    return { resent: untaken.length, continued };
  }

  // ---------------- the owner's words ----------------

  /**
   * The owner's words (or the assistant's, `from`), into the session as
   * typed; asleep, it's woken first. Words go in one after another in the
   * order they came, also those that come while it's being woken. `peer`:
   * they're another session's (the assistant's pal_send), shown to it as a
   * SendMessage from that name.
   */
  send(text: string, o: { clientMsgId?: string; from?: string; peer?: string } = {}): Promise<ChatMessage> {
    const t = text.trim();
    if (!t) return Promise.reject(new Error("要说的话不能是空的"));
    this.queuedSends++;
    const run = this.sendChain.then(() => this.deliver(t, o)).finally(() => this.queuedSends--);
    this.sendChain = run.catch(() => {});
    return run;
  }

  private async deliver(t: string, o: { clientMsgId?: string; from?: string; peer?: string }): Promise<ChatMessage> {
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
    const content = o.peer ? peerWrap(o.peer, t) : t;
    this.pendingUuids.add(uuid);
    this.pendingText.set(uuid, { text: content, ...(o.from ? { from: o.from } : {}) });
    this.rec.lastUsedAt = ts;
    this.d.save();
    proc.send(content, uuid);
    this.windingDown = false;
    this.touch();
    return msg;
  }

  /**
   * 停止: ends the current turn; its open cards are answered no. The list
   * shows it stopped within a moment: Claude Code ends a stopped turn with
   * its result at once, and one it's slower to wind down (a tool that takes
   * a while to stop) is ended here, its late events not making it busy again.
   */
  async interrupt(by: string): Promise<void> {
    this.dropCards(`stop:${by}`);
    this.d.changed();
    const proc = this.proc;
    if (!this.busy || !proc) return;
    this.interrupted = true;
    const ended = new Promise<void>((r) => this.turnEndWaiters.push(r));
    void proc.interrupt();
    await Promise.race([ended, sleep(STOP_SETTLE_MS)]);
    if (this.interrupted && this.busy && proc === this.proc) {
      this.endTurn();
      this.windingDown = true;
    }
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
    if (this.turnOpen || this.windingDown) return;
    this.turnOpen = true;
    this.activity = "";
    this.touch();
  }

  private endTurn(): void {
    this.closeStream();
    this.turnOpen = false;
    this.pendingUuids.clear();
    this.pendingText.clear();
    this.interrupted = false;
    this.activity = "";
    for (const w of this.turnEndWaiters.splice(0)) w();
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
    if (a === null || a === this.activity || this.windingDown) return;
    this.activity = a;
    this.d.changed();
  }

  private onEvent(e: HarnessEvent): void {
    this.lastEventAt = this.d.now();
    switch (e.type) {
      case "init":
        if (e.model && e.model !== this.model) {
          this.model = e.model;
          this.rec.model = e.model;
          this.d.save();
        }
        this.windingDown = false; // a new turn
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
      case "tool_result":
        this.openTools.delete(e.toolUseId);
        this.turnTools.delete(e.toolUseId);
        break;
      case "background_tasks":
        this.bgTasks = new Set(e.taskIds);
        break;
      case "task_notification":
        this.bgTasks.delete(e.taskId);
        break;
      case "tool_start":
      case "tool_use":
        if (e.type === "tool_use") this.openTools.set(e.id, e.name);
        if (e.parentToolUseId) break;
        if (e.type === "tool_use") this.turnTools.add(e.id);
        this.beginTurn();
        this.setActivity(describeActivity(e.name));
        break;
      case "result": {
        const stopped = this.interrupted || this.windingDown; // its error is the stop, not news
        this.windingDown = false;
        for (const u of e.consumedUuids ?? [...this.pendingUuids]) {
          this.pendingUuids.delete(u);
          this.pendingText.delete(u);
        }
        // its own tool calls end with the turn (a stopped one may not say so)
        for (const id of this.turnTools) this.openTools.delete(id);
        this.turnTools.clear();
        if (e.isError && !stopped && !e.startupFailure) this.notice(friendlyError(e.text, e.errorCategory));
        this.noteCost(e.costUsd, e.totalCostUsd);
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

  // A turn's cost: Claude Code's running total less what it was before. A
  // resumed process starts from the session's total so far (when Claude Code
  // kept it; otherwise from 0, and the turn's cost is the whole new total).
  // The first turn after a wake is what waking cost (the prompt cache has
  // mostly gone cold): kept for the list, unless the total before is unknown.
  private noteCost(costUsd: number, total: number): void {
    let cost: number | null = costUsd;
    if (this.firstResult) {
      this.firstResult = false;
      const prior = this.priorTotal;
      cost = prior === undefined ? null : total >= prior ? total - prior : total;
    }
    if (Number.isFinite(total)) this.rec.costTotalUsd = total;
    if (this.wakeCost) {
      this.wakeCost = false;
      if (cost !== null && Number.isFinite(cost)) {
        this.rec.lastWakeUsd = Math.round(cost * 10_000) / 10_000;
        this.d.log(`pal ${this.rec.name}: waking cost $${cost.toFixed(4)}`);
      }
    }
    this.d.save();
  }

  // Lines that reach it without passing through the host: another session's
  // SendMessage (the assistant's too), shown as said by that session.
  private onTranscript(e: any): void {
    if (e?.type !== "user" || e.isSidechain) return;
    if (this.inherited?.has(String(e.uuid ?? ""))) return;
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

  // ---------------- 回到这里重来 (docs/rewind-prd.md) ----------------

  private transcriptOf(sessionId: string): string {
    return transcriptPath(this.d.claudeDir, this.rec.cwd, sessionId);
  }

  /** A rewind whose fork Claude Code hasn't written yet (none once it has). */
  pendingRewind(): PendingRewind | undefined {
    const r = this.rec.rewind;
    if (!r) return undefined;
    if (existsSync(this.transcript)) {
      delete this.rec.rewind;
      this.d.save();
      return undefined;
    }
    return r;
  }

  /**
   * Its conversation as it stands, from the transcript: the session's own
   * (the last entry's line of parents), or, gone back and not spoken to
   * since, the old session's up to where it was cut. Oldest first.
   */
  conversationEntries(): { sessionId: string; entries: any[]; chain: any[]; pending?: PendingRewind } {
    const pending = this.pendingRewind();
    const sessionId = pending ? pending.from : this.rec.sessionId;
    const entries = readTranscript(this.transcriptOf(sessionId));
    return { sessionId, entries, chain: chainTo(entries, pending ? pending.at : leafOf(entries)), ...(pending ? { pending } : {}) };
  }

  /** Whether its files can go back to how they were before the owner's message `uuid`. */
  canRestoreFiles(uuid: string): boolean {
    return hasFileCheckpoint(this.conversationEntries().entries, uuid);
  }

  /**
   * Goes back to just before the owner's message `uuid` (in its current
   * conversation): its process ends, its files go back too if asked (Claude
   * Code's own checkpoints, through a process on the old session that says
   * nothing), and its next process is a new session forked from the entry
   * before that message. One that was awake comes back at once; one asleep
   * stays asleep. Refused while a turn is on. Returns the message's words and
   * the ids of the messages that left the conversation.
   */
  async rewind(uuid: string, restoreFiles: boolean): Promise<{ text: string; filesRestored: boolean; dropped: string[]; from: string; at: string | null; copied: boolean }> {
    // (A turn stopped but still winding down is no matter: its process ends here.)
    if (this.busy || this.starting || this.sleeping || this.queuedSends || this.pendingCards() > 0) throw new Error(REWIND_BUSY);
    const { sessionId, entries, chain } = this.conversationEntries();
    const i = chain.findIndex((e) => e.uuid === uuid);
    if (i < 0) throw new Error(REWIND_NOT_FOUND);
    const entry = chain[i];
    const text = ownerText(entry);
    // The owner's own words only: not the assistant's (pal_send), not another session's.
    if (text === null || /^\s*<cross-session-message/.test(text) || (this.rec.duty && i === chain.findIndex((e) => ownerText(e) !== null) && text.trim() === this.rec.duty.trim()))
      throw new Error("这一条不是你说的，不能回到这里");
    if (restoreFiles && !hasFileCheckpoint(entries, uuid)) throw new Error(REWIND_NO_FILES);
    const held = await this.d.holders(sessionId, this.rec.pid);
    if (held.length) throw new HeldElsewhere(`「${this.rec.name}」在别处开着（进程 ${held.map((h) => h.pid).join("、")}），先在那边退出`);
    const awake = this.running || !!this.restartTimer || this.queued;
    await this.shutdown();
    if (restoreFiles) {
      const r = await this.restoreFiles(sessionId, uuid);
      if (!r.canRewind) {
        this.d.log(`pal ${this.rec.name}: files not restored (${r.error ?? "no reason"})`);
        if (awake) await this.start().catch((e) => this.d.log(`pal ${this.rec.name}: couldn't start again: ${e instanceof Error ? e.message : e}`));
        throw new Error(REWIND_NO_FILES);
      }
    }
    const dropped = toPalMessages(chain.slice(i), { ...this.d.mapOptions(), pal: this.rec.id }).map((m) => m.id);
    const at = typeof entry.parentUuid === "string" ? entry.parentUuid : typeof entry.logicalParentUuid === "string" ? entry.logicalParentUuid : null;
    // Before its last compaction: copied into a new session up to there now
    // (new uuids); otherwise forked by its next process.
    const copied = beforeCompaction(chain, at);
    if (copied) {
      try {
        this.rec.sessionId = (await this.d.forkSession(sessionId, { dir: this.rec.cwd, upToMessageId: at!, title: this.rec.name })).sessionId;
      } catch (e) {
        if (awake) await this.start().catch(() => {});
        throw new Error(`没能回到这里：${e instanceof Error ? e.message : e}`);
      }
      delete this.rec.rewind;
    } else {
      this.rec.rewind = { from: sessionId, at, cut: uuid };
      this.rec.sessionId = randomUUID();
    }
    this.rec.formerSessions = [...(this.rec.formerSessions ?? []).filter((x) => x !== sessionId), sessionId].slice(-20);
    this.lastLine = transcriptLastLine(chain.slice(0, i));
    this.rec.lastUsedAt = this.d.now();
    this.d.save();
    this.touch();
    if (awake) await this.start().catch((e) => this.d.log(`pal ${this.rec.name}: couldn't start again: ${e instanceof Error ? e.message : e}`));
    return { text: text.trim(), filesRestored: restoreFiles, dropped, from: sessionId, at, copied };
  }

  // Claude Code puts the files back (rewindFiles) in a process of its own on
  // the old session: it's only asked that, never spoken to.
  private async restoreFiles(sessionId: string, uuid: string): Promise<FilesRewound> {
    const launch = await this.d.launch();
    let exitDone!: () => void;
    const exited = new Promise<void>((r) => (exitDone = r));
    let pid: number | undefined;
    let spawned = false;
    const spawner = makeSpawner(launch.helper, { onPid: (p) => (pid = p), onExit: () => exitDone(), stderr: () => {} });
    const proc = this.d.driver.startPal({
      cwd: this.rec.cwd,
      resumeSessionId: sessionId,
      model: this.rec.model,
      permissionMode: this.rec.permissionMode,
      fileCheckpointing: true,
      spawn: (req) => {
        spawned = true;
        return spawner(req);
      },
      baseEnv: launch.env,
      canUseTool: async () => ({ behavior: "deny", message: "只是在恢复文件" }),
      onEvent: () => {},
    });
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([proc.ready(), new Promise<never>((_, rej) => (timer = setTimeout(() => rej(new Error("Claude Code 没有按时起来")), this.d.timing.readyMs)))]);
      if (!proc.rewindFiles) return { canRewind: false, error: "这个版本的 Claude Code 不能恢复文件" };
      return await proc.rewindFiles(uuid);
    } catch (e) {
      return { canRewind: false, error: e instanceof Error ? e.message : String(e) };
    } finally {
      clearTimeout(timer);
      proc.close();
      if (spawned) await Promise.race([exited, sleep(this.d.timing.exitWaitMs)]);
      if (pid && this.d.pidAlive(pid)) await this.killPid(pid);
    }
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
