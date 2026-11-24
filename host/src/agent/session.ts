// One AgentSession for the assistant and every agent (docs/harness-adapter-design.md
// §1.3, step 13): its harness process (ProcessHost), the owner's messages in
// flight (TurnLedger), its turns, the reply being streamed (StreamAssembler),
// where its words go (OutputSink), its tasks (TaskProjection), its open tool
// calls, what it's doing, and what the stall watchdog reads, chosen by its
// flags. The assistant (conversation.ts) and an agent (palSession.ts) are
// this with their flags and what only each has: the assistant's
// host-initiated queue with its pieces (WeChat, an Ally's gated turn, idle
// compaction) and its runtime record; an agent's record, list line and cards.
//
// One turn model, its differences flags (flags.ts): who opens a turn
// (`turns`: the host or the harness), whose ids its replies carry
// (`replyIds`), whether a reply's text blocks are one message or several
// (`textBlocks`), whether a turn the harness started on its own closes when it
// goes quiet (`implicitQuiet`), whether a subagent's output is the session's
// (`subagentTurns`). What's done to a session is written once too: 停止
// (stopWork, flag `stop`), a frozen process ended and resumed (recoverStall),
// 回到这里重来 (goBack) and its model and depth (setModel); where they differ
// by how its process is started, `startMode` says. What each does at the
// edges of a turn or of these (its record, its cards, its pushes, what goes
// next) it says through the hooks below.
import { randomUUID } from "node:crypto";
import { ACTIVITY, activityBackground, describeActivity } from "../copy.ts";
import type { FilesRewound, Harness, HarnessEvent, ImageInput, LimitHit, MainSession, RewindChain, RewindPoint, Rewinder, SessionRef } from "../harness/types.ts";
import { t as tr } from "../i18n/index.ts";
import { type PendingRewind, rewindBusy, rewindNoFiles, rewindNotFound } from "../rewind.ts";
import type { StallRecovery, StallTarget } from "../stallWatch.ts";
import type { ChatMessage } from "../types.ts";
import { newId, sleep } from "../util.ts";
import type { AgentFlags } from "./flags.ts";
import type { OutputSink } from "./outputSink.ts";
import { ProcessHost, type ProcessHostDeps, type ProcessRecord } from "./processHost.ts";
import { StreamAssembler } from "./streamAssembler.ts";
import type { TaskProjection } from "./taskProjection.ts";
import { type Turn, type TurnEnd, timing } from "./turn.ts";
import { TurnLedger } from "./turnLedger.ts";

/** The harness session it goes on in, as its record keeps it (the assistant's runtime.json, an agent's pals.json). */
export interface KeptSession {
  sessionId?: string;
  // 回到这里重来 (docs/rewind-prd.md §4.1): sessionId is a fork of `from` that
  // the harness hasn't written yet; each start forks it until it has.
  rewind?: PendingRewind;
}

/** 回到这里重来, done: the conversation it was and the message it went back to, and the session it goes on in. */
export interface WentBack {
  conv: RewindChain;
  point: RewindPoint;
  from: string;
  to: string;
  copied: boolean; // `to` is a copy made now (the point is before the last compaction), not a fork to be made
}

export interface SessionParts<T extends TaskProjection, S extends OutputSink> {
  /** What of its process is kept with its record (an agent's PalRecord; the assistant keeps none). */
  record: ProcessRecord;
  process: ProcessHostDeps;
  /** The harness it runs on. */
  harness: Harness;
  kept: KeptSession;
  /** Writes what's kept. */
  keep: () => void;
  /** The folder it works in (its conversation is kept under it). */
  cwd: () => string;
  out: S;
  tasks: T;
}

/** What it keeps with each of the owner's messages in flight: the words, and where they came from (the host's turns read it). */
export type InFlight = { text: string; images?: ImageInput[]; origin?: Turn["origin"]; wechat?: Turn["wechat"]; sentAt?: number };

/** What it's told after the watchdog restarted it mid-turn. */
export const stallContinue = (): string => tr("stall.continue");

const HANDLE_NOW_MS = 5_000; // 立刻处理: how long what holds the turn may take to go to the background
const STOP_SETTLE_MS = 250; // a stopped turn not ended by the harness by then is ended here (stop "settle")

/** A model and/or thinking depth for its next turns: the ones asked for (null: back to the default). */
export interface ModelChoice {
  model?: string | null;
  effort?: string | null;
}

