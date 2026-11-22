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
// (`subagentTurns`). What each does at a turn's edges (its record, its
// pushes, what goes next) it says through the hooks below.
import { ACTIVITY, activityBackground, describeActivity } from "../copy.ts";
import type { HarnessEvent } from "../harness/types.ts";
import type { StallTarget } from "../stallWatch.ts";
import type { ChatMessage } from "../types.ts";
import { newId } from "../util.ts";
import type { AgentFlags } from "./flags.ts";
import type { OutputSink } from "./outputSink.ts";
import { ProcessHost, type ProcessHostDeps, type ProcessRecord } from "./processHost.ts";
import { StreamAssembler } from "./streamAssembler.ts";
import type { TaskProjection } from "./taskProjection.ts";
import { type Turn, type TurnEnd, timing } from "./turn.ts";
import { TurnLedger } from "./turnLedger.ts";

export interface SessionParts<T extends TaskProjection, S extends OutputSink> {
  /** What of its process is kept with its record (an agent's PalRecord; the assistant keeps none). */
  record: ProcessRecord;
  process: ProcessHostDeps;
  out: S;
  tasks: T;
}

/** What it keeps with each of the owner's messages in flight: the words, and where they came from (the host's turns read it). */
export type InFlight = { text?: string; origin?: Turn["origin"]; wechat?: Turn["wechat"] };

export type ResultEvent = Extract<HarnessEvent, { type: "result" }>;

export abstract class AgentSession<P extends InFlight, T extends TaskProjection = TaskProjection, S extends OutputSink = OutputSink> {
  /** Its harness process. */
  protected readonly host: ProcessHost;
  /** The owner's words sent to the harness and not yet answered, by uuid. */
  protected readonly pending = new TurnLedger<P>();
  /** The reply being streamed. */
  protected readonly stream = new StreamAssembler();
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
  /** The open turn's text blocks, as written. */
  protected texts: string[] = [];
  /** 停止 was asked during the open turn. */
  protected interrupted = false;
  /** A stopped turn was ended here: what's left of it doesn't open a turn or say what it's doing. */
  protected windingDown = false;
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
    this.out = parts.out;
    this.taskView = parts.tasks;
  }

  // ---------------- what each says about itself ----------------

  /** What it shows changed (the assistant's status line, an agent's line in the list). */
  protected abstract changed(): void;

  /** It did something worth showing now (an agent's line also says when). */
  protected touched(): void {
    this.changed();
  }

  protected now(): number {
    return Date.now();
  }

  protected log(_s: string): void {}

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

  /** What the stall watchdog reads the same way for both: its open tool calls and its last sign of life. */
  protected stallSigns(): Pick<StallTarget, "openTools" | "lastActivity"> {
    return {
      openTools: () => [...this.openTools.values()],
      lastActivity: () => Math.max(this.lastEventAt, this.host.proc?.lastActivity ?? 0),
    };
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

  /** Resolves when the open turn ends (or its process does). */
  protected turnEnds(): Promise<void> {
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
    // what was still running ends with its process
    this.taskView.processEnded();
    this.activity = "";
    this.windingDown = false;
    for (const w of this.turnEndWaiters.splice(0)) w();
  }

  // ---------------- harness events ----------------

  onHarnessEvent(e: HarnessEvent): void {
    this.lastEventAt = this.now();
    if (e.type === "tool_use") this.openTools.set(e.id, e.name);
    else if (e.type === "tool_result") this.openTools.delete(e.toolUseId);
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
