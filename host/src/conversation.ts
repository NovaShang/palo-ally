import { t } from "./i18n/index.ts";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { allyTurnTool, type AllyGateScope } from "./allyGate.ts";
import type { ApprovalManager } from "./approvals.ts";
import { ASK_TOOL, type QuestionManager } from "./questions.ts";
import type { Audit } from "./audit.ts";
import type { WechatChannel, WechatReplyTarget } from "./channels/types.ts";
import type { ChatLog } from "./chat.ts";
import type { Config, Paths } from "./config.ts";
import { ACTIVITY, activityBackground, allyToolDenied, budgetNotice, describeActivity, friendlyError } from "./copy.ts";
import { behaviorPrompt } from "./home.ts";
import type { HarnessDriver, HarnessEvent, ImageInput, MainSession, ModelOption, SlashCommandInfo, ToolGate, ToolHandlers } from "./harness/types.ts";
import { autoMemoryDir } from "./memory.ts";
import type { Router } from "./router.ts";
import type { RuntimeState } from "./runtime.ts";
import { type PendingRewind, rewindBusy } from "./rewind.ts";
import { type StallRecovery, type StallTarget, WATCHDOG_DEFAULTS, transcriptHas } from "./stallWatch.ts";
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
  maintenance?: boolean; // housekeeping for the harness (native /compact): nothing shown, nothing pushed
  allyId?: string; // an Ally's message: more from the same Ally joins it while it waits
  pal?: boolean; // a Pal's palo_send: answers work already asked for, so the proactive budget doesn't drop it
}

type OwnerMessage = { origin: Channel; wechat?: WechatReplyTarget };
type HeldMessage = { text: string; origin: Channel; wechat?: WechatReplyTarget; images?: ImageInput[]; uuid?: string };

const SKIP = /^\s*\[skip\]\s*$/i;

// A turn the harness started by itself is closed if it goes quiet without a result.
export const timing = { implicitQuietMs: 90_000 };

// What the assistant is told after the watchdog restarted it mid-turn.
export const stallContinue = (): string => t("stall.continue");
const stallContinueProactive = (): string => t("stall.continueProactive");

/** Where the stall watchdog finds the assistant's process and transcript (the hub knows). */
export interface MainStallHooks {
  name: () => string;
  pid: () => number | undefined;
  transcript: () => string | undefined;
  kill: (pid: number | undefined) => Promise<void>;
}

// Compaction (PRD §6.1): Claude Code compacts natively when the context nears
// session.compactWindowTokens (passed as its autoCompactWindow). The host adds
// one trigger: compact before the prompt cache expires, at a clean break. A
// clean break means nothing is running or waiting and the owner has been quiet this long.
export const COMPACT_QUIET_MS = 5 * 60_000;
// An idle compaction that found no clean break tries again this often while the session stays idle.
export const COMPACT_RETRY_MS = 5 * 60_000;

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
  // a schedule run answered: record it as the goal's progress line
  onGoalResult?: (watchId: string, text: string) => void;
  // work handed to another session the assistant is waiting on
  handoffsInFlight?: () => boolean;
  // where Claude Code keeps a session's transcript (a rewound session: has the fork been written?)
  transcriptOf?: (sessionId: string) => string | undefined;
  metric: (m: Record<string, unknown>) => void;
  log: (s: string) => void;
}

// Conversation is the one main conversation with the harness: it owns the CLI
// process, decides which output belongs to whom (owner reply vs proactive),
// and keeps proactive turns waiting until the harness is idle.
export class Conversation {
  model = ""; // the model the harness reports running
  permissionMode = ""; // the permission mode it reports running in (not always the configured one)
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
  private implicitTimer: ReturnType<typeof setTimeout> | null = null;
  private lastContextTokens = 0;
  private turnWaiters: (() => void)[] = [];
  // Every owner message sent to the harness and not yet answered, by uuid.
  // A turn counts as answering the owner only once its result lists the uuid.
  private pending = new Map<string, OwnerMessage & { sentAt: number; text: string; images?: ImageInput[] }>();
  private openTools = new Set<string>(); // main-thread tool calls without a result yet
  private liveTools = new Map<string, string>(); // every tool call without a result yet (subagents' too): id → name
  private lastEventAt = 0;
  private budgetNoticeDay = "";
  private compactReason: string | null = null; // our /compact turn is queued or running
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private idleStamp = 0; // when the last turn ended: the idle stretch the timer belongs to
  private idleFiredFor = 0; // the stretch an idle compaction was already started for
  // 「只说话不动手」(docs/allies-prd.md §11.1): an Ally's message is in the
  // harness and the turn answering it hasn't finished, i.e. from sending it
  // until a result says it consumed that message (however the harness
  // queued it). Meanwhile every main-thread tool call goes through the gate,
  // nothing else is sent to the harness, and the owner's words are held.
  private allyGate: { allyId: string; uuid: string } | null = null;
  private held: HeldMessage[] = [];
  private gateTimer: ReturnType<typeof setTimeout> | null = null;
  private modeChecked = false; // this process' permission mode was compared with the config

