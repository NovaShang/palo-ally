import { t } from "./i18n/index.ts";
import { randomUUID } from "node:crypto";
import type { AllyGateScope } from "./allyGate.ts";
import type { ApprovalManager } from "./approvals.ts";
import { ASK_TOOL, type QuestionManager } from "./questions.ts";
import type { Audit } from "./audit.ts";
import type { WechatChannel, WechatReplyTarget } from "./channels/types.ts";
import type { ChatLog } from "./chat.ts";
import type { Config, Paths } from "./config.ts";
import { budgetNotice, friendlyError } from "./copy.ts";
import { behaviorPrompt } from "./home.ts";
import type { Harness, HarnessDriver, HarnessEvent, ImageInput, MainSession, ModelOption, SlashCommandInfo, ToolHandlers } from "./harness/types.ts";
import { PALO_NAME } from "./pals.ts";
import type { Router } from "./router.ts";
import type { RuntimeState } from "./runtime.ts";
import { WATCHDOG_DEFAULTS, killHard } from "./stallWatch.ts";
import type { TaskTracker } from "./tasks.ts";
import type { Channel, Task } from "./types.ts";
import type { UsageLedger } from "./usage.ts";
import { appendJsonl, truncate } from "./util.ts";
import { ChatLogSink } from "./agent/outputSink.ts";
import { TrackerTasks } from "./agent/taskProjection.ts";
import { AgentSession, type ResultEvent } from "./agent/session.ts";
import { ASSISTANT_FLAGS } from "./agent/flags.ts";
import { AllyTurn } from "./agent/allyTurn.ts";
import { IdleCompact } from "./agent/idleCompact.ts";
import { stripSkip } from "./agent/skip.ts";
import { TurnQueue } from "./agent/turnQueue.ts";
import { WechatRelay } from "./agent/wechatRelay.ts";
import { type Turn, type TurnEnd, timing } from "./agent/turn.ts";

export type { Turn };
// A turn the harness started by itself is closed if it goes quiet without a result.
export { timing };

type InFlightOwner = { origin: Channel; wechat?: WechatReplyTarget; sentAt?: number; text: string; images?: ImageInput[] };

// What the assistant is told after the watchdog restarted it mid-turn.
export const stallContinue = (): string => t("stall.continue");
const stallContinueProactive = (): string => t("stall.continueProactive");

// Compaction (PRD §6.1): Claude Code compacts natively when the context nears
// session.compactWindowTokens (passed as its autoCompactWindow). The host adds
// one trigger: compact before the prompt cache expires, at a clean break. A
// clean break means nothing is running or waiting and the owner has been quiet this long.
export const COMPACT_QUIET_MS = 5 * 60_000;
export { COMPACT_RETRY_MS } from "./agent/idleCompact.ts";
// stripSkip removes the "[skip]" marker a proactive turn uses to stay silent.
export { stripSkip };

export interface ConversationDeps {
  paths: Paths;
  config: () => Config;
  driver: HarnessDriver;
  /** The harness it runs on (where its memory is, …). */
  harness: Harness;
  runtime: RuntimeState;
  chat: ChatLog;
  tasks: TaskTracker;
  approvals: ApprovalManager;
  questions: QuestionManager;
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
  // the session's name, which other sessions SendMessage it by
  peerName?: () => string;
  /** Its process' pid, as Claude Code registered it (the stall watchdog's). */
  pid?: () => number | undefined;
  // a schedule run answered: record it as the goal's progress line
  onGoalResult?: (watchId: string, text: string) => void;
  // work handed to another session the assistant is waiting on
  handoffsInFlight?: () => boolean;
  metric: (m: Record<string, unknown>) => void;
  // The assistant's own AskUserQuestion goes on the owner's pending list
  // instead of stopping the conversation: the words it's told (null: ask as
  // before, a blocking card; a WeChat turn, where the owner answers in text).
  deferQuestion?: (input: Record<string, unknown>) => string | null;
  /** A turn went through (null) or failed for want of Claude Code's login (what it was for). */
  onAuth?: (failed: { text: string; watchId?: string } | null) => void;
  log: (s: string) => void;
}