/** Where a limit of the plan stands, as the process says. */
export type LimitEvent = Extract<HarnessEvent, { type: "limit" }>;

export type ResultEvent = Extract<HarnessEvent, { type: "result" }>;

export abstract class AgentSession<P extends InFlight, T extends TaskProjection = TaskProjection, S extends OutputSink = OutputSink> {
  /** Its harness process. */
  protected readonly host: ProcessHost;
  /** The owner's words sent to the harness and not yet answered, by uuid. */
  protected readonly pending = new TurnLedger<P>();
  /** The reply being streamed. */
  protected readonly stream = new StreamAssembler();
  protected readonly harness: Harness;
  private readonly kept: KeptSession;
  private readonly keep: () => void;
  private readonly cwd: () => string;
  private readonly sessionName: () => string;
  /** Where its words go: the assistant's chat log, or events carrying an agent's id. */
  protected readonly out: S;
  /** Its subagents and background tasks. */
  protected readonly taskView: T;
  /** Every tool call without a result yet (subagents' too): id → name. */
  protected readonly openTools = new Map<string, string>();
  protected lastEventAt = 0;
  /** What it's doing right now, in words (empty: nothing to say). */
  activity = "";

  // ---- its turn ----
  /** The turn the harness is answering now (null: none open). */
  protected current: Turn | null = null;
  /** The open turn's own tool calls (the main thread's) without a result yet. */
  protected readonly turnTools = new Set<string>();
  /** Messages put in that wait for a step of the open turn to end (uuid → since when). */
  private readonly waitingWords = new Map<string, number>();
  /** The harness' tasks for tool calls in the foreground that can go on in the background: task → tool call. */
  private readonly frontTasks = new Map<string, string>();
  private movedWaiters: (() => void)[] = [];
  /** The open turn's text blocks, as written. */
  protected texts: string[] = [];
  /** 停止 was asked during the open turn. */
  protected interrupted = false;
  /** A stopped turn was ended here: what's left of it doesn't open a turn or say what it's doing. */
  protected windingDown = false;
  /** The plan's limits its process says are used up, by kind; and whether it speaks of limits at all. */
  private readonly usedUpLimits = new Map<string, LimitHit>();
  private limitsSaid = false;
  /** When it last went from idle to busy. */
  protected workSince = 0;
  /** Ids already shown (followTranscript: a line read from the transcript isn't shown twice). */
  protected readonly emitted = new Set<string>();
  /** A reply's text so far, by its id (textBlocks "joined": its blocks are one message). */
  private readonly replies = new Map<string, string>();
  private implicitTimer: ReturnType<typeof setTimeout> | null = null;
  private turnEndWaiters: (() => void)[] = [];

  constructor(
    readonly flags: AgentFlags,
    parts: SessionParts<T, S>,
  ) {
    this.host = new ProcessHost(flags, parts.record, parts.process);
    this.harness = parts.harness;
    this.kept = parts.kept;
    this.keep = parts.keep;
    this.sessionName = parts.process.name;
    this.cwd = parts.cwd;
    this.out = parts.out;
    this.taskView = parts.tasks;
  }

  /** Its conversation as the harness keeps it (none before its first turn). */
  get ref(): SessionRef | undefined {
    const { sessionId } = this.kept;
    return sessionId ? { sessionId, cwd: this.cwd() } : undefined;
  }

  // ---------------- what each says about itself ----------------

  /** What the watchdog knows it by, as the owner does, and in the log. */
  protected abstract who(): { key: string; name: string; label: string };

  /** What it shows changed (the assistant's status line, an agent's line in the list). */
  protected abstract changed(): void;

  /** It did something worth showing now (an agent's line also says when). */
  protected touched(): void {
    this.changed();
  }

  protected now(): number {
    return Date.now();
  }

  protected abstract log(s: string): void;

  /** A permission prompt or a question of its own is waiting for the owner. */
  abstract waitingOnOwner(): boolean;

  /** A harness event, before its turn sees it: what each keeps of it (its model, mode, effort, commands, compaction, an error). */
  protected sessionEvent(_e: HarnessEvent): void {}

  /** A turn began. */
  protected turnBegan(_turn: Turn): void {}

  /** A text block of the main thread was written (and shown, unless its turn is host-initiated). */
  protected said(_turn: Turn | null, _text: string): void {}

