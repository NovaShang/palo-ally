import { randomBytes, randomUUID } from "node:crypto";
import type { WechatChannel as WechatChannelIface, WechatReplyTarget } from "../hub.ts";
import { readJson, writeJson } from "../util.ts";

// WeChat via Tencent's iLink bot API (the ClawBot channel). Wire shapes follow
// the protocol as used by the openclaw-weixin plugin; they are not an official
// public API, so every field is read defensively.
//
// Limits we design around (PRD §7.5.4): context_token expires after 24h, at
// most 10 bot messages per user turn, at most 5 messages/second. WeChat is not
// E2E (it transits Tencent), so proactive content defaults to a bare hint.

const CONTEXT_TTL_MS = 24 * 3600_000;
const MAX_PER_TURN = 10;
const MAX_PER_SEC = 5;
const MAX_CHARS = 1800;
const CHANNEL_VERSION = "1.0.2";

export interface WechatState {
  botToken?: string;
  botId?: string;
  baseUrl?: string;
  ownerUserId?: string;
  updatesBuf?: string;
  context?: { token: string; at: number; sentSinceUser: number };
}

export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export class WechatILink implements WechatChannelIface {
  private state: WechatState;
  private running = false;
  private sendTimes: number[] = [];
  private expired = false;
  onMessage: (text: string, target: WechatReplyTarget) => void = () => {};
  log: (s: string) => void = (s) => console.log(`[wechat] ${s}`);

  constructor(
    private statePath: string,
    private defaultBase: string,
    private fetchFn: FetchFn = fetch,
    private now: () => number = Date.now,
    private sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
  ) {
    this.state = readJson<WechatState>(statePath, {});
  }

  get loggedIn(): boolean {
    return !!this.state.botToken;
  }

  status(): "off" | "connected" | "expired" {
    if (!this.state.botToken) return "off";
    if (this.expired) return "expired";
    return "connected";
  }

  available(): boolean {
    return this.status() === "connected" && this.contextUsable();
  }

  private base(): string {
    return (this.state.baseUrl || this.defaultBase).replace(/\/$/, "");
  }

  private headers(): Record<string, string> {
    const uin = Buffer.from(String(randomBytes(4).readUInt32BE(0))).toString("base64");
    return {
      "Content-Type": "application/json",
      AuthorizationType: "ilink_bot_token",
      Authorization: `Bearer ${this.state.botToken ?? ""}`,
      "X-WECHAT-UIN": uin,
    };
  }

  private save(): void {
    writeJson(this.statePath, this.state);
  }

  // ---- login (QR) ----

  async beginLogin(): Promise<{ qrcode: string; qrUrl: string }> {
    const r = await this.fetchFn(`${this.defaultBase.replace(/\/$/, "")}/ilink/bot/get_bot_qrcode?bot_type=3`);
    const j: any = await r.json();
    if (!j.qrcode) throw new Error(`获取二维码失败：${JSON.stringify(j).slice(0, 200)}`);
    return { qrcode: j.qrcode, qrUrl: j.qrcode_img_content ?? j.qrcode };
  }

  // waitLogin polls until scanned + confirmed (or expired / timeout).
  async waitLogin(qrcode: string, timeoutMs = 5 * 60_000, onStatus: (s: string) => void = () => {}): Promise<boolean> {
    const deadline = this.now() + timeoutMs;
    let last = "";
    while (this.now() < deadline) {
      const r = await this.fetchFn(
        `${this.defaultBase.replace(/\/$/, "")}/ilink/bot/get_qrcode_status?qrcode=${encodeURIComponent(qrcode)}`,
        { headers: { "iLink-App-ClientVersion": "1" } },
      );
      const j: any = await r.json().catch(() => ({}));
      const st = String(j.status ?? "");
      if (st !== last) onStatus((last = st));
      if (st === "confirmed" && j.bot_token) {
        this.state = {
          botToken: j.bot_token,
          botId: j.ilink_bot_id,
          baseUrl: j.baseurl || undefined,
          ownerUserId: j.ilink_user_id || undefined,
        };
        this.expired = false;
        this.save();
        return true;
      }
      if (st === "expired") return false;
      await this.sleep(1500);
    }
    return false;
  }

  logout(): void {
    this.state = {};
    this.save();
  }

  // ---- receive loop ----

  async start(): Promise<void> {
    if (!this.loggedIn || this.running) return;
    this.running = true;
    let backoff = 1000;
    while (this.running) {
      try {
        await this.pollOnce();
        backoff = 1000;
      } catch (e) {
        this.log(`poll failed: ${e}`);
        await this.sleep(backoff);
        backoff = Math.min(backoff * 2, 60_000);
      }
    }
  }

  stop(): void {
    this.running = false;
  }

  async pollOnce(): Promise<number> {
    const r = await this.fetchFn(`${this.base()}/ilink/bot/getupdates`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ get_updates_buf: this.state.updatesBuf ?? "", base_info: { channel_version: CHANNEL_VERSION } }),
    });
    const j: any = await r.json();
    const code = j.ret ?? j.errcode ?? 0;
    if (code === -14) {
      // bot session expired: needs a fresh QR login
      this.expired = true;
      this.running = false;
      this.log("登录已过期，需要重新扫码（paloally wechat login）");
      return 0;
    }
    if (code !== 0) throw new Error(`getupdates ret=${code} ${j.errmsg ?? ""}`);
    if (j.get_updates_buf) {
      this.state.updatesBuf = j.get_updates_buf;
      this.save();
    }
    let n = 0;
    for (const m of j.msgs ?? []) {
      if (this.handleIncoming(m)) n++;
    }
    return n;
  }

  private handleIncoming(m: any): boolean {
    if (m?.message_type !== 1) return false; // 1 = from user, 2 = bot echo
    const from = String(m.from_user_id ?? "");
    if (!from) return false;
    // Single-owner assistant: the first user who reaches the bot is the owner.
    if (!this.state.ownerUserId) this.state.ownerUserId = from;
    if (from !== this.state.ownerUserId) {
      this.log(`ignored message from non-owner`);
      return false;
    }
    const text = (m.item_list ?? [])
      .map((it: any) => it?.text_item?.text ?? it?.voice_item?.text ?? "")
      .filter(Boolean)
      .join("\n")
      .trim();
    if (m.context_token) {
      this.state.context = { token: m.context_token, at: this.now(), sentSinceUser: 0 };
      this.save();
    }
    if (!text) return false;
    this.onMessage(text, { userId: from, contextToken: m.context_token ?? this.state.context?.token ?? "" });
    return true;
  }

  // ---- send ----

  private contextUsable(): boolean {
    const c = this.state.context;
    return !!c && this.now() - c.at < CONTEXT_TTL_MS && c.sentSinceUser < MAX_PER_TURN;
  }

  async reply(target: WechatReplyTarget, text: string): Promise<void> {
    for (const chunk of splitText(text, MAX_CHARS)) {
      if (!(await this.sendText(target.userId, target.contextToken, chunk))) break;
    }
  }

  async sendProactive(text: string): Promise<boolean> {
    const owner = this.state.ownerUserId;
    const c = this.state.context;
    if (!owner || !c || !this.contextUsable()) return false;
    return this.sendText(owner, c.token, text.slice(0, MAX_CHARS));
  }

  private async sendText(to: string, contextToken: string, text: string): Promise<boolean> {
    const c = this.state.context;
    if (c && c.token === contextToken) {
      if (c.sentSinceUser >= MAX_PER_TURN) {
        this.log("per-turn message cap reached; dropping");
        return false;
      }
      c.sentSinceUser++;
      this.save();
    }
    await this.rateLimit();
    const r = await this.fetchFn(`${this.base()}/ilink/bot/sendmessage`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        msg: {
          from_user_id: "",
          to_user_id: to,
          client_id: randomUUID(),
          message_type: 2,
          message_state: 2,
          item_list: [{ type: 1, text_item: { text } }],
          context_token: contextToken,
        },
        base_info: { channel_version: CHANNEL_VERSION },
      }),
    });
    const j: any = await r.json().catch(() => ({}));
    const code = j.ret ?? j.errcode ?? 0;
    if (code !== 0) {
      this.log(`sendmessage ret=${code} ${j.errmsg ?? ""}`);
      return false;
    }
    return true;
  }

  private async rateLimit(): Promise<void> {
    const t = this.now();
    this.sendTimes = this.sendTimes.filter((x) => t - x < 1000);
    if (this.sendTimes.length >= MAX_PER_SEC) await this.sleep(1000 - (t - this.sendTimes[0]!));
    this.sendTimes.push(this.now());
  }
}

export function splitText(text: string, max: number): string[] {
  if (text.length <= max) return [text];
  const out: string[] = [];
  let rest = text;
  while (rest.length > max) {
    let cut = rest.lastIndexOf("\n", max);
    if (cut < max / 2) cut = max;
    out.push(rest.slice(0, cut));
    rest = rest.slice(cut).replace(/^\n/, "");
  }
  if (rest) out.push(rest);
  return out;
}
