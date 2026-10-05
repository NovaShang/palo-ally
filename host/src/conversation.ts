import { randomUUID } from "node:crypto";
import type { ApprovalManager } from "./approvals.ts";
import type { Audit } from "./audit.ts";
import type { WechatChannel, WechatReplyTarget } from "./channels/types.ts";
import type { ChatLog } from "./chat.ts";
import type { Config, Paths } from "./config.ts";
import { ACTIVITY_BACKGROUND, budgetNotice, describeActivity, friendlyError } from "./copy.ts";
import { BEHAVIOR } from "./home.ts";
import type { HarnessDriver, HarnessEvent, ImageInput, MainSession, ModelOption, SlashCommandInfo, ToolHandlers } from "./harness/types.ts";
import type { Router } from "./router.ts";
import type { RuntimeState } from "./runtime.ts";
import type { TaskTracker } from "./tasks.ts";
import type { Channel, Task } from "./types.ts";
import type { UsageLedger } from "./usage.ts";
import { appendJsonl, truncate } from "./util.ts";

export interface Turn {
  text: string; // what the model sees
  origin: Channel;
  proactive: boolean; // output is filtered for [skip] and routed as a push
  wechat?: WechatReplyTarget;
  implicit?: boolean; // harness started a turn on its own (e.g. a background task finished)
  label?: string;
  uuids?: string[]; // user messages this turn answers
  watchId?: string; // a schedule run: its reply becomes the goal's progress line
}

type OwnerMessage = { origin: Channel; wechat?: WechatReplyTarget };

const SKIP = /^\s*\[skip\]\s*$/i;

// A turn the harness started by itself is closed if it goes quiet without a result.
export const timing = { implicitQuietMs: 90_000 };

// stripSkip removes the "[skip]" marker a proactive turn uses to stay silent.
export function stripSkip(text: string): string {
  return text
    .split(/\n{2,}/)
    .filter((p) => !SKIP.test(p))
    .join("\n\n")
    .trim();
}

export interface ConversationDeps {
  paths: Paths;
  config: () => Config;
  driver: HarnessDriver;
  runtime: RuntimeState;
  chat: ChatLog;
  tasks: TaskTracker;
  approvals: ApprovalManager;
  router: Router;
  wechat: WechatChannel | null;
  audit: Audit;
  usage: UsageLedger;
  tools: () => ToolHandlers;
  mcpServers: () => Record<string, unknown>;
  // every harness event goes through here (the hub routes it back to onHarnessEvent)
  onEvent: (e: HarnessEvent) => void;
  onCommands: (cmds: SlashCommandInfo[]) => void;
  onModels: (models: ModelOption[]) => void;
  onTerminalCommands: (names: string[]) => void;
  statusChanged: () => void;
  // a schedule run answered: record it as the goal's progress line
  onGoalResult?: (watchId: string, text: string) => void;
  metric: (m: Record<string, unknown>) => void;
  log: (s: string) => void;
}

// Conversation is the one main conversation with the harness: it owns the CLI
// process, decides which output belongs to whom (owner reply vs proactive),
// and keeps proactive turns waiting until the harness is idle.
export class Conversation {
  model = ""; // the model the harness reports running
  activity = "";
  private session: MainSession | null = null;
  private queue: Turn[] = [];
  private current: Turn | null = null;
  private turnTexts: string[] = [];
  // WeChat turns get each paragraph as it's written (in order), not just the end.
  private wechatStreamed = 0;
  private wechatChain: Promise<void> = Promise.resolve();
  private deltaId: string | null = null;
  private deltaText = ""; // streamed text of the current delta id, to finalize if the turn dies
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private implicitTimer: ReturnType<typeof setTimeout> | null = null;
  private lastContextTokens = 0;
  private turnWaiters: (() => void)[] = [];
  // Every owner message sent to the harness and not yet answered, by uuid.
  // A turn counts as answering the owner only once its result lists the uuid.
  private pending = new Map<string, OwnerMessage & { sentAt: number }>();
  private openTools = new Set<string>(); // main-thread tool calls without a result yet
  private budgetNoticeDay = "";