// Conversation is the assistant: the one main conversation with the harness.
// It is an AgentSession (agent/session.ts: its process, its turns, its
// replies) with ASSISTANT_FLAGS: its process started by the words that need
// it, at once (no ready wait), never asleep, no holders check; its turns made
// by the host (which owner messages each answers, one the harness starts on
// its own, closed when it goes quiet), its replies one message per text block
// under ids of the host's, into its chat log; its tasks the host's list. What
// only the assistant has plugs in by its flags: host-initiated turns
// (turnQueue.ts), WeChat (wechatRelay.ts), an Ally's gated turn
// (allyTurn.ts), idle compaction (idleCompact.ts).
export class Conversation extends AgentSession<InFlightOwner, TrackerTasks, ChatLogSink> {
  model = ""; // the model the harness reports running
  permissionMode = ""; // the permission mode it reports running in (not always the configured one)
  private lastContextTokens = 0;
  // (pending: every owner message sent to the harness and not yet answered,
  // by uuid; a turn counts as answering the owner only once its result lists the uuid.)
  // Its pieces, by its flags: host-initiated turns wait in a queue and are
  // shown as what they are (proactiveTurns); WeChat turns get each paragraph
  // as it's written (wechat); an Ally's turn is gated and the owner's words
  // held meanwhile (allyGate); the host compacts at a clean break before the
  // cache expires (autoCompact).
  private turnQueue: TurnQueue | null;
  private wechat: WechatRelay | null;
  private ally: AllyTurn | null;
  private compactor: IdleCompact | null;
  private modeChecked = false; // this process' permission mode was compared with the config

  constructor(private d: ConversationDeps) {
    // (only closures here: `this` is there once super() has returned)
    super(ASSISTANT_FLAGS, {
      record: {},
      out: new ChatLogSink(d.chat),
      tasks: new TrackerTasks(d.tasks),
      process: {
        name: () => d.peerName?.() ?? "main",
        save: () => {},
        changed: () => d.statusChanged(),
        log: (s) => d.log(s),
        now: () => Date.now(),
        open: () => ({ proc: this.open() }),
        startError: (why) => why,
        pid: () => d.pid?.(),
        killFrozen: (pid) => killHard(pid),
      },
      harness: d.harness,
      kept: d.runtime.data,
      keep: () => d.runtime.update({}),
      cwd: () => d.paths.home,
    });
    this.lastContextTokens = d.runtime.data.contextTokens ?? 0;
    this.turnQueue = this.flags.proactiveTurns
      ? new TurnQueue({
          busy: () => !!this.current || this.pending.size > 0 || this.allyInFlight,
          inFlight: () => this.pending.size,
          expire: () => this.expirePending(),
          quiet: () => this.quiet,
          overBudget: () => this.d.usage.over("mainUsd", this.d.config().budget.mainDailyUsd),
          day: () => this.d.usage.today().day,
          budgetNotice,
          start: (turn) => {
            const uuid = randomUUID();
            if (turn.allyId) this.ally?.start(turn.allyId, uuid);
            this.beginTurn({ ...turn, uuids: [uuid] });
            this.ensureSession().send(turn.text, uuid);
          },
          out: () => this.out,
          push: (msg) => void this.d.router.proactive(msg),
          goalResult: (id, text) => this.d.onGoalResult?.(id, text),
          metric: (m) => this.d.metric(m),
          log: (s) => this.d.log(s),
        })
      : null;
    this.wechat = this.flags.wechat
      ? new WechatRelay({ channel: () => this.d.wechat, audit: () => this.d.audit, log: (s) => this.d.log(s), current: (turn) => this.current === turn })
      : null;
    this.ally = this.flags.allyGate
      ? new AllyTurn({
          audit: () => this.d.audit,
          log: (s) => this.d.log(s),
          scope: () => this.allyScope(),
          busy: () => !!this.current,
          resend: (h) => this.sendOwner(h.text, h.origin, h.wechat, h.images, h.uuid),
          pump: () => this.turnQueue?.pump(),
          quietMs: () => timing.implicitQuietMs,
        })
      : null;
    this.compactor = this.flags.autoCompact
      ? new IdleCompact({
          session: () => this.d.config().session,
          contextTokens: () => this.lastContextTokens,
          cleanBreak: (now) => this.cleanBreak(now),
          audit: () => this.d.audit,
          compact: () => this.enqueue({ text: "/compact", origin: "system", proactive: true, maintenance: true, label: "compact" }),
        })
      : null;
  }

