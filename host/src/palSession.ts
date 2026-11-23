import { t as tr } from "./i18n/index.ts";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import type { ApprovalManager } from "./approvals.ts";
import { askOwner } from "./ownerCards.ts";
import { firstLine } from "./ccSessions.ts";
import { ACTIVITY, friendlyError } from "./copy.ts";
import { PALO_SEND_TOOL, SESSION_ALLOWED_TOOLS, type Harness, type RewindChain, type RewindPoint, type SessionRef, type DeliveryToolHandlers, type FilesRewound, type HarnessDriver, type HarnessEvent, type ImageInput, type MainSession, type PermissionDecision, type PermissionRequest } from "./harness/types.ts";
import type { MediaStore } from "./media.ts";
import { type PalLaunch, makeSpawner } from "./palLauncher.ts";
import { CARD_TOOLS, type PalMapOptions, cardKey } from "./palHistory.ts";
import type { QuestionManager } from "./questions.ts";
import type { PendingRewind } from "./rewind.ts";
import type { Attachment, CardSource, ChatMessage, Pal, PalAttention, PalStatus } from "./types.ts";
import { stripTldrMarker } from "./tldr.ts";
import { newId, sleep, truncate } from "./util.ts";
import { AgentSession, type ModelChoice, type ResultEvent, type WentBack, stallContinue } from "./agent/session.ts";
import { AGENT_FLAGS } from "./agent/flags.ts";
import { TranscriptSink } from "./agent/outputSink.ts";
import { HeldElsewhere, type Holder, type OpenContext, ProcessHost } from "./agent/processHost.ts";
import { type PalTask, type PastPalTask, RecordTasks } from "./agent/taskProjection.ts";
import { PAL_MODES, contextWindowFor, contextWindowOf } from "./harness/claude/settings.ts";
import { peerWrap, startError } from "./harness/claude/process.ts";

// (Claude Code's own: harness/claude/; kept here for the modules and tests that import them from here.)
export { PAL_MODES, contextWindowFor, contextWindowOf, peerWrap, startError };

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
  stoppedFor?: "failed" | "elsewhere";
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
  finishedAt?: number; // its last turn ended normally then (a real turn; the host's restart doesn't write it)
  seenAt?: number; // the owner last looked then (any device); the owner's own words count too
  autoNamed?: boolean; // still under the placeholder name it was created with: named from its first words after a turn
  workspaceId?: string; // the workspace it belongs to (workspaces: docs/workbench-rpc.md §3)
  effort?: string; // chosen effort level; absent = the model's default (applies at the next start when it's asleep)
  appliedEffort?: string; // with none chosen: the effort it was started at (from Claude Code's settings), then what its Stop hook says turns ran at
  contextTokens?: number; // its context size after its last turn or compaction
  contextWindow?: number; // its model's context window, as Claude Code last reported it
  pastTasks?: PastPalTask[]; // its subagents and background tasks that ended, newest first (at most 30)
  lastCompactAt?: number; // when it last compacted
}

export type { PalTask, PastPalTask };

export { HeldElsewhere, type Holder };

export interface PalSessionDeps {
  driver: HarnessDriver;
  approvals: ApprovalManager;
  questions: QuestionManager;
  /** The harness it runs on: its transcript, settings and how it reads them. */
  harness: Harness;
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
  /** Its palo_send: the words go to the assistant's session (docs/pals-prd.md §16). The result is what the Pal is told. */
  toPalo: (pal: PalSession, text: string) => Promise<string> | string;
  /** Its tools that reach the owner (Artifact, SendUserFile, …), scoped to it; none: it has only palo_send. */
  tools?: (pal: PalSession) => DeliveryToolHandlers | undefined;
  /** A turn ended (its spending is checked). */
  /** A turn is over; `finished`: it really ended (not stopped, not failed, nothing queued). */
  onTurnEnd: (pal: PalSession, finished?: boolean) => void;
  /** A turn went through (true) or failed for want of Claude Code's login (false). */
  onAuth?: (pal: PalSession, ok: boolean) => void;
  /** It was asleep and is up again. */
  onWoke?: (pal: PalSession) => void;
  /** Right before its process starts: its name is read back from Claude Code's title (§13). */
  beforeStart?: (pal: PalSession) => Promise<void>;
  /** It stopped by itself for good (couldn't start again, or opened elsewhere). */
  onStopped: (pal: PalSession) => void;
  pidAlive: (pid: number) => boolean;
  kill: (pid: number, signal: NodeJS.Signals) => void;
  /** What the owner attaches: images as Palo gets them, files put where the Pal reads them. */
  media?: Pick<MediaStore, "read" | "inbox" | "remember" | "recall">;
  timing: { readyMs: number; restartMs: number[]; exitWaitMs: number };
  /** settings.foldDays: unused this many days outside a workspace, it's folded into 以前的 (0 = never). */
  foldDays: () => number;
  now: () => number;
  log: (s: string) => void;
}