  constructor(private d: ConversationDeps) {}

  get busy(): boolean {
    return this.current !== null;
  }

  // Nothing in flight at all (safe to restart the process).
  get quiet(): boolean {
    return !this.current && !this.queue.length && !this.pending.size;
  }

  // Resolves when the turn queue is drained (tests, CLI one-shots).
  idle(): Promise<void> {
    if (this.quiet) return Promise.resolve();
    return new Promise((r) => this.turnWaiters.push(r));
  }

  hasQueued(pred: (t: Turn) => boolean): boolean {
    return this.queue.some(pred);
  }

  // ---------------- inputs ----------------

  // Owner messages go to the harness immediately, even mid-turn: Claude Code
  // queues them or folds them into the running turn, so "好了吗" gets heard
  // while work is in progress. Only proactive turns wait for idle.
  sendOwner(text: string, origin: Channel, wechat?: WechatReplyTarget, images?: ImageInput[]): void {
    const uuid = randomUUID();
    this.pending.set(uuid, { origin, wechat, sentAt: Date.now() });
    if (!this.current) this.beginTurn({ text, origin, proactive: false, wechat, uuids: [uuid] });
    this.ensureSession().send(text, uuid, images);
  }

  enqueue(turn: Turn): void {
    this.queue.push(turn);
    this.pump();
  }

  private pump(): void {
    this.expirePending();
    if (this.current || this.pending.size || !this.queue.length) {
      this.flushWaitersIfIdle();
      return;
    }
    const turn = this.queue.shift()!;
    if (turn.proactive && this.d.usage.over("mainUsd", this.d.config().budget.mainDailyUsd)) {
      this.d.log(`proactive turn dropped: main budget used up (${turn.label ?? turn.origin})`);
      const day = this.d.usage.today().day;
      if (this.budgetNoticeDay !== day) {
        this.budgetNoticeDay = day;
        this.d.chat.add({ role: "system", kind: "notice", text: budgetNotice(turn.label), channel: "system" });
      }
      return this.pump();
    }
    const uuid = randomUUID();
    this.beginTurn({ ...turn, uuids: [uuid] });
    this.ensureSession().send(turn.text, uuid);
  }

  // Owner messages the harness never answered (e.g. lost in a crash) stop
  // blocking proactive turns after a while.
  private expirePending(): void {
    const cutoff = Date.now() - 10 * 60_000;
    for (const [u, p] of this.pending) if (p.sentAt < cutoff && !this.current?.uuids?.includes(u)) this.pending.delete(u);
  }