  /** A result came, before it settles anything (`stopped`: the turn was stopped, its error is the stop). */
  protected resultIn(_e: ResultEvent, _turn: Turn | null, _stopped: boolean): void {}

  /** A turn is over: what each does with it (its cost and record, pushes, what goes next). */
  protected turnEnded(_turn: Turn | null, _end: TurnEnd<P>): void {
    this.touched();
  }

  /** 停止: what of it waits is dropped (its open cards answered no, what's queued). */
  protected dropWaiting(_by: string): void {}

  /** A frozen process is about to be ended: whether what it was doing is asked to go on. */
  protected abstract goesOn(): boolean;

  /** A frozen process ended: what died with it. */
  protected frozenEnded(): void {}

  /** Its process is up again after it froze (awaited). */
  protected restarted(): void {}

  /** It's asked to go on with `turn`, or with the words it had `taken` and not opened a turn for yet. False: there's nothing to go on with. */
  protected abstract goOn(turn: Turn | null, taken: P[]): boolean | Promise<boolean>;

  /** Back at work after its process froze: what waited meanwhile. */
  protected recovered(): void {}

  /** Something else of it than a turn or words in flight keeps it from going back (回到这里重来). */
  protected abstract occupied(): boolean;

  /** Refuses a message it can't go back to (besides one that isn't there). */
  protected refusePoint(_conv: RewindChain, _point: RewindPoint): void {}

  /** Refuses to go back while another process holds the session (exclusive). */
  protected refuseHeld(_sessionId: string): Promise<void> {
    return Promise.resolve();
  }

  /** Its files as they were before the message `uuid` of the session (fileCheckpoints). */
  protected filesBack(_sessionId: string, _uuid: string): Promise<FilesRewound> {
    return Promise.resolve({ canRewind: false });
  }

  /** Why it couldn't be copied, as the owner is told. */
  protected copyFailed(e: unknown): unknown {
    return e;
  }

  /** It has gone back: what each keeps besides the session it goes on in (written right after). */
  protected wentBack(_w: WentBack): void {}

  /** A model and/or depth was chosen: kept where its record is (config.json, an agent's record). */
  protected abstract choose(o: ModelChoice): void;

  /** Its process didn't take a live switch. */
  protected switchFailed(_what: string, e: unknown): void {
    throw e;
  }

  /** Its process said where a limit of the plan stands. */
  protected limitHeard(_e: LimitEvent): void {}

  /** A result has settled its turn. */
  protected resultDone(_e: ResultEvent, _stopped: boolean): void {}

  // ---------------- what it's doing ----------------

  protected setActivity(a: string | null): void {
    // (a stopped turn winding down doesn't say what it's doing)
    if (a === null || a === this.activity || this.windingDown) return;
    this.activity = a;
    this.changed();
  }

  /** The status line for a main-thread tool; some tools keep the current one. */
  protected setActivityFor(tool: string): void {
    this.setActivity(describeActivity(tool));
  }

  /**
   * The reply being streamed right now (its message id and all its text so
   * far), for a client that reconnects mid-reply: the deltas it missed while
   * offline are not replayed, so it takes this, then keeps appending deltas.
   */
  streaming(): { id: string; text: string } | null {
    return this.stream.current();
  }

  /** A turn is open, or (turns the harness opens) words of the owner wait for one. */
  get busy(): boolean {
    return this.current !== null || (this.flags.turns === "harness" && this.pending.size > 0);
  }

  /** How long the work that just ended ran: from when it went busy (0 if never). */
  workedMs(): number {
    return this.workSince ? Math.max(0, this.now() - this.workSince) : 0;
  }

  // ---------------- its turns ----------------

  protected beginTurn(turn: Turn): void {
    if (!this.busy) this.workSince = this.now();
    this.current = turn;
    this.texts = [];
    this.activity = "";
    if (turn.implicit && this.flags.implicitQuiet) this.armImplicitTimer();
    this.turnBegan(turn);
    this.touched();
  }

  /**
   * Words into its harness, each under its uuid, kept as in flight until a
   * result says they were answered. The host's turns: they open one for them
   * if none is open (`turnText`: what it says it's about).
   */
  protected put(words: [uuid: string, meta: P][], proc: () => MainSession, turnText = ""): void {
    for (const [uuid, meta] of words) this.pending.add(uuid, { ...meta, sentAt: this.now() });
    if (this.flags.turns === "host" && !this.current) {
      this.beginTurn({
        text: turnText,
        origin: words[0]![1].origin ?? "app",
        proactive: false,
        wechat: words.map(([, p]) => p.wechat).find(Boolean),
        uuids: words.map(([u]) => u),
      });
    }
    for (const [uuid, p] of words) proc().send(p.text, uuid, p.images);
  }