export { stallContinue };

// An agent is an AgentSession (agent/session.ts: its process, its turns, its
// replies) with AGENT_FLAGS: its process started awaited, brought back with
// backoff, never two writers, put to sleep; its turns the harness' own, its
// replies under the API message's id with a message's text blocks joined,
// out as events; its history its transcript, its tasks in its record.
export class PalSession extends AgentSession<{ text: string; from?: string; images?: ImageInput[]; sentAt?: number }, RecordTasks, TranscriptSink> {
  private calls: { name: string; id: string }[] = []; // its card tools' calls (tool_use ids) waiting for their handler
  private follower: { start(): void; poke(): void; stop(): void } | null = null;
  // A fork's entries copied from the session it was forked from: history, not news.
  private inherited: Set<string> | null = null;
  private compacting = false; // our /compact is going: its own result says nothing about the context
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
  private reportedMode?: string; // the permission mode its process says it runs in (none until it has said)

  constructor(
    readonly rec: PalRecord,
    private d: PalSessionDeps,
  ) {
    // (only closures here: `this` is there once super() has returned)
    super(AGENT_FLAGS, {
      record: rec,
      out: new TranscriptSink(rec.id, { emit: (ev, data) => d.emit(ev, data), now: () => d.now() }),
      tasks: new RecordTasks(rec, { save: () => d.save(), now: () => d.now() }),
      process: {
      name: () => this.rec.name,
      save: () => this.d.save(),
      changed: () => this.d.changed(),
      log: (s) => this.d.log(s),
      now: () => this.d.now(),
      open: (ctx) => this.open(ctx),
      onUp: (o) => this.onUp(o),
      onDown: (why, o) => this.down(why, o.closing),
      onStopped: () => this.d.onStopped(this),
      holders: (own) => this.d.holders(this.rec.sessionId, own),
      heldMessage: (pids) => tr("pals.heldElsewhere", { name: this.rec.name, pids: pids.join("、") }),
      beforeStart: () => this.d.beforeStart?.(this) ?? Promise.resolve(),
      launch: () => this.d.launch(),
      helperFailed: (why) => this.d.helperFailed(why),
      startError: (why) => this.d.harness.settings.startError(why),
      pidAlive: (pid) => this.d.pidAlive(pid),
      kill: (pid, sig) => this.d.kill(pid, sig),
      timing: d.timing,
      },
      harness: d.harness,
      kept: rec,
      keep: () => d.save(),
      cwd: () => rec.cwd,
    });
    this.updatedAt = rec.lastUsedAt;
    const history = this.d.harness.history;
    const tail = history.tail(this.ref, 512 * 1024);
    this.lastLine = history.lastLine(tail);
    // Its model entries are written when it starts: the beginning has one too.
    if (!rec.model) rec.model = history.model([...history.head(this.ref, 256 * 1024), ...tail]) ?? undefined;
    this.model = rec.model;
  }

  get id(): string {
    return this.rec.id;
  }

  /** Its conversation as the harness keeps it. */
  override get ref(): SessionRef {
    return { sessionId: this.rec.sessionId, cwd: this.rec.cwd };
  }

  /** Where the harness keeps its conversation (logs and diagnostics). */
  get transcript(): string {
    return this.d.harness.history.locate(this.ref);
  }

  /** Claude Code's pid while it runs. */
  get pid(): number | undefined {
    return this.host.pid;
  }

  get running(): boolean {
    return this.host.running;
  }

  private get proc(): MainSession | null {
    return this.host.proc;
  }

  /** Put to sleep: no process (its record is kept); being put to sleep counts. */
  get asleep(): boolean {
    return this.rec.status === "asleep" && !this.host.up && !this.host.starting;
  }

  /** It has a process, or one is coming up: what counts towards the five awake. */
  get awake(): boolean {
    const h = this.host;
    return !this.asleep && !this.rec.stoppedFor && (h.up || !!h.starting || h.restarting || h.queued);
  }

