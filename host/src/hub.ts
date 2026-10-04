import { ApprovalManager } from "./approvals.ts";
import { ArtifactLibrary } from "./artifacts.ts";
import { Audit } from "./audit.ts";
import { Bus } from "./bus.ts";
import { ChatLog } from "./chat.ts";
import { type Config, type Paths, type Settings, VERSION, patchConfig, validateSettings } from "./config.ts";
import { BEHAVIOR } from "./home.ts";
import type { HarnessDriver, HarnessEvent, MainSession, ModelOption, SlashCommandInfo, ToolHandlers } from "./harness/types.ts";
import { MemoryView, autoMemoryDir } from "./memory.ts";
import { ProbeScheduler, type ProbeTrigger } from "./probe.ts";
import { Router, type Pusher, type WechatOut } from "./router.ts";
import { TaskTracker } from "./tasks.ts";
import type { Approval, Channel, ChatMessage, Status, Task, Watch } from "./types.ts";
import { randomUUID } from "node:crypto";
import { appendJsonl, formatDuration, readJson, truncate, writeJson, zonedParts } from "./util.ts";
import { WatchStore } from "./watches.ts";

export interface ClientConn {
  id: string;
  kind: string; // "app" | "cli"
  send(msg: unknown): void;
}

export interface WechatReplyTarget {
  userId: string;
  contextToken: string;
}

export interface WechatChannel extends WechatOut {
  status(): "off" | "connected" | "expired";
  reply(target: WechatReplyTarget, text: string): Promise<void>;
}

interface Turn {
  text: string; // what the model sees
  origin: Channel;
  proactive: boolean; // output is filtered for [skip] and routed as a push
  wechat?: WechatReplyTarget;
  implicit?: boolean; // harness started a turn on its own (e.g. a background task finished)
  label?: string;
  uuids?: string[]; // user messages this turn answers
}

interface Runtime {
  sessionId?: string;
  sessionCostUsd?: number; // running total the harness reports for this session
  lastHeartbeat?: number;
}

interface Usage {
  day: string;
  mainUsd: number;
  probeUsd: number;
}

const SKIP = /^\s*\[skip\]\s*$/i;
const HEARTBEAT_MS = 60_000;
// A turn the harness started by itself is closed if it goes quiet without a result.
export const timing = { implicitQuietMs: 90_000 };
// After a restart, an owner message this recent with no reply is sent again.
const REDELIVER_WINDOW_MS = 30 * 60_000;

// Plain words for what the assistant is doing right now (shown while busy).
// friendlyError turns harness/API errors into something the owner can act on.
export function friendlyError(error: string): string {
  const e = error.toLowerCase();
  if (/rate.?limit|429|overloaded|529/.test(e)) return "模型那边太忙了，这一步没做完。稍后再跟我说一次就好。";
  if (/not logged in|unauthorized|401|invalid api key|authentication/.test(e)) return "我连不上模型了（登录失效）。请在电脑上运行 claude 重新登录，或者检查 API 密钥。";
  if (/credit|billing|quota|usage limit/.test(e)) return "模型额度用完了，等额度恢复或者换个模型再试。";
  if (/network|econn|timed? ?out|socket|fetch failed/.test(e)) return "网络出了问题，这一步没做完。网络恢复后再跟我说一次。";
  if (/exited with code|process/.test(e)) return "我这边刚才意外中断了，已经重新准备好。刚才那件事可以再说一次。";
  return `出了点问题，这一步没做完。（${truncate(error, 120)}）`;
}

// stripSkip removes the "[skip]" marker a proactive turn uses to stay silent.
export function stripSkip(text: string): string {
  return text
    .split(/\n{2,}/)
    .filter((p) => !SKIP.test(p))
    .join("\n\n")
    .trim();
}

export function describeActivity(tool: string): string {
  if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") return "正在写文件";
  if (tool === "Bash") return "正在电脑上跑命令";
  if (tool === "Read" || tool === "Grep" || tool === "Glob") return "正在翻资料";
  if (tool === "WebSearch" || tool === "WebFetch") return "正在网上查";
  if (tool === "Agent" || tool === "Task") return "正在安排后台的事";
  if (/browser_/.test(tool)) return "正在用浏览器";
  if (tool.startsWith("mcp__paloally__")) return "正在整理";
  return "正在处理";
}

export interface HubDeps {
  paths: Paths;
  config: Config;
  driver: HarnessDriver;
  pushers?: Pusher[];
  wechat?: WechatChannel | null;
  now?: () => number;
  log?: (s: string) => void;
}