  /** When the idle stretch now going began (idle compaction's). */
  private get idleStamp(): number {
    return this.compactor?.idleStamp ?? 0;
  }

  /** An Ally's turn is on, or the owner's words wait for one that just ended. */
  private get allyInFlight(): boolean {
    return !!this.ally?.inFlight;
  }

  protected who(): { key: string; name: string; label: string } {
    return { key: "main", name: this.d.config().settings.assistantName || PALO_NAME, label: "main session" };
  }

  protected changed(): void {
    this.d.statusChanged();
  }

  protected log(s: string): void {
    this.d.log(s);
  }

  /** The main session's context size after its last turn (or compaction). */
  get contextTokens(): number {
    return this.lastContextTokens;
  }

  /** The goal whose scheduled run is the current turn (a brief's), if it is one. */
  currentWatch(): { id: string; label?: string } | undefined {
    const c = this.current;
    return c?.watchId && c.origin === "schedule" ? { id: c.watchId, label: c.label } : undefined;
  }

  // Nothing in flight at all (safe to restart the process).
  get quiet(): boolean {
    return !this.current && !this.turnQueue?.length && !this.pending.size && !this.allyInFlight;
  }

  /** The Ally whose message the harness is handling now (its turn is gated), if any. */
  allyTurnAlly(): string | undefined {
    return this.ally?.allyId;
  }

  // Resolves when the turn queue is drained (tests, CLI one-shots).
  idle(): Promise<void> {
    return this.turnQueue?.idle() ?? Promise.resolve();
  }

  hasQueued(pred: (t: Turn) => boolean): boolean {
    return !!this.turnQueue?.has(pred);
  }

  /** A turn still waiting to start, so more can be added to it. */
  findQueued(pred: (t: Turn) => boolean): Turn | undefined {
    return this.turnQueue?.find(pred);
  }

  // ---------------- inputs ----------------

  // Owner messages go to the harness immediately, even mid-turn: Claude Code
  // queues them or folds them into the running turn, so "好了吗" gets heard
  // while work is in progress. Only proactive turns wait for idle.
  //
  // Except during an Ally's turn: the owner's words wait for it to end, then
  // go as a turn of their own. Folded into it they'd lend the Ally's message
  // the owner's say, or be answered with the Ally turn's few tools.
  //
  // `uuid` is what Claude Code keeps the message under (the chat log has it
  // too, so the owner can go back to it: docs/rewind-prd.md §4.2).
  sendOwner(text: string, origin: Channel, wechat?: WechatReplyTarget, images?: ImageInput[], uuid: string = randomUUID()): void {
    if (this.ally?.hold({ text, origin, wechat, images, uuid })) return;
    this.put([[uuid, { origin, wechat, text, ...(images?.length ? { images } : {}) }]], () => this.ensureSession(), text);
  }

  /** A host-initiated turn: it waits until nothing else is in flight (TurnQueue). */
  enqueue(turn: Turn): void {
    this.turnQueue?.add(turn);
  }