  /**
   * Since when it's had nothing on: no turn, no words it hasn't taken (nor
   * any waiting to go in), no card on the owner, no tool or background task
   * open. null: it isn't idle (or isn't running).
   */
  idleSince(): number | null {
    if (!this.running || this.host.starting || this.host.sleeping) return null;
    if (this.current || this.windingDown || this.pending.size || this.queuedSends || this.openTools.size || this.taskView.background) return null;
    if (this.pendingCards() > 0) return null;
    return Math.max(this.lastEventAt, this.rec.lastUsedAt, this.host.upAt);
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

  /** A card of its own waits on the owner. */
  waitingOnOwner(): boolean {
    return this.pendingCards() > 0;
  }

  status(): PalStatus {
    if (this.rec.stoppedFor) return "stopped";
    const h = this.host;
    if (!h.up) return h.starting || h.restarting || h.queued ? "starting" : this.rec.status === "asleep" ? "asleep" : "stopped";
    if (this.pendingCards() > 0) return "waiting";
    return this.busy ? "busy" : "idle";
  }

  /** What the owner should look at: a card waits (first), it works, it finished and they haven't looked, else nothing. */
  attention(status = this.status()): PalAttention {
    if (status === "waiting") return "waiting";
    if (status === "busy") return "working";
    const { finishedAt, seenAt } = this.rec;
    if ((status === "idle" || status === "asleep") && finishedAt !== undefined && finishedAt > (seenAt ?? 0)) return "done";
    return "idle";
  }

  /** Outside any workspace and unused for longer than settings.foldDays. */
  folded(): boolean {
    const days = this.d.foldDays();
    return !this.rec.workspaceId && days > 0 && this.d.now() - this.rec.lastUsedAt > days * 86_400_000;
  }

  /**
   * The owner looked (pals.seen). False: nothing to mark, because no turn
   * has finished since they last looked.
   */
  markSeen(at: number): boolean {
    const { finishedAt, seenAt } = this.rec;
    if (finishedAt === undefined || (seenAt ?? 0) >= finishedAt) return false;
    this.rec.seenAt = Math.max(at, finishedAt);
    this.d.save();
    return true;
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
      ...(this.effort() ? { effort: this.effort() } : {}),
      ...(this.mode() ? { permissionMode: this.mode() } : {}),
      ...(this.contextPct() !== undefined ? { contextPct: this.contextPct() } : {}),
      ...(this.taskView.running().length ? { tasksRunning: this.taskView.running().length } : {}),
      ...(typeof this.rec.lastWakeUsd === "number" ? { lastWakeUsd: this.rec.lastWakeUsd } : {}),
      createdBy: this.rec.createdBy,
      updatedAt: Math.round(this.updatedAt),
      attention: this.attention(status),
      ...(this.rec.finishedAt !== undefined ? { finishedAt: Math.round(this.rec.finishedAt) } : {}),
      ...(this.rec.seenAt !== undefined ? { seenAt: Math.round(this.rec.seenAt) } : {}),
      ...(this.rec.workspaceId ? { workspaceId: this.rec.workspaceId } : {}),
      folded: this.folded(),
    };
  }

  /** How full its context is, in whole percent (none until a turn has reported it). */
  contextPct(): number | undefined {
    const n = this.rec.contextTokens;
    if (typeof n !== "number" || !(n >= 0)) return undefined;
    return Math.min(100, Math.round((n / this.contextWindow()) * 100));
  }

  private contextWindow(): number {
    return this.d.harness.settings.contextWindow(this.model ?? this.rec.model, this.rec.contextTokens, this.rec.contextWindow);
  }

  /** The effort it runs at: the one chosen, else the one it was started at or Claude Code last said its turns ran at. */
  private effort(): string | undefined {
    return this.rec.effort ?? this.rec.appliedEffort;
  }

  /** The permission mode it runs in: what its process last said while it runs, else the one it starts in. */
  private mode(): string {
    return (this.running && this.reportedMode) || this.rec.permissionMode;
  }

