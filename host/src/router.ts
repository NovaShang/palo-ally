import type { Audit } from "./audit.ts";
import type { Settings } from "./config.ts";
import type { ChatMessage } from "./types.ts";
import { inWindow, minuteOfDay, parseHHMM, truncate } from "./util.ts";
import { t } from "./i18n/index.ts";

export interface Pusher {
  readonly name: string;
  available(): boolean;
  /** Resolves with the number of devices reached when the pusher knows it. */
  push(title: string, body: string, data: Record<string, unknown>): Promise<number | void>;
}

export interface WechatOut {
  available(): boolean;
  // proactive text to the owner (subject to iLink limits)
  sendProactive(text: string): Promise<boolean>;
  /** Why a proactive message can't go out on WeChat right now, in plain words. */
  unavailableReason?(): string | null;
}

const ACTIVE_MS = 10 * 60_000;
// Above the relay push timeout (5 s), so the pusher reports its own reason first.
const PUSH_TIMEOUT_MS = 6_000;

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

export type DeliveryResult = {
  pushed: boolean;
  wechat: boolean;
  suppressed?: "quiet" | "burst" | "duplicate";
  /** Devices a push reached, when the pusher reports it. */
  devices?: number;
  /** Why no push went out, in plain words (unset when one did). */
  pushError?: string;
  /** Why WeChat wasn't used (unset when it was, or wasn't wanted). */
  wechatNote?: string;
  /** End of quiet hours ("HH:MM") when suppressed for quiet. */
  quietEnds?: string;
};

/** The last push attempt, for `paloally status` / doctor. */
export interface PushHealth {
  at: number;
  ok: boolean;
  detail: string;
}

// pushFailureReason turns pusher errors into something the owner (and the
// assistant) can act on.
export function pushFailureReason(errors: string[]): string {
  const all = errors.join(" ");
  if (/unsupported/.test(all)) return t("push.err.unsupported");
  if (/NotConfigured/.test(all)) return t("push.err.notConfigured");
  if (/relay not (connected|started)/.test(all)) return t("push.err.relayDown");
  if (/RateLimited/.test(all)) return t("push.err.rate");
  if (/NoPairedDevice/.test(all)) return t("push.err.noDevice");
  if (/BadDeviceToken|Unregistered|\b410\b/.test(all)) return t("push.err.token");
  if (/timed out/.test(all)) return t("push.err.timeout");
  return t("push.err.failed", { detail: truncate(all, 80) });
}

// Runaway guard for pushes the assistant starts on its own (schedule / probe
// turns). There is no daily total — heavy use is fine; only abnormal patterns
// are held back: a burst in a short window, or the same text again.
export const runaway = { burstWindowMs: 10 * 60_000, burstMax: 5, duplicateWindowMs: 60 * 60_000 };
const GUARDED: ReadonlySet<string> = new Set(["probe", "schedule"]);

// Router decides where an outbound proactive message goes (design §6). The
// chat log already has it; this only adds interrupts (push / WeChat).
export class Router {
  private recent: { ts: number; key: string }[] = []; // guarded pushes actually sent
  private health: PushHealth | null = null;
  onRunaway: (reason: "burst" | "duplicate") => void = () => {};

  pushHealth(): PushHealth | null {
    return this.health;
  }

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

  async proactive(msg: ChatMessage, opts: { urgent?: boolean; title?: string; skipWechat?: boolean } = {}): Promise<DeliveryResult> {
    const s = this.settings();
    if (!opts.urgent) {
      if (this.isQuiet()) {
        this.audit.log("deliver.suppressed", { reason: "quiet", msg: msg.id });
        return { pushed: false, wechat: false, suppressed: "quiet", ...(s.quietHours ? { quietEnds: s.quietHours.end } : {}) };
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
    let devices: number | undefined;
    let tried = false;
    const errors: string[] = [];
    for (const p of this.pushers) {
      if (!p.available()) continue;
      tried = true;
      try {
        // A half-open connection (laptop slept) must not hang the caller.
        const n = await withTimeout(p.push(title, body, { seq: msg.seq, id: msg.id, taskId: msg.taskId, approvalId: msg.approvalId, questionId: msg.questionId, ...(msg.pal ? { pal: msg.pal } : {}) }), PUSH_TIMEOUT_MS);
        if (n === 0) continue; // no device registered with this pusher
        pushed = true;
        if (typeof n === "number") devices = (devices ?? 0) + n;
      } catch (e) {
        errors.push(String(e));
        this.audit.log("deliver.error", { via: p.name, error: String(e) });
      }
    }
    const pushError = pushed ? undefined : errors.length ? pushFailureReason(errors) : t("push.err.noneEnabled");
    if (tried || errors.length) this.health = { at: this.now(), ok: pushed, detail: pushed ? (devices ? t("push.ok.devices", { n: devices }) : t("push.ok")) : pushError! };

    // WeChat as well as the push (and the fallback when the push failed).
    let wechat = false;
    let wechatNote: string | undefined;
    if (opts.skipWechat) {
      // already sent there as part of the turn
    } else if (!this.wechat) {
      wechatNote = t("wechat.note.off");
    } else if (s.wechatProactive === "off") {
      wechatNote = t("wechat.note.muted");
    } else if (!this.wechat.available()) {
      wechatNote = this.wechat.unavailableReason?.() ?? t("wechat.note.cantSend");
    } else {
      // WeChat goes through Tencent's servers (not E2E): by default only a hint.
      const text = s.wechatProactive === "full" ? msg.text : t("wechat.hint", { hint: hintFor(msg) });
      wechat = await withTimeout(this.wechat.sendProactive(text), PUSH_TIMEOUT_MS).catch(() => false);
      if (!wechat) wechatNote = t("wechat.note.failed");
    }
    this.audit.log("deliver", { msg: msg.id, pushed, wechat, ...(pushError ? { pushError } : {}), ...(wechatNote ? { wechatNote } : {}) });
    return { pushed, wechat, ...(devices !== undefined ? { devices } : {}), ...(pushError ? { pushError } : {}), ...(wechatNote ? { wechatNote } : {}) };
  }
}

// hintFor names the kind of message without its content.
function hintFor(msg: ChatMessage): string {
  if (msg.kind === "approval") return t("wechat.hint.approval", { code: msg.approvalId?.slice(-4) ?? "" });
  if (msg.kind === "question") return t("wechat.hint.question");
  if (msg.kind === "task") return t("wechat.hint.task");
  if (msg.kind === "ally") return t("wechat.hint.ally");
  return t("wechat.hint.other");
}
