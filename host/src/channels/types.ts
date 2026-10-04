import type { WechatOut } from "../router.ts";

// A connected client (app over the relay, or the local CLI socket).
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