  // Owner messages the harness never answered (e.g. lost in a crash) stop
  // blocking proactive turns after a while.
  // (Not before the stall watchdog has had its chance to resend them.)
  private expirePending(): void {
    const stall = this.d.config().watchdog?.stallMinutes ?? WATCHDOG_DEFAULTS.stallMinutes;
    const cutoff = Date.now() - Math.max(10, 2 * stall) * 60_000;
    this.pending.expire((u, p) => (p.sentAt ?? 0) < cutoff && !this.current?.uuids?.includes(u));
  }

  // A WeChat turn shows typing.
  protected override turnBegan(turn: Turn): void {
    this.wechat?.turnBegan(turn);
  }

  /**
   * The reply being streamed right now (its message id and all its text so
   * far), for a client that reconnects mid-reply: the deltas it missed while
   * offline are not replayed, so it takes this, then keeps appending deltas.
   */
  streamingReply(): { id: string; text: string } | null {
    return this.streaming();
  }

  ensureSession(): MainSession {
    return this.host.ensure();
  }

  // Its process, as ensureSession starts it.
  private open(): MainSession {
    const cfg = this.d.config();
    const rt = this.d.runtime.data;
    this.modeChecked = false;
    return this.d.driver.startMain({
      cwd: this.d.paths.home,
      model: cfg.model,
      effort: cfg.effort,
      ...this.startOn(),
      priorCostUsd: rt.sessionId ? rt.sessionCostUsd : undefined,
      permissionMode: cfg.permissionMode,
      appendSystemPrompt: behaviorPrompt(this.d.paths) + `\n\n${t("conv.timezone", { tz: cfg.settings.timezone })}`,
      tools: this.d.tools(),
      // AskUserQuestion is a question for the owner, not a permission prompt.
      // In an Ally's turn the gate answers first (the hook already did; this
      // is the second lock).
      canUseTool: (req) => {
        const deny = this.gateTool({ toolName: req.toolName, input: req.input, agentId: req.agentId, via: "canUseTool" });
        if (deny) return Promise.resolve({ behavior: "deny", message: deny });
        if (req.toolName === ASK_TOOL) {
          const deferred = this.flags.questions !== "defer" || this.current?.origin === "wechat" ? null : (this.d.deferQuestion?.(req.input) ?? null);
          return deferred !== null ? Promise.resolve({ behavior: "deny", message: deferred }) : this.d.questions.request(req);
        }
        return this.d.approvals.request(req);
      },
      toolGate: (req) => this.gateTool(req),
      mcpServers: this.d.mcpServers(),
      sharedChrome: cfg.browser.enabled && cfg.browser.mode === "shared",
      compactWindowTokens: cfg.session.compactWindowTokens,
      env: cfg.env,
      ...(this.d.peerName ? { name: this.d.peerName() } : {}),
      onEvent: (e) => this.d.onEvent(e),
      stderr: (s) => appendJsonl(`${this.d.paths.logs}/harness-stderr.jsonl`, { ts: Date.now(), s: truncate(s, 2000) }),
    });
  }

  // Live switches on the running process (the next one starts with the saved config).
  async applyModel(model: string | undefined): Promise<void> {
    if (model) this.model = "";
    await this.host.proc?.setModel(model).catch((e) => this.d.log(`setModel failed: ${e}`));
  }

  async applyEffort(effort: string | undefined): Promise<void> {
    await this.host.proc?.setEffort(effort).catch((e) => this.d.log(`setEffort failed: ${e}`));
  }

  // ---------------- harness events ----------------