  /** What pals.detail shows besides the Pal itself. */
  detailInfo(): {
    contextTokens?: number;
    contextWindow: number;
    model?: string;
    effort?: string;
    permissionMode: string;
    runningMode?: string;
    permissionModes: string[];
    tasks: PalTask[];
    pastTasks: PastPalTask[];
    lastCompactAt?: number;
    costTotalUsd: number;
  } {
    const model = this.model ?? this.rec.model;
    const chosen = this.rec.permissionMode;
    const running = this.running ? this.reportedMode : undefined;
    // the ones offered, then one it is in that isn't (bypassPermissions…), so it shows
    const modes: string[] = [...this.d.harness.settings.permissionModes];
    for (const m of [chosen, running]) if (m && !modes.includes(m)) modes.push(m);
    return {
      ...(typeof this.rec.contextTokens === "number" ? { contextTokens: this.rec.contextTokens } : {}),
      contextWindow: this.contextWindow(),
      ...(model ? { model } : {}),
      ...(this.effort() ? { effort: this.effort() } : {}),
      permissionMode: chosen,
      ...(running ? { runningMode: running } : {}),
      permissionModes: modes,
      tasks: this.taskView.wire(),
      pastTasks: this.rec.pastTasks ?? [],
      ...(typeof this.rec.lastCompactAt === "number" ? { lastCompactAt: this.rec.lastCompactAt } : {}),
      costTotalUsd: this.rec.costTotalUsd ?? 0,
    };
  }

  // Its model and effort (agent/session.ts) are its record's.
  protected choose(o: ModelChoice): void {
    if (o.model) this.model = this.rec.model = o.model;
    if (o.effort) this.rec.effort = o.effort;
    this.d.save();
  }

  /**
   * Its permission mode. Running: switched live (Claude Code's own
   * set_permission_mode, the phone's Shift+Tab; a turn in progress goes on in
   * the new one). Asleep: only the record changes; it wakes in it.
   */
  async setMode(mode: string): Promise<void> {
    this.rec.permissionMode = mode;
    this.d.save();
    const proc = this.proc;
    if (proc && this.running) {
      await proc.setPermissionMode(mode);
      this.reportedMode = mode;
    }
    this.touch();
  }

  /** The harness' own /compact, as a turn of its own that the owner doesn't see as their words. */
  async compact(): Promise<void> {
    if (this.rec.stoppedFor === "failed" || this.rec.stoppedFor === "elsewhere") throw new Error(tr("pals.stoppedNoCompact"));
    if (this.busy) throw new Error(tr("pals.busyNoCompact"));
    this.compacting = true;
    try {
      await this.deliver("/compact", { silent: true });
    } catch (e) {
      this.compacting = false;
      throw e;
    }
  }

  /** Stops a subagent or background task. */
  async stopTask(taskId: string): Promise<void> {
    if (!this.taskView.has(taskId)) throw new Error(tr("pals.noTask"));
    const proc = this.proc;
    if (!proc || !this.running) throw new Error(tr("pals.cantStopTask"));
    try {
      await proc.stopTask(taskId);
    } catch {
      throw new Error(tr("pals.cantStopTask"));
    }
  }

  private touch(): void {
    this.updatedAt = this.d.now();
    this.d.changed();
  }

  // ---------------- the process ----------------

  /** The host starts it shortly (at its own start, a few seconds apart): it shows as starting. */
  queueStart(): void {
    this.host.queueStart();
  }

  /** Starts (or resumes) its process; resolves once Claude Code is up. */
  start(): Promise<void> {
    return this.host.start();
  }

  // Its process, as the host starts it (ProcessHost: holders checked, through PaloAlly Helper or direct).
  private open(ctx: OpenContext): { proc: MainSession; how?: string } {
    const { rec } = this;
    // A Pal the assistant opened has no transcript before its first message.
    // One gone back to an earlier message is forked from its old session
    // until Claude Code has written the new one (docs/rewind-prd.md §4.1).
    const fork = this.pendingRewind();
    const on = this.startOn(fork);
    // The effort it starts at: the one chosen in PaloAlly, else what Claude
    // Code's settings give it, passed explicitly so what's shown is what runs.
    const effort = rec.effort ?? this.d.harness.settings.defaultEffort(rec.model, rec.cwd);
    if (!rec.effort && effort && effort !== rec.appliedEffort) {
      rec.appliedEffort = effort;
      this.d.save();
    }
    this.inherited = fork ? this.d.harness.rewind.keptIds({ sessionId: fork.from, cwd: rec.cwd }, fork.at) : null;
    const proc: MainSession = this.d.driver.startPal({
      cwd: rec.cwd,
      ...on,
      // Its files can go back to how they were before any of the owner's messages from now on.
      fileCheckpointing: this.flags.fileCheckpoints,
      model: rec.model,
      ...(effort ? { effort } : {}),
      // so a turn's cost is its own, not the session's running total
      ...(typeof rec.costTotalUsd === "number" ? { priorCostUsd: rec.costTotalUsd } : {}),
      permissionMode: rec.permissionMode,
      appendSystemPrompt: this.d.appendPrompt(),
      name: (this.spawnedAs = rec.name),
      spawn: ctx.spawn,
      baseEnv: ctx.baseEnv,
      ownerOrigin: true,
      canUseTool: (req) => this.canUseTool(req),
      paloSend: async (text) => this.d.toPalo(this, text),
      ...(this.d.tools?.(this) ? { sessionTools: this.d.tools(this)! } : {}),
      onEvent: (e) => {
        if (proc === this.proc) this.onHarnessEvent(e);
      },
      onExit: ctx.onExit,
      stderr: ctx.stderr,
    });
    this.reportedMode = undefined;
    return { proc, how: on.resumeSessionId ? "resumed" : fork ? "forked" : undefined };
  }

