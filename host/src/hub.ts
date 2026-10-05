import { ApprovalManager } from "./approvals.ts";
import { ArtifactLibrary } from "./artifacts.ts";
import { Audit } from "./audit.ts";
import { Bus } from "./bus.ts";
import type { ClientConn, WechatChannel, WechatReplyTarget } from "./channels/types.ts";
import { ChatLog } from "./chat.ts";
import { type Config, type Paths, type Settings, VERSION, patchConfig, validateSettings } from "./config.ts";
import { Conversation } from "./conversation.ts";
import { ACTIVITY_THINKING, approvalAnswerReply, questionLineHelp, statusReply, stopReply } from "./copy.ts";
import type { HarnessDriver, HarnessEvent, ModelOption, SlashCommandInfo, ToolHandlers } from "./harness/types.ts";
import { HarnessInfo } from "./harnessInfo.ts";
import { MemoryView, autoMemoryDir } from "./memory.ts";
import { ProbeScheduler, type ProbeTrigger } from "./probe.ts";
import { QuestionManager, parseTextAnswer, questionText } from "./questions.ts";
import { Proactive } from "./proactive.ts";
import { Router, type Pusher } from "./router.ts";
import { RuntimeState } from "./runtime.ts";
import { setSoulName } from "./home.ts";
import { makeShellTools } from "./shellTools.ts";
import { SuggestionStore } from "./suggestions.ts";
import { TaskTracker } from "./tasks.ts";
import type { Attachment, Channel, ChatMessage, Status, Task, Watch, ReplyTo } from "./types.ts";
import { MediaStore } from "./media.ts";
import { ensureMorningBrief } from "./brief.ts";
import { type Usage, UsageLedger } from "./usage.ts";
import { appendJsonl } from "./util.ts";
import { WatchStore } from "./watches.ts";

export type { ClientConn, WechatChannel, WechatReplyTarget } from "./channels/types.ts";
export { timing } from "./conversation.ts";

export interface HubDeps {
  paths: Paths;
  config: Config;
  driver: HarnessDriver;
  pushers?: Pusher[];
  wechat?: WechatChannel | null;
  now?: () => number;
  log?: (s: string) => void;
}

// Hub assembles the assistant: the main conversation with the harness, the
// task projection, approval relay, probe, artifacts, memory, and the client
// channels. The work itself lives in the modules it wires together.
export class Hub {
  readonly bus = new Bus();
  readonly paths: Paths;
  config: Config;
  readonly audit: Audit;
  readonly chat: ChatLog;
  readonly tasks: TaskTracker;
  readonly approvals: ApprovalManager;
  readonly questions: QuestionManager;
  readonly watches: WatchStore;
  readonly artifacts: ArtifactLibrary;
  readonly media: MediaStore;
  readonly memory: MemoryView;
  readonly router: Router;
  readonly probe: ProbeScheduler;
  readonly suggestions: SuggestionStore;
  readonly conversation: Conversation;
  private readonly info: HarnessInfo;
  private readonly proactive: Proactive;
  private readonly ledger: UsageLedger;
  private readonly runtime: RuntimeState;
  private readonly wechat: WechatChannel | null;
  private readonly log: (s: string) => void;
  private clients = new Map<string, { conn: ClientConn; off: () => void }>();
  private suggestionTimer: ReturnType<typeof setInterval> | null = null;
  // questions sent to WeChat as text: the owner's next WeChat message answers them
  private wechatQuestions = new Set<string>();
  // set by the daemon: drops a paired device (its relay pairing)
  onUnpairDevice?: (deviceId: string) => void;

