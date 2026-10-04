import type { Audit } from "./audit.ts";
import type { Settings } from "./config.ts";
import type { ChatMessage } from "./types.ts";
import { inWindow, minuteOfDay, parseHHMM, truncate, zonedParts } from "./util.ts";

export interface Pusher {
  readonly name: string;
  available(): boolean;
  push(title: string, body: string, data: Record<string, unknown>): Promise<void>;
}

export interface WechatOut {
  available(): boolean;
  // proactive text to the owner (subject to iLink limits)
  sendProactive(text: string): Promise<boolean>;
}

const ACTIVE_MS = 10 * 60_000;

export type DeliveryResult = { pushed: boolean; wechat: boolean; suppressed?: "quiet" | "cap" };

// Router decides where an outbound proactive message goes (design §6). The
// chat log already has it; this only adds interrupts (push / WeChat).
export class Router {
  private sentToday = { day: "", count: 0 };

  constructor(
    private settings: () => Settings,
    private pushers: Pusher[],
    private wechat: WechatOut | null,
    private audit: Audit,
    private now: () => number = Date.now,
    private lastOwnerActivity: () => number = () => 0,
  ) {}

  isQuiet(): boolean {
    const s = this.settings();
    if (!s.quietHours) return false;
    // Someone who was just chatting is clearly awake.
    if (this.now() - this.lastOwnerActivity() < ACTIVE_MS) return false;
    const start = parseHHMM(s.quietHours.start);
    const end = parseHHMM(s.quietHours.end);
    if (start === null || end === null) return false;
    return inWindow(minuteOfDay(this.now(), s.timezone), start, end);
  }

  async proactive(msg: ChatMessage, opts: { urgent?: boolean; title?: string } = {}): Promise<DeliveryResult> {
    const s = this.settings();
    const day = zonedParts(this.now(), s.timezone).dateKey;
    if (this.sentToday.day !== day) this.sentToday = { day, count: 0 };

    if (!opts.urgent) {
      if (this.isQuiet()) {
        this.audit.log("deliver.suppressed", { reason: "quiet", msg: msg.id });
        return { pushed: false, wechat: false, suppressed: "quiet" };
      }
      if (this.sentToday.count >= s.maxProactivePerDay) {
        this.audit.log("deliver.suppressed", { reason: "cap", msg: msg.id });
        return { pushed: false, wechat: false, suppressed: "cap" };
      }
      this.sentToday.count++; // urgent ones don't use up the day's allowance
    }

    const title = opts.title ?? "PaloAlly";
    const body = truncate(msg.text.replace(/\s+/g, " "), 180);
    let pushed = false;
    for (const p of this.pushers) {
      if (!p.available()) continue;
      try {
        await p.push(title, body, { seq: msg.seq, id: msg.id, taskId: msg.taskId, approvalId: msg.approvalId });
        pushed = true;
      } catch (e) {
        this.audit.log("deliver.error", { via: p.name, error: String(e) });
      }
    }

    let wechat = false;
    if (this.wechat?.available() && s.wechatProactive !== "off") {
      // WeChat goes through Tencent's servers (not E2E): by default only a hint.
      const text = s.wechatProactive === "full" ? msg.text : `PaloAlly 有一条新消息：${hintFor(msg)}。打开 App 查看。`;
      wechat = await this.wechat.sendProactive(text).catch(() => false);
    }
    this.audit.log("deliver", { msg: msg.id, pushed, wechat });
    return { pushed, wechat };
  }
}

// hintFor names the kind of message without its content.
function hintFor(msg: ChatMessage): string {
  if (msg.kind === "approval") return `有个操作等你确认（回复「同意 ${msg.approvalId?.slice(-4)}」或「拒绝 ${msg.approvalId?.slice(-4)}」，或在 App 里看详情）`;
  if (msg.kind === "task") return "有个任务有结果了";
  return "我有事想跟你说";
}