  // Its process is up: a new running total, and (woken) the first turn's cost is what waking cost.
  private onUp(o: { woke: boolean }): void {
    this.priorTotal = this.rec.costTotalUsd;
    this.firstResult = true;
    if (o.woke) this.wakeCost = true;
    this.follower?.stop();
    this.follower = this.d.harness.history.follow(this.ref, (e) => this.onTranscript(e));
    this.follower.start();
    if (o.woke) this.d.onWoke?.(this);
  }

  // Not running any more: whatever was streaming is closed, its cards go.
  private down(why: string, closing: boolean): void {
    this.reportedMode = undefined;
    this.follower?.stop();
    this.follower = null;
    const wasBusy = this.busy;
    this.processDown();
    this.compacting = false;
    this.wakeCost = false;
    this.dropCards(why);
    if (wasBusy && !closing) this.notice(tr("pals.interrupted"));
  }

  private dropCards(by: string): void {
    this.d.approvals.denyFor(this.rec.id, by);
    this.d.questions.cancelFor(this.rec.id, by);
  }

  /** Stopped for good, with a reason the list shows; the owner's words bring it back. */
  stopFor(why: NonNullable<PalRecord["stoppedFor"]>, note: string): void {
    this.host.stopFor(why, note);
  }

  /** Stopped without a process to end (it never came up). */
  markStopped(why: NonNullable<PalRecord["stoppedFor"]>, note: string): void {
    this.host.markStopped(why, note);
  }

  /** Clears a stop (the owner spoke to it, or a new day for its spending). */
  clearStop(): void {
    this.host.clearStop();
  }

  /**
   * Puts it to sleep (§12): its process ends cleanly, its record stays,
   * marked asleep (also across the host's restarts); the next start wakes it.
   */
  sleep(): Promise<void> {
    return this.host.sleep();
  }

  /** Marked asleep without a process to end (the host's start, past five awake). */
  markAsleep(): void {
    this.host.markAsleep();
  }

  /** Ends its process and waits until it's really gone (nothing writes its transcript after this). */
  shutdown(): Promise<void> {
    return this.host.shutdown();
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

  // ---------------- the stall watchdog ----------------

  // Its turn goes on (agent/session.ts): it's told to, as by the assistant, in its conversation.
  protected goesOn(): boolean {
    return this.busy;
  }

  protected override restarted(): void {
    this.notice(tr("pals.stuckRestarted"));
  }

  protected goOn(): Promise<boolean> {
    return this.send(stallContinue(), { from: this.d.mapOptions().assistantName }).then(() => true);
  }

  // ---------------- the owner's words ----------------

  /**
   * The owner's words (or the assistant's, `from`), into the session as
   * typed; asleep, it's woken first. Words go in one after another in the
   * order they came, also those that come while it's being woken. `peer`:
   * they're another session's (the assistant's pal_send), shown to it as a
   * SendMessage from that name. `attachments` (the owner's, media ids):
   * images go in as image blocks, the way Palo gets them; files are put in
   * its folder's .paloally/inbox and named in the words as 「[文件] path」.
   */
  send(text: string, o: { clientMsgId?: string; from?: string; peer?: string; attachments?: Attachment[] } = {}): Promise<ChatMessage> {
    const t = text.trim();
    if (!t && !o.attachments?.length) return Promise.reject(new Error(tr("pals.emptyMessage")));
    this.queuedSends++;
    const run = this.sendChain.then(() => this.deliver(t, o)).finally(() => this.queuedSends--);
    this.sendChain = run.catch(() => {});
    return run;
  }

  private async deliver(t: string, o: { clientMsgId?: string; from?: string; peer?: string; attachments?: Attachment[]; silent?: boolean }): Promise<ChatMessage> {
    if (this.rec.stoppedFor) this.clearStop();
    try {
      await this.start();
    } catch (e) {
      // Still open somewhere else: it stays stopped, saying so.
      if (e instanceof HeldElsewhere) this.markStopped("elsewhere", e.message);
      throw e;
    }
    const proc = this.proc;
    if (!proc || !this.host.up) throw new Error(tr("pals.notRunning", { name: this.rec.name }));
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
      ...(o.attachments?.length ? { attachments: o.attachments } : {}),
    };
    const { images, body } = this.withAttachments(t, o.attachments ?? []);
    // Its page reads the transcript, which has only the bytes and the paths: kept as sent.
    if (o.attachments?.length) this.d.media?.remember(uuid, { text: t, attachments: o.attachments });
    this.emitted.add(uuid);
    if (!o.silent) this.out.put(msg);
    const content = o.peer ? this.d.harness.settings.peerWrap(o.peer, body) : body;
    if (!this.busy) this.workSince = this.d.now();
    this.rec.lastUsedAt = ts;
    // The owner's own words mean they're looking at it.
    if (!o.from && !o.silent) this.rec.seenAt = ts;
    this.d.save();
    this.put([[uuid, { text: content, ...(o.from ? { from: o.from } : {}), ...(images.length ? { images } : {}) }]], () => proc);
    this.windingDown = false;
    this.touch();
    return msg;
  }