  // What the assistant keeps of the harness' events besides its turns (agent/session.ts).
  protected override sessionEvent(e: HarnessEvent): void {
    switch (e.type) {
      case "commands":
        this.d.onCommands(e.commands);
        break;
      case "models":
        this.d.onModels(e.models);
        break;
      case "init":
        this.model = e.model;
        if (e.permissionMode) this.checkMode(e.permissionMode, e.model);
        if (e.terminalCommands) this.d.onTerminalCommands(e.terminalCommands);
        if (this.d.runtime.data.sessionId !== e.sessionId) this.d.runtime.update({ sessionId: e.sessionId });
        this.d.statusChanged();
        break;
      case "compact": {
        // Ours (the idle trigger, in its own /compact turn) or Claude Code's native one.
        const reason = this.current?.maintenance && this.compactor?.reason ? this.compactor.reason : "native";
        this.d.metric({ type: "compact", trigger: e.trigger, reason, preTokens: e.preTokens, postTokens: e.postTokens });
        this.d.audit.log("session.compact", { reason, trigger: e.trigger, preTokens: e.preTokens, postTokens: e.postTokens });
        if (typeof e.postTokens === "number") this.lastContextTokens = e.postTokens;
        this.d.runtime.update({ contextTokens: this.lastContextTokens, lastCompactAt: Date.now() });
        if (this.current?.maintenance && this.compactor) this.compactor.reason = null;
        break;
      }
      case "error":
        this.d.log(`harness error: ${e.message}`);
        this.host.close();
        this.pending.clear();
        this.openTools.clear();
        // The Ally's message died with the process; the owner's held words didn't.
        if (this.ally?.active) this.ally.end("harness error");
        if (this.current) this.endTurn({ error: e.message });
        break;
    }
  }

  // A WeChat turn gets each paragraph as it's written.
  protected override said(turn: Turn | null, text: string): void {
    if (turn?.wechat && !turn.proactive) this.wechat?.paragraph(turn, text);
  }

  protected override resultIn(e: ResultEvent, turn: Turn | null): void {
    // The Ally's turn is over once a result consumed its message (an
    // older CLI that doesn't list them: once our turn for it ends).
    const gateDone = !!this.ally?.doneBy(e.consumedUuids, turn?.uuids);
    this.d.runtime.update({ sessionCostUsd: e.totalCostUsd, ...(e.contextWindow ? { contextWindow: e.contextWindow } : {}) });
    // The owner's held words go before anything queued behind this turn.
    if (gateDone) this.ally?.end("done");
  }

  protected override resultDone(): void {
    if (this.ally?.active) this.ally.watch();
  }

  // Claude Code doesn't refuse a permission mode it can't run: it starts in
  // another (auto mode needs a model that has it; otherwise it's "default").
  // Said once per process, so a quiet downgrade shows in the log and audit.
  private checkMode(effective: string, model: string): void {
    this.permissionMode = effective;
    if (this.modeChecked) return;
    this.modeChecked = true;
    const configured = this.d.config().permissionMode;
    if (!configured || effective === configured) return;
    this.d.log(`harness runs in permission mode ${effective}, not the configured ${configured} (model ${model})`);
    this.d.audit.log("harness.mode_mismatch", { configured, effective, model });
  }

  // ---------------- an Ally's turn: 只说话不动手 ----------------

  // The host's rule for a tool call: in an Ally's turn, only what allyGate.ts lets through.
  private gateTool(req: Parameters<AllyTurn["gateTool"]>[0]): string | null {
    return this.ally?.gateTool(req) ?? null;
  }

  private allyScope(): AllyGateScope {
    const home = this.d.paths.home;
    return { home, memoryDir: this.d.harness.memory.autoMemoryDir(home, this.d.config().env?.CLAUDE_CONFIG_DIR || undefined) };
  }

  /** A permission prompt or a question is waiting for the owner. */
  waitingOnOwner(): boolean {
    // The assistant's own prompts; a session's card on the phone is that session's wait.
    return this.d.approvals.listPending().some((a) => !a.source) || this.d.questions.listPending().some((q) => !q.source);
  }

  /** Where to reply on WeChat when the current turn came from there. */
  wechatTarget(): WechatReplyTarget | undefined {
    return this.current?.origin === "wechat" ? this.current.wechat : undefined;
  }

