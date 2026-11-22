// One AgentSession for the assistant and every agent (docs/harness-adapter-design.md
// §1.3, step 13): its harness process (ProcessHost), the owner's messages in
// flight (TurnLedger), the reply being streamed (StreamAssembler), where its
// words go (OutputSink), its tasks (TaskProjection), its open tool calls, what
// it's doing, and what the stall watchdog reads, chosen by its flags. The
// assistant (conversation.ts) and an agent (palSession.ts) are this with
// their flags and their own turns: the assistant's host-initiated queue with
// its pieces (WeChat, an Ally's gated turn, idle compaction), an agent's
// turns as its harness runs them.
import type { StallTarget } from "../stallWatch.ts";
import type { AgentFlags } from "./flags.ts";
import type { OutputSink } from "./outputSink.ts";
import { ProcessHost, type ProcessHostDeps, type ProcessRecord } from "./processHost.ts";
import { StreamAssembler } from "./streamAssembler.ts";
import type { TaskProjection } from "./taskProjection.ts";
import { TurnLedger } from "./turnLedger.ts";

export interface SessionParts<T extends TaskProjection, S extends OutputSink> {
  /** What of its process is kept with its record (an agent's PalRecord; the assistant keeps none). */
  record: ProcessRecord;
  process: ProcessHostDeps;
  out: S;
  tasks: T;
}

export abstract class AgentSession<P, T extends TaskProjection = TaskProjection, S extends OutputSink = OutputSink> {
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

  constructor(
    readonly flags: AgentFlags,
    parts: SessionParts<T, S>,
  ) {
    this.host = new ProcessHost(flags, parts.record, parts.process);
    this.out = parts.out;
    this.taskView = parts.tasks;
  }

  /** What it shows changed (the assistant's status line, an agent's line in the list). */
  protected abstract changed(): void;

  /** While this says so, what it's doing isn't updated (an agent's stopped turn winding down). */
  protected activityHeld(): boolean {
    return false;
  }

  protected setActivity(a: string | null): void {
    if (a === null || a === this.activity || this.activityHeld()) return;
    this.activity = a;
    this.changed();
  }

  /**
   * The reply being streamed right now (its message id and all its text so
   * far), for a client that reconnects mid-reply: the deltas it missed while
   * offline are not replayed, so it takes this, then keeps appending deltas.
   */
  streaming(): { id: string; text: string } | null {
    return this.stream.current();
  }

  /** What the stall watchdog reads the same way for both: its open tool calls and its last sign of life. */
  protected stallSigns(): Pick<StallTarget, "openTools" | "lastActivity"> {
    return {
      openTools: () => [...this.openTools.values()],
      lastActivity: () => Math.max(this.lastEventAt, this.host.proc?.lastActivity ?? 0),
    };
  }
}
