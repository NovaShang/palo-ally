// 「只说话不动手」 (flag `allyGate`, the assistant's; docs/allies-prd.md §11.1):
// an Ally's message is in the harness and the turn answering it hasn't
// finished, i.e. from sending it until a result says it consumed that message
// (however the harness queued it). Meanwhile every main-thread tool call goes
// through the gate, nothing else is sent to the harness, and the owner's words
// are held, to go in as turns of their own once it's over.
import { allyTurnTool, type AllyGateScope } from "../allyGate.ts";
import type { Audit } from "../audit.ts";
import type { WechatReplyTarget } from "../channels/types.ts";
import { allyToolDenied } from "../copy.ts";
import type { ImageInput, ToolGate } from "../harness/types.ts";
import type { Channel } from "../types.ts";
import { truncate } from "../util.ts";

export type HeldMessage = { text: string; origin: Channel; wechat?: WechatReplyTarget; images?: ImageInput[]; uuid?: string };

export class AllyTurn {
  private gate: { allyId: string; uuid: string } | null = null;
  private held: HeldMessage[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private d: {
      audit: () => Audit;
      log: (s: string) => void;
      scope: () => AllyGateScope;
      /** A turn is running. */
      busy: () => boolean;
      /** The owner's held words go in, each as it would have gone. */
      resend: (h: HeldMessage) => void;
      /** What waited behind the Ally's turn may go now. */
      pump: () => void;
      quietMs: () => number;
    },
  ) {}

  /** The Ally whose message the harness is handling now, if any. */
  get allyId(): string | undefined {
    return this.gate?.allyId;
  }

  get active(): boolean {
    return !!this.gate;
  }

  /** An Ally's turn is on, or the owner's words wait for one that just ended. */
  get inFlight(): boolean {
    return !!this.gate || this.held.length > 0;
  }

  /** The owner's words during an Ally's turn: held (true), or nothing to hold them for. */
  hold(h: HeldMessage): boolean {
    if (!this.gate) return false;
    this.held.push(h);
    this.d.audit().log("ally.turn.held", { allyId: this.gate.allyId, origin: h.origin });
    return true;
  }

  /** The Ally's message goes in under `uuid`: its turn is gated from now on. */
  start(allyId: string, uuid: string): void {
    this.gate = { allyId, uuid };
    this.d.audit().log("ally.turn.start", { allyId });
  }

  // gateTool is the host's rule for a tool call: in an Ally's turn, only
  // what allyGate.ts lets through; otherwise nothing to say. A subagent's call
  // (agentId) belongs to work the owner started earlier (this turn can't start
  // or message one: Agent and SendMessage are denied here), so it isn't gated.
  gateTool: ToolGate = (req) => {
    const g = this.gate;
    if (!g || req.agentId) return null;
    if (allyTurnTool(req.toolName, req.input ?? {}, this.d.scope()).ok) return null;
    this.d.audit().log("ally.tool.denied", { allyId: g.allyId, tool: req.toolName, via: req.via, input: truncate(JSON.stringify(req.input ?? {}), 300) });
    return allyToolDenied(req.toolName);
  };

  /**
   * A result came: whether it ended the Ally's turn (it consumed its message;
   * an older CLI that doesn't list them: our turn for it, `answering`, ended).
   */
  doneBy(consumed: string[] | undefined, answering: string[] | undefined): boolean {
    const g = this.gate;
    return !!g && (consumed ? consumed.includes(g.uuid) : !!answering?.includes(g.uuid));
  }

  // end lifts the gate and sends the owner's held words, each as it would
  // have gone (they reach the harness after the Ally's turn is over).
  end(why: string): void {
    const g = this.gate;
    if (!g) return;
    this.gate = null;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.d.audit().log("ally.turn.end", { allyId: g.allyId, why, held: this.held.length });
    for (const h of this.held.splice(0)) this.d.resend(h);
  }

  // Our turn ended but the harness hasn't said it consumed the Ally's message
  // (it queued it behind something else). The gate stays until it does; if
  // the harness goes quiet without ever getting to it, the gate ends.
  watch(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (!this.gate) return;
      if (this.d.busy()) return this.watch();
      this.d.log("an Ally's message got no result; its turn ends here");
      this.end("no result");
      this.d.pump();
    }, this.d.quietMs());
    (this.timer as any).unref?.();
  }

  /** The process froze: the Ally's message died with it (true if there was one); the owner's held words stay for takeHeld(). */
  stalled(): boolean {
    const g = this.gate;
    if (!g) return false;
    this.gate = null;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.d.audit().log("ally.turn.end", { allyId: g.allyId, why: "stalled", held: this.held.length });
    return true;
  }

  /** The owner's held words, taken to be sent now. */
  takeHeld(): HeldMessage[] {
    return this.held.splice(0);
  }

  /** 停止: the Ally's turn and the owner's words held for it are dropped, as words already sent are. */
  stop(): void {
    if (!this.gate) return;
    this.held = [];
    this.gate = null;
    if (this.timer) clearTimeout(this.timer);
  }
}