  private beginTurn(turn: Turn): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.current = turn;
    this.turnTexts = [];
    this.wechatStreamed = 0;
    if (turn.wechat && !turn.proactive) void this.d.wechat?.startTyping?.(turn.wechat);
    this.deltaId = null;
    this.deltaText = "";
    this.openTools.clear();
    this.activity = "";
    if (turn.implicit) this.armImplicitTimer();
    this.d.statusChanged();
  }

  private armImplicitTimer(): void {
    if (this.implicitTimer) clearTimeout(this.implicitTimer);
    this.implicitTimer = setTimeout(() => {
      // Waiting on the owner or on a running tool is not "quiet".
      if (this.current?.implicit && (this.openTools.size || this.d.approvals.listPending().length)) return this.armImplicitTimer();
      if (this.current?.implicit) {
        this.d.log("implicit turn went quiet without a result; closing it");
        this.endTurn(0, this.lastContextTokens);
      }
    }, timing.implicitQuietMs);
  }

  ensureSession(): MainSession {
    if (this.session && !this.session.closed) return this.session;
    const cfg = this.d.config();
    const rt = this.d.runtime.data;
    this.session = this.d.driver.startMain({
      cwd: this.d.paths.home,
      model: cfg.model,
      effort: cfg.effort,
      resumeSessionId: rt.sessionId,
      priorCostUsd: rt.sessionId ? rt.sessionCostUsd : undefined,
      permissionMode: cfg.permissionMode,
      appendSystemPrompt: BEHAVIOR + `\n\n主人所在时区：${cfg.settings.timezone}。`,
      tools: this.d.tools(),
      canUseTool: (req) => this.d.approvals.request(req),
      mcpServers: this.d.mcpServers(),
      sharedChrome: cfg.browser.enabled && cfg.browser.mode === "shared",
      env: cfg.env,
      onEvent: (e) => this.d.onEvent(e),
      stderr: (s) => appendJsonl(`${this.d.paths.logs}/harness-stderr.jsonl`, { ts: Date.now(), s: truncate(s, 2000) }),
    });
    return this.session;
  }

  // Live switches on the running process (the next one starts with the saved config).
  async applyModel(model: string | undefined): Promise<void> {
    if (model) this.model = "";
    await this.session?.setModel(model).catch((e) => this.d.log(`setModel failed: ${e}`));
  }

  async applyEffort(effort: string | undefined): Promise<void> {
    await this.session?.setEffort(effort).catch((e) => this.d.log(`setEffort failed: ${e}`));
  }

  // ---------------- harness events ----------------

  onHarnessEvent(e: HarnessEvent): void {
    // The harness names the owner messages a turn answers on its first frames:
    // start that turn with exactly those, instead of guessing.
    if (e.type === "answering" && !this.current) {
      const mine = e.uuids.filter((u) => this.pending.has(u));
      if (mine.length) {
        const first = this.pending.get(mine[0]!)!;
        const wechat = mine.map((u) => this.pending.get(u)!.wechat).find(Boolean);
        this.beginTurn({ text: "", origin: first.origin, proactive: false, wechat, uuids: mine });
      }
      return;
    }
    if (e.type === "answering") return;
    if (!this.current && (e.type === "text_delta" || e.type === "assistant_text" || e.type === "tool_use" || e.type === "tool_start")) {
      if (this.pending.size) {
        // The harness is now answering owner messages it had queued.
        const [first] = this.pending.values();
        const wechat = [...this.pending.values()].find((x) => x.wechat)?.wechat;
        this.beginTurn({ text: "", origin: first!.origin, proactive: false, wechat, uuids: [...this.pending.keys()] });
      } else {
        // The harness started a turn on its own (e.g. a background task finished).
        this.beginTurn({ text: "", origin: "system", proactive: true, implicit: true });
      }
    } else if (this.current?.implicit) {
      this.armImplicitTimer();
    }
    const turn = this.current;
    const { chat, tasks } = this.d;
    switch (e.type) {
      case "commands":
        this.d.onCommands(e.commands);
        break;
      case "models":
        this.d.onModels(e.models);
        break;
      case "init":
        this.model = e.model;
        if (e.terminalCommands) this.d.onTerminalCommands(e.terminalCommands);
        if (this.d.runtime.data.sessionId !== e.sessionId) this.d.runtime.update({ sessionId: e.sessionId });
        this.d.statusChanged();
        break;
      case "text_delta":
        if (turn && !turn.proactive) {
          if (!this.deltaId) this.deltaId = `m_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
          this.deltaText += e.text;
          chat.delta(this.deltaId, e.text);
        }
        break;
      case "assistant_text":
        if (e.parentToolUseId) {
          tasks.onSubagentText(e.text, e.parentToolUseId);
          break;
        }
        this.turnTexts.push(e.text);
        if (turn?.wechat && !turn.proactive) this.streamToWechat(turn, e.text);
        if (turn && !turn.proactive) {
          chat.add({ id: this.deltaId ?? undefined, role: "assistant", kind: "text", text: e.text, channel: turn.origin });
        }
        this.deltaId = null;
        this.deltaText = "";
        break;
      case "tool_start":
        if (!e.parentToolUseId) this.setActivity(describeActivity(e.name));
        break;
      case "tool_use":
        if (!e.parentToolUseId) this.openTools.add(e.id);
        tasks.onToolUse(e.id, e.name, e.input, e.parentToolUseId);
        this.setActivity(e.parentToolUseId ? ACTIVITY_BACKGROUND : describeActivity(e.name));
        break;
      case "tool_result":
        this.openTools.delete(e.toolUseId);
        tasks.onToolResult(e.toolUseId, e.content, e.isError, e.parentToolUseId);
        break;
      case "task_started":
        tasks.onTaskStarted(e.taskId, e.toolUseId, e.background);
        break;
      case "task_progress":
        if (e.summary) tasks.onProgress(e.taskId, e.summary);
        break;
      case "background_tasks":
        tasks.setLiveSet(e.taskIds);
        break;
      case "task_backgrounded":
        tasks.onTaskBackgrounded(e.taskId);
        break;
      case "task_notification":
        tasks.onTaskNotification(e.taskId, e.toolUseId, e.status, e.summary);
        break;
      case "compact":
        this.d.metric({ type: "compact", trigger: e.trigger, preTokens: e.preTokens, postTokens: e.postTokens });
        break;
      case "result":
        this.d.runtime.update({ sessionCostUsd: e.totalCostUsd });
        this.endTurn(e.costUsd, e.contextTokens, e.isError ? e.text : undefined, this.consume(e.consumedUuids), e.errorCategory);
        break;
      case "error":
        this.d.log(`harness error: ${e.message}`);
        this.session?.close();
        this.session = null;
        this.pending.clear();
        if (this.current) this.endTurn(0, this.lastContextTokens, e.message);
        break;
    }
  }

  // From wechat-agent: the owner on WeChat sees progress mid-task instead of
  // waiting for the end. Sends are chained so paragraphs arrive in order; the
  // typing indicator comes back between them while the turn is still going.
  private streamToWechat(turn: Turn, raw: string): void {
    const wechat = this.d.wechat;
    const target = turn.wechat;
    const text = stripSkip(raw.trim());
    if (!wechat || !target || !text) return;
    this.wechatStreamed++;
    this.wechatChain = this.wechatChain.then(async () => {
      await wechat.reply(target, text).catch((err) => this.d.log(`wechat reply failed: ${err}`));
      this.d.audit.log("wechat.reply", { chars: text.length });
      await wechat.stopTyping?.();
      if (this.current === turn) void wechat.startTyping?.(target);
    });
  }

  /** The channel the owner is on in the current turn (proactive turns: the app). */
  ownerChannel(): Channel {
    const o = this.current?.origin;
    return o === "wechat" || o === "cli" ? o : "app";
  }

  private setActivity(a: string): void {
    if (a === this.activity) return;
    this.activity = a;
    this.d.statusChanged();
  }

  // consume settles which owner messages a result answered. When the harness
  // doesn't say (older CLIs), an owner turn is taken to have answered its own
  // messages; a proactive/implicit turn answered none.
  private consume(listed?: string[]): OwnerMessage[] {
    const ids = listed ?? (this.current && !this.current.proactive ? this.current.uuids ?? [] : []);
    const answered: OwnerMessage[] = [];
    for (const u of ids) {
      const p = this.pending.get(u);
      if (p) answered.push(p);
      this.pending.delete(u);
    }
    return answered;
  }

  private endTurn(costUsd: number, contextTokens: number, error?: string, answered: OwnerMessage[] = [], errorCategory?: string): void {
    const { chat, router, wechat, audit } = this.d;
    const turn = this.current;
    this.current = null;
    this.activity = "";
    if (this.implicitTimer) clearTimeout(this.implicitTimer);
    // A stream cut off by an error/kill still gets a final message, so clients
    // don't keep a half-written bubble "typing" forever.
    if (this.deltaId) {
      if (this.deltaText.trim()) chat.add({ id: this.deltaId, role: "assistant", kind: "text", text: this.deltaText, channel: turn?.origin ?? "system" });
      this.deltaId = null;
      this.deltaText = "";
    }
    this.openTools.clear();
    this.d.usage.add("mainUsd", costUsd);
    this.lastContextTokens = contextTokens;
    this.d.tasks.finalizePending();
    if (turn) {
      this.d.metric({ type: "turn", origin: turn.origin, proactive: turn.proactive, costUsd, contextTokens, error });
      if (error) chat.add({ role: "system", kind: "notice", text: friendlyError(error, errorCategory), channel: "system" });
      const shown = stripSkip(this.turnTexts.join("\n\n").trim());
      if (turn.watchId && shown && !error) this.d.onGoalResult?.(turn.watchId, shown);
      // The owner spoke while this proactive turn ran and it answered them too:
      // show it as a normal reply (no push), not as something it brought up.
      const ownerFolded = turn.proactive && answered.length > 0;
      if (ownerFolded) {
        if (shown) chat.add({ role: "assistant", kind: "text", text: shown, channel: answered[0]!.origin });
      } else if (turn.proactive) {
        if (shown) {
          const msg = chat.add({ role: "assistant", kind: "text", text: shown, channel: turn.origin, proactive: true });
          void router.proactive(msg);
        } else {
          this.d.metric({ type: "skip", origin: turn.origin, label: turn.label });
        }
      }
      const wechatTarget = answered.find((a) => a.wechat)?.wechat ?? (turn.proactive ? undefined : turn.wechat);
      // Already streamed paragraph by paragraph? Then nothing more to send.
      if (wechatTarget && wechat && shown && !this.wechatStreamed) {
        const text = shown;
        this.wechatChain = this.wechatChain.then(() => wechat.reply(wechatTarget, text).catch((err) => this.d.log(`wechat reply failed: ${err}`)));
        audit.log("wechat.reply", { chars: shown.length });
      }
      if (wechat) this.wechatChain = this.wechatChain.then(() => wechat.stopTyping?.());
      this.wechatStreamed = 0;
    }
    this.d.statusChanged();
    this.scheduleIdle();
    if (this.pending.size === 0) this.pump();
    else this.flushWaitersIfIdle();
  }

  private flushWaitersIfIdle(): void {
    if (this.quiet) for (const w of this.turnWaiters.splice(0)) w();
  }

  // ---------------- idle close ----------------

  scheduleIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    const min = this.d.config().session.idleCloseMinutes;
    if (!min) return;
    this.idleTimer = setTimeout(() => this.onIdle(), min * 60_000);
  }

  // After a lookup that started the process just to ask it something.
  scheduleIdleIfIdle(): void {
    if (!this.current) this.scheduleIdle();
  }

  onIdle(): void {
    if (this.current || this.queue.length || !this.session) return;
    // Close the CLI process; the next message resumes the same conversation.
    // (Keeping the context in shape is the harness' job: it compacts on its own.)
    if (!this.d.tasks.live().length && !this.d.approvals.listPending().length) {
      this.session.close();
      this.session = null;
      this.d.metric({ type: "idle_close", contextTokens: this.lastContextTokens });
    }
  }

  // ---------------- stop ----------------

  // stopAll interrupts what the harness is doing right now (its own interrupt
  // and stopTask). Nothing stays blocked afterwards: the next message works as usual.
  stopAll(by: string): void {
    this.d.audit.log("stop", { by });
    this.queue = [];
    this.d.approvals.denyAll(`stop:${by}`);
    for (const t of this.d.tasks.running()) {
      if (t.sdkTaskId) void this.session?.stopTask(t.sdkTaskId).catch(() => {});
      this.d.tasks.markStopped(t.id);
    }
    void this.session?.interrupt();
    // A tool that never returns can't be interrupted: end the turn here and
    // let the next message start a fresh process (same conversation, resumed).
    if (this.current) {
      this.pending.clear();
      this.endTurn(0, this.lastContextTokens);
      this.session?.close();
      this.session = null;
    }
    this.d.statusChanged();
  }

  async stopTask(t: Task): Promise<void> {
    if (t.sdkTaskId) {
      await this.session?.stopTask(t.sdkTaskId).catch(() => {});
    } else if (t.toolUseId && this.current) {
      // A foreground subagent runs inside the current turn: stopping it means
      // interrupting that turn.
      await this.session?.interrupt();
    }
  }

  close(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.session?.close();
    this.session = null;
  }
}
