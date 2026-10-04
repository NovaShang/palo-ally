import { ApprovalManager } from "./approvals.ts";
import { ArtifactLibrary } from "./artifacts.ts";
import { Audit } from "./audit.ts";
import { Bus } from "./bus.ts";
import { ChatLog } from "./chat.ts";
import { type Config, type Paths, type Settings, VERSION, saveConfig } from "./config.ts";
import { BEHAVIOR } from "./home.ts";
import type { HarnessDriver, HarnessEvent, MainSession, ToolHandlers } from "./harness/types.ts";
import { MemoryView, autoMemoryDir } from "./memory.ts";
import { ProbeScheduler, type ProbeTrigger } from "./probe.ts";
import { Router, type Pusher, type WechatOut } from "./router.ts";
import { TaskTracker } from "./tasks.ts";
import type { Approval, Channel, ChatMessage, Status, Task, Watch } from "./types.ts";
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
  hidden?: boolean; // internal (flush): never shown
  wechat?: WechatReplyTarget;
  implicit?: boolean; // harness started a turn on its own (e.g. a background task finished)
  label?: string;
}

interface Runtime {
  sessionId?: string;
  killed?: boolean;
  lastHeartbeat?: number;
}

interface Usage {
  day: string;
  mainUsd: number;
  probeUsd: number;
}

