import { Allies, type AlliesDeps } from "./allies.ts";
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
import type { Attachment, Channel, ChatMessage, PairedDevice, Status, Task, Watch, ReplyTo } from "./types.ts";
import { MediaStore } from "./media.ts";
import { BRIEF_TITLE, ensureMorningBrief } from "./brief.ts";
import { HandoffTracker, claudeConfigDir, transcriptPath } from "./handoffs.ts";
import { readRegistry } from "./ccSessions.ts";
import { StallWatch, type StallWatchDeps, WATCHDOG_DEFAULTS, apiSockets, diagnoseInto, killHard } from "./stallWatch.ts";
import { PowerWatcher, type PowerReading, readPower } from "./power.ts";
import { Updater, type UpdaterDeps } from "./update.ts";
import { type Usage, UsageLedger } from "./usage.ts";
import { randomUUID } from "node:crypto";
import { forkSession as sdkForkSession } from "@anthropic-ai/claude-agent-sdk";
import { type ForkSession, REWIND_NOT_FOUND, beforeCompaction, chainTo, findEntry, forkedUuids, leafOf, matchOwnerEntry, readTranscript } from "./rewind.ts";
import { appendJsonl, readJson, writeJson } from "./util.ts";
import { WatchStore } from "./watches.ts";
import { Sessions, type SessionsDeps } from "./sessions.ts";
import { PALO_NAME, Pals, type PalsDeps } from "./pals.ts";

export type { ClientConn, WechatChannel, WechatReplyTarget } from "./channels/types.ts";
export { timing } from "./conversation.ts";

/** How long a pairing link from pair_link / pair.invite works (the relay's longest window). */
export const PAIR_INVITE_TTL_SEC = 300;