  /** The turn that output with none open belongs to. */
  private turnFor(): Turn {
    // The harness' own turn: a plain reply.
    if (this.flags.turns === "harness") return { text: "", origin: "app", proactive: false, uuids: this.pending.uuids() };
    if (this.pending.size) {
      // The harness is now answering owner messages it had queued.
      const [first] = this.pending.values();
      const wechat = this.pending.values().find((x) => x.wechat)?.wechat;
      return { text: "", origin: first!.origin ?? "app", proactive: false, wechat, uuids: this.pending.uuids() };
    }
    // The harness started a turn on its own (e.g. a background task finished).
    return { text: "", origin: "system", proactive: true, implicit: true };
  }

  /** Whether this event, with no turn open, opens one. */
  private opens(e: HarnessEvent): boolean {
    switch (e.type) {
      case "init":
        return this.flags.turns === "harness";
      case "text_delta":
        return true;
      case "assistant_text":
      case "tool_use":
      case "tool_start":
        return !e.parentToolUseId || this.flags.subagentTurns;
      default:
        return false;
    }
  }

  private armImplicitTimer(): void {
    if (this.implicitTimer) clearTimeout(this.implicitTimer);
    this.implicitTimer = setTimeout(() => {
      // Waiting on the owner or on a running tool is not "quiet".
      if (this.current?.implicit && (this.turnTools.size || this.waitingOnOwner())) return this.armImplicitTimer();
      if (this.current?.implicit) {
        this.log("implicit turn went quiet without a result; closing it");
        this.endTurn();
      }
    }, timing.implicitQuietMs);
  }

  /** Where its words in a turn go: the turn's channel (the host's turns), or its page (an agent's). */
  private channelOf(turn: Turn | null): { channel?: ChatMessage["channel"] } {
    return this.flags.turns === "host" ? { channel: turn?.origin ?? "system" } : {};
  }

  /** The turn is over: its result came, it was stopped, it went quiet, its process failed. */
  protected endTurn(end: TurnEnd<P> = {}): void {
    const turn = this.current;
    this.current = null;
    this.activity = "";
    this.interrupted = false;
    if (this.implicitTimer) clearTimeout(this.implicitTimer);
    this.closeStream(turn);
    if (this.flags.subagentTurns) {
      this.turnTools.clear();
      this.openTools.clear();
    }
    for (const w of this.turnEndWaiters.splice(0)) w();
    this.turnEnded(turn, end);
  }

  // ---------------- the stall watchdog (stallWatch.ts) ----------------

  /** What the stall watchdog watches. */
  stallTarget(): StallTarget {
    const { key } = this.who();
    const name = () => this.who().name;
    return {
      key,
      get name() {
        return name();
      },
      busy: () => this.host.running && (this.current !== null || this.pending.size > 0),
      waiting: () => this.waitingOnOwner(),
      openTools: () => [...this.openTools.values()],
      lastActivity: () => Math.max(this.lastEventAt, this.host.proc?.lastActivity ?? 0),
      pid: () => this.host.pid,
      progress: () => (this.ref ? this.harness.history.growth(this.ref) : ""),
      recover: () => this.recoverStall(),
    };
  }

  /**
   * Its process froze mid-work: it's ended (killed if it must be) and the
   * same session resumes. The owner's words it never took go in again (same
   * ids, so the app shows them once); if there are none, the turn it was in
   * is asked to go on (how: goOn). A process started awaited is started here;
   * one started by the words that need it, by those.
   */
  protected async recoverStall(): Promise<StallRecovery> {
    const awaited = this.flags.startMode === "awaited";
    const turn = this.current;
    const goes = this.goesOn();
    const before = this.pending.entries();
    await this.host.endFrozen();
    // Nothing writes its transcript now: what's in it was taken. (Awaited,
    // what was in flight went with the process; else it's still here.)
    const { taken, untaken } = this.pending.split((uuid) => !!this.ref && this.harness.history.took(this.ref, uuid), awaited ? before : undefined);
    if (!awaited) this.pending.clear();
    if (!awaited) this.forgetWaiting();
    this.frozenEnded();
    this.log(`${this.who().label} stalled; resuming it (${untaken.length} message(s) to send again)`);
    let proc: MainSession | null = null;
    if (awaited) {
      await this.host.start();
      proc = this.host.proc;
      if (!proc || !this.host.up) throw new Error(tr("pals.restartFailed", { name: this.who().name }));
      this.restarted();
    }
    let continued = false;
    if (goes && !untaken.length) {
      const asked = this.goOn(turn, taken.map(([, p]) => p));
      continued = typeof asked === "boolean" ? asked : await asked;
    }
    if (!awaited) {
      // (in flight again before its turn ends, so nothing queued goes first)
      for (const [uuid, p] of untaken) this.pending.add(uuid, { ...p, sentAt: this.now() });
      if (turn) this.endTurn();
    }
    if (untaken.length) this.put(untaken, () => proc ?? this.host.ensure());
    this.recovered();
    this.touched();
    return { resent: untaken.length, continued };
  }