// Hub wires everything: one main conversation, the task projection, approvals,
// the probe, artifacts, memory, and every client channel.
export class Hub {
  readonly bus = new Bus();
  readonly paths: Paths;
  config: Config;
  readonly audit: Audit;
  readonly chat: ChatLog;
  readonly tasks: TaskTracker;
  readonly approvals: ApprovalManager;
  readonly watches: WatchStore;
  readonly artifacts: ArtifactLibrary;
  readonly memory: MemoryView;
  readonly router: Router;
  readonly probe: ProbeScheduler;
  private driver: HarnessDriver;
  private wechat: WechatChannel | null;
  private pushers: Pusher[];
  private log: (s: string) => void;

  private session: MainSession | null = null;
  private queue: Turn[] = [];
  private current: Turn | null = null;
  private turnTexts: string[] = [];
  private deltaId: string | null = null;
  private model = "";
  private runtime: Runtime;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private lastContextTokens = 0;
  private clients = new Map<string, { conn: ClientConn; off: () => void }>();
  private turnWaiters: (() => void)[] = [];
  // Every owner message sent to the harness and not yet answered, by uuid.
  // A turn counts as answering the owner only once its result lists the uuid.
  private pending = new Map<string, { origin: Channel; wechat?: WechatReplyTarget; sentAt: number }>();
  private openTools = new Set<string>(); // main-thread tool calls without a result yet
  private deltaText = ""; // streamed text of the current delta id, to finalize if the turn dies
  private implicitTimer: ReturnType<typeof setTimeout> | null = null;
  private activity = "";
  // set by the daemon: drops a paired device (its relay pairing)
  onUnpairDevice?: (deviceId: string) => void;
  private terminalCommands = new Set(["doctor", "color", "focus", "reload-plugins", "exit", "quit", "statusline", "terminal-setup", "vim", "ide"]);
  private commandWaiters: (() => void)[] = [];
  private budgetNoticeDay = "";
  private modelWaiters: (() => void)[] = [];

  constructor(deps: HubDeps) {
    this.paths = deps.paths;
    this.config = deps.config;
    this.driver = deps.driver;
    this.wechat = deps.wechat ?? null;
    this.pushers = deps.pushers ?? [];
    this.log = deps.log ?? ((s) => console.log(`[hub] ${s}`));
    this.runtime = readJson<Runtime>(this.paths.runtime, {});

    this.audit = new Audit(this.paths.audit);
    this.chat = new ChatLog(this.paths.chat, this.bus);
    this.tasks = new TaskTracker(this.paths.tasks, this.paths.taskActivity, this.bus, (t, k) => this.onTaskTransition(t, k));
    this.watches = new WatchStore(this.paths.watches, this.bus);
    this.artifacts = new ArtifactLibrary(this.paths.artifacts, this.bus);
    this.memory = new MemoryView(this.paths.home, autoMemoryDir(this.paths.home));
    this.router = new Router(
      () => this.config.settings,
      this.pushers,
      this.wechat,
      this.audit,
      deps.now,
      () => this.chat.lastUserActivity(),
      `${this.paths.state}/push-count.json`,
    );
    this.approvals = new ApprovalManager(this.paths.approvals, this.bus, this.audit, {
      taskForToolUse: (id) => (id ? this.tasks.taskIdForToolUse(id) : undefined),
      onCreated: (a) => this.onApprovalCreated(a),
      timeoutMinutes: () => this.config.settings.approvalTimeoutMinutes,
    });
    this.probe = new ProbeScheduler({
      driver: this.driver,
      watches: this.watches,
      timezone: () => this.config.settings.timezone,
      probeModel: () => this.config.probeModel,
      cwd: () => this.paths.home,
      mcpServers: () => this.extraMcpServers(),
      inheritConnectors: () => this.config.probeInheritConnectors,
      lastUserActivity: () => this.chat.lastUserActivity(),
      budgetLeftUsd: () => this.config.budget.probeDailyUsd - this.usage().probeUsd,
      spend: (usd) => this.addUsage("probeUsd", usd),
      onSchedule: (w) => this.onSchedule(w),
      onTriggers: (t) => this.onProbeTriggers(t),
      log: (s) => this.log(`probe: ${s}`),
    });
  }

  // ---------------- lifecycle ----------------

  start(opts: { probe?: boolean; watchArtifacts?: boolean } = {}): void {
    const orphaned = this.tasks.orphanRunning();
    this.recoverAfterRestart(orphaned); // before the offline notice, which isn't an answer
    this.detectOffline();
    this.beat();
    this.heartbeat = setInterval(() => this.beat(), HEARTBEAT_MS);
    if (opts.probe !== false) {
      this.probe.start(this.config.settings.probeIntervalMinutes);
      setTimeout(() => void this.probe.tick(), 5_000);
    }
    if (opts.watchArtifacts !== false) this.artifacts.watch();
    this.emitStatus();
  }