  /** The words and image blocks a message with attachments goes in as. */
  private withAttachments(t: string, attachments: Attachment[]): { images: ImageInput[]; body: string } {
    const images: ImageInput[] = [];
    const files: string[] = [];
    for (const a of attachments) {
      if (a.kind === "image") {
        const m = this.d.media?.read(a.id);
        if (m) images.push({ mediaType: m.mediaType, data: m.data });
      } else if (a.kind === "file") {
        const path = this.d.media?.inbox(a.id, this.rec.cwd);
        if (path) files.push(`[文件] ${path}`);
      }
    }
    return { images, body: [t, ...files].filter((x) => x.trim()).join("\n") };
  }

  /**
   * 停止 (agent/session.ts): ends the current turn; its open cards are
   * answered no. The list shows it stopped within a moment.
   */
  async interrupt(by: string): Promise<void> {
    await this.stopWork(by);
  }

  protected override dropWaiting(by: string): void {
    this.dropCards(`stop:${by}`);
  }

  // ---------------- what it says ----------------

  private chat(msg: Omit<ChatMessage, "seq" | "ts" | "pal" | "channel"> & { channel?: ChatMessage["channel"] }): void {
    this.out.message(msg);
  }

  /**
   * What one of its own tools delivers (files, a published page, a clipboard
   * text): a message in its conversation, shown now and kept in its history. It
   * takes the id of the tool call that made it, so the live message and the
   * history's are the same one.
   */
  card(m: Omit<ChatMessage, "seq" | "id" | "ts">, tool: string): ChatMessage {
    const name = `mcp__paloally__${tool}`;
    const i = this.calls.findIndex((c) => c.name === name);
    const id = i >= 0 ? this.calls.splice(i, 1)[0]!.id : newId("m_");
    const ts = this.d.now();
    const msg: ChatMessage = { ...m, seq: ts, id, ts, channel: "app", pal: this.rec.id };
    this.emitted.add(id);
    this.d.media?.remember(cardKey(id), {
      text: msg.text,
      attachments: msg.attachments ?? [],
      ...(msg.kind === "clipboard" ? { kind: "clipboard" as const } : {}),
      ...(msg.label ? { label: msg.label } : {}),
    });
    this.out.put(msg);
    this.touch();
    return msg;
  }

  /** A message that only goes out as a push: it isn't in its conversation, and opens it. */
  pushNotice(text: string): ChatMessage {
    const ts = this.d.now();
    return { seq: ts, id: newId("m_"), role: "assistant", kind: "notice", text, channel: "system", ts, pal: this.rec.id, proactive: true };
  }

  private notice(text: string): void {
    this.chat({ id: newId("m_"), role: "system", kind: "notice", text, channel: "system" });
  }

  // The mode its process says it runs in. Claude Code may run in another than
  // the one asked for (auto needs a model that has it), and leaves plan mode
  // when its plan is approved: then that's the one it wakes in next time too.
  private noteMode(mode: string): void {
    if (mode === this.reportedMode) return;
    const leftPlan = this.reportedMode === "plan" && this.rec.permissionMode === "plan";
    this.reportedMode = mode;
    if (leftPlan) {
      this.rec.permissionMode = mode;
      this.d.save();
    }
    this.d.changed();
  }