export interface HubDeps {
  paths: Paths;
  config: Config;
  driver: HarnessDriver;
  pushers?: Pusher[];
  wechat?: WechatChannel | null;
  now?: () => number;
  log?: (s: string) => void;
  claudeDir?: string; // Claude Code's config dir (session registry, transcripts); tests point it elsewhere
  readPower?: () => PowerReading | null; // tests feed readings; default reads the OS
  updater?: Partial<UpdaterDeps>; // tests point the updater at a temp checkout
  allies?: Partial<AlliesDeps>; // tests connect hosts in memory and move the clock
  sessions?: Partial<SessionsDeps>; // tests fake the claude CLI, the clock and whether the owner is away
  pals?: Partial<PalsDeps>; // tests fake how Pals start, the registry and the timing
  stallWatch?: Partial<StallWatchDeps>; // tests drive the watchdog's clock and checks
  forkSession?: ForkSession; // tests copy sessions in their own Claude Code folder
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
  readonly handoffs: HandoffTracker;
  readonly power: PowerWatcher;
  readonly updater: Updater;
  readonly allies: Allies;
  readonly sessions: Sessions;
  readonly pals: Pals;
  readonly stallWatch: StallWatch;
  private compactTimer: ReturnType<typeof setInterval> | null = null;
  private readonly info: HarnessInfo;
  private readonly proactive: Proactive;
  private readonly ledger: UsageLedger;
  private readonly runtime: RuntimeState;
  private readonly wechat: WechatChannel | null;
  private readonly log: (s: string) => void;
  private readonly claudeDir: string;
  private readonly forkSession: ForkSession;
  private clients = new Map<string, { conn: ClientConn; off: () => void }>();
  private suggestionTimer: ReturnType<typeof setInterval> | null = null;
  // questions sent to WeChat as text: the owner's next WeChat message answers them
  private wechatQuestions = new Set<string>();
  // set by the daemon: drops a paired device (its relay pairing)
  onUnpairDevice?: (deviceId: string) => void;
  /** The owner's paired devices, as the relay keeps them (set by the daemon when the relay is on). */
  devices?: {
    list: () => { deviceId: string; label: string; pairedAt: number; lastSeen?: number }[];
    remove: (deviceId: string) => boolean;
  };
  // set by the daemon: opens the relay's pairing window for one more of the
  // owner's devices (what `paloally pair` opens) and gives back its link
  openPairing?: (ttlSec: number) => Promise<{ code: string; ttl: number; link: string }>;

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
    const claudeDir = deps.sessions?.claudeDir ?? deps.claudeDir ?? claudeConfigDir();
    this.claudeDir = claudeDir;
    this.forkSession = deps.forkSession ?? ((sid, o) => sdkForkSession(sid, o));
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
      // Pals reach the assistant (and it them) by this name with SendMessage.
      peerName: () => PALO_NAME,
      handoffsInFlight: () => this.handoffs.inFlight(),
      transcriptOf: (sid) => transcriptPath(claudeDir, this.paths.home, sid),
      onGoalResult: (id, text) => {
        const w = this.watches.get(id);
        // The assistant may have set a better line itself during this run.
        if (!w || (w.progressAt && Date.now() - w.progressAt < 10 * 60_000)) return;
        this.watches.progress(id, text);
      },
      metric: (m) => this.metric(m),
      log: this.log,
    });
    this.handoffs = new HandoffTracker({
      path: this.paths.handoffs,
      claudeDir: deps.claudeDir ?? claudeConfigDir(),
      homeCwd: () => this.paths.home,
      selfSessionId: () => this.runtime.data.sessionId,
      tasks: this.tasks,
      notify: (taskId, title, body) => {
        const msg = this.chat.add({ role: "assistant", kind: "task", text: body, channel: "system", taskId, proactive: true });
        void this.router.proactive(msg, { title });
      },
      assistantSpokeAt: () => {
        for (const m of this.chat.recent(50).reverse()) {
          if (m.role === "assistant" && m.kind === "text" && m.channel !== "system") return m.ts;
        }
        return 0;
      },
      audit: this.audit,
      // A Pal's prompts reach the phone by themselves: nothing to chase.
      isPal: (sessionId) => this.pals.isPal(sessionId),
      log: (s) => this.log(s),
    });
    this.power = new PowerWatcher({
      path: this.paths.power,
      read: deps.readPower ?? readPower,
      enabled: () => this.config.power.alerts,
      alert: (text, urgent) => {
        const msg = this.chat.add({ role: "assistant", kind: "text", text, channel: "system", proactive: true });
        void this.router.proactive(msg, { urgent });
      },
      note: (text) => this.chat.add({ role: "system", kind: "notice", text, channel: "system" }),
      audit: (type, data) => this.audit.log(type, data),
      log: (s) => this.log(s),
    });
    // Following official releases: switch at a clean break, never mid-work.
    this.updater = new Updater({
      statePath: this.paths.update,
      stagingRoot: this.paths.updateStaging,
      config: () => this.config.update,
      cleanBreak: () => this.conversation.cleanBreak(),
      quiet: () => this.quietForRestart(),
      audit: (type, data) => this.audit.log(type, data),
      exit: () => setTimeout(() => process.exit(0), 300),
      log: (s) => this.log(s),
      ...deps.updater,
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
      audit: (type, data) => this.audit.log(type, data),
      budgetUsd: () => this.config.budget.probeDailyUsd,
      onPaused: (reason, due) =>
        this.chat.add({
          role: "system",
          kind: "notice",
          text: `${reason}：${due.map((w) => `「${w.title}」`).join("、")}今天先不查了。要多查一些，把 config.json 里的 budget.probeDailyUsd 调高。`,
          channel: "system",
        }),
    });
    // Other people's assistants: messages in both directions, every outgoing
    // word a draft the owner sends. Our relay is handed over by RelayChannel.
    this.allies = new Allies({
      paths: this.paths,
      bus: this.bus,
      chat: this.chat,
      router: this.router,
      audit: this.audit,
      settings: () => this.config.settings,
      hostName: () => this.config.hostName,
      enqueue: (t) => this.conversation.enqueue(t),
      findQueued: (p) => this.conversation.findQueued(p),
      turnAlly: () => this.conversation.allyTurnAlly(),
      log: (s) => this.log(`allies: ${s}`),
      ...deps.allies,
    });
    // The computer's own Claude Code sessions the host doesn't run: listed,
    // and their prompts on the phone while the owner is away.
    this.sessions = new Sessions({
      paths: this.paths,
      claudeDir: deps.claudeDir ?? claudeConfigDir(),
      bus: this.bus,
      approvals: this.approvals,
      questions: this.questions,
      router: this.router,
      audit: this.audit,
      settings: () => this.config.settings,
      mainSessionId: () => this.runtime.data.sessionId,
      isPal: (sessionId) => this.pals?.isPal(sessionId) ?? false,
      adopting: (sessionId) => this.pals?.adopting(sessionId) ?? false,
      endedCwd: async (sessionId) => this.pals?.endedCwd(sessionId),
      paloName: () => PALO_NAME,
      log: this.log,
      ...deps.sessions,
    });
    // Pals: Claude Code sessions the host runs itself (docs/pals-prd.md).
    this.pals = new Pals({
      paths: this.paths,
      claudeDir: deps.sessions?.claudeDir ?? deps.claudeDir ?? claudeConfigDir(),
      bus: this.bus,
      chat: this.chat,
      approvals: this.approvals,
      questions: this.questions,
      router: this.router,
      audit: this.audit,
      driver: deps.driver,
      sessions: this.sessions,
      cli: this.sessions.cli,
      settings: () => this.config.settings,
      helperApp: () => this.config.pals?.helperApp,
      launchMode: () => this.config.pals?.launch ?? "auto",
      media: this.media,
      ...(deps.sessions?.readMessages ? { readMessages: deps.sessions.readMessages } : {}),
      log: this.log,
      ...deps.pals,
    });
    // The stall watchdog: the assistant's own process and every Pal's.
    const mainTranscript = () => {
      const sid = this.runtime.data.sessionId;
      return sid ? transcriptPath(claudeDir, this.paths.home, sid) : undefined;
    };
    const mainPid = () => {
      const sid = this.runtime.data.sessionId;
      if (!sid) return undefined;
      try {
        return readRegistry(`${claudeDir}/sessions`).find((e) => e.sessionId === sid)?.pid;
      } catch {
        return undefined;
      }
    };
    this.stallWatch = new StallWatch({
      targets: () => [
        this.conversation.stallTarget({
          name: () => this.config.settings.assistantName || PALO_NAME,
          pid: mainPid,
          transcript: mainTranscript,
          kill: (pid) => killHard(pid),
        }),
        ...this.pals.stallTargets(),
      ],
      config: () => ({ ...WATCHDOG_DEFAULTS, ...this.config.watchdog }),
      notify: (text) => {
        const msg = this.chat.add({ role: "assistant", kind: "notice", text, channel: "system", proactive: true });
        void this.router.proactive(msg, { title: "自动重启" }).catch(() => {});
      },
      audit: (type, data) => this.audit.log(type, data),
      sockets: apiSockets,
      diagnose: (pid, name) => diagnoseInto(`${this.paths.logs}/stalls`, pid, name),
      log: (s) => this.log(s),
      ...deps.stallWatch,
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
      this.probe.start();
      setTimeout(() => void this.probe.tick(), 5_000);
      // 「试试」: first batch soon after start, then refreshed daily or when few are left.
      setTimeout(() => this.suggestions.maybeRefresh("start"), 30_000);
      this.suggestionTimer = setInterval(() => this.suggestions.maybeRefresh("daily"), 3600_000);
    }
    if (opts.watchArtifacts !== false) this.artifacts.watch();
    this.allies.start();
    if (opts.probe !== false) {
      // Work handed to other sessions: the host follows it itself.
      this.handoffs.startTimer();
      // Compact earlier than the harness' default, at clean breaks only.
      this.compactTimer = setInterval(() => this.conversation.maybeCompact(), 60_000);
      (this.compactTimer as any).unref?.();
      // The host laptop on battery: a heads-up before it dies and takes the assistant offline.
      this.power.start();
      // New official release: staged in the background, switched to at a clean break.
      this.updater.start();
      this.sessions.start();
      // Every Pal comes back: they stay up so SendMessage always reaches them.
      this.pals.start();
      // A session stuck mid-work is restarted and resumed, the owner told.
      this.stallWatch.start();
      // The owner's earlier messages, matched in the transcript, so they can be gone back to.
      const t = setTimeout(() => {
        const n = this.backfillOwnerUuids();
        if (n) this.log(`matched ${n} earlier owner message(s) in the transcript`);
      }, 3_000);
      (t as any).unref?.();
    }
    this.emitStatus();
  }

  stop(): void {
    this.proactive.stopHeartbeat();
    this.probe.stop();
    this.handoffs.stop();
    this.power.stop();
    this.updater.stop();
    this.allies.stop();
    this.sessions.stop();
    this.pals.stop();
    this.stallWatch.stop();
    if (this.compactTimer) clearInterval(this.compactTimer);
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
    const answered = cmd === null && channel === "wechat" && !attachments.length ? this.answerOnWechat(t) : null;
    // What goes to the harness has the uuid it's kept under there, so the
    // owner can go back to it later (not a slash command: docs/rewind-prd.md §3).
    const uuid = cmd === null && answered === null && !t.startsWith("/") ? randomUUID() : undefined;
    const msg = this.chat.add({
      role: "user",
      kind: "text",
      text: t,
      channel,
      ...(clientMsgId ? { clientMsgId } : {}),
      ...(attachments.length ? { attachments } : {}),
      ...(replyTo ? { replyTo } : {}),
      ...(uuid ? { uuid } : {}),
    });
    // The owner is here: an Ally's message shown before now has been seen.
    if (channel === "app" || channel === "cli") this.allies.ownerActive();
    if (answered === "") return msg; // it answered an open question; the harness carries on
    if (answered !== null || cmd !== null) {
      const reply = (answered ?? cmd)!;
      this.chat.add({ role: "system", kind: "notice", text: reply, channel: "system" });
      if (channel === "wechat" && wechat && this.wechat) void this.wechat.reply(wechat, reply).catch(() => {});
      return msg;
    }
    const images = attachments.flatMap((a) => {
      const m = a.kind === "image" ? this.media.read(a.id) : null;
      return m ? [{ mediaType: m.mediaType, data: m.data }] : [];
    });
    this.conversation.sendOwner(this.ownerBody(msg), channel, wechat, images, uuid);
    return msg;
  }

  // The words an owner message goes to the harness as.
  private ownerBody(m: Pick<ChatMessage, "text" | "channel" | "attachments" | "replyTo">): string {
    const t = m.text;
    // Slash commands must reach the harness verbatim, so they get no prefix.
    const prefix = m.channel === "wechat" && !t.startsWith("/") ? "[来自微信] " : "";
    // Files go in as paths the assistant can open, the way WeChat files do.
    const files = (m.attachments ?? []).flatMap((a) => {
      const path = a.kind === "file" ? this.media.filePath(a.id) : null;
      return path ? [`[文件] ${path}`] : [];
    });
    // A quoted part of an earlier message goes first, as a quote block, so the
    // assistant knows what 「这个」 refers to.
    const quote = m.replyTo && !t.startsWith("/") ? m.replyTo.excerpt.split("\n").map((l) => `> ${l}`).join("\n") + "\n\n" : "";
    return [prefix + quote + t, ...files].filter((x) => x.trim()).join("\n");
  }

  // ---------------- 回到这里重来 (docs/rewind-prd.md) ----------------

  /**
   * chat.rewind: the conversation goes back to just before one of the
   * owner's messages. Its process ends; the next one is a new session forked
   * from the entry before that message (the old transcript keeps it all).
   * That message and everything after it leave the conversation (kept in the
   * log, marked rewound); its words come back for the composer. Refused while
   * a turn is on. What was done meanwhile stays done.
   */
  async rewindChat(messageId: string, by: string): Promise<{ text: string }> {
    const msg = this.chat.get(String(messageId ?? ""));
    if (!msg || msg.pal || msg.role !== "user" || msg.kind !== "text") throw new Error("这一条不能回到这里");
    if (msg.rewound) throw new Error("这一条已经撤回了");
    const busy = this.conversation.rewindBlocker();
    if (busy) throw new Error(busy);
    const { sessionId, pending } = this.conversation.rewindSource();
    if (!sessionId) throw new Error(REWIND_NOT_FOUND);
    const entries = readTranscript(transcriptPath(this.claudeDir, this.paths.home, sessionId));
    // The conversation as it stands (an earlier rewind not yet followed by a message: what it kept).
    const chain = chainTo(entries, pending ? pending.at : leafOf(entries));
    const used = new Set(this.chat.recent(2000).flatMap((m) => (m.uuid && m.id !== msg.id ? [m.uuid] : [])));
    // By its uuid; failing that (kept before it had one), by its words and time.
    const entry = (msg.uuid ? findEntry(chain, msg.uuid) : undefined) ?? matchOwnerEntry(chain, this.ownerBody(msg), msg.ts, used);
    if (!entry) throw new Error(REWIND_NOT_FOUND);
    const at = typeof entry.parentUuid === "string" ? entry.parentUuid : typeof entry.logicalParentUuid === "string" ? entry.logicalParentUuid : null;
    let to: string = randomUUID();
    // Before the last compaction: copied into a new session up to there
    // (new uuids, which the log then keeps for the messages it kept).
    const copy = beforeCompaction(chain, at);
    if (copy) to = (await this.forkSession(sessionId, { dir: this.paths.home, upToMessageId: at!, title: PALO_NAME })).sessionId;
    // (The conversation may have moved meanwhile.)
    const late = this.conversation.rewindBlocker();
    if (late) throw new Error(late);
    this.conversation.rewindTo({ from: sessionId, at, cut: entry.uuid, to, written: copy });
    const ids = this.chat.rewind(msg.seq);
    if (copy) {
      const moved = forkedUuids(readTranscript(transcriptPath(this.claudeDir, this.paths.home, to)));
      this.chat.setUuids(new Map(this.chat.recent(5000).flatMap((m) => (m.uuid && moved.has(m.uuid) ? [[m.id, moved.get(m.uuid)!] as [string, string]] : []))));
    }
    this.bus.emit("chat.rewound", { id: msg.id, ids });
    this.audit.log("chat.rewind", { messageId: msg.id, seq: msg.seq, uuid: entry.uuid, from: sessionId, to, at, dropped: ids.length, ...(copy ? { copied: true } : {}), by });
    this.log(`went back to before message ${msg.id} (${ids.length} message(s) out; session ${sessionId} ${copy ? "copied" : "forked"} as ${to})`);
    return { text: msg.text };
  }

  /**
   * The owner's messages from before they carried a uuid, matched by their
   * words and time in the current session's transcript (the newest 300), so
   * they can be gone back to too. Returns how many it matched.
   */
  backfillOwnerUuids(): number {
    const { sessionId, pending } = this.conversation.rewindSource();
    if (!sessionId || pending) return 0;
    const entries = readTranscript(transcriptPath(this.claudeDir, this.paths.home, sessionId), ['"type":"user"']);
    if (!entries.length) return 0;
    const recent = this.chat.recent(5000);
    const used = new Set(recent.flatMap((m) => (m.uuid ? [m.uuid] : [])));
    const first = Date.parse(entries[0]?.timestamp ?? "") || 0;
    const todo = recent
      .filter((m) => m.role === "user" && m.kind === "text" && !m.pal && !m.uuid && !m.text.startsWith("/") && m.ts >= first - 60_000 && ["app", "cli", "wechat"].includes(m.channel))
      .reverse()
      .slice(0, 300);
    let n = 0;
    for (const m of todo) {
      const e = matchOwnerEntry(entries, this.ownerBody(m), m.ts, used);
      if (!e) continue;
      used.add(e.uuid);
      this.chat.update(m.id, { uuid: e.uuid });
      n++;
    }
    return n;
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
    // The assistant handing work to another session (main thread only).
    if (e.type === "tool_use" && !e.parentToolUseId && e.name === "SendMessage") this.handoffs.onSend(e.id, e.input);
    // …or to a Pal with pal_send (asleep or awake), followed the same way.
    if (e.type === "tool_use" && !e.parentToolUseId && e.name === "mcp__paloally__pal_send") this.handoffs.onSend(e.id, { to: e.input.name, message: e.input.text });
    if (e.type === "tool_result" && !e.parentToolUseId) this.handoffs.onSendResult(e.toolUseId, e.content, e.isError);
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

  /** Nothing in flight at all: safe to restart the process. */
  quietForRestart(): boolean {
    return this.conversation.quiet && !this.tasks.live().length && !this.conversation.waitingOnOwner() && this.pals.quiet();
  }

  // restartWhenIdle exits once nothing is in flight; the service manager
  // (launchd / systemd) starts a fresh process. Never cuts work off.
  async restartWhenIdle(maxWaitMs = 30 * 60_000, exit: () => void = () => process.exit(0)): Promise<"restarting" | "timeout"> {
    const deadline = Date.now() + maxWaitMs;
    while (Date.now() < deadline) {
      if (this.quietForRestart()) {
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
    return makeShellTools({ tasks: this.tasks, handoffs: this.handoffs, watches: this.watches, artifacts: this.artifacts, chat: this.chat, router: this.router, audit: this.audit, wechat: this.wechat, media: this.media, allies: this.allies, pals: this.pals,
      ownerChannel: () => this.conversation.ownerChannel(), cwd: this.paths.home, timezone: () => this.config.settings.timezone,
      pairInvite: () => this.pairInvite("assistant") });
  }

  /**
   * A link that pairs one more of the owner's devices with this computer:
   * the relay's pairing window, as `paloally pair` opens it, for 5 minutes
   * and one device. Clicked on that device, the app opens and pairs.
   */
  async pairInvite(by: string): Promise<{ link: string; expiresAt: number }> {
    if (!this.openPairing) throw new Error("这台电脑没开远程连接，没法给新设备配对");
    const r = await this.openPairing(PAIR_INVITE_TTL_SEC);
    this.audit.log("pair.invite", { by, ttl: r.ttl });
    return { link: r.link, expiresAt: Date.now() + r.ttl * 1000 };
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
    if (probeChanged) this.probe.start();
    this.bus.emit("settings.updated", next);
    return next;
  }

  usage(): Usage {
    return this.ledger.today();
  }

  // ---------------- the owner's devices (docs/devices-prd.md) ----------------

  /** What a device's app said in hello: its platform; and when it was last here. */
  noteDevice(deviceId: string, client: unknown): void {
    const meta = readJson<Record<string, { platform?: string; lastSeen?: number }>>(this.paths.deviceMeta, {});
    const was = meta[deviceId] ?? {};
    const platform = client === "ios" || client === "mac" ? client : was.platform;
    meta[deviceId] = { ...(platform ? { platform } : {}), lastSeen: Date.now() };
    writeJson(this.paths.deviceMeta, meta);
  }

  /** device.list: the devices paired with this computer, the asking one marked. */
  listDevices(current?: string): PairedDevice[] {
    const meta = readJson<Record<string, { platform?: string; lastSeen?: number }>>(this.paths.deviceMeta, {});
    // Connected right now: relay clients are app_<stream>_<device id>.
    const online = new Set([...this.clients.keys()].flatMap((id) => (id.startsWith("app_") ? [id.split("_").slice(2).join("_")] : [])));
    return (this.devices?.list() ?? [])
      .map((d): PairedDevice => {
        const m = meta[d.deviceId] ?? {};
        const seen = Math.max(d.lastSeen ?? 0, m.lastSeen ?? 0);
        return {
          deviceId: d.deviceId,
          label: d.label,
          ...(m.platform === "ios" || m.platform === "mac" ? { platform: m.platform as "ios" | "mac" } : {}),
          pairedAt: d.pairedAt,
          ...(seen ? { lastSeen: seen } : {}),
          online: online.has(d.deviceId),
          current: d.deviceId === current,
        };
      })
      .sort((a, b) => Number(b.current) - Number(a.current) || (b.lastSeen ?? 0) - (a.lastSeen ?? 0));
  }

  /**
   * device.remove: another of the owner's devices stops being paired (its
   * connection closes, the relay forgets it). Never the asking device: that
   * one leaves with device.unpair.
   */
  removeDevice(deviceId: string, by: { deviceId?: string; channel: string }): void {
    if (!this.devices) throw new Error("这台电脑没开远程连接");
    if (deviceId && deviceId === by.deviceId) throw new Error("这是你正在用的这台，要断开它请用「解除配对」");
    const d = this.devices.list().find((x) => x.deviceId === deviceId);
    if (!d) throw new Error("没有这台设备");
    this.devices.remove(deviceId);
    const meta = readJson<Record<string, unknown>>(this.paths.deviceMeta, {});
    if (deviceId in meta) {
      delete meta[deviceId];
      writeJson(this.paths.deviceMeta, meta);
    }
    this.audit.log("device.removed", { deviceId, label: d.label, by: by.deviceId ?? by.channel });
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
    // Right before the 晨报: compact first (clean break only), so the brief opens a lighter context.
    if (w.title === BRIEF_TITLE) this.conversation.maybeCompact({ beforeBrief: true });
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
