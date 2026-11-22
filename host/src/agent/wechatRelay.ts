// WeChat turns (flag `wechat`, the assistant's): from wechat-agent, the
// owner on WeChat sees progress mid-task instead of waiting for the end.
// Paragraphs go out as they're written, chained so they arrive in order; the
// typing indicator comes back between them while the turn is still going; a
// turn whose words weren't streamed gets them in one reply at its end.
import type { Audit } from "../audit.ts";
import type { WechatChannel, WechatReplyTarget } from "../channels/types.ts";
import type { Turn } from "../conversation.ts";
import { stripSkip } from "./skip.ts";

export class WechatRelay {
  private streamed = 0; // paragraphs of this turn already sent
  private chain: Promise<void> = Promise.resolve();

  constructor(
    private d: {
      channel: () => WechatChannel | null;
      audit: () => Audit;
      log: (s: string) => void;
      /** The turn is still the one running. */
      current: (turn: Turn) => boolean;
    },
  ) {}

  /** A turn began: one from WeChat shows typing. */
  turnBegan(turn: Turn): void {
    this.streamed = 0;
    if (turn.wechat && !turn.proactive) void this.d.channel()?.startTyping?.(turn.wechat);
  }

  /** A paragraph of the reply was written. */
  paragraph(turn: Turn, raw: string): void {
    const wechat = this.d.channel();
    const target = turn.wechat;
    const text = stripSkip(raw.trim());
    if (!wechat || !target || !text) return;
    this.streamed++;
    this.chain = this.chain.then(async () => {
      await wechat.reply(target, text).catch((err) => this.d.log(`wechat reply failed: ${err}`));
      this.d.audit().log("wechat.reply", { chars: text.length });
      await wechat.stopTyping?.();
      if (this.d.current(turn)) void wechat.startTyping?.(target);
    });
  }

  /** The turn ended: what it said goes to `target` unless it was streamed already; typing stops. */
  turnEnded(target: WechatReplyTarget | undefined, shown: string): void {
    const wechat = this.d.channel();
    // Already streamed paragraph by paragraph? Then nothing more to send.
    if (target && wechat && shown && !this.streamed) {
      const text = shown;
      this.chain = this.chain.then(() => wechat.reply(target, text).catch((err) => this.d.log(`wechat reply failed: ${err}`)));
      this.d.audit().log("wechat.reply", { chars: shown.length });
    }
    if (wechat) this.chain = this.chain.then(() => wechat.stopTyping?.());
    this.streamed = 0;
  }
}