  constructor(private d: ConversationDeps) {
    this.lastContextTokens = d.runtime.data.contextTokens ?? 0;
  }

  /** The main session's context size after its last turn (or compaction). */
  get contextTokens(): number {
    return this.lastContextTokens;
  }

  get busy(): boolean {
    return this.current !== null;
  }

  // Nothing in flight at all (safe to restart the process).
  get quiet(): boolean {
    return !this.current && !this.queue.length && !this.pending.size && !this.allyGate && !this.held.length;
  }

  /** The Ally whose message the harness is handling now (its turn is gated), if any. */
  allyTurnAlly(): string | undefined {
    return this.allyGate?.allyId;
  }

  // Resolves when the turn queue is drained (tests, CLI one-shots).
  idle(): Promise<void> {
    if (this.quiet) return Promise.resolve();
    return new Promise((r) => this.turnWaiters.push(r));
  }

  hasQueued(pred: (t: Turn) => boolean): boolean {
    return this.queue.some(pred);
  }

  /** A turn still waiting to start, so more can be added to it. */
  findQueued(pred: (t: Turn) => boolean): Turn | undefined {
    return this.queue.find(pred);
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
    if (this.allyGate) {
      this.held.push({ text, origin, wechat, images, uuid });
      this.d.audit.log("ally.turn.held", { allyId: this.allyGate.allyId, origin });
      return;
    }
    this.pending.set(uuid, { origin, wechat, sentAt: Date.now(), text, ...(images?.length ? { images } : {}) });
    if (!this.current) this.beginTurn({ text, origin, proactive: false, wechat, uuids: [uuid] });
    this.ensureSession().send(text, uuid, images);
  }

  enqueue(turn: Turn): void {
    this.queue.push(turn);
    this.pump();
  }

  private pump(): void {
    this.expirePending();
    if (this.current || this.pending.size || this.allyGate || this.held.length || !this.queue.length) {
      this.flushWaitersIfIdle();
      return;
    }
    const turn = this.queue.shift()!;
    if (turn.proactive && !turn.maintenance && !turn.pal && this.d.usage.over("mainUsd", this.d.config().budget.mainDailyUsd)) {
      this.d.log(`proactive turn dropped: main budget used up (${turn.label ?? turn.origin})`);
      const day = this.d.usage.today().day;
      if (this.budgetNoticeDay !== day) {
        this.budgetNoticeDay = day;
        this.d.chat.add({ role: "system", kind: "notice", text: budgetNotice(turn.label), channel: "system" });
      }
      return this.pump();
    }
    const uuid = randomUUID();
    if (turn.allyId) {
      this.allyGate = { allyId: turn.allyId, uuid };
      this.d.audit.log("ally.turn.start", { allyId: turn.allyId });
    }
    this.beginTurn({ ...turn, uuids: [uuid] });
    this.ensureSession().send(turn.text, uuid);
  }

  // Owner messages the harness never answered (e.g. lost in a crash) stop
  // blocking proactive turns after a while.
  // (Not before the stall watchdog has had its chance to resend them.)
  private expirePending(): void {
    const stall = this.d.config().watchdog?.stallMinutes ?? WATCHDOG_DEFAULTS.stallMinutes;
    const cutoff = Date.now() - Math.max(10, 2 * stall) * 60_000;
    for (const [u, p] of this.pending) if (p.sentAt < cutoff && !this.current?.uuids?.includes(u)) this.pending.delete(u);
  }