const SKIP = /^\s*\[skip\]\s*$/i;
const HEARTBEAT_MS = 60_000;

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
  private rollPending = false;
  private clients = new Map<string, { conn: ClientConn; off: () => void }>();
  private turnWaiters: (() => void)[] = [];

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
    this.router = new Router(() => this.config.settings, this.pushers, this.wechat, this.audit, deps.now);
    this.approvals = new ApprovalManager(this.paths.approvals, this.paths.rules, this.bus, this.audit, {
      isKilled: () => this.killed,
      taskForToolUse: (id) => (id ? this.tasks.taskIdForToolUse(id) : undefined),
      onCreated: (a) => this.onApprovalCreated(a),
      timeoutMinutes: () => this.config.settings.approvalTimeoutMinutes,
      sensitiveDomains: () => this.config.browser.sensitiveDomains,
    });
    this.probe = new ProbeScheduler({
      driver: this.driver,
      watches: this.watches,
      isKilled: () => this.killed,
      timezone: () => this.config.settings.timezone,
      probeModel: () => this.config.probeModel,
      cwd: () => this.paths.home,
      mcpServers: () => this.extraMcpServers(),
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
    this.tasks.orphanRunning();
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

  get killed(): boolean {
    return !!this.runtime.killed;
  }

  get busy(): boolean {
    return this.current !== null;
  }

  status(): Status {
    return {
      online: true,
      killed: this.killed,
      busy: this.busy,
      model: this.model || this.config.model || "",
      sessionId: this.runtime.sessionId,
      wechat: this.wechat?.status() ?? "off",
      version: VERSION,
    };
  }

  // Resolves when the turn queue is drained (tests, CLI one-shots).
  idle(): Promise<void> {
    if (!this.current && !this.queue.length) return Promise.resolve();
    return new Promise((r) => this.turnWaiters.push(r));
  }

  // ---------------- inputs ----------------

  // A message from the owner on any channel.
  userMessage(text: string, channel: Channel, wechat?: WechatReplyTarget): ChatMessage | null {
    const t = text.trim();
    if (!t) return null;
    const cmd = this.tryCommand(t, channel, wechat);
    const msg = this.chat.add({ role: "user", kind: "text", text: t, channel });
    if (cmd !== null) {
      this.reply(cmd, channel, wechat);
      return msg;
    }
    if (this.killed) {
      this.reply("我现在处于急停状态，什么都不会做。发送 /resume（或在 App 里点恢复）让我继续。", channel, wechat);
      return msg;
    }
    const prefix = channel === "wechat" ? "[来自微信] " : "";
    this.enqueue({ text: prefix + t, origin: channel, proactive: false, wechat });
    return msg;
  }

  private tryCommand(t: string, channel: Channel, wechat?: WechatReplyTarget): string | null {
    const by = channel;
    if (/^\/(kill|stop|急停)$/i.test(t)) {
      this.kill(by);
      return "已急停：当前的事都停下了，之后的操作一律拒绝。发送 /resume 恢复。";
    }
    if (/^\/(resume|恢复)$/i.test(t)) {
      this.resume(by);
      return "好，我回来了。";
    }
    if (/^\/status$/i.test(t)) {
      const s = this.status();
      const running = this.tasks.running().length;
      const pending = this.approvals.listPending().length;
      return `${s.killed ? "急停中" : s.busy ? "忙着" : "空闲"}；进行中的任务 ${running} 个，待确认 ${pending} 个。`;
    }
    const m = /^(同意|批准|允许|ok|yes|拒绝|不同意|不行|no)\s*([0-9a-z]{4,})?$/i.exec(t);
    if (m && this.approvals.listPending().length) {
      const allow = /^(同意|批准|允许|ok|yes)$/i.test(m[1]!);
      const pending = this.approvals.listPending();
      const target = m[2] ? pending.find((a) => a.id.endsWith(m[2]!.toLowerCase())) : pending.length === 1 ? pending[0] : undefined;
      if (!target) return `有 ${pending.length} 个待确认，请带上编号，比如「同意 ${shortId(pending[0]!.id)}」。`;
      this.approvals.answer(target.id, allow, `${channel}`);
      return allow ? "好，已同意。" : "好，已拒绝。";
    }
    void by;
    void wechat;
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
    if (this.current || !this.queue.length) {
      if (!this.current && !this.queue.length) this.flushWaiters();
      return;
    }
    if (this.killed) {
      this.queue = [];
      this.flushWaiters();
      return;
    }
    const turn = this.queue.shift()!;
    if (turn.proactive && !turn.hidden && this.overMainBudget()) {
      this.log(`proactive turn dropped: main budget used up (${turn.label ?? turn.origin})`);
      return this.pump();
    }
    this.beginTurn(turn);
    this.ensureSession().send(turn.text);
  }

  private beginTurn(turn: Turn): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.current = turn;
    this.turnTexts = [];
    this.deltaId = null;
    this.emitStatus();
  }

  private ensureSession(): MainSession {
    if (this.session && !this.session.closed) return this.session;
    this.session = this.driver.startMain({
      cwd: this.paths.home,
      model: this.config.model,
      resumeSessionId: this.runtime.sessionId,
      permissionMode: this.config.permissionMode,
      appendSystemPrompt: BEHAVIOR + `\n\n主人所在时区：${this.config.settings.timezone}。`,
      tools: this.toolHandlers(),
      canUseTool: (req) => this.approvals.request(req),
      preToolGate: ({ toolName, input }) => this.approvals.preGate(toolName, input),
      postToolUse: (c) => {
        if (/browser_navigate/.test(c.toolName)) this.approvals.noteNavigation((c.input as any)?.url);
        this.audit.log("tool", { tool: c.toolName, input: c.input, agent: c.agentId, toolUseId: c.toolUseId });
      },
      mcpServers: this.extraMcpServers(),
      onEvent: (e) => this.onHarnessEvent(e),
      stderr: (s) => appendJsonl(`${this.paths.logs}/harness-stderr.jsonl`, { ts: Date.now(), s: truncate(s, 2000) }),
    });
    return this.session;
  }

  extraMcpServers(): Record<string, unknown> {
    const servers: Record<string, unknown> = { ...this.config.extraMcpServers };
    if (this.config.browser.enabled) {
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
    // The harness may start a turn on its own (a background task finished).
    if (!this.current && (e.type === "text_delta" || e.type === "assistant_text" || e.type === "tool_use")) {
      this.beginTurn({ text: "", origin: "system", proactive: true, implicit: true });
    }
    const turn = this.current;
    switch (e.type) {
      case "init":
        this.model = e.model;
        if (this.runtime.sessionId !== e.sessionId) {
          this.runtime.sessionId = e.sessionId;
          this.saveRuntime();
        }
        this.emitStatus();
        break;
      case "text_delta":
        if (turn && !turn.proactive && !turn.hidden) {
          if (!this.deltaId) this.deltaId = `m_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
          this.chat.delta(this.deltaId, e.text);
        }
        break;
      case "assistant_text":
        if (e.parentToolUseId) {
          this.tasks.onSubagentText(e.text, e.parentToolUseId);
          break;
        }
        this.turnTexts.push(e.text);
        if (turn && !turn.proactive && !turn.hidden) {
          this.chat.add({ id: this.deltaId ?? undefined, role: "assistant", kind: "text", text: e.text, channel: turn.origin });
        }
        this.deltaId = null;
        break;
      case "tool_use":
        this.tasks.onToolUse(e.id, e.name, e.input, e.parentToolUseId);
        break;
      case "tool_result":
        this.tasks.onToolResult(e.toolUseId, e.content, e.isError, e.parentToolUseId);
        break;
      case "task_started":
        this.tasks.onTaskStarted(e.taskId, e.toolUseId, e.background);
        break;
      case "task_notification":
        this.tasks.onTaskNotification(e.taskId, e.toolUseId, e.status, e.summary);
        break;
      case "compact":
        this.metric({ type: "compact", trigger: e.trigger, preTokens: e.preTokens, postTokens: e.postTokens });
        break;
      case "result":
        this.endTurn(e.costUsd, e.contextTokens, e.isError ? e.text : undefined);
        break;
      case "error":
        this.log(`harness error: ${e.message}`);
        this.session?.close();
        this.session = null;
        if (this.current) this.endTurn(0, this.lastContextTokens, e.message);
        break;
    }
  }

  private endTurn(costUsd: number, contextTokens: number, error?: string): void {
    const turn = this.current;
    this.current = null;
    this.addUsage("mainUsd", costUsd);
    this.lastContextTokens = contextTokens;
    this.tasks.finalizePending();
    if (turn) {
      this.metric({ type: "turn", origin: turn.origin, proactive: turn.proactive, costUsd, contextTokens, error });
      const text = this.turnTexts.join("\n\n").trim();
      if (error && !turn.hidden) {
        this.chat.add({ role: "system", kind: "notice", text: `出了点问题：${truncate(error, 300)}`, channel: "system" });
      }
      if (turn.proactive && !turn.hidden) {
        if (text && !SKIP.test(text) && !/^\[skip\]/i.test(text)) {
          const msg = this.chat.add({ role: "assistant", kind: "text", text, channel: turn.origin, proactive: true });
          void this.router.proactive(msg);
        } else {
          this.metric({ type: "skip", origin: turn.origin, label: turn.label });
        }
      }
      if (turn.wechat && this.wechat && text) {
        void this.wechat.reply(turn.wechat, text).catch((err) => this.log(`wechat reply failed: ${err}`));
        this.audit.log("wechat.reply", { chars: text.length });
      }
      if (turn.hidden && this.rollPending) this.finishRoll();
    }
    this.emitStatus();
    this.scheduleIdle();
    this.pump();
  }

  private flushWaiters(): void {
    for (const w of this.turnWaiters.splice(0)) w();
  }

  // ---------------- session idle / roll ----------------

  private scheduleIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    const min = this.config.session.idleCloseMinutes;
    if (!min) return;
    this.idleTimer = setTimeout(() => this.onIdle(), min * 60_000);
  }

  onIdle(): void {
    if (this.current || this.queue.length || !this.session) return;
    const roll = this.config.session.rollAfterTokens;
    if (roll > 0 && this.lastContextTokens > roll && !this.tasks.running().length) {
      // Flush before rolling: let the model write what matters to native memory.
      this.rollPending = true;
      this.enqueue({
        text: "[系统] 这段对话要收尾换新了。把其中值得长期记住的事写进你的记忆（没有就算了），然后只回复 [skip]。",
        origin: "system",
        proactive: true,
        hidden: true,
      });
      return;
    }
    // Close the CLI process; the next message resumes the same conversation.
    if (!this.tasks.running().length) {
      this.session.close();
      this.session = null;
      this.metric({ type: "idle_close", contextTokens: this.lastContextTokens });
    }
  }

  private finishRoll(): void {
    this.rollPending = false;
    this.session?.close();
    this.session = null;
    this.metric({ type: "roll", fromSession: this.runtime.sessionId, contextTokens: this.lastContextTokens });
    this.runtime.sessionId = undefined;
    this.lastContextTokens = 0;
    this.saveRuntime();
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
        const r = await this.router.proactive(msg, { urgent });
        return r.suppressed ? `已记入对话（${r.suppressed === "quiet" ? "免打扰时段" : "今日推送已达上限"}，未推送）` : "已推送";
      },
    };
  }

  // ---------------- proactive sources ----------------

  private onSchedule(w: Watch): void {
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
      role: "system",
      kind: "approval",
      text: `等你确认：${a.title}${a.irreversible ? "（不可撤销）" : ""}\n${truncate(a.detail, 300)}\n回复「同意 ${shortId(a.id)}」或「拒绝 ${shortId(a.id)}」`,
      channel: "system",
      approvalId: a.id,
      taskId: a.taskId,
      proactive: true,
    });
    void this.router.proactive(msg, { title: "需要你确认" });
  }

  // ---------------- kill switch ----------------

  kill(by: string): void {
    this.runtime.killed = true;
    this.saveRuntime();
    this.audit.log("kill", { by });
    this.queue = [];
    this.approvals.denyAll(`kill:${by}`);
    for (const t of this.tasks.running()) {
      if (t.sdkTaskId) void this.session?.stopTask(t.sdkTaskId).catch(() => {});
      this.tasks.markStopped(t.id);
    }
    void this.session?.interrupt();
    this.emitStatus();
  }

  resume(by: string): void {
    this.runtime.killed = false;
    this.saveRuntime();
    this.audit.log("resume", { by });
    this.emitStatus();
  }

  async stopTask(id: string): Promise<Task | undefined> {
    const t = this.tasks.get(id);
    if (!t) return undefined;
    if (t.sdkTaskId) await this.session?.stopTask(t.sdkTaskId).catch(() => {});
    this.audit.log("task.stop", { id });
    return this.tasks.markStopped(t.id);
  }

  // ---------------- settings ----------------

  updateSettings(patch: Partial<Settings>): Settings {
    const next = { ...this.config.settings, ...patch };
    if (typeof next.maxProactivePerDay !== "number" || next.maxProactivePerDay < 0) throw new Error("maxProactivePerDay 不合法");
    if (typeof next.probeIntervalMinutes !== "number" || next.probeIntervalMinutes < 1) throw new Error("probeIntervalMinutes 不合法");
    const probeChanged = next.probeIntervalMinutes !== this.config.settings.probeIntervalMinutes;
    this.config.settings = next;
    saveConfig(this.paths, this.config);
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
      text: `我掉线了 ${formatDuration(gap)}（${f(last)} – ${f(Date.now())}），刚恢复。这段时间错过的定时任务我会补上，期间的消息可能没收到。`,
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

export function shortId(id: string): string {
  return id.slice(-4);
}

function statusWord(s: string): string {
  return s === "done" ? "办完了" : s === "failed" ? "没办成" : s === "needs_input" ? "需要你" : "已停止";
}
