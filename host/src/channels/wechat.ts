import crypto, { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { WechatChannel as WechatChannelIface, WechatReplyTarget } from "./types.ts";
import { readJson, writeJson } from "../util.ts";

// WeChat via Tencent's iLink bot API (the ClawBot channel). The wire code is
// ported from wechat-agent (src/wechat/ilink.ts + adapter.ts, proven in daily
// use): long poll with a client timeout, typing indicator, media in/out
// through the encrypted CDN, quoted messages. Shapes follow Tencent's
// openclaw-weixin plugin; they are not an official public API, so every field
// is read defensively.
//
// Limits we design around (PRD §7.5.4): context_token expires after 24h, at
// most 10 bot messages per user turn, at most 5 messages/second. WeChat is not
// E2E (it transits Tencent), so proactive content defaults to a bare hint.

const CONTEXT_TTL_MS = 24 * 3600_000;
const MAX_PER_TURN = 10;
const MAX_PER_SEC = 5;
const MAX_CHARS = 2000;
const CHANNEL_VERSION = "1.0.2";
const LONG_POLL_MS = 35_000;
const CDN_BASE = "https://novac2c.cdn.weixin.qq.com/c2c";
const TYPING_KEEPALIVE_MS = 5_000;
const TYPING_MAX_MS = 10 * 60_000;
export const RET_SESSION_EXPIRED = -14;

export interface WechatState {
  botToken?: string;
  botId?: string;
  baseUrl?: string;
  ownerUserId?: string;
  updatesBuf?: string;
  context?: { token: string; at: number; sentSinceUser: number };
}

export interface MediaRef {
  encrypt_query_param?: string;
  aes_key?: string;
}

export interface MessageItem {
  type?: number; // 1 text, 2 image, 3 voice, 4 file, 5 video
  text_item?: { text?: string };
  image_item?: { media?: MediaRef; aeskey?: string };
  voice_item?: { media?: MediaRef; text?: string };
  file_item?: { media?: MediaRef; file_name?: string };
  video_item?: { media?: MediaRef };
  ref_msg?: { title?: string; message_item?: MessageItem };
}

export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export class IlinkError extends Error {
  constructor(public code: number, msg: string) {
    super(msg);
  }
}

export class WechatILink implements WechatChannelIface {
  private state: WechatState;
  private running = false;
  private sendTimes: number[] = [];
  private expired = false;
  private typingTicket: string | null = null;
  private typingTimer: ReturnType<typeof setInterval> | null = null;
  private typingOn = false;
  onMessage: (text: string, target: WechatReplyTarget) => void = () => {};
  log: (s: string) => void = (s) => console.log(`[wechat] ${s}`);

  constructor(
    private statePath: string,
    private defaultBase: string,
    private fetchFn: FetchFn = fetch,
    private now: () => number = Date.now,
    private sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
    private mediaDir: string = join(dirname(statePath), "wechat-media"),
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

  unavailableReason(): string | null {
    if (!this.state.botToken) return "微信没登录";
    if (this.expired) return "微信登录过期了，要重新扫码";
    const c = this.state.context;
    if (!this.state.ownerUserId || !c) return "主人还没在微信上发过消息";
    if (this.now() - c.at >= CONTEXT_TTL_MS) return "主人超过 24 小时没在微信上发消息，微信这边暂时发不过去";
    if (c.sentSinceUser >= MAX_PER_TURN) return "这一轮微信消息到上限了，要等主人再发一条";
    return null;
  }

  private base(): string {
    return (this.state.baseUrl || this.defaultBase).replace(/\/$/, "");
  }

  private save(): void {
    writeJson(this.statePath, this.state);
  }

  private async call<T>(endpoint: string, payload: object, timeoutMs: number): Promise<T> {
    const body = JSON.stringify({ ...payload, base_info: { channel_version: CHANNEL_VERSION } });
    const uin = crypto.randomBytes(4).readUInt32BE(0);
    const r = await this.fetchFn(`${this.base()}/${endpoint}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        AuthorizationType: "ilink_bot_token",
        Authorization: `Bearer ${this.state.botToken ?? ""}`,
        "X-WECHAT-UIN": Buffer.from(String(uin)).toString("base64"),
      },
      body,
      signal: AbortSignal.timeout(timeoutMs),
    });
    const j: any = await r.json().catch(() => ({}));
    const code = j.ret || j.errcode;
    if (code) throw new IlinkError(code, `${endpoint} ret=${code} ${j.errmsg ?? ""}`);
    return j as T;
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
    void this.stopTyping();
  }

  async pollOnce(): Promise<number> {
    let j: any;
    try {
      j = await this.call("ilink/bot/getupdates", { get_updates_buf: this.state.updatesBuf ?? "" }, LONG_POLL_MS + 5000);
    } catch (e) {
      // The server holds the long poll; our own timeout just means "nothing new".
      if (e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError")) return 0;
      if (e instanceof IlinkError && e.code === RET_SESSION_EXPIRED) {
        // bot session expired: needs a fresh QR login
        this.expired = true;
        this.running = false;
        this.log("登录已过期，需要重新扫码（paloally wechat login）");
        return 0;
      }
      throw e;
    }
    if (j.get_updates_buf) {
      this.state.updatesBuf = j.get_updates_buf;
      this.save();
    }
    let n = 0;
    for (const m of j.msgs ?? []) {
      if (await this.handleIncoming(m)) n++;
    }
    return n;
  }

  private async handleIncoming(m: any): Promise<boolean> {
    if (m?.message_type !== 1) return false; // 1 = from user, 2 = bot echo
    const from = String(m.from_user_id ?? "");
    if (!from) return false;
    // Single-owner assistant: the first user who reaches the bot is the owner.
    if (!this.state.ownerUserId) this.state.ownerUserId = from;
    if (from !== this.state.ownerUserId) {
      this.log(`ignored message from non-owner`);
      return false;
    }
    if (m.context_token) {
      this.state.context = { token: m.context_token, at: this.now(), sentSinceUser: 0 };
      this.typingTicket = null; // tickets are per context
      this.save();
    }
    const text = await this.extract(m.item_list ?? []);
    if (!text) return false;
    this.onMessage(text, { userId: from, contextToken: m.context_token ?? this.state.context?.token ?? "" });
    return true;
  }

  // Text, quoted messages, voice transcripts, and media saved to disk (the
  // agent gets the local path and can open it).
  private async extract(items: MessageItem[]): Promise<string> {
    const parts: string[] = [];
    for (const item of items) {
      if (item.type === 1 && item.text_item?.text) {
        const ref = item.ref_msg?.title || item.ref_msg?.message_item?.text_item?.text;
        parts.push(ref ? `[引用: ${ref}]\n${item.text_item.text}` : item.text_item.text);
      } else if (item.type === 3 && item.voice_item?.text) {
        parts.push(`[语音转文字] ${item.voice_item.text}`);
      } else if (item.type && [2, 3, 4, 5].includes(item.type)) {
        const label = { 2: "图片", 3: "语音", 4: "文件", 5: "视频" }[item.type as 2 | 3 | 4 | 5];
        try {
          const file = await this.downloadMedia(item);
          parts.push(file ? `[${label}] ${file}` : `[${label}]（无法下载）`);
        } catch (err) {
          this.log(`media download failed: ${err}`);
          parts.push(`[${label}]（下载失败）`);
        }
      } else if (!item.type && item.text_item?.text) {
        parts.push(item.text_item.text);
      }
    }
    return parts.join("\n").trim();
  }

  // ---- send ----

  private contextUsable(): boolean {
    const c = this.state.context;
    return !!c && this.now() - c.at < CONTEXT_TTL_MS && c.sentSinceUser < MAX_PER_TURN;
  }

  async reply(target: WechatReplyTarget, text: string): Promise<void> {
    for (const chunk of splitText(text, MAX_CHARS)) {
      if (!(await this.sendItems(target.userId, target.contextToken, [{ type: 1, text_item: { text: chunk } }]))) break;
    }
  }

  async sendProactive(text: string): Promise<boolean> {
    const owner = this.state.ownerUserId;
    const c = this.state.context;
    if (!owner || !c || !this.contextUsable()) return false;
    return this.sendItems(owner, c.token, [{ type: 1, text_item: { text: text.slice(0, MAX_CHARS) } }]);
  }

  private async sendItems(to: string, contextToken: string, items: object[]): Promise<boolean> {
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
    try {
      await this.call(
        "ilink/bot/sendmessage",
        {
          msg: {
            from_user_id: "",
            to_user_id: to,
            client_id: `paloally:${Date.now()}-${randomBytes(4).toString("hex")}`,
            message_type: 2,
            message_state: 2,
            item_list: items,
            context_token: contextToken,
          },
        },
        15_000,
      );
      return true;
    } catch (e) {
      this.log(`sendmessage failed: ${e}`);
      return false;
    }
  }

  private async rateLimit(): Promise<void> {
    const t = this.now();
    this.sendTimes = this.sendTimes.filter((x) => t - x < 1000);
    if (this.sendTimes.length >= MAX_PER_SEC) await this.sleep(1000 - (t - this.sendTimes[0]!));
    this.sendTimes.push(this.now());
  }

  // ---- typing indicator ----

  // "对方正在输入…" while the assistant works on a WeChat turn. Kept alive
  // every 5s, capped at 10 min; cancelled after the reply lands (same order as
  // the official plugin).
  async startTyping(target: WechatReplyTarget): Promise<void> {
    if (this.typingOn || this.status() !== "connected") return;
    this.typingOn = true;
    try {
      this.typingTicket ||=
        (await this.call<{ typing_ticket?: string }>("ilink/bot/getconfig", { ilink_user_id: target.userId, context_token: target.contextToken }, 10_000))
          .typing_ticket ?? null;
      if (!this.typingOn) return;
      if (!this.typingTicket) {
        this.typingOn = false;
        return;
      }
      const ping = () =>
        this.call("ilink/bot/sendtyping", { ilink_user_id: target.userId, typing_ticket: this.typingTicket, status: 1 }, 10_000).catch(
          () => (this.typingTicket = null),
        );
      await ping();
      // stopTyping ran while we were awaiting: don't start the keepalive after it.
      if (!this.typingOn) return;
      const started = this.now();
      this.typingTimer = setInterval(() => {
        if (this.now() - started > TYPING_MAX_MS) void this.stopTyping(target.userId);
        else void ping();
      }, TYPING_KEEPALIVE_MS);
    } catch (e) {
      this.log(`typing failed: ${e}`);
      this.typingOn = false;
    }
  }

  async stopTyping(userId = this.state.ownerUserId): Promise<void> {
    if (!this.typingOn) return;
    this.typingOn = false;
    if (this.typingTimer) clearInterval(this.typingTimer);
    this.typingTimer = null;
    if (this.typingTicket && userId)
      await this.call("ilink/bot/sendtyping", { ilink_user_id: userId, typing_ticket: this.typingTicket, status: 2 }, 10_000).catch(() => {});
  }

  // ---- media ----

  /** Download and decrypt one media item. Returns the saved path. */
  private async downloadMedia(item: MessageItem): Promise<string | null> {
    const media = item.image_item?.media ?? item.file_item?.media ?? item.video_item?.media ?? item.voice_item?.media;
    const key = item.image_item?.aeskey ?? media?.aes_key;
    if (!media?.encrypt_query_param || !key) return null;
    const res = await this.fetchFn(`${CDN_BASE}/download?encrypted_query_param=${encodeURIComponent(media.encrypt_query_param)}`, {
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new Error(`CDN download ${res.status}`);
    const plain = aes("dec", Buffer.from(await res.arrayBuffer()), aesKey(key));
    const ts = Date.now();
    const name =
      item.type === 2 ? `img_${ts}.${imageExt(plain)}`
      : item.type === 4 ? `${ts}_${basename(item.file_item?.file_name || "file")}`
      : item.type === 5 ? `video_${ts}.mp4`
      : `voice_${ts}.silk`;
    mkdirSync(this.mediaDir, { recursive: true });
    const file = join(this.mediaDir, name);
    writeFileSync(file, plain);
    return file;
  }

  /** Encrypt, upload to the CDN and send as an image / video / file message. */
  async sendFile(target: WechatReplyTarget, file: string): Promise<boolean> {
    const plain = readFileSync(file);
    const key = crypto.randomBytes(16);
    const filekey = crypto.randomBytes(16).toString("hex");
    const kind = /\.(jpe?g|png|gif|webp|bmp)$/i.test(file) ? "image" : /\.(mp4|mov|avi)$/i.test(file) ? "video" : "file";
    const paddedSize = Math.ceil((plain.length + 1) / 16) * 16;
    const { upload_param } = await this.call<{ upload_param?: string }>(
      "ilink/bot/getuploadurl",
      {
        filekey,
        media_type: { image: 1, video: 2, file: 3 }[kind],
        to_user_id: target.userId,
        rawsize: plain.length,
        rawfilemd5: crypto.createHash("md5").update(plain).digest("hex"),
        filesize: paddedSize,
        no_need_thumb: true,
        aeskey: key.toString("hex"),
      },
      15_000,
    );
    if (!upload_param) throw new Error("getuploadurl returned no upload_param");
    const cdn = await this.fetchFn(`${CDN_BASE}/upload?encrypted_query_param=${encodeURIComponent(upload_param)}&filekey=${filekey}`, {
      method: "POST",
      headers: { "Content-Type": "application/octet-stream" },
      body: new Uint8Array(aes("enc", plain, key)),
    });
    const download = cdn.headers.get("x-encrypted-param");
    if (!cdn.ok || !download) throw new Error(`CDN upload failed: ${cdn.status}`);
    const ref = { encrypt_query_param: download, aes_key: Buffer.from(key.toString("hex")).toString("base64"), encrypt_type: 1 };
    const item =
      kind === "image" ? { type: 2, image_item: { media: ref, mid_size: paddedSize } }
      : kind === "video" ? { type: 5, video_item: { media: ref, video_size: paddedSize } }
      : { type: 4, file_item: { media: ref, file_name: basename(file), len: String(plain.length) } };
    return this.sendItems(target.userId, target.contextToken, [item]);
  }

  /** The owner's current reply target, if WeChat can reach them now. */
  ownerTarget(): WechatReplyTarget | null {
    const owner = this.state.ownerUserId;
    const c = this.state.context;
    if (!owner || !c || !this.contextUsable()) return null;
    return { userId: owner, contextToken: c.token };
  }
}

function aesKey(s: string): Buffer {
  if (/^[0-9a-f]{32}$/i.test(s)) return Buffer.from(s, "hex");
  const decoded = Buffer.from(s, "base64");
  const asText = decoded.toString("utf-8");
  if (/^[0-9a-f]{32}$/i.test(asText)) return Buffer.from(asText, "hex");
  return decoded.subarray(0, 16);
}

function aes(mode: "enc" | "dec", data: Buffer, key: Buffer): Buffer {
  const c = mode === "enc" ? crypto.createCipheriv("aes-128-ecb", key, null) : crypto.createDecipheriv("aes-128-ecb", key, null);
  return Buffer.concat([c.update(data), c.final()]);
}

function imageExt(b: Buffer): string {
  if (b[0] === 0x89 && b[1] === 0x50) return "png";
  if (b[0] === 0x47 && b[1] === 0x49) return "gif";
  if (b[0] === 0x52 && b[1] === 0x49) return "webp";
  return "jpg";
}

// Prefers paragraph breaks, then line breaks, then a hard cut.
export function splitText(text: string, max: number): string[] {
  const out: string[] = [];
  let rest = text;
  while (rest.length > max) {
    const win = rest.slice(0, max);
    let cut = win.lastIndexOf("\n\n");
    if (cut < max / 2) cut = win.lastIndexOf("\n");
    if (cut < max / 2) cut = max;
    out.push(rest.slice(0, cut).trimEnd());
    rest = rest.slice(cut).replace(/^\n+/, "");
  }
  if (rest) out.push(rest);
  return out;
}