  constructor(deps: HubDeps) {
    this.paths = deps.paths;
    this.config = deps.config;
    this.wechat = deps.wechat ?? null;
    this.log = deps.log ?? ((s) => console.log(`[hub] ${s}`));
    this.runtime = new RuntimeState(this.paths.runtime);
    this.ledger = new UsageLedger(this.paths.usage, () => this.config.settings.timezone);

    this.audit = new Audit(this.paths.audit);
    this.chat = new ChatLog(this.paths.chat, this.bus);
    this.tasks = new TaskTracker(this.paths.tasks, this.paths.taskActivity, this.bus, (t, k) => this.proactive.onTaskTransition(t, k));
    this.watches = new WatchStore(this.paths.watches, this.bus);
    this.artifacts = new ArtifactLibrary(this.paths.artifacts, this.bus);
    this.media = new MediaStore(this.paths.media);
    this.memory = new MemoryView(this.paths.home, autoMemoryDir(this.paths.home));
    this.router = new Router(
      () => this.config.settings,
      deps.pushers ?? [],
      this.wechat,
      this.audit,
      deps.now,
      () => this.chat.lastUserActivity(),
    );
    this.router.onRunaway = (reason) => this.proactive?.onRunaway(reason);
    this.approvals = new ApprovalManager(this.paths.approvals, this.bus, this.audit, {
      taskForToolUse: (id) => (id ? this.tasks.taskIdForToolUse(id) : undefined),
      onCreated: (a) => this.proactive.onApprovalCreated(a),
      timeoutMinutes: () => this.config.settings.approvalTimeoutMinutes,
    });
    this.questions = new QuestionManager(this.paths.questions, this.bus, this.audit, {
      taskForToolUse: (id) => (id ? this.tasks.taskIdForToolUse(id) : undefined),
      onCreated: (q) => {
        // Asked during a WeChat turn: the owner gets it there as numbered options.
        const target = this.conversation.wechatTarget();
        if (target && this.wechat) {
          this.wechatQuestions.add(q.id);
          void this.wechat.reply(target, questionText(q)).catch((e) => this.log(`wechat question failed: ${e}`));
        }
        this.proactive.onQuestionCreated(q, { sentToWechat: !!(target && this.wechat) });
      },
      timeoutMinutes: () => this.config.settings.approvalTimeoutMinutes,
    });
    this.info = new HarnessInfo(
      this.paths.state,
      this.bus,
      () => void this.conversation.ensureSession(),
      () => this.conversation.scheduleIdleIfIdle(),
    );
    this.conversation = new Conversation({
      paths: this.paths,
      config: () => this.config,
      driver: deps.driver,
      runtime: this.runtime,
      chat: this.chat,
      tasks: this.tasks,
      approvals: this.approvals,
      questions: this.questions,
      router: this.router,
      wechat: this.wechat,
      audit: this.audit,
      usage: this.ledger,
      tools: () => this.toolHandlers(),
      mcpServers: () => this.extraMcpServers(),
      onEvent: (e) => this.onHarnessEvent(e),
      onCommands: (c) => this.info.saveCommands(c),
      onModels: (m) => this.info.saveModels(m),
      onTerminalCommands: (n) => this.info.setTerminalCommands(n),
      statusChanged: () => this.emitStatus(),
      onGoalResult: (id, text) => {
        const w = this.watches.get(id);
        // The assistant may have set a better line itself during this run.
        if (!w || (w.progressAt && Date.now() - w.progressAt < 10 * 60_000)) return;
        this.watches.progress(id, text);
      },
      metric: (m) => this.metric(m),
      log: this.log,
    });
    this.proactive = new Proactive({
      chat: this.chat,
      router: this.router,
      audit: this.audit,
      runtime: this.runtime,
      settings: () => this.config.settings,
      enqueue: (t) => this.conversation.enqueue(t),
      hasQueued: (p) => this.conversation.hasQueued(p),
      metric: (m) => this.metric(m),
    });
    this.probe = new ProbeScheduler({
      driver: deps.driver,
      watches: this.watches,
      timezone: () => this.config.settings.timezone,
      probeModel: () => this.config.probeModel,
      cwd: () => this.paths.home,
      mcpServers: () => this.extraMcpServers(),
      inheritConnectors: () => this.config.probeInheritConnectors,
      env: () => this.config.env,
      lastUserActivity: () => this.chat.lastUserActivity(),
      budgetLeftUsd: () => this.config.budget.probeDailyUsd - this.ledger.today().probeUsd,
      spend: (usd) => this.ledger.add("probeUsd", usd),
      onSchedule: (w) => this.onSchedule(w),
      onTriggers: (t) => this.onProbeTriggers(t),
      log: (s) => this.log(`probe: ${s}`),
    });
    this.suggestions = new SuggestionStore(this.paths.suggestions, this.bus, {
      driver: deps.driver,
      probeModel: () => this.config.probeModel,
      cwd: () => this.paths.home,
      env: () => this.config.env,
      context: () => this.ownerContext(),
      budgetLeftUsd: () => this.config.budget.probeDailyUsd - this.ledger.today().probeUsd,
      spend: (usd) => this.ledger.add("probeUsd", usd),
      log: (s) => this.log(s),
      now: deps.now,
    });
  }