  stop(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.probe.stop();
    this.artifacts.stop();
    this.session?.close();
    this.session = null;
    for (const c of this.clients.values()) c.off();
  }

  get busy(): boolean {
    return this.current !== null;
  }

  status(): Status {
    return {
      online: true,
      busy: this.busy,
      activity: this.busy ? this.activity || "正在想" : undefined,
      model: this.model || this.config.model || "",
      effort: this.config.effort,
      sessionId: this.runtime.sessionId,
      wechat: this.wechat?.status() ?? "off",
      version: VERSION,
    };
  }

  // Resolves when the turn queue is drained (tests, CLI one-shots).
  idle(): Promise<void> {
    if (!this.current && !this.queue.length && !this.pending.size) return Promise.resolve();
    return new Promise((r) => this.turnWaiters.push(r));
  }

  // ---------------- inputs ----------------

  // A message from the owner on any channel.
  userMessage(text: string, channel: Channel, wechat?: WechatReplyTarget, clientMsgId?: string): ChatMessage | null {
    const t = text.trim();
    if (!t) return null;
    const cmd = this.tryCommand(t, channel, wechat);
    const msg = this.chat.add({ role: "user", kind: "text", text: t, channel, ...(clientMsgId ? { clientMsgId } : {}) });
    if (cmd !== null) {
      this.reply(cmd, channel, wechat);
      return msg;
    }
    // Slash commands must reach the harness verbatim, so they get no prefix.
    const prefix = channel === "wechat" && !t.startsWith("/") ? "[来自微信] " : "";
    this.sendUser(prefix + t, channel, wechat);
    return msg;
  }

  // Owner messages go to the harness immediately, even mid-turn: Claude Code
  // queues them or folds them into the running turn, so "好了吗" gets heard
  // while work is in progress. Only proactive turns wait for idle.
  private sendUser(text: string, origin: Channel, wechat?: WechatReplyTarget): void {
    const uuid = randomUUID();
    this.pending.set(uuid, { origin, wechat, sentAt: Date.now() });
    if (!this.current) this.beginTurn({ text, origin, proactive: false, wechat, uuids: [uuid] });
    this.ensureSession().send(text, uuid);
  }

  private tryCommand(t: string, channel: Channel, wechat?: WechatReplyTarget): string | null {
    const by = channel;
    if (/^\/(stop|停)$/i.test(t)) {
      this.stopAll(by);
      return "好，手上的事都停下了。";
    }
    if (/^\/status$/i.test(t)) {
      const s = this.status();
      const running = this.tasks.running().length;
      const pending = this.approvals.listPending().length;
      return `${s.busy ? "忙着" : "空闲"}；进行中的任务 ${running} 个，待确认 ${pending} 个。`;
    }
    // Answering an approval in text needs its 4-character code ("同意 3f2a"), so
    // an ordinary "ok"/"yes" in conversation can never approve anything.
    const m = /^(同意|批准|允许|拒绝|不同意)\s*([0-9a-f]{4})$/i.exec(t);
    if (m) {
      const target = this.approvals.listPending().find((a) => a.id.endsWith(m[2]!.toLowerCase()));
      if (target) {
        const allow = /^(同意|批准|允许)$/.test(m[1]!);
        this.approvals.answer(target.id, allow, `${channel}`);
        return allow ? "好，已同意。" : "好，已拒绝。";
      }
    }
    return null;
  }

  private reply(text: string, channel: Channel, wechat?: WechatReplyTarget): void {
    this.chat.add({ role: "system", kind: "notice", text, channel: "system" });
    if (channel === "wechat" && wechat && this.wechat) void this.wechat.reply(wechat, text).catch(() => {});
  }

  // ---------------- turn queue ----------------