  // ---------------- model and thinking depth ----------------

  /**
   * Model and/or effort for its next turns (checked already: modelChoice.ts).
   * Running: switched live (a turn in progress keeps its own). Not running:
   * only kept, it isn't started; both apply when it next starts.
   */
  async setModel(o: ModelChoice): Promise<void> {
    this.choose(o);
    const proc = this.host.running ? this.host.proc : null;
    if (proc && "model" in o) await proc.setModel(o.model || undefined).catch((e) => this.switchFailed("setModel", e));
    if (proc && "effort" in o) await proc.setEffort(o.effort || undefined).catch((e) => this.switchFailed("setEffort", e));
    this.touched();
  }

  // ---------------- 回到这里重来 (docs/rewind-prd.md) ----------------

  /** A rewind whose fork the harness hasn't written yet (none once it has). */
  pendingRewind(): PendingRewind | undefined {
    const r = this.kept.rewind;
    if (r && this.ref && this.harness.history.exists(this.ref)) {
      delete this.kept.rewind;
      this.keep();
      return undefined;
    }
    return r;
  }

  /**
   * Its conversation as it stands, as the harness keeps it: the session's
   * own, or, gone back and not spoken to since, the old session's up to where
   * it was cut. Oldest first.
   */
  conversationEntries(): RewindChain & { pending?: PendingRewind } {
    const ref = this.ref;
    if (!ref) throw new Error(rewindNotFound());
    const pending = this.pendingRewind();
    return { ...this.harness.rewind.chain(ref, pending), ...(pending ? { pending } : {}) };
  }

  /**
   * Which session its process starts on: the one it's in, resumed; gone back
   * and not written since, a new one forked from the old one after the last
   * entry kept (none: a fresh one); one it has no transcript of yet, that one.
   */
  protected startOn(pending = this.pendingRewind()): { resumeSessionId?: string; sessionId?: string; fork?: { fromSessionId: string; at: string } } {
    const { sessionId } = this.kept;
    // (an agent's session has its id before the harness has written any of it)
    const known = this.flags.history === "chatLog" || (!!this.ref && this.harness.history.exists(this.ref));
    if (!pending && known) return { resumeSessionId: sessionId };
    return { sessionId, ...(pending?.at ? { fork: { fromSessionId: pending.from, at: pending.at } } : {}) };
  }

  private cantGoBackNow(): boolean {
    return this.current !== null || this.pending.size > 0 || !!this.host.starting || !!this.host.sleeping || this.occupied();
  }

