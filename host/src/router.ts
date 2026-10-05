import type { Audit } from "./audit.ts";
import type { Settings } from "./config.ts";
import type { ChatMessage } from "./types.ts";
import { inWindow, minuteOfDay, parseHHMM, truncate } from "./util.ts";

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

export type DeliveryResult = { pushed: boolean; wechat: boolean; suppressed?: "quiet" | "burst" | "duplicate" };

// Runaway guard for pushes the assistant starts on its own (schedule / probe
// turns). There is no daily total — heavy use is fine; only abnormal patterns
// are held back: a burst in a short window, or the same text again.
export const runaway = { burstWindowMs: 10 * 60_000, burstMax: 5, duplicateWindowMs: 60 * 60_000 };
const GUARDED: ReadonlySet<string> = new Set(["probe", "schedule"]);

// Router decides where an outbound proactive message goes (design §6). The
// chat log already has it; this only adds interrupts (push / WeChat).
export class Router {
  private recent: { ts: number; key: string }[] = []; // guarded pushes actually sent
  onRunaway: (reason: "burst" | "duplicate") => void = () => {};

  constructor(
    private settings: () => Settings,
    private pushers: Pusher[],
    private wechat: WechatOut | null,
    private audit: Audit,
    private now: () => number = Date.now,
    private lastOwnerActivity: () => number = () => 0,
  ) {}

  // runawayCheck returns why a guarded push should be held back, if at all.
  private runawayCheck(msg: ChatMessage): "burst" | "duplicate" | null {
    if (!GUARDED.has(msg.channel)) return null;
    const t = this.now();
    this.recent = this.recent.filter((r) => t - r.ts < runaway.duplicateWindowMs);
    const key = msg.text.replace(/\s+/g, " ").trim();
    if (this.recent.some((r) => r.key === key)) return "duplicate";
    if (this.recent.filter((r) => t - r.ts < runaway.burstWindowMs).length >= runaway.burstMax) return "burst";
    this.recent.push({ ts: t, key });
    return null;
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
      const runawayReason = this.runawayCheck(msg);
      if (runawayReason) {
        this.audit.log("deliver.suppressed", { reason: runawayReason, msg: msg.id });
        this.onRunaway(runawayReason);
        return { pushed: false, wechat: false, suppressed: runawayReason };
      }
    }

    const title = opts.title ?? (this.settings().assistantName || "Palo");
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
