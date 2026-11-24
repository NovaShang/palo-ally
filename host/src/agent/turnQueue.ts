// Host-initiated turns (flag `proactiveTurns`, the assistant's;
// docs/harness-adapter-design.md §1.1 row 6): a schedule run, a goal check,
// an Ally's or an agent's message, the host's own /compact, words a question
// was answered with late. They wait in a queue until nothing else is in
// flight (no turn, no owner words unanswered, no Ally's turn), one at a time;
// the proactive daily budget drops them once it's used up (an agent's message
// excepted: it answers work already asked for). At a turn's end what it said
// is shown as what it is: a goal's line, a push of what it brought up (a card
// titled by the goal for a schedule run), nothing for [skip], or a plain
// reply when the owner's words were answered in it too.
import type { ChatMessage } from "../types.ts";
import type { OutputSink } from "./outputSink.ts";
import type { Turn } from "./turn.ts";

export class TurnQueue {
  private queue: Turn[] = [];
  private waiters: (() => void)[] = [];
  private budgetNoticeDay = "";

  constructor(
    private d: {
      /** Something is in flight, so a queued turn waits: a turn, owner words unanswered, an Ally's turn. */
      busy: () => boolean;
      /** Words of the owner in flight. */
      inFlight: () => number;
      /** Owner words the harness never answered stop blocking the queue after a while. */
      expire: () => void;
      /** Nothing at all in flight (the queue's own turns included). */
      quiet: () => boolean;
      /** The proactive budget for today is used up; the day it counts in. */
      overBudget: () => boolean;
      day: () => string;
      budgetNotice: (label?: string) => string;
      /** The turn goes in: it opens and its words go to the harness. */
      start: (turn: Turn) => void;
      out: () => OutputSink;
      push: (msg: ChatMessage) => void;
      /** A schedule run answered: its words become the goal's line. */
      goalResult?: (watchId: string, text: string) => void;
      metric: (m: Record<string, unknown>) => void;
      log: (s: string) => void;
    },
  ) {}

  get length(): number {
    return this.queue.length;
  }

  add(turn: Turn): void {
    this.queue.push(turn);
    this.pump();
  }

  /** Goes first (the turn a stall cut off, asked to go on). */
  first(turn: Turn): void {
    this.queue.unshift(turn);
  }

  has(pred: (t: Turn) => boolean): boolean {
    return this.queue.some(pred);
  }

  find(pred: (t: Turn) => boolean): Turn | undefined {
    return this.queue.find(pred);
  }

  /** What's queued. */
  all(): Turn[] {
    return [...this.queue];
  }

  /** 停止: nothing queued goes on. */
  clear(): void {
    this.queue = [];
  }

  /** The next turn starts if nothing is in flight. */
  pump(): void {
    this.d.expire();
    if (this.d.busy() || !this.queue.length) {
      this.flushIfIdle();
      return;
    }
    const turn = this.queue.shift()!;
    if (turn.proactive && !turn.maintenance && !turn.pal && this.d.overBudget()) {
      this.d.log(`proactive turn dropped: main budget used up (${turn.label ?? turn.origin})`);
      const day = this.d.day();
      if (this.budgetNoticeDay !== day) {
        this.budgetNoticeDay = day;
        this.d.out().message({ role: "system", kind: "notice", text: this.d.budgetNotice(turn.label), channel: "system" });
      }
      return this.pump();
    }
    this.d.start(turn);
  }

  /** A turn ended: the next goes, unless owner words are still in flight (their turn comes first). */
  next(): void {
    if (this.d.inFlight() === 0) this.pump();
    else this.flushIfIdle();
  }

  /** Resolves when nothing is in flight any more (tests, CLI one-shots). */
  idle(): Promise<void> {
    if (this.d.quiet()) return Promise.resolve();
    return new Promise((r) => this.waiters.push(r));
  }

  flushIfIdle(): void {
    if (this.d.quiet()) for (const w of this.waiters.splice(0)) w();
  }

  /**
   * What a turn said, at its end (`shown`: its words without [skip];
   * `answered`: the channels of the owner's words it answered).
   */
  said(turn: Turn, shown: string, answered: { origin: Turn["origin"] }[], error?: string): void {
    if (turn.watchId && shown && !error) this.d.goalResult?.(turn.watchId, shown);
    const out = this.d.out();
    // The owner spoke while this proactive turn ran and it answered them too:
    // show it as a normal reply (no push), not as something it brought up.
    const ownerFolded = turn.proactive && answered.length > 0;
    if (ownerFolded) {
      if (shown) out.message({ role: "assistant", kind: "text", text: shown, channel: answered[0]!.origin });
    } else if (turn.proactive) {
      if (shown) {
        // A schedule goal's output (晨报 and the like) shows as a card titled by the goal.
        const card = turn.watchId && turn.origin === "schedule" ? { card: { title: turn.label ?? "", goalId: turn.watchId } } : {};
        const msg = out.message({ role: "assistant", kind: "text", text: shown, channel: turn.origin, proactive: true, ...card });
        this.d.push(msg);
      } else {
        this.d.metric({ type: "skip", origin: turn.origin, label: turn.label });
      }
    }
  }
}