  private beginTurn(turn: Turn): void {
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
      if (this.current?.implicit && (this.openTools.size || this.waitingOnOwner())) return this.armImplicitTimer();
      if (this.current?.implicit) {
        this.d.log("implicit turn went quiet without a result; closing it");
        this.endTurn(0, this.lastContextTokens);
      }
    }, timing.implicitQuietMs);
  }

  /**
   * The reply being streamed right now (its message id and all its text so
   * far), for a client that reconnects mid-reply: the deltas it missed while
   * offline are not replayed, so it takes this, then keeps appending deltas.
   */
  streamingReply(): { id: string; text: string } | null {
    return this.deltaId && this.deltaText ? { id: this.deltaId, text: this.deltaText } : null;
  }

  ensureSession(): MainSession {
    if (this.session && !this.session.closed) return this.session;
    const cfg = this.d.config();
    const rt = this.d.runtime.data;
    this.modeChecked = false;
    // Gone back to an earlier message (docs/rewind-prd.md §4.1): the new
    // session is forked from the old one until Claude Code has written it.
    const fork = this.pendingRewind();
    this.session = this.d.driver.startMain({
      cwd: this.d.paths.home,
      model: cfg.model,
      effort: cfg.effort,
      ...(fork
        ? { sessionId: rt.sessionId, ...(fork.at ? { fork: { fromSessionId: fork.from, at: fork.at } } : {}) }
        : { resumeSessionId: rt.sessionId }),
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
        return req.toolName === ASK_TOOL ? this.d.questions.request(req) : this.d.approvals.request(req);
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
    this.lastEventAt = Date.now();
    if (e.type === "tool_use") this.liveTools.set(e.id, e.name);
    else if (e.type === "tool_result") this.liveTools.delete(e.toolUseId);
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
        if (e.permissionMode) this.checkMode(e.permissionMode, e.model);
        if (e.terminalCommands) this.d.onTerminalCommands(e.terminalCommands);
        if (this.d.runtime.data.sessionId !== e.sessionId) this.d.runtime.update({ sessionId: e.sessionId });
        this.d.statusChanged();
        break;
      case "text_delta":
        if (turn && !turn.proactive) {
          if (!this.deltaId) this.deltaId = `m_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
          this.deltaText += e.text;
          chat.delta(this.deltaId, e.text);
          // The words themselves now show the progress.
          this.setActivity(ACTIVITY.reply);
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
        if (!e.parentToolUseId) this.setActivityFor(e.name);
        break;
      case "tool_use":
        if (!e.parentToolUseId) this.openTools.add(e.id);
        tasks.onToolUse(e.id, e.name, e.input, e.parentToolUseId);
        if (e.parentToolUseId) this.setActivity(activityBackground());
        else this.setActivityFor(e.name);
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
      case "compact": {
        // Ours (the idle trigger, in its own /compact turn) or Claude Code's native one.
        const reason = this.current?.maintenance && this.compactReason ? this.compactReason : "native";
        this.d.metric({ type: "compact", trigger: e.trigger, reason, preTokens: e.preTokens, postTokens: e.postTokens });
        this.d.audit.log("session.compact", { reason, trigger: e.trigger, preTokens: e.preTokens, postTokens: e.postTokens });
        if (typeof e.postTokens === "number") this.lastContextTokens = e.postTokens;
        this.d.runtime.update({ contextTokens: this.lastContextTokens, lastCompactAt: Date.now() });
        if (this.current?.maintenance) this.compactReason = null;
        break;
      }
      case "result": {
        const gate = this.allyGate;
        // The Ally's turn is over once a result consumed its message (an
        // older CLI that doesn't list them: once our turn for it ends).
        const gateDone = !!gate && (e.consumedUuids ? e.consumedUuids.includes(gate.uuid) : !!this.current?.uuids?.includes(gate.uuid));
        this.d.runtime.update({ sessionCostUsd: e.totalCostUsd });
        // The owner's held words go before anything queued behind this turn.
        if (gateDone) this.endAllyGate("done");
        this.endTurn(e.costUsd, e.contextTokens, e.isError ? e.text : undefined, this.consume(e.consumedUuids), e.errorCategory);
        if (this.allyGate) this.watchGate();
        break;
      }
      case "error":
        this.d.log(`harness error: ${e.message}`);
        this.session?.close();
        this.session = null;
        this.pending.clear();
        this.liveTools.clear();
        // The Ally's message died with the process; the owner's held words didn't.
        if (this.allyGate) this.endAllyGate("harness error");
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

  // gateTool is the host's rule for a tool call: in an Ally's turn, only
  // what allyGate.ts lets through; otherwise nothing to say. A subagent's call
  // (agentId) belongs to work the owner started earlier (this turn can't start
  // or message one: Agent and SendMessage are denied here), so it isn't gated.
  private gateTool: ToolGate = (req) => {
    const g = this.allyGate;
    if (!g || req.agentId) return null;
    if (allyTurnTool(req.toolName, req.input ?? {}, this.allyScope()).ok) return null;
    this.d.audit.log("ally.tool.denied", { allyId: g.allyId, tool: req.toolName, via: req.via, input: truncate(JSON.stringify(req.input ?? {}), 300) });
    return allyToolDenied(req.toolName);
  };

  private allyScope(): AllyGateScope {
    const home = this.d.paths.home;
    return { home, memoryDir: autoMemoryDir(home, this.d.config().env?.CLAUDE_CONFIG_DIR || undefined) };
  }

  // endAllyGate lifts the gate and sends the owner's held words, each as it
  // would have gone (they reach the harness after the Ally's turn is over).
  private endAllyGate(why: string): void {
    const g = this.allyGate;
    if (!g) return;
    this.allyGate = null;
    if (this.gateTimer) clearTimeout(this.gateTimer);
    this.gateTimer = null;
    this.d.audit.log("ally.turn.end", { allyId: g.allyId, why, held: this.held.length });
    for (const h of this.held.splice(0)) this.sendOwner(h.text, h.origin, h.wechat, h.images, h.uuid);
  }

  // Our turn ended but the harness hasn't said it consumed the Ally's message
  // (it queued it behind something else). The gate stays until it does; if
  // the harness goes quiet without ever getting to it, the gate ends.
  private watchGate(): void {
    if (this.gateTimer) clearTimeout(this.gateTimer);
    this.gateTimer = setTimeout(() => {
      if (!this.allyGate) return;
      if (this.current) return this.watchGate();
      this.d.log("an Ally's message got no result; its turn ends here");
      this.endAllyGate("no result");
      this.pump();
    }, timing.implicitQuietMs);
    (this.gateTimer as any).unref?.();
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

  /** The status line for a main-thread tool; some tools keep the current one. */
  private setActivityFor(tool: string): void {
    const a = describeActivity(tool);
    if (a !== null) this.setActivity(a);
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
    this.liveTools.clear();
    this.d.usage.add("mainUsd", costUsd);
    if (turn?.maintenance) {
      // A /compact turn: its own result says nothing about the context (the
      // compact boundary did). If no boundary came, say so in the audit.
      if (this.compactReason) {
        this.d.audit.log("session.compact.failed", { reason: this.compactReason, error: error ?? "no compact boundary" });
        this.compactReason = null;
      }
      this.d.statusChanged();
      if (this.pending.size === 0) this.pump();
      else this.flushWaitersIfIdle();
      return;
    }
    this.lastContextTokens = contextTokens;
    this.d.runtime.update({ contextTokens, lastTurnAt: Date.now() });
    this.armIdleCompact();
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
          // A schedule goal's output (晨报 and the like) shows as a card titled by the goal.
          const card = turn.watchId && turn.origin === "schedule" ? { card: { title: turn.label ?? "", goalId: turn.watchId } } : {};
          const msg = chat.add({ role: "assistant", kind: "text", text: shown, channel: turn.origin, proactive: true, ...card });
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
    if (this.pending.size === 0) this.pump();
    else this.flushWaitersIfIdle();
  }

  private flushWaitersIfIdle(): void {
    if (this.quiet) for (const w of this.turnWaiters.splice(0)) w();
  }

  // ---------------- compaction ----------------

  // A clean break: no turn running or queued, no owner message unanswered, no
  // background agent or handoff in flight, nobody waiting on the owner, and the
  // owner quiet for a few minutes. Compaction never cuts into work.
  cleanBreak(now = Date.now()): boolean {
    if (!this.quiet || this.compactReason) return false;
    if (this.d.tasks.live().length || this.waitingOnOwner() || this.d.handoffsInFlight?.()) return false;
    return now - this.d.chat.lastUserActivity() >= COMPACT_QUIET_MS;
  }

  // Idle compaction, mirroring Claude Code's own (2.1.299): once the session
  // has been idle most of the prompt cache's one-hour life, a big context is
  // compacted before the cache expires, so the next message doesn't re-read
  // the whole thing at full price. Claude Code's version is server-gated and
  // terminal-only; SDK sessions don't get it. The timer starts when a turn
  // ends. (Size-based compaction is Claude Code's: session.compactWindowTokens.)
  private armIdleCompact(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    const minutes = this.d.config().session.idleCompactMinutes;
    this.idleStamp = Date.now();
    if (!(minutes > 0)) return;
    const stamp = this.idleStamp;
    this.idleTimer = setTimeout(() => this.idleCompactFire(stamp), minutes * 60_000);
    (this.idleTimer as any).unref?.();
  }

  /** Cancel the idle timer (the host is shutting down). */
  stopIdleCompact(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
  }

  private idleCompactFire(stamp: number): void {
    this.idleTimer = null;
    if (this.maybeIdleCompact(stamp) === "later") {
      this.idleTimer = setTimeout(() => this.idleCompactFire(stamp), COMPACT_RETRY_MS);
      (this.idleTimer as any).unref?.();
    }
  }

  // Compacts (the harness' native /compact, no instructions) if the idle
  // stretch that began at `stamp` is still going, the context is big enough and
  // this is a clean break. "later": still idle but not a clean break yet.
  maybeIdleCompact(stamp = this.idleStamp, now = Date.now()): "started" | "later" | null {
    const s = this.d.config().session;
    if (!(s.idleCompactMinutes > 0) || !stamp || stamp !== this.idleStamp) return null; // a newer turn began
    if (this.idleFiredFor === stamp) return null; // once per idle stretch
    if (now - stamp < s.idleCompactMinutes * 60_000) return null;
    const tokens = this.lastContextTokens;
    if (tokens < s.idleCompactMinTokens) return null;
    if (!this.cleanBreak(now)) return "later";
    this.idleFiredFor = stamp;
    this.compactReason = "idle";
    this.d.audit.log("session.compact.start", { reason: "idle", tokens });
    this.enqueue({ text: "/compact", origin: "system", proactive: true, maintenance: true, label: "compact" });
    return "started";
  }

  // ---------------- the process stays up ----------------
  // The assistant's process is never closed for being idle: other Claude Code
  // sessions find it by name (SendMessage) only while it runs, and a session
  // that was closed dropped out of their list until the next message woke it
  // (pals-prd §16). An idle process costs memory, not tokens. onIdle() is what
  // closing used to do, kept for the tests that resume a closed session.

  onIdle(): void {
    if (this.current || this.queue.length || this.allyGate || this.held.length || !this.session) return;
    // Close the CLI process; the next message resumes the same conversation.
    // (Keeping the context in shape is the harness' job: it compacts on its own.)
    if (!this.d.tasks.live().length && !this.waitingOnOwner()) {
      this.session.close();
      this.session = null;
      this.d.metric({ type: "idle_close", contextTokens: this.lastContextTokens });
    }
  }

  // ---------------- 回到这里重来 (docs/rewind-prd.md) ----------------

  /** A rewind whose fork Claude Code hasn't written yet (none once it has). */
  private pendingRewind(): PendingRewind | undefined {
    const rt = this.d.runtime.data;
    if (!rt.rewind) return undefined;
    const path = rt.sessionId ? this.d.transcriptOf?.(rt.sessionId) : undefined;
    if (path && existsSync(path)) {
      this.d.runtime.update({ rewind: undefined });
      return undefined;
    }
    return rt.rewind;
  }

  /** Why the conversation can't be taken back now (a turn is on), or null. */
  rewindBlocker(): string | null {
    if (this.current || this.pending.size || this.allyGate || this.held.length || this.d.tasks.live().length) return rewindBusy();
    return null;
  }

  /**
   * The session whose transcript has the conversation as it stands: the
   * current one, or (a rewind not followed by a message yet) the one it
   * will be forked from, with that rewind.
   */
  rewindSource(): { sessionId?: string; pending?: PendingRewind } {
    const pending = this.pendingRewind();
    return pending ? { sessionId: pending.from, pending } : { sessionId: this.d.runtime.data.sessionId };
  }

  /**
   * Goes back to just before the owner's message `cut`: the process ends,
   * and the next one is a new session (`to`) forked from `from` after the
   * entry `at` (none: a fresh one). The context size is unknown until it
   * has run a turn.
   */
  //
  // `written`: the new session is already on disk (a copy made before a
  // compaction, docs/rewind-prd.md §4.1): it's simply resumed.
  rewindTo(r: PendingRewind & { to: string; written?: boolean }): void {
    this.session?.close();
    this.session = null;
    this.lastContextTokens = 0;
    this.d.runtime.update({ sessionId: r.to, rewind: r.written ? undefined : { from: r.from, at: r.at, cut: r.cut }, contextTokens: 0 });
    this.d.statusChanged();
  }

  // ---------------- the stall watchdog ----------------

  /** What the stall watchdog watches (stallWatch.ts): the assistant's own process. */
  stallTarget(h: MainStallHooks): StallTarget {
    return {
      key: "main",
      get name() {
        return h.name();
      },
      busy: () => !!this.session && !this.session.closed && (!!this.current || this.pending.size > 0),
      waiting: () => this.waitingOnOwner(),
      openTools: () => [...this.liveTools.values()],
      lastActivity: () => Math.max(this.lastEventAt, this.session?.lastActivity ?? 0),
      pid: () => h.pid(),
      transcript: () => h.transcript(),
      recover: () => this.recoverStall(h),
    };
  }

  /**
   * The process froze mid-work: it's ended (killed if it must be) and the
   * next one resumes the same session. The owner's words it never took go in
   * again; a turn it was in is asked to go on, as the same kind of turn. An
   * Ally's turn isn't: its message died with the process, as after a crash.
   */
  async recoverStall(h: Pick<MainStallHooks, "pid" | "transcript" | "kill">): Promise<StallRecovery> {
    const pid = h.pid();
    const turn = this.current;
    const gate = this.allyGate;
    const session = this.session;
    this.session = null;
    session?.close();
    await h.kill(pid);
    // Nothing writes the transcript now: what's in it was taken.
    const path = h.transcript();
    const sent = [...this.pending];
    const untaken = sent.filter(([uuid]) => !transcriptHas(path, uuid));
    const taken = sent.filter(([uuid]) => !untaken.some(([u]) => u === uuid)).map(([, p]) => p);
    this.pending.clear();
    if (gate) {
      this.allyGate = null;
      if (this.gateTimer) clearTimeout(this.gateTimer);
      this.gateTimer = null;
      this.d.audit.log("ally.turn.end", { allyId: gate.allyId, why: "stalled", held: this.held.length });
    }
    this.d.log(`main session stalled; resuming it (${untaken.length} message(s) to send again)`);
    // The turn it was in (or the one it had just taken the owner's words for) goes on first.
    const resumeAs: Pick<Turn, "origin" | "proactive" | "wechat" | "watchId"> | null =
      untaken.length || gate || turn?.maintenance ? null : (turn ?? (taken.length ? { origin: taken[0]!.origin, proactive: false, wechat: taken[0]!.wechat } : null));
    if (resumeAs) {
      this.queue.unshift({
        text: resumeAs.proactive ? stallContinueProactive() : stallContinue(),
        origin: resumeAs.origin,
        proactive: resumeAs.proactive,
        wechat: resumeAs.wechat,
        label: "resume",
        ...(resumeAs.watchId ? { watchId: resumeAs.watchId } : {}),
      });
    }
    const now = Date.now();
    for (const [uuid, p] of untaken) this.pending.set(uuid, { ...p, sentAt: now });
    if (turn) this.endTurn(0, this.lastContextTokens);
    if (untaken.length) {
      if (!this.current) {
        this.beginTurn({
          text: "",
          origin: untaken[0]![1].origin,
          proactive: false,
          wechat: untaken.map(([, p]) => p.wechat).find(Boolean),
          uuids: untaken.map(([u]) => u),
        });
      }
      for (const [uuid, p] of untaken) this.ensureSession().send(p.text, uuid, p.images);
    }
    // The owner's words held for the Ally's turn go now, each as it would have.
    for (const m of this.held.splice(0)) this.sendOwner(m.text, m.origin, m.wechat, m.images, m.uuid);
    this.pump();
    this.d.statusChanged();
    return { resent: untaken.length, continued: !!resumeAs };
  }

  // ---------------- stop ----------------

  // stopAll interrupts what the harness is doing right now (its own interrupt
  // and stopTask). Nothing stays blocked afterwards: the next message works as usual.
  stopAll(by: string): void {
    this.d.audit.log("stop", { by });
    this.queue = [];
    // As with words already sent: stopped, not carried over.
    if (this.allyGate) {
      this.held = [];
      this.allyGate = null;
      if (this.gateTimer) clearTimeout(this.gateTimer);
    }
    this.d.approvals.denyAll(`stop:${by}`);
    this.d.questions.cancelAll(`stop:${by}`);
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
    this.session?.close();
    this.session = null;
  }
}