  /**
   * Goes back to just before one of the owner's messages: its process ends
   * and the next one is a new session, forked from the entry before that
   * message (past the last compaction, where the harness can't fork: a copy
   * made here), the old one left as it is; its files go back too if asked
   * (fileCheckpoints). Refused while it's at work. A process started awaited
   * ends first, and comes back if it was up; one started by the words that
   * need it goes on until the new session is there, unless words came meanwhile.
   * `done` is called the moment it has gone back, before anything else can happen.
   */
  async goBack(by: Parameters<Rewinder["find"]>[1], o: { restoreFiles?: boolean; done?: (w: WentBack) => void } = {}): Promise<WentBack> {
    // (A turn stopped but still winding down is no matter: its process ends here.)
    if (this.cantGoBackNow()) throw new Error(rewindBusy());
    const rw = this.harness.rewind;
    const conv = this.conversationEntries();
    const { sessionId } = conv;
    const point = rw.find(conv, by);
    if (!point) throw new Error(rewindNotFound());
    this.refusePoint(conv, point);
    if (o.restoreFiles && !(this.flags.fileCheckpoints && rw.canRestoreFiles(conv, point.uuid))) throw new Error(rewindNoFiles());
    if (this.flags.exclusive) await this.refuseHeld(sessionId);
    const awaited = this.flags.startMode === "awaited";
    const awake = awaited && (this.host.running || this.host.restarting || this.host.queued);
    const backUp = () => this.host.start().catch((e) => this.log(`${this.who().label} couldn't start again: ${e instanceof Error ? e.message : e}`));
    if (awaited) await this.host.shutdown();
    if (o.restoreFiles) {
      const r = await this.filesBack(sessionId, point.uuid);
      if (!r.canRewind) {
        this.log(`${this.who().label} files not restored (${r.error ?? "no reason"})`);
        if (awake) await backUp();
        throw new Error(rewindNoFiles());
      }
    }
    let to: string = randomUUID();
    const copied = rw.needsCopy(conv, point);
    if (copied) {
      try {
        to = await rw.copy({ sessionId, cwd: this.cwd() }, point.at!, this.sessionName());
      } catch (e) {
        if (awake) await backUp();
        throw this.copyFailed(e);
      }
    }
    if (!awaited) {
      // (The conversation may have moved meanwhile.)
      if (this.cantGoBackNow()) throw new Error(rewindBusy());
      this.host.close();
    }
    if (copied) delete this.kept.rewind;
    else this.kept.rewind = { from: sessionId, at: point.at, cut: point.uuid };
    this.kept.sessionId = to;
    const w = { conv, point, from: sessionId, to, copied };
    this.wentBack(w);
    this.keep();
    this.touched();
    o.done?.(w);
    if (awake) await backUp();
    return w;
  }

  // ---------------- 停止 ----------------

  /**
   * Ends what it's doing: what waits is dropped, the harness interrupted, its
   * turn ended and the owner's words in flight with it. How is its flag
   * (`stop`): "cut" is over when this returns, a process that can't be
   * interrupted (a tool that never returns) closed; "settle" gives the harness
   * a moment to end it itself.
   */
  protected stopWork(by: string): void | Promise<void> {
    const settle = this.flags.stop === "settle";
    this.dropWaiting(by);
    const proc = this.host.proc;
    if (settle) {
      this.changed();
      if (!this.busy || !proc) return;
      this.interrupted = true;
    }
    const ended = settle ? this.turnEnds() : null;
    void proc?.interrupt();
    if (!ended) {
      this.cutTurn();
      this.changed();
      return;
    }
    return Promise.race([ended, sleep(STOP_SETTLE_MS)]).then(() => {
      if (this.interrupted && proc === this.host.proc) this.cutTurn();
    });
  }

  // The stopped turn ends here: nothing stays blocked, the next words work as usual.
  private cutTurn(): void {
    if (!this.busy) return;
    this.pending.clear();
    this.forgetWaiting();
    this.endTurn();
    if (this.flags.stop === "cut") this.host.close();
    else this.windingDown = true;
  }

  /** Resolves when the open turn ends (or its process does). */
  private turnEnds(): Promise<void> {
    return new Promise<void>((r) => this.turnEndWaiters.push(r));
  }

  // A reply cut off mid-stream (an error, a kill, a stop) still gets its
  // final message, so no half-written bubble keeps "typing".
  protected closeStream(turn: Turn | null = this.current): void {
    const s = this.stream.take();
    if (s && s.text.trim() && !(this.flags.textBlocks === "joined" && this.replies.has(s.id))) {
      this.out.message({ id: s.id, role: "assistant", kind: "text", text: s.text, ...this.channelOf(turn) });
    }
  }

  /** Its process ended (restart "backoff"): its turn and whatever was going on in it end too. */
  protected processDown(): void {
    this.closeStream();
    this.current = null;
    this.pending.clear();
    this.openTools.clear();
    this.turnTools.clear();
    this.forgetWaiting();
    // what was still running ends with its process
    this.taskView.processEnded();
    this.activity = "";
    this.windingDown = false;
    for (const w of this.turnEndWaiters.splice(0)) w();
  }

  // ---------------- 立刻处理 ----------------
  //
  // Words that come while a step runs are read when it ends. When every step
  // that holds the turn is one the harness can let go on in the background (a
  // command, a subagent; not an MCP tool), the owner can have that done, so
  // they are read now and nothing is lost.

