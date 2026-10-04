import type { Audit } from "./audit.ts";
import type { Settings } from "./config.ts";
import type { ChatMessage } from "./types.ts";
import { inWindow, minuteOfDay, parseHHMM, readJson, truncate, writeJson, zonedParts } from "./util.ts";

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
const PUSH_TIMEOUT_MS = 10_000;

export function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms);
    p.then(
      (v) => {
        clearTimeout(t);
        resolve(v);
      },
      (e) => {
        clearTimeout(t);
        reject(e);
      },
    );
  });
}

export type DeliveryResult = { pushed: boolean; wechat: boolean; suppressed?: "quiet" | "cap" };

// Router decides where an outbound proactive message goes (design §6). The
// chat log already has it; this only adds interrupts (push / WeChat).
export class Router {
  constructor(
    private settings: () => Settings,
    private pushers: Pusher[],
    private wechat: WechatOut | null,
    private audit: Audit,
    private now: () => number = Date.now,
    private lastOwnerActivity: () => number = () => 0,
    // where today's push count is kept, so a restart doesn't reset the allowance
    private counterPath?: string,
  ) {}

  private counter(): { day: string; count: number } {
    const day = zonedParts(this.now(), this.settings().timezone).dateKey;
    const c = this.counterPath ? readJson<{ day: string; count: number }>(this.counterPath, { day, count: 0 }) : this.mem;
    return c.day === day ? c : { day, count: 0 };
  }

  private mem = { day: "", count: 0 };

  private bump(): void {
    const c = this.counter();
    c.count++;
    if (this.counterPath) writeJson(this.counterPath, c);
    else this.mem = c;
  }

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
    if (!opts.urgent) {
      if (this.isQuiet()) {
        this.audit.log("deliver.suppressed", { reason: "quiet", msg: msg.id });
        return { pushed: false, wechat: false, suppressed: "quiet" };
      }
      // An approval is the assistant waiting on the owner: never capped.
      if (msg.kind !== "approval") {
        if (this.counter().count >= s.maxProactivePerDay) {
          this.audit.log("deliver.suppressed", { reason: "cap", msg: msg.id });
          return { pushed: false, wechat: false, suppressed: "cap" };
        }
        this.bump();
      }
    }

    const title = opts.title ?? "PaloAlly";
    const body = truncate(msg.text.replace(/\s+/g, " "), 180);
    let pushed = false;
    for (const p of this.pushers) {
      if (!p.available()) continue;
      try {
        // A half-open connection (laptop slept) must not hang the caller.
        await withTimeout(p.push(title, body, { seq: msg.seq, id: msg.id, taskId: msg.taskId, approvalId: msg.approvalId }), PUSH_TIMEOUT_MS);
        pushed = true;
      } catch (e) {
        this.audit.log("deliver.error", { via: p.name, error: String(e) });
      }
    }

    let wechat = false;
    if (this.wechat?.available() && s.wechatProactive !== "off") {
      // WeChat goes through Tencent's servers (not E2E): by default only a hint.
      const text = s.wechatProactive === "full" ? msg.text : `PaloAlly 有一条新消息：${hintFor(msg)}。打开 App 查看。`;
      wechat = await withTimeout(this.wechat.sendProactive(text), PUSH_TIMEOUT_MS).catch(() => false);
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