  // ---------------- lifecycle ----------------

  start(opts: { probe?: boolean; watchArtifacts?: boolean } = {}): void {
    // The default 晨报 goal, once per install (deleting it keeps it gone).
    if (ensureMorningBrief(this.watches, this.runtime)) this.log("added the default 晨报 goal");
    const orphaned = this.tasks.orphanRunning();
    this.proactive.recoverAfterRestart(orphaned); // before the offline notice, which isn't an answer
    this.proactive.detectOffline();
    this.proactive.startHeartbeat();
    if (opts.probe !== false) {
      this.probe.start(this.config.settings.probeIntervalMinutes);
      setTimeout(() => void this.probe.tick(), 5_000);
      // 「试试」: first batch soon after start, then refreshed daily or when few are left.
      setTimeout(() => this.suggestions.maybeRefresh("start"), 30_000);
      this.suggestionTimer = setInterval(() => this.suggestions.maybeRefresh("daily"), 3600_000);
    }
    if (opts.watchArtifacts !== false) this.artifacts.watch();
    this.emitStatus();
  }

  stop(): void {
    this.proactive.stopHeartbeat();
    this.probe.stop();
    if (this.suggestionTimer) clearInterval(this.suggestionTimer);
    this.artifacts.stop();
    this.conversation.close();
    for (const c of this.clients.values()) c.off();
  }

  status(): Status {
    const busy = this.conversation.busy;
    return {
      online: true,
      busy,
      activity: busy ? this.conversation.activity || ACTIVITY_THINKING : undefined,
      model: this.conversation.model || this.config.model || "",
      effort: this.config.effort,
      sessionId: this.runtime.data.sessionId,
      wechat: this.wechat?.status() ?? "off",
      version: VERSION,
      metAt: this.chat.startedAt,
    };
  }

  // Resolves when nothing is in flight (tests, CLI one-shots).
  idle(): Promise<void> {
    return this.conversation.idle();
  }

  // ---------------- owner input ----------------

  // A message from the owner on any channel.
  userMessage(
    text: string,
    channel: Channel,
    wechat?: WechatReplyTarget,
    clientMsgId?: string,
    attachments: Attachment[] = [],
    replyTo?: ReplyTo,
  ): ChatMessage | null {
    const t = text.trim();
    if (!t && !attachments.length) return null;
    const cmd = attachments.length ? null : this.tryCommand(t, channel);
    const msg = this.chat.add({
      role: "user",
      kind: "text",
      text: t,
      channel,
      ...(clientMsgId ? { clientMsgId } : {}),
      ...(attachments.length ? { attachments } : {}),
      ...(replyTo ? { replyTo } : {}),
    });
    const answered = cmd === null && channel === "wechat" && !attachments.length ? this.answerOnWechat(t) : null;
    if (answered === "") return msg; // it answered an open question; the harness carries on
    if (answered !== null || cmd !== null) {
      const reply = (answered ?? cmd)!;
      this.chat.add({ role: "system", kind: "notice", text: reply, channel: "system" });
      if (channel === "wechat" && wechat && this.wechat) void this.wechat.reply(wechat, reply).catch(() => {});
      return msg;
    }
    // Slash commands must reach the harness verbatim, so they get no prefix.
    const prefix = channel === "wechat" && !t.startsWith("/") ? "[来自微信] " : "";
    const images = attachments.flatMap((a) => {
      const m = a.kind === "image" ? this.media.read(a.id) : null;
      return m ? [{ mediaType: m.mediaType, data: m.data }] : [];
    });
    // Files go in as paths the assistant can open, the way WeChat files do.
    const files = attachments.flatMap((a) => {
      const path = a.kind === "file" ? this.media.filePath(a.id) : null;
      return path ? [`[文件] ${path}`] : [];
    });
    // A quoted part of an earlier message goes first, as a quote block, so the
    // assistant knows what 「这个」 refers to.
    const quote = replyTo && !t.startsWith("/") ? replyTo.excerpt.split("\n").map((l) => `> ${l}`).join("\n") + "\n\n" : "";
    const body = [prefix + quote + t, ...files].filter((x) => x.trim()).join("\n");
    this.conversation.sendOwner(body, channel, wechat, images);
    return msg;
  }