  /** The channel the owner is on in the current turn (proactive turns: the app). */
  ownerChannel(): Channel {
    const o = this.current?.origin;
    return o === "wechat" || o === "cli" ? o : "app";
  }

  // A turn is over (its result, an error, a stop, gone quiet): its cost, its
  // context size, what it said (a reply, or what it brought up as a push, or
  // nothing for [skip]), a goal's line, WeChat, and the next queued turn.
  protected override turnEnded(turn: Turn | null, end: TurnEnd<InFlightOwner>): void {
    const chat = this.out;
    const costUsd = end.costUsd ?? 0;
    const contextTokens = end.contextTokens ?? this.lastContextTokens;
    const { error, errorCategory } = end;
    const answered = end.answered ?? [];
    this.d.usage.add("mainUsd", costUsd);
    if (turn?.maintenance) {
      // A /compact turn: its own result says nothing about the context (the
      // compact boundary did). If no boundary came, say so in the audit.
      if (this.compactor?.reason) {
        this.d.audit.log("session.compact.failed", { reason: this.compactor.reason, error: error ?? "no compact boundary" });
        this.compactor.reason = null;
      }
      this.d.statusChanged();
      this.turnQueue?.next();
      return;
    }
    this.lastContextTokens = contextTokens;
    this.d.runtime.update({ contextTokens, lastTurnAt: Date.now() });
    this.compactor?.arm();
    this.taskView.turnEnded();
    if (turn) {
      this.d.metric({ type: "turn", origin: turn.origin, proactive: turn.proactive, costUsd, contextTokens, error });
      // The login ran out: said once for everything (auth.ts), not after each turn.
      const noLogin = !!error && this.d.harness.auth.isFailure(error, errorCategory);
      if (error && !noLogin) chat.message({ role: "system", kind: "notice", text: friendlyError(error, errorCategory), channel: "system" });
      if (noLogin) {
        const owner = answered.flatMap((m) => (m.text ? [m.text] : []));
        this.d.onAuth?.({ text: owner.length ? owner.join("\n") : turn.label ? `${turn.label}: ${turn.text}` : turn.text, ...(turn.watchId ? { watchId: turn.watchId } : {}) });
      } else if (!error) this.d.onAuth?.(null);
      const shown = stripSkip(this.texts.join("\n\n").trim());
      this.turnQueue?.said(turn, shown, answered, error);
      this.wechat?.turnEnded(answered.find((a) => a.wechat)?.wechat ?? (turn.proactive ? undefined : turn.wechat), shown);
    }
    this.d.statusChanged();
    this.turnQueue?.next();
  }

  // ---------------- compaction ----------------

  // A clean break: no turn running or queued, no owner message unanswered, no
  // background agent or handoff in flight, nobody waiting on the owner, and the
  // owner quiet for a few minutes. Compaction never cuts into work.
  cleanBreak(now = Date.now()): boolean {
    if (!this.quiet || this.compactor?.reason) return false;
    if (this.d.tasks.live().length || this.waitingOnOwner() || this.d.handoffsInFlight?.()) return false;
    return now - this.d.chat.lastUserActivity() >= COMPACT_QUIET_MS;
  }

  /** Cancel the idle timer (the host is shutting down). */
  stopIdleCompact(): void {
    this.compactor?.stop();
  }

  // Compacts (the harness' native /compact, no instructions) if the idle
  // stretch that began at `stamp` is still going, the context is big enough and
  // this is a clean break. "later": still idle but not a clean break yet.
  maybeIdleCompact(stamp?: number, now?: number): "started" | "later" | null {
    return this.compactor?.maybe(stamp, now) ?? null;
  }

  // ---------------- the process stays up ----------------
  // The assistant's process is never closed for being idle: other Claude Code
  // sessions find it by name (SendMessage) only while it runs, and a session
  // that was closed dropped out of their list until the next message woke it
  // (pals-prd §16). An idle process costs memory, not tokens. onIdle() is what
  // closing used to do, kept for the tests that resume a closed session.