  protected who(): { key: string; name: string; label: string } {
    return { key: this.rec.id, name: this.rec.name, label: `pal ${this.rec.name}:` };
  }

  protected changed(): void {
    this.d.changed();
  }

  protected log(s: string): void {
    this.d.log(s);
  }

  protected override touched(): void {
    this.touch();
  }

  protected override now(): number {
    return this.d.now();
  }

  // What an agent keeps of the harness' events besides its turns (agent/session.ts).
  protected override sessionEvent(e: HarnessEvent): void {
    switch (e.type) {
      case "effort":
        if (e.level !== this.rec.appliedEffort) {
          this.rec.appliedEffort = e.level;
          this.d.save();
          this.d.changed();
        }
        break;
      case "mode":
        this.noteMode(e.mode);
        break;
      case "init":
        if (e.model && e.model !== this.model) {
          this.model = e.model;
          this.rec.model = e.model;
          this.d.save();
        }
        if (e.effort && e.effort !== this.rec.appliedEffort) {
          this.rec.appliedEffort = e.effort;
          this.d.save();
        }
        if (e.permissionMode) this.noteMode(e.permissionMode);
        // A turn it started by itself is often another session's message: show it.
        setTimeout(() => this.follower?.poke(), 300).unref?.();
        break;
      case "compact":
        this.rec.lastCompactAt = this.d.now();
        // after compacting, its size is what is left; unknown until the next turn says
        this.rec.contextTokens = typeof e.postTokens === "number" ? e.postTokens : undefined;
        this.d.save();
        this.touch();
        break;
      case "tool_start":
      case "tool_use":
        if (e.type === "tool_use" && CARD_TOOLS.has(e.name)) this.calls.push({ name: e.name, id: e.id });
        if (this.calls.length > 20) this.calls.shift();
        if (e.parentToolUseId) break;
        // Its words to the assistant show in its own conversation, as it said them.
        if (e.type === "tool_use" && e.name === PALO_SEND_TOOL && typeof e.input?.text === "string" && e.input.text.trim()) {
          this.emitted.add(e.id);
          this.chat({ id: e.id, role: "assistant", kind: "text", text: e.input.text.trim() });
        }
        break;
      case "error":
        this.d.log(`pal ${this.rec.name}: ${e.message}`);
        break;
    }
  }

  // Its last words are its line in the list.
  protected override said(_turn: unknown, text: string): void {
    this.lastLine = firstLine(text) || this.lastLine;
    this.touch();
  }

  protected override resultIn(e: ResultEvent, _turn: unknown, stopped: boolean): void {
    // (a stopped turn's error is the stop, not news)
    if (e.isError && !stopped && !e.startupFailure) this.notice(friendlyError(e.text, e.errorCategory));
    if (!e.isError) this.d.onAuth?.(this, true);
    else if (!stopped && this.d.harness.auth.isFailure(e.text, e.errorCategory)) this.d.onAuth?.(this, false);
    this.noteCost(e.costUsd, e.totalCostUsd);
    // (our /compact turn's result says nothing about the context: the compact boundary did)
    if (!this.compacting && !e.isError && Number.isFinite(e.contextTokens) && e.contextTokens > 0) this.rec.contextTokens = e.contextTokens;
    if (e.contextWindow) this.rec.contextWindow = e.contextWindow;
    this.compacting = false;
    this.rec.lastUsedAt = this.d.now();
  }

  protected override resultDone(e: ResultEvent, stopped: boolean): void {
    const finished = !this.pending.size && !stopped && !e.isError;
    // A turn that really ended (not stopped, not failed): the owner has something to look at.
    if (finished) {
      this.rec.finishedAt = this.d.now();
      this.d.save();
    }
    this.follower?.poke();
    this.d.onTurnEnd(this, finished);
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
    const m = this.d.harness.history.entryMessage(e, { ...this.d.mapOptions(), pal: this.rec.id });
    if (!m || !m.id || this.emitted.has(m.id)) return;
    this.emitted.add(m.id);
    if (this.emitted.size > 500) this.emitted.delete(this.emitted.values().next().value!);
    this.out.put(m);
    this.touch();
  }

  // ---------------- 回到这里重来 (agent/session.ts) ----------------