  private enqueue(turn: Turn): void {
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
    if (turn.proactive && this.overMainBudget()) {
      this.log(`proactive turn dropped: main budget used up (${turn.label ?? turn.origin})`);
      if (this.budgetNoticeDay !== this.usage().day) {
        this.budgetNoticeDay = this.usage().day;
        this.chat.add({ role: "system", kind: "notice", text: `今天的花费到了你设的上限，定时和盯梢的事先停下了（比如「${turn.label ?? "定时任务"}」）。明天会恢复。`, channel: "system" });
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
    this.deltaId = null;
    this.deltaText = "";
    this.openTools.clear();
    this.activity = "";
    if (turn.implicit) this.armImplicitTimer();
    this.emitStatus();
  }

  private armImplicitTimer(): void {
    if (this.implicitTimer) clearTimeout(this.implicitTimer);
    this.implicitTimer = setTimeout(() => {
      // Waiting on the owner or on a running tool is not "quiet".
      if (this.current?.implicit && (this.openTools.size || this.approvals.listPending().length)) return this.armImplicitTimer();
      if (this.current?.implicit) {
        this.log("implicit turn went quiet without a result; closing it");
        this.endTurn(0, this.lastContextTokens);
      }
    }, timing.implicitQuietMs);
  }

  private ensureSession(): MainSession {
    if (this.session && !this.session.closed) return this.session;
    this.session = this.driver.startMain({
      cwd: this.paths.home,
      model: this.config.model,
      effort: this.config.effort,
      resumeSessionId: this.runtime.sessionId,
      priorCostUsd: this.runtime.sessionId ? this.runtime.sessionCostUsd : undefined,
      permissionMode: this.config.permissionMode,
      appendSystemPrompt: BEHAVIOR + `\n\n主人所在时区：${this.config.settings.timezone}。`,
      tools: this.toolHandlers(),
      canUseTool: (req) => this.approvals.request(req),
      mcpServers: this.extraMcpServers(),
      sharedChrome: this.config.browser.enabled && this.config.browser.mode === "shared",
      onEvent: (e) => this.onHarnessEvent(e),
      stderr: (s) => appendJsonl(`${this.paths.logs}/harness-stderr.jsonl`, { ts: Date.now(), s: truncate(s, 2000) }),
    });
    return this.session;
  }

  extraMcpServers(): Record<string, unknown> {
    const servers: Record<string, unknown> = { ...this.config.extraMcpServers };
    if (this.config.browser.enabled && this.config.browser.mode === "dedicated") {
      const cmd = this.config.browser.command ?? [
        "npx",
        "-y",
        "@playwright/mcp@latest",
        "--browser",
        "chrome",
        "--user-data-dir",
        this.paths.browserProfile,
      ];
      servers.browser = { type: "stdio", command: cmd[0], args: cmd.slice(1) };
    }
    return servers;
  }

  // ---------------- harness events ----------------

  onHarnessEvent(e: HarnessEvent): void {
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
    switch (e.type) {
      case "commands":
        this.saveCommands(e.commands);
        break;
      case "models":
        writeJson(`${this.paths.state}/models.json`, e.models);
        for (const w of this.modelWaiters.splice(0)) w();
        break;
      case "init":
        this.model = e.model;
        if (e.terminalCommands) this.terminalCommands = new Set(e.terminalCommands);
        if (this.runtime.sessionId !== e.sessionId) {
          this.runtime.sessionId = e.sessionId;
          this.saveRuntime();
        }
        this.emitStatus();
        break;
      case "text_delta":
        if (turn && !turn.proactive) {
          if (!this.deltaId) this.deltaId = `m_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
          this.deltaText += e.text;
          this.chat.delta(this.deltaId, e.text);
        }
        break;
      case "assistant_text":
        if (e.parentToolUseId) {
          this.tasks.onSubagentText(e.text, e.parentToolUseId);
          break;
        }
        this.turnTexts.push(e.text);
        if (turn && !turn.proactive) {
          this.chat.add({ id: this.deltaId ?? undefined, role: "assistant", kind: "text", text: e.text, channel: turn.origin });
        }
        this.deltaId = null;
        this.deltaText = "";
        break;
      case "tool_start":
        if (!e.parentToolUseId) this.setActivity(describeActivity(e.name));
        break;
      case "tool_use":
        if (!e.parentToolUseId) this.openTools.add(e.id);
        this.tasks.onToolUse(e.id, e.name, e.input, e.parentToolUseId);
        this.setActivity(e.parentToolUseId ? "后台在办事" : describeActivity(e.name));
        break;
      case "tool_result":
        this.openTools.delete(e.toolUseId);
        this.tasks.onToolResult(e.toolUseId, e.content, e.isError, e.parentToolUseId);
        break;
      case "task_started":
        this.tasks.onTaskStarted(e.taskId, e.toolUseId, e.background);
        break;
      case "task_backgrounded":
        this.tasks.onTaskBackgrounded(e.taskId);
        break;
      case "task_notification":
        this.tasks.onTaskNotification(e.taskId, e.toolUseId, e.status, e.summary);
        break;
      case "compact":
        this.metric({ type: "compact", trigger: e.trigger, preTokens: e.preTokens, postTokens: e.postTokens });
        break;
      case "result":
        this.runtime.sessionCostUsd = e.totalCostUsd;
        this.saveRuntime();
        this.endTurn(e.costUsd, e.contextTokens, e.isError ? e.text : undefined, this.consume(e.consumedUuids));
        break;
      case "error":
        this.log(`harness error: ${e.message}`);
        this.session?.close();
        this.session = null;
        this.pending.clear();
        if (this.current) this.endTurn(0, this.lastContextTokens, e.message);
        break;
    }
  }

  private setActivity(a: string): void {
    if (a === this.activity) return;
    this.activity = a;
    this.emitStatus();
  }

  // consume settles which owner messages a result answered. When the harness
  // doesn't say (older CLIs), an owner turn is taken to have answered its own
  // messages; a proactive/implicit turn answered none.
  private consume(listed?: string[]): { origin: Channel; wechat?: WechatReplyTarget }[] {
    const ids = listed ?? (this.current && !this.current.proactive ? this.current.uuids ?? [] : []);
    const answered: { origin: Channel; wechat?: WechatReplyTarget }[] = [];
    for (const u of ids) {
      const p = this.pending.get(u);
      if (p) answered.push(p);
      this.pending.delete(u);
    }
    return answered;
  }

  private endTurn(
    costUsd: number,
    contextTokens: number,
    error?: string,
    answered: { origin: Channel; wechat?: WechatReplyTarget }[] = [],
  ): void {
    const turn = this.current;
    this.current = null;
    this.activity = "";
    if (this.implicitTimer) clearTimeout(this.implicitTimer);
    // A stream cut off by an error/kill still gets a final message, so clients
    // don't keep a half-written bubble "typing" forever.
    if (this.deltaId) {
      if (this.deltaText.trim()) this.chat.add({ id: this.deltaId, role: "assistant", kind: "text", text: this.deltaText, channel: turn?.origin ?? "system" });
      this.deltaId = null;
      this.deltaText = "";
    }
    this.openTools.clear();
    this.addUsage("mainUsd", costUsd);
    this.lastContextTokens = contextTokens;
    this.tasks.finalizePending();
    if (turn) {
      this.metric({ type: "turn", origin: turn.origin, proactive: turn.proactive, costUsd, contextTokens, error });
      const text = this.turnTexts.join("\n\n").trim();
      if (error) {
        this.chat.add({ role: "system", kind: "notice", text: friendlyError(error), channel: "system" });
      }
      const shown = stripSkip(text);
      // The owner spoke while this proactive turn ran and it answered them too:
      // show it as a normal reply (no push), not as something it brought up.
      const ownerFolded = turn.proactive && answered.length > 0;
      if (ownerFolded) {
        if (shown) this.chat.add({ role: "assistant", kind: "text", text: shown, channel: answered[0]!.origin });
      } else if (turn.proactive) {
        if (shown) {
          const msg = this.chat.add({ role: "assistant", kind: "text", text: shown, channel: turn.origin, proactive: true });
          void this.router.proactive(msg);
        } else {
          this.metric({ type: "skip", origin: turn.origin, label: turn.label });
        }
      }
      const wechatTarget = answered.find((a) => a.wechat)?.wechat ?? (turn.proactive ? undefined : turn.wechat);
      if (wechatTarget && this.wechat && shown) {
        void this.wechat.reply(wechatTarget, shown).catch((err) => this.log(`wechat reply failed: ${err}`));
        this.audit.log("wechat.reply", { chars: shown.length });
      }
    }
    this.emitStatus();
    this.scheduleIdle();
    if (this.pending.size === 0) this.pump();
    else this.flushWaitersIfIdle();
  }

  private flushWaitersIfIdle(): void {
    if (!this.current && !this.queue.length && !this.pending.size) this.flushWaiters();
  }

  private flushWaiters(): void {
    for (const w of this.turnWaiters.splice(0)) w();
  }

  // ---------------- session idle ----------------

  private scheduleIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    const min = this.config.session.idleCloseMinutes;
    if (!min) return;
    this.idleTimer = setTimeout(() => this.onIdle(), min * 60_000);
  }

  onIdle(): void {
    if (this.current || this.queue.length || !this.session) return;
    // Close the CLI process; the next message resumes the same conversation.
    // (Keeping the context in shape is the harness' job: it compacts on its own.)
    if (!this.tasks.live().length && !this.approvals.listPending().length) {
      this.session.close();
      this.session = null;
      this.metric({ type: "idle_close", contextTokens: this.lastContextTokens });
    }
  }

  // ---------------- tool handlers (the paloally MCP server) ----------------

  toolHandlers(): ToolHandlers {
    return {
      report_task: async ({ id, summary, status, title }) => {
        const t = this.tasks.report(id, summary, status, title);
        this.audit.log("report_task", { id, status, summary });
        return `ok: ${t.id} ${t.status}`;
      },
      register_watch: async ({ title, instruction, interval_minutes, at, kind }) => {
        const w = this.watches.add({ title, instruction, intervalMinutes: interval_minutes, at, kind }, "agent");
        this.audit.log("watch.registered", { id: w.id, title });
        return `ok: ${w.id}（${w.kind === "check" ? `每 ${w.intervalMinutes} 分钟检查` : `定时 ${w.at?.join(",") ?? `每 ${w.intervalMinutes} 分钟`}`}）`;
      },
      list_watches: async () =>
        JSON.stringify(
          this.watches.list().map((w) => ({ id: w.id, title: w.title, kind: w.kind, enabled: w.enabled, instruction: w.instruction, intervalMinutes: w.intervalMinutes, at: w.at })),
        ),
      remove_watch: async ({ id }) => (this.watches.remove(id) ? "ok" : "not found"),
      publish_artifact: async ({ slug, title, main_file, type, pinned }) => {
        const a = this.artifacts.publish(slug, title, main_file, type, pinned);
        return `ok: ${a.id}（${a.files.length} 个文件）`;
      },
      notify_user: async ({ text, urgent }) => {
        const msg = this.chat.add({ role: "assistant", kind: "notice", text, channel: "system", proactive: true });
        // Decide synchronously, deliver in the background: a slow push must never block the turn.
        const delivery = this.router.proactive(msg, { urgent });
        const r = await Promise.race([delivery, new Promise<null>((res) => setTimeout(() => res(null), 1500))]);
        if (r?.suppressed) return `已记入对话（${r.suppressed === "quiet" ? "免打扰时段" : "今日推送已达上限"}，未推送）`;
        return "已推送";
      },
    };
  }

  // ---------------- proactive sources ----------------

  private onSchedule(w: Watch): void {
    // One run of the same schedule waiting is enough.
    if (this.queue.some((t) => t.label === w.title && t.origin === "schedule")) return;
    this.audit.log("schedule.fire", { id: w.id, title: w.title });
    this.enqueue({ text: `[定时·${w.title}] ${w.instruction}`, origin: "schedule", proactive: true, label: w.title });
  }

  private onProbeTriggers(triggers: ProbeTrigger[]): void {
    this.audit.log("probe.triggered", { watches: triggers.map((t) => t.watch.id) });
    const lines = triggers.map((t) => `- 「${t.watch.title}」：${t.summary}`).join("\n");
    this.enqueue({
      text: `[探针] 以下盯梢有新情况：\n${lines}\n判断是否值得告诉主人；值得就直接写给主人看的话，不值得就只回复 [skip]。`,
      origin: "probe",
      proactive: true,
      label: triggers.map((t) => t.watch.title).join(","),
    });
  }

  private onTaskTransition(t: Task, kind: "accepted" | "finished"): void {
    if (kind === "accepted") {
      this.chat.add({ role: "assistant", kind: "task", text: `收到，开始办：${t.summary || t.title}`, channel: "system", taskId: t.id });
      return;
    }
    const icon = t.status === "done" ? "✅" : t.status === "failed" ? "⚠️" : "⏹";
    const msg = this.chat.add({
      role: "assistant",
      kind: "task",
      text: `${icon} ${t.title}：${t.summary || statusWord(t.status)}`,
      channel: "system",
      taskId: t.id,
      proactive: t.status !== "stopped",
    });
    if (t.status !== "stopped") void this.router.proactive(msg, { title: t.title });
  }

  private onApprovalCreated(a: Approval): void {
    const msg = this.chat.add({
      role: "assistant",
      kind: "approval",
      text: `这一步要你点头：${a.title}${a.careful ? "（请仔细看一下）" : ""}`,
      channel: "system",
      approvalId: a.id,
      taskId: a.taskId,
      proactive: true,
    });
    void this.router.proactive(msg, { title: "需要你确认" });
  }

  // ---------------- slash commands (a hidden entry: no hints in the UI) ----------------

  private saveCommands(cmds: SlashCommandInfo[]): void {
    writeJson(`${this.paths.state}/commands.json`, cmds);
    this.bus.emit("commands.updated", { commands: this.commandList() });
    for (const w of this.commandWaiters.splice(0)) w();
  }

  // commandList merges the harness' commands with PaloAlly's own (which win on
  // a name clash) and drops the ones that only make sense in a terminal.
  commandList(): SlashCommandInfo[] {
    const own: SlashCommandInfo[] = [
      { name: "stop", description: "停下手上的事" },
      { name: "status", description: "看看我在忙什么" },
    ];
    const ownNames = new Set(own.map((c) => c.name));
    const harness = readJson<SlashCommandInfo[]>(`${this.paths.state}/commands.json`, []).filter(
      (c) => !ownNames.has(c.name) && !this.terminalCommands.has(c.name) && c.name !== "help" && !c.name.startsWith("_"),
    );
    return [...own, ...harness.sort((a, b) => a.name.localeCompare(b.name))];
  }

  // The list comes from a running harness; start one if we've never seen it.
  async loadCommands(timeoutMs = 8000): Promise<SlashCommandInfo[]> {
    if (readJson<SlashCommandInfo[]>(`${this.paths.state}/commands.json`, []).length === 0) {
      const ready = new Promise<void>((r) => this.commandWaiters.push(r));
      this.ensureSession();
      await Promise.race([ready, new Promise((r) => setTimeout(r, timeoutMs))]);
      if (!this.current) this.scheduleIdle(); // don't leave a process up just for the list
    }
    return this.commandList();
  }

  // ---------------- model & effort (shown quietly, changed from a second-level page) ----------------

  async modelInfo(timeoutMs = 8000): Promise<{ model: string; setting: string | null; effort: string | null; models: ModelOption[] }> {
    const path = `${this.paths.state}/models.json`;
    if (readJson<ModelOption[]>(path, []).length === 0) {
      const ready = new Promise<void>((r) => this.modelWaiters.push(r));
      this.ensureSession();
      await Promise.race([ready, new Promise((r) => setTimeout(r, timeoutMs))]);
      if (!this.current) this.scheduleIdle();
    }
    return { model: this.status().model, setting: this.config.model ?? null, effort: this.config.effort ?? null, models: readJson<ModelOption[]>(path, []) };
  }

  // setModel persists the choice and applies it to the running conversation.
  // `null` goes back to the default.
  async setModel(patch: { model?: string | null; effort?: string | null }): Promise<Status> {
    const efforts = ["low", "medium", "high", "xhigh", "max"];
    if (patch.effort != null && !efforts.includes(patch.effort)) throw new Error("思考深度不对");
    if (patch.model != null) {
      const known = readJson<ModelOption[]>(`${this.paths.state}/models.json`, []);
      const ok = known.length ? known.some((m) => m.value === patch.model) : /^[\w.\-:[\]]{1,80}$/.test(patch.model);
      if (!ok) throw new Error(`没有这个模型：${patch.model}`);
    }
    if ("model" in patch) {
      this.config.model = patch.model || undefined;
      if (patch.model) this.model = "";
      await this.session?.setModel(this.config.model).catch((e) => this.log(`setModel failed: ${e}`));
    }
    if ("effort" in patch) {
      this.config.effort = (patch.effort || undefined) as Config["effort"];
      await this.session?.setEffort(this.config.effort).catch((e) => this.log(`setEffort failed: ${e}`));
    }
    patchConfig(this.paths, (c) => {
      c.model = this.config.model;
      c.effort = this.config.effort;
    });
    this.audit.log("model.set", { model: this.config.model ?? "default", effort: this.config.effort ?? "default" });
    this.emitStatus();
    return this.status();
  }

  // ---------------- stop button ----------------

  // stopAll interrupts what the harness is doing right now (its own interrupt
  // and stopTask). Nothing stays blocked afterwards: the next message works as usual.
  stopAll(by: string): void {
    this.audit.log("stop", { by });
    this.queue = [];
    this.approvals.denyAll(`stop:${by}`);
    for (const t of this.tasks.running()) {
      if (t.sdkTaskId) void this.session?.stopTask(t.sdkTaskId).catch(() => {});
      this.tasks.markStopped(t.id);
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
    this.emitStatus();
  }

  async stopTask(id: string): Promise<Task | undefined> {
    const t = this.tasks.get(id);
    if (!t) return undefined;
    if (t.sdkTaskId) {
      await this.session?.stopTask(t.sdkTaskId).catch(() => {});
    } else if (t.toolUseId && this.current) {
      // A foreground subagent runs inside the current turn: stopping it means
      // interrupting that turn.
      await this.session?.interrupt();
    }
    this.audit.log("task.stop", { id });
    return this.tasks.markStopped(t.id);
  }

  // ---------------- settings ----------------

  updateSettings(patch: Partial<Settings>): Settings {
    const next = validateSettings(this.config.settings, patch as Record<string, unknown>);
    const probeChanged = next.probeIntervalMinutes !== this.config.settings.probeIntervalMinutes;
    this.config.settings = next;
    patchConfig(this.paths, (c) => (c.settings = next));
    if (probeChanged) this.probe.start(next.probeIntervalMinutes);
    this.bus.emit("settings.updated", next);
    return next;
  }

  // ---------------- clients ----------------

  attach(conn: ClientConn): void {
    const off = this.bus.on((event, data) => conn.send({ event, data }));
    this.clients.set(conn.id, { conn, off });
    this.audit.log("client.attach", { id: conn.id, kind: conn.kind });
  }

  detach(id: string): void {
    const c = this.clients.get(id);
    if (!c) return;
    c.off();
    this.clients.delete(id);
  }

  clientCount(): number {
    return this.clients.size;
  }

  // ---------------- bookkeeping ----------------

  private emitStatus(): void {
    this.bus.emit("status", this.status());
  }

  private saveRuntime(): void {
    writeJson(this.paths.runtime, this.runtime);
  }

  private beat(): void {
    this.runtime.lastHeartbeat = Date.now();
    this.saveRuntime();
  }

  // A restart cuts off work in flight. Tell the assistant what was lost and let
  // it pick things back up, rather than leaving a silent "stopped".
  private recoverAfterRestart(orphaned: Task[]): void {
    const lines: string[] = [];
    if (orphaned.length) lines.push(`这些后台任务被打断了：${orphaned.map((t) => `「${t.title}」`).join("、")}。`);
    const msgs = this.chat.recent(50);
    let lastOwner = -1;
    for (let i = msgs.length - 1; i >= 0; i--) {
      const m = msgs[i]!;
      if (m.role === "user" && (m.channel === "app" || m.channel === "cli" || m.channel === "wechat")) {
        lastOwner = i;
        break;
      }
    }
    const owner = lastOwner >= 0 ? msgs[lastOwner]! : undefined;
    const answered = msgs.slice(lastOwner + 1).some((m) => m.role === "assistant" && m.kind === "text" && !m.proactive);
    if (owner && !answered && Date.now() - owner.ts < REDELIVER_WINDOW_MS) {
      lines.push(`主人在重启前发的这条消息还没回：「${truncate(owner.text, 500)}」。`);
    }
    if (!lines.length) return;
    this.audit.log("restart.recover", { orphaned: orphaned.length, redeliver: !!owner && !answered });
    this.enqueue({
      text: `[系统] 助理刚刚重启了。${lines.join("")}需要的话接着办或者回答主人；都不需要就只回复 [skip]。`,
      origin: "system",
      proactive: true,
      label: "restart",
    });
  }

  // restartWhenIdle exits once nothing is in flight; the service manager
  // (launchd / systemd) starts a fresh process. Never cuts work off.
  async restartWhenIdle(maxWaitMs = 30 * 60_000, exit: () => void = () => process.exit(0)): Promise<"restarting" | "timeout"> {
    const deadline = Date.now() + maxWaitMs;
    while (Date.now() < deadline) {
      if (!this.current && !this.queue.length && !this.pending.size && !this.tasks.live().length && !this.approvals.listPending().length) {
        this.audit.log("restart", {});
        setTimeout(exit, 200);
        return "restarting";
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
    return "timeout";
  }

  private detectOffline(): void {
    const last = this.runtime.lastHeartbeat;
    if (!last) return;
    const gap = Date.now() - last;
    const threshold = 2 * this.config.settings.probeIntervalMinutes * 60_000 + HEARTBEAT_MS;
    if (gap <= threshold) return;
    const tz = this.config.settings.timezone;
    const f = (ms: number) => {
      const p = zonedParts(ms, tz);
      return `${p.month}/${p.day} ${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
    };
    const msg = this.chat.add({
      role: "system",
      kind: "notice",
      text: `我掉线了 ${formatDuration(gap)}（${f(last)} – ${f(Date.now())}），刚恢复。6 小时内错过的定时任务我会补上，更早的就跳过了；这段时间的微信消息可能没收到。`,
      channel: "system",
      proactive: true,
    });
    this.metric({ type: "offline", gapMs: gap });
    void this.router.proactive(msg, { title: "我回来了" });
  }

  usage(): Usage {
    const day = zonedParts(Date.now(), this.config.settings.timezone).dateKey;
    const u = readJson<Usage>(this.paths.usage, { day, mainUsd: 0, probeUsd: 0 });
    return u.day === day ? u : { day, mainUsd: 0, probeUsd: 0 };
  }

  private addUsage(field: "mainUsd" | "probeUsd", usd: number): void {
    if (!usd) return;
    const u = this.usage();
    u[field] += usd;
    writeJson(this.paths.usage, u);
  }

  private overMainBudget(): boolean {
    const cap = this.config.budget.mainDailyUsd;
    return cap > 0 && this.usage().mainUsd >= cap;
  }

  private metric(m: Record<string, unknown>): void {
    appendJsonl(this.paths.metrics, { ts: Date.now(), ...m });
  }
}


function statusWord(s: string): string {
  return s === "done" ? "办完了" : s === "failed" ? "没办成" : s === "needs_input" ? "需要你" : "已停止";
}