  /** The owner's words it hasn't read yet, and whether 立刻处理 would have them read. */
  waiting(): { count: number; canHandleNow: boolean } | undefined {
    if (!this.waitingWords.size || !this.current) return undefined;
    return { count: this.waitingWords.size, canHandleNow: this.movable() };
  }

  private movable(): boolean {
    if (!this.turnTools.size || !this.host.proc?.backgroundSteps) return false;
    const front = new Set(this.frontTasks.values());
    for (const id of this.turnTools) if (!front.has(id)) return false;
    return true;
  }

  /** 立刻处理: what holds the turn goes on in the background. Says so when it couldn't. */
  async handleNow(): Promise<void> {
    const proc = this.host.proc;
    if (!this.waitingWords.size) return; // read meanwhile
    if (!proc?.backgroundSteps || !this.movable()) throw new Error(tr("session.cantHandleNow"));
    const held = [...this.turnTools];
    // (What it answers doesn't say whether anything moved: the steps ending does.)
    await proc.backgroundSteps();
    const until = this.now() + HANDLE_NOW_MS;
    while (held.some((id) => this.turnTools.has(id)) && this.waitingWords.size && this.now() < until) {
      await Promise.race([new Promise<void>((r) => this.movedWaiters.push(r)), sleep(100)]);
    }
    if (held.some((id) => this.turnTools.has(id)) && this.waitingWords.size) throw new Error(tr("session.cantHandleNow"));
  }

  private trackWaiting(e: HarnessEvent): void {
    const before = JSON.stringify(this.waiting() ?? null);
    if (e.type === "words") {
      if (e.state === "queued" && this.pending.has(e.uuid) && this.current) this.waitingWords.set(e.uuid, this.now());
      else if (e.state !== "queued") this.waitingWords.delete(e.uuid);
    } else if (e.type === "task_started" && e.toolUseId && e.background !== true) this.frontTasks.set(e.taskId, e.toolUseId);
    else if (e.type === "task_backgrounded" || e.type === "task_notification") this.frontTasks.delete(e.taskId);
    else if (e.type === "tool_result" && !e.parentToolUseId) {
      for (const [task, tool] of this.frontTasks) if (tool === e.toolUseId) this.frontTasks.delete(task);
    } else if (e.type === "result") {
      for (const u of e.consumedUuids ?? []) this.waitingWords.delete(u);
    } else return;
    if (JSON.stringify(this.waiting() ?? null) !== before) this.touched();
    for (const w of this.movedWaiters.splice(0)) w();
  }

  protected forgetWaiting(): void {
    this.waitingWords.clear();
    this.frontTasks.clear();
    for (const w of this.movedWaiters.splice(0)) w();
  }

  // ---------------- a limit of the plan used up ----------------

  /**
   * The used-up limit a failed turn failed on; null: it failed otherwise (a
   * busy server says rate_limit too). What its process said of the limits
   * decides; one that said nothing of them, the error's own words (those
   * also when the error has no kind: a crash while a limit is used up isn't one).
   */
  protected usedUp(text: string, category?: string): LimitHit | null {
    if (category && category !== "rate_limit") return null;
    const words = this.harness.auth.isLimit(text);
    if (!category && !words) return null;
    if (!this.limitsSaid) return words;
    const now = this.now();
    for (const [key, l] of this.usedUpLimits) if (l.resetsAt !== undefined && l.resetsAt <= now) this.usedUpLimits.delete(key);
    return [...this.usedUpLimits.values()].at(-1) ?? null;
  }

  // ---------------- harness events ----------------