  /** Whether its files can go back to how they were before the owner's message `uuid`. */
  canRestoreFiles(uuid: string): boolean {
    return this.d.harness.rewind.canRestoreFiles(this.conversationEntries(), uuid);
  }

  /**
   * Goes back to just before the owner's message `uuid` (in its current
   * conversation; its files too if asked: Claude Code's own checkpoints,
   * through a process on the old session that says nothing). One that was
   * awake comes back at once; one asleep stays asleep. Returns the message's
   * words and the ids of the messages that left the conversation.
   */
  async rewind(uuid: string, restoreFiles: boolean): Promise<{ text: string; filesRestored: boolean; dropped: string[]; from: string; at: string | null; copied: boolean }> {
    const { conv, point, from, copied } = await this.goBack({ uuid, exact: true }, { restoreFiles });
    const dropped = this.d.harness.rewind.dropped(conv, point, { ...this.d.mapOptions(), pal: this.rec.id });
    // (An old 「TL;DR」 ask comes back without its marker.)
    return { text: stripTldrMarker(this.wordsAt(point)!.trim()), filesRestored: restoreFiles, dropped, from, at: point.at, copied };
  }

  // Sent from the app with images or files: its words as typed, without the files' paths.
  private wordsAt(point: RewindPoint): string | null {
    const sent = this.d.media?.recall(point.uuid);
    return sent ? sent.text : point.text;
  }

  protected occupied(): boolean {
    return this.queuedSends > 0 || this.pendingCards() > 0;
  }

  // The owner's own words only: not the assistant's (pal_send), not another session's.
  protected override refusePoint({ chain }: RewindChain, point: RewindPoint): void {
    const text = this.wordsAt(point);
    const rw = this.d.harness.rewind;
    if (text === null || /^\s*<cross-session-message/.test(text) || (this.rec.duty && point.index === chain.findIndex((e) => rw.ownerWords(e) !== null) && text.trim() === this.rec.duty.trim()))
      throw new Error(tr("pals.notYourMessage"));
  }

  protected override async refuseHeld(sessionId: string): Promise<void> {
    const held = await this.d.holders(sessionId, this.rec.pid);
    if (held.length) throw new HeldElsewhere(tr("pals.heldElsewhereRewind", { name: this.rec.name, pids: held.map((h) => h.pid).join("、") }));
  }

  protected override copyFailed(e: unknown): unknown {
    return new Error(tr("pals.rewindFailed", { why: e instanceof Error ? e.message : String(e) }));
  }

  // The session it was forked from is its own too; its line in the list is back to what was said before.
  protected override wentBack({ conv, point, from }: WentBack): void {
    this.rec.formerSessions = [...(this.rec.formerSessions ?? []).filter((x) => x !== from), from].slice(-20);
    this.lastLine = this.d.harness.history.lastLine(conv.chain.slice(0, point.index));
    this.rec.lastUsedAt = this.d.now();
  }

  // Claude Code puts the files back (rewindFiles) in a process of its own on
  // the old session: it's only asked that, never spoken to.
  protected override async filesBack(sessionId: string, uuid: string): Promise<FilesRewound> {
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
      canUseTool: async () => ({ behavior: "deny", message: tr("pals.restoringFiles") }),
      onEvent: () => {},
    });
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([proc.ready(), new Promise<never>((_, rej) => (timer = setTimeout(() => rej(new Error(tr("pals.startTimeout"))), this.d.timing.readyMs)))]);
      if (!proc.rewindFiles) return { canRewind: false, error: tr("pals.noFileRestore") };
      return await proc.rewindFiles(uuid);
    } catch (e) {
      return { canRewind: false, error: e instanceof Error ? e.message : String(e) };
    } finally {
      clearTimeout(timer);
      proc.close();
      if (spawned) await Promise.race([exited, sleep(this.d.timing.exitWaitMs)]);
      if (pid && this.d.pidAlive(pid)) await this.host.killPid(pid);
    }
  }

  // ---------------- its cards ----------------

  private async canUseTool(req: PermissionRequest): Promise<PermissionDecision> {
    const source = this.source();
    // Its one tool of ours: never a card (it is also allowed up front).
    if (SESSION_ALLOWED_TOOLS.includes(req.toolName)) return { behavior: "allow", updatedInput: req.input };
    const card = askOwner(this.d, req, { source, notify: false });
    if (!card) return { behavior: "deny", message: tr("pals.badQuestion") };
    this.d.changed();
    this.d.onWaiting(this, card.line, card.ids);
    const r = await card.result;
    this.d.changed();
    return r;
  }
}