  // A question sent to WeChat is answered by the owner's next WeChat message:
  // "" when it answered, a help line when it couldn't be matched, null when
  // no question is waiting there.
  private answerOnWechat(t: string): string | null {
    if (t.startsWith("/")) return null;
    const q = this.questions.listPending().find((x) => this.wechatQuestions.has(x.id));
    if (!q) return null;
    const answers = parseTextAnswer(q, t);
    if (!answers) return questionLineHelp;
    this.wechatQuestions.delete(q.id);
    this.questions.answer(q.id, answers, "wechat");
    return "";
  }

  // The few things the shell answers itself (everything else goes to the harness).
  private tryCommand(t: string, channel: Channel): string | null {
    if (/^\/(stop|停)$/i.test(t)) {
      this.stopAll(channel);
      return stopReply;
    }
    if (/^\/status$/i.test(t)) {
      return statusReply(this.conversation.busy, this.tasks.running().length, this.approvals.listPending().length);
    }
    // Answering an approval in text needs its 4-character code ("同意 3f2a"), so
    // an ordinary "ok"/"yes" in conversation can never approve anything.
    const m = /^(同意|批准|允许|拒绝|不同意)\s*([0-9a-f]{4})$/i.exec(t);
    if (m) {
      const target = this.approvals.listPending().find((a) => a.id.endsWith(m[2]!.toLowerCase()));
      if (target) {
        const allow = /^(同意|批准|允许)$/.test(m[1]!);
        this.approvals.answer(target.id, allow, channel);
        return approvalAnswerReply(allow);
      }
    }
    return null;
  }

  // Exposed so it can be traced/wrapped; the conversation routes every harness event here.
  onHarnessEvent(e: HarnessEvent): void {
    if (e.type === "init") this.suggestions.setConnectors(e.tools);
    this.conversation.onHarnessEvent(e);
  }

  onIdle(): void {
    this.conversation.onIdle();
  }

  stopAll(by: string): void {
    this.conversation.stopAll(by);
  }

  async stopTask(id: string): Promise<Task | undefined> {
    const t = this.tasks.get(id);
    if (!t) return undefined;
    await this.conversation.stopTask(t);
    this.audit.log("task.stop", { id });
    return this.tasks.markStopped(t.id);
  }