  onIdle(): void {
    if (this.current || this.turnQueue?.length || this.allyInFlight || !this.host.proc) return;
    // Close the CLI process; the next message resumes the same conversation.
    // (Keeping the context in shape is the harness' job: it compacts on its own.)
    if (!this.d.tasks.live().length && !this.waitingOnOwner()) {
      this.host.close();
      this.d.metric({ type: "idle_close", contextTokens: this.lastContextTokens });
    }
  }

  // ---------------- 回到这里重来 (agent/session.ts) ----------------

  protected occupied(): boolean {
    return this.allyInFlight || this.d.tasks.live().length > 0;
  }

  // The context size is unknown until the new session has run a turn.
  protected override wentBack(): void {
    this.lastContextTokens = 0;
    this.d.runtime.data.contextTokens = 0;
  }

  /**
   * Claude Code's login is back: an idle process ends and a new one starts
   * on the same session, so it signs in afresh. False while a turn is on.
   */
  restartIdle(): boolean {
    if (!this.host.proc || this.current || this.pending.size || this.ally?.active) return false;
    this.host.close();
    this.ensureSession();
    return true;
  }

  // ---------------- the stall watchdog ----------------

  // Its turn goes on as the same kind of turn (agent/session.ts). An Ally's
  // turn doesn't: its message died with the process, as after a crash; nor the
  // host's own /compact.
  protected goesOn(): boolean {
    return !this.ally?.active && !this.current?.maintenance;
  }

  protected override frozenEnded(): void {
    this.ally?.stalled();
  }

  protected goOn(turn: Turn | null, taken: InFlightOwner[]): boolean {
    // The turn it was in (or the one it had just taken the owner's words for) goes on first.
    const as: Pick<Turn, "origin" | "proactive" | "wechat" | "watchId"> | null = turn ?? (taken.length ? { origin: taken[0]!.origin, proactive: false, wechat: taken[0]!.wechat } : null);
    if (!as) return false;
    this.turnQueue?.first({
      text: as.proactive ? stallContinueProactive() : stallContinue(),
      origin: as.origin,
      proactive: as.proactive,
      wechat: as.wechat,
      label: "resume",
      ...(as.watchId ? { watchId: as.watchId } : {}),
    });
    return true;
  }

  protected override recovered(): void {
    // The owner's words held for the Ally's turn go now, each as it would have.
    for (const m of this.ally?.takeHeld() ?? []) this.sendOwner(m.text, m.origin, m.wechat, m.images, m.uuid);
    this.turnQueue?.pump();
  }

  // ---------------- stop ----------------

  /** 停止 (agent/session.ts): over when this returns; the next message works as usual. */
  stopAll(by: string): void {
    void this.stopWork(by);
  }

  // Its queue, an Ally's turn (as with words already sent: stopped, not
  // carried over), its own cards, and its background tasks.
  protected override dropWaiting(by: string): void {
    this.d.audit.log("stop", { by });
    this.turnQueue?.clear();
    this.ally?.stop();
    this.d.approvals.denyAll(`stop:${by}`);
    this.d.questions.cancelAll(`stop:${by}`);
    for (const t of this.d.tasks.running()) {
      if (t.sdkTaskId) void this.host.proc?.stopTask(t.sdkTaskId).catch(() => {});
      this.d.tasks.markStopped(t.id);
    }
  }

  async stopTask(t: Task): Promise<void> {
    if (t.sdkTaskId) {
      await this.host.proc?.stopTask(t.sdkTaskId).catch(() => {});
    } else if (t.toolUseId && this.current) {
      // A foreground subagent runs inside the current turn: stopping it means
      // interrupting that turn.
      await this.host.proc?.interrupt();
    }
  }

  close(): void {
    this.host.close();
  }
}