  onHarnessEvent(e: HarnessEvent): void {
    this.lastEventAt = this.now();
    if (e.type === "tool_use") this.openTools.set(e.id, e.name);
    else if (e.type === "tool_result") this.openTools.delete(e.toolUseId);
    this.trackWaiting(e);
    if (e.type === "words") return;
    if (e.type === "limit") {
      this.limitsSaid = true;
      const key = `${e.kind ?? ""}/${e.scope ?? ""}`;
      if (e.blocked) this.usedUpLimits.set(key, { ...(e.kind ? { kind: e.kind } : {}), ...(e.scope ? { scope: e.scope } : {}), ...(e.resetsAt ? { resetsAt: e.resetsAt } : {}) });
      else this.usedUpLimits.delete(key);
      this.limitHeard(e);
      return;
    }
    if (e.type === "answering") {
      // The harness names the owner messages a turn answers on its first
      // frames: the host's turn starts with exactly those, instead of guessing.
      if (this.flags.turns === "host" && !this.current) {
        const mine = e.uuids.filter((u) => this.pending.has(u));
        if (mine.length) {
          const first = this.pending.get(mine[0]!)!;
          const wechat = mine.map((u) => this.pending.get(u)!.wechat).find(Boolean);
          this.beginTurn({ text: "", origin: first.origin ?? "app", proactive: false, wechat, uuids: mine });
        }
      }
      return;
    }
    if (e.type === "init" && this.flags.turns === "harness") this.windingDown = false; // a new turn
    this.sessionEvent(e);
    if (!this.current && !this.windingDown && this.opens(e)) this.beginTurn(this.turnFor());
    else if (this.current?.implicit && this.flags.implicitQuiet) this.armImplicitTimer();
    const turn = this.current;
    switch (e.type) {
      case "text_delta": {
        if (turn?.proactive) break; // a host-initiated turn's words are shown at its end, if at all
        const id =
          this.flags.replyIds === "api"
            ? (e.messageId ?? this.stream.id ?? newId("m_"))
            : (this.stream.id ?? `m_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`);
        if (id !== this.stream.id) {
          this.closeStream();
          this.stream.open(id);
          // a second text block of the same reply goes on after a blank line
          if (this.flags.textBlocks === "joined" && this.replies.has(id)) this.out.delta(id, "\n\n");
        }
        this.stream.append(e.text);
        this.out.delta(id, e.text);
        // The words themselves now show the progress.
        this.setActivity(ACTIVITY.reply);
        break;
      }
      case "assistant_text": {
        if (e.parentToolUseId) {
          this.taskView.onEvent(e);
          break;
        }
        this.texts.push(e.text);
        if (!turn?.proactive) {
          const id = this.flags.replyIds === "api" ? (e.messageId ?? this.stream.id ?? newId("m_")) : (this.stream.id ?? undefined);
          let text = e.text;
          if (this.flags.textBlocks === "joined" && id) {
            const before = this.replies.get(id);
            text = before ? `${before}\n\n${e.text}` : e.text;
            this.replies.set(id, text);
            if (this.replies.size > 50) this.replies.delete(this.replies.keys().next().value!);
          }
          if (id && this.flags.followTranscript) this.emitted.add(id);
          this.out.message({ id, role: "assistant", kind: "text", text, ...this.channelOf(turn) });
          if (id === this.stream.id) this.stream.take();
        }
        this.said(turn, e.text);
        break;
      }
      case "tool_start":
      case "tool_use":
        if (e.type === "tool_use") {
          if (!e.parentToolUseId) this.turnTools.add(e.id);
          this.taskView.onEvent(e);
        }
        if (e.parentToolUseId) {
          if (this.flags.subagentTurns && e.type === "tool_use") this.setActivity(activityBackground());
          break;
        }
        this.setActivityFor(e.name);
        break;
      case "tool_result":
        this.turnTools.delete(e.toolUseId);
        this.taskView.onEvent(e);
        break;
      case "task_started":
      case "task_progress":
      case "background_tasks":
      case "task_backgrounded":
      case "task_notification":
        if (this.taskView.onEvent(e)) this.touched();
        break;
      case "result": {
        const stopped = this.interrupted || this.windingDown;
        this.windingDown = false;
        this.resultIn(e, turn, stopped);
        // When the harness doesn't say which it answered (older CLIs): the
        // host's owner turn answered its own, a host-initiated one none; the
        // harness' turn all that were in flight.
        const listed = e.consumedUuids ?? (this.flags.turns === "harness" ? this.pending.uuids() : turn && !turn.proactive ? (turn.uuids ?? []) : []);
        const answered = this.pending.consume(listed);
        // its own tool calls end with the turn (a stopped one may not say so)
        for (const id of this.turnTools) this.openTools.delete(id);
        this.turnTools.clear();
        if (this.flags.turns === "harness" && this.pending.size) {
          // more of the owner's words to answer: the next turn goes on with them
          this.closeStream(turn);
          this.current = null;
          this.touched();
        } else {
          this.endTurn({ costUsd: e.costUsd, contextTokens: e.contextTokens, ...(e.isError ? { error: e.text } : {}), errorCategory: e.errorCategory, answered });
        }
        this.resultDone(e, stopped);
        break;
      }
    }
  }
}