  // restartWhenIdle exits once nothing is in flight; the service manager
  // (launchd / systemd) starts a fresh process. Never cuts work off.
  async restartWhenIdle(maxWaitMs = 30 * 60_000, exit: () => void = () => process.exit(0)): Promise<"restarting" | "timeout"> {
    const deadline = Date.now() + maxWaitMs;
    while (Date.now() < deadline) {
      if (this.conversation.quiet && !this.tasks.live().length && !this.conversation.waitingOnOwner()) {
        this.audit.log("restart", {});
        setTimeout(exit, 200);
        return "restarting";
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
    return "timeout";
  }

  // ---------------- what the harness offers ----------------

  toolHandlers(): ToolHandlers {
    return makeShellTools({ tasks: this.tasks, watches: this.watches, artifacts: this.artifacts, chat: this.chat, router: this.router, audit: this.audit, wechat: this.wechat, media: this.media,
      ownerChannel: () => this.conversation.ownerChannel(), cwd: this.paths.home });
  }

  extraMcpServers(): Record<string, unknown> {
    const servers: Record<string, unknown> = { ...this.config.extraMcpServers };
    if (this.config.browser.enabled && this.config.browser.mode === "dedicated") {
      const cmd = this.config.browser.command ?? ["npx", "-y", "@playwright/mcp@latest", "--browser", "chrome", "--user-data-dir", this.paths.browserProfile];
      servers.browser = { type: "stdio", command: cmd[0], args: cmd.slice(1) };
    }
    return servers;
  }

  commandList(): SlashCommandInfo[] {
    return this.info.commandList();
  }

  loadCommands(timeoutMs?: number): Promise<SlashCommandInfo[]> {
    return this.info.loadCommands(timeoutMs);
  }

  async modelInfo(timeoutMs?: number): Promise<{ model: string; setting: string | null; effort: string | null; models: ModelOption[] }> {
    const models = await this.info.loadModels(timeoutMs);
    return { model: this.status().model, setting: this.config.model ?? null, effort: this.config.effort ?? null, models };
  }

  // setModel persists the choice and applies it to the running conversation.
  // `null` goes back to the default.
  async setModel(patch: { model?: string | null; effort?: string | null }): Promise<Status> {
    const efforts = ["low", "medium", "high", "xhigh", "max"];
    if (patch.effort != null && !efforts.includes(patch.effort)) throw new Error("思考深度不对");
    if (patch.model != null) {
      const known = this.info.models();
      const ok = known.length ? known.some((m) => m.value === patch.model) : /^[\w.\-:[\]]{1,80}$/.test(patch.model);
      if (!ok) throw new Error(`没有这个模型：${patch.model}`);
    }
    if ("model" in patch) {
      this.config.model = patch.model || undefined;
      await this.conversation.applyModel(this.config.model);
    }
    if ("effort" in patch) {
      this.config.effort = (patch.effort || undefined) as Config["effort"];
      await this.conversation.applyEffort(this.config.effort);
    }
    patchConfig(this.paths, (c) => {
      c.model = this.config.model;
      c.effort = this.config.effort;
    });
    this.audit.log("model.set", { model: this.config.model ?? "default", effort: this.config.effort ?? "default" });
    this.emitStatus();
    return this.status();
  }

  // ---------------- settings & usage ----------------

  updateSettings(patch: Partial<Settings>): Settings {
    const next = validateSettings(this.config.settings, patch as Record<string, unknown>);
    const probeChanged = next.probeIntervalMinutes !== this.config.settings.probeIntervalMinutes;
    if (next.assistantName && next.assistantName !== this.config.settings.assistantName) setSoulName(this.paths, next.assistantName);
    this.config.settings = next;
    patchConfig(this.paths, (c) => (c.settings = next));
    if (probeChanged) this.probe.start(next.probeIntervalMinutes);
    this.bus.emit("settings.updated", next);
    return next;
  }

  usage(): Usage {
    return this.ledger.today();
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

  // ---------------- internals ----------------

  private onSchedule(w: Watch): void {
    this.proactive.onSchedule(w);
  }

  private onProbeTriggers(t: ProbeTrigger[]): void {
    this.proactive.onProbeTriggers(t);
  }

  // What the assistant knows about the owner, for writing 「试试」 suggestions:
  // the core files and the auto-memory index (not the whole memory).
  private ownerContext(): string {
    const parts: string[] = [];
    for (const path of ["user.md", "soul.md", "memory/MEMORY.md"]) {
      try {
        const text = this.memory.read(path).trim();
        if (text) parts.push(`## ${path}\n${text}`);
      } catch {
        /* not there */
      }
    }
    return parts.join("\n\n");
  }

  private emitStatus(): void {
    this.bus.emit("status", this.status());
  }

  private metric(m: Record<string, unknown>): void {
    appendJsonl(this.paths.metrics, { ts: Date.now(), ...m });
  }
}
