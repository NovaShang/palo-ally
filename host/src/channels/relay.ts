import type { Hub } from "../hub.ts";
import { hostAccept, parseHandshake, parseSshWirePubkey, b64, b64url, fingerprint, newIdentity, sign, unb64, type Identity, type Secure } from "../proto/e2e.ts";
import { serveRpc } from "../rpc.ts";
import { newId, readJson, writeJson } from "../util.ts";

// Frame layer of the bento relay (bento/docs/relay-protocol.md), daemon side.
export const FRAME_VERSION = 0x01;
export const T_OPEN = 0x01;
export const T_DATA = 0x02;
export const T_CLOSE = 0x03;
export const T_CONTROL = 0x10;

export function buildFrame(type: number, streamId: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  const buf = new Uint8Array(6 + payload.length);
  buf[0] = FRAME_VERSION;
  buf[1] = type;
  new DataView(buf.buffer).setUint32(2, streamId);
  buf.set(payload, 6);
  return buf;
}

export function parseFrame(buf: Uint8Array): { version: number; type: number; streamId: number; payload: Uint8Array } | null {
  if (buf.length < 6) return null;
  return {
    version: buf[0]!,
    type: buf[1]!,
    streamId: new DataView(buf.buffer, buf.byteOffset, buf.byteLength).getUint32(2),
    payload: buf.slice(6),
  };
}

export interface HostIdentityFile {
  seed: string; // b64
  daemonId: string;
}

export interface Device {
  deviceId: string;
  pub: string; // b64 raw Ed25519
  label: string;
  pairedAt: number;
  lastSeen?: number;
}

export function loadHostIdentity(path: string): { id: Identity; daemonId: string } {
  let f = readJson<HostIdentityFile | null>(path, null);
  if (!f) {
    const id = newIdentity();
    f = { seed: b64(id.seed), daemonId: "pa-" + newId() + newId() };
    writeJson(path, f);
  }
  return { id: newIdentity(unb64(f.seed)), daemonId: f.daemonId };
}

interface Stream {
  id: number;
  secure: Secure | null;
  deviceId?: string;
  clientId?: string;
}

export type RelayState = "disconnected" | "connecting" | "connected";

/** One APNs push the relay sends on our behalf (bento relay `push` control). */
export interface RelayPushRequest {
  token: string;
  env: string; // "sandbox" | "production"
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

export interface RelayPushResult {
  ok: boolean;
  status: number; // APNs HTTP status; 0 when APNs wasn't reached
  reason?: string;
}

const PUSH_TIMEOUT_MS = 8_000;

// RelayChannel keeps the daemon socket to the relay alive, handles pairing,
// and terminates E2E per stream. Each stream becomes one app client of the hub.
export class RelayChannel {
  private ws: WebSocket | null = null;
  private streams = new Map<number, Stream>();
  private backoff = 1000;
  private stopped = false;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private lastPong = 0;
  private pairWaiter: ((code: { code: string; ttl: number }) => void) | null = null;
  private pushWaiters = new Map<string, (r: RelayPushResult) => void>();
  private pairOpenUntil = 0;
  state: RelayState = "disconnected";
  lastError = "";

  constructor(
    private hub: Hub,
    private relayUrl: string,
    private identity: Identity,
    readonly daemonId: string,
    private devicesPath: string,
    private log: (s: string) => void = (s) => console.log(`[relay] ${s}`),
  ) {}

  devices(): Device[] {
    return readJson<Device[]>(this.devicesPath, []);
  }

  removeDevice(deviceId: string): boolean {
    const list = this.devices();
    const next = list.filter((d) => d.deviceId !== deviceId);
    writeJson(this.devicesPath, next);
    // Drop live streams of a revoked device.
    for (const s of this.streams.values()) if (s.deviceId === deviceId) this.closeStream(s.id);
    return next.length !== list.length;
  }

  async start(): Promise<void> {
    this.stopped = false;
    await this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.ws?.close();
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    this.state = "connecting";
    const base = this.relayUrl.replace(/\/$/, "");
    try {
      await fetch(`${base}/v1/daemon/register`, {
        method: "POST",
        headers: { "x-bento-daemon-id": this.daemonId },
        signal: AbortSignal.timeout(15_000),
      });
    } catch (e) {
      this.fail(`register failed: ${e}`);
      return;
    }
    const ts = Math.floor(Date.now() / 1000);
    const sig = sign(this.identity, `bento-daemon-register:${this.daemonId}:${ts}`);
    const wsUrl =
      base.replace(/^http/, "ws") +
      `/v1/daemon/socket?daemon_id=${encodeURIComponent(this.daemonId)}&ts=${ts}&pubkey=${b64url(this.identity.pub)}&sig=${b64url(sig)}&proto=1`;
    const ws = new WebSocket(wsUrl);
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    // After bento's daemon (relay/client.go, liveness.go): a dial that never
    // opens is retried, backoff resets only once a session has proven stable,
    // any inbound frame counts as liveness, and a socket replaced by another
    // host with the same identity backs off instead of fighting it.
    const dialTimer = setTimeout(() => {
      if (this.ws === ws && ws.readyState === WebSocket.CONNECTING) {
        this.log("dial timeout");
        ws.close();
      }
    }, 20_000);
    let stableTimer: ReturnType<typeof setTimeout> | null = null;
    ws.onopen = () => {
      clearTimeout(dialTimer);
      this.state = "connected";
      this.lastError = "";
      this.lastPong = Date.now();
      this.log(`connected as ${this.daemonId}`);
      stableTimer = setTimeout(() => (this.backoff = 1000), 60_000);
      this.pingTimer = setInterval(() => this.ping(), 30_000);
    };
    ws.onmessage = (ev) => {
      this.lastPong = Date.now();
      this.onMessage(new Uint8Array(ev.data as ArrayBuffer));
    };
    ws.onclose = (ev) => {
      clearTimeout(dialTimer);
      if (stableTimer) clearTimeout(stableTimer);
      if (this.ws !== ws) return; // a stale socket
      if (this.pingTimer) clearInterval(this.pingTimer);
      for (const id of [...this.streams.keys()]) this.dropStream(id);
      if (ev.code === 4002) this.lastError = "relay 不支持当前协议版本，请更新 paloally";
      if (ev.code === 4000) {
        this.lastError = "另一个 paloally 用同一个身份连上了 relay（同一份 ~/.paloally 跑了两份？）";
        this.backoff = 60_000;
      }
      this.fail(`closed ${ev.code} ${ev.reason}`);
    };
    ws.onerror = () => {
      /* onclose follows */
    };
  }

  private fail(why: string): void {
    this.state = "disconnected";
    if (!this.lastError) this.lastError = why;
    if (this.stopped) return;
    // ±25% jitter so hosts don't reconnect in lockstep after a relay blip.
    const delay = Math.round(this.backoff * (0.75 + Math.random() * 0.5));
    this.backoff = Math.min(this.backoff * 2, 60_000);
    this.log(`${why}; retry in ${delay}ms`);
    setTimeout(() => void this.connect(), delay);
  }

  private ping(): void {
    if (Date.now() - this.lastPong > 75_000) {
      this.log("pong timeout; reconnecting");
      this.ws?.close();
      return;
    }
    this.sendControl({ type: "ping", nonce: newId() });
  }

  private send(frame: Uint8Array): void {
    try {
      this.ws?.send(frame);
    } catch {
      /* closed */
    }
  }

  private sendControl(obj: unknown): void {
    this.send(buildFrame(T_CONTROL, 0, new TextEncoder().encode(JSON.stringify(obj))));
  }

  private onMessage(buf: Uint8Array): void {
    const f = parseFrame(buf);
    if (!f || f.version !== FRAME_VERSION) return;
    if (f.type === T_CONTROL && f.streamId === 0) return this.onControl(JSON.parse(new TextDecoder().decode(f.payload)));
    if (f.type === T_OPEN) {
      this.streams.set(f.streamId, { id: f.streamId, secure: null });
      return;
    }
    if (f.type === T_CLOSE) return this.dropStream(f.streamId);
    if (f.type === T_DATA) {
      let s = this.streams.get(f.streamId);
      if (!s) {
        s = { id: f.streamId, secure: null };
        this.streams.set(f.streamId, s);
      }
      this.onStreamData(s, f.payload);
    }
  }

  // ---- pairing ----

  // openPairing asks the relay for a 6-digit code and returns the link the
  // app scans.
  openPairing(ttlSec = 120): Promise<{ code: string; ttl: number; link: string }> {
    if (this.state !== "connected") return Promise.reject(new Error("还没连上中转服务器"));
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("中转服务器没回配对码")), 10_000);
      this.pairWaiter = ({ code, ttl }) => {
        clearTimeout(t);
        this.pairOpenUntil = Date.now() + ttl * 1000;
        const link = `paloally://pair?relay=${encodeURIComponent(this.relayUrl)}&daemon=${encodeURIComponent(this.daemonId)}&code=${code}&hostkey=${b64url(this.identity.pub)}`;
        resolve({ code, ttl, link });
      };
      this.sendControl({ type: "pair.open", ttl_sec: ttlSec });
    });
  }

  // ---- push ----

  // The relay holds the app's APNs key (it belongs to the developer, not to
  // any one user's host) and pushes for us. A relay without the feature
  // ignores the message, so the wait times out and the caller falls back.
  pushViaRelay(req: RelayPushRequest): Promise<RelayPushResult> {
    if (this.state !== "connected") return Promise.reject(new Error("relay not connected"));
    const nonce = newId();
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        this.pushWaiters.delete(nonce);
        reject(new Error("relay push timed out"));
      }, PUSH_TIMEOUT_MS);
      this.pushWaiters.set(nonce, (r) => {
        clearTimeout(t);
        resolve(r);
      });
      this.sendControl({ type: "push", nonce, ...req });
    });
  }

  private onControl(msg: any): void {
    if (msg.type === "pong") {
      this.lastPong = Date.now();
    } else if (msg.type === "push_result") {
      const done = this.pushWaiters.get(String(msg.nonce ?? ""));
      if (!done) return;
      this.pushWaiters.delete(String(msg.nonce));
      done({ ok: !!msg.ok, status: Number(msg.status ?? 0), ...(msg.reason ? { reason: String(msg.reason) } : {}) });
    } else if (msg.type === "pair.opened") {
      this.pairWaiter?.({ code: String(msg.code), ttl: Number(msg.ttl_sec ?? 60) });
      this.pairWaiter = null;
    } else if (msg.type === "pair.attach") {
      const reqId = msg.request_id;
      // Only accept attaches while a window we opened is live.
      if (Date.now() > this.pairOpenUntil) {
        this.sendControl({ type: "pair.ack", request_id: reqId, status: "error", error: "pairing not open" });
        return;
      }
      const pub = parseSshWirePubkey(String(msg.device_pubkey ?? ""));
      if (!pub) {
        this.sendControl({ type: "pair.ack", request_id: reqId, status: "error", error: "bad device pubkey" });
        return;
      }
      const device: Device = {
        deviceId: "dev-" + newId(),
        pub: b64(pub),
        label: String(msg.device_label ?? "").slice(0, 60) || "设备",
        pairedAt: Date.now(),
      };
      writeJson(this.devicesPath, [...this.devices(), device]);
      this.pairOpenUntil = 0; // one device per window
      this.hub.audit.log("device.paired", { deviceId: device.deviceId, label: device.label });
      this.sendControl({
        type: "pair.ack",
        request_id: reqId,
        status: "ok",
        device_id: device.deviceId,
        host_fingerprint: fingerprint(this.identity.pub),
        daemon_label: this.hub.config.hostName,
      });
    }
  }

  // ---- streams ----

  private onStreamData(s: Stream, unit: Uint8Array): void {
    if (!s.secure) {
      try {
        const hello = parseHandshake(unit);
        const r = hostAccept(hello, this.identity, (id) => {
          const d = this.devices().find((x) => x.deviceId === id);
          return d ? unb64(d.pub) : null;
        });
        s.secure = r.secure;
        s.deviceId = r.deviceId;
        s.clientId = `app_${s.id}_${r.deviceId}`;
        this.send(buildFrame(T_DATA, s.id, r.reply));
        this.hub.attach({ id: s.clientId, kind: "app", send: (m) => this.sendSealed(s, m) });
        this.touchDevice(r.deviceId);
      } catch (e) {
        const err = new TextEncoder().encode(JSON.stringify({ t: "error", error: String(e instanceof Error ? e.message : e) }));
        this.send(buildFrame(T_DATA, s.id, new Uint8Array([0x01, ...err])));
        this.closeStream(s.id);
      }
      return;
    }
    let req: any;
    try {
      req = JSON.parse(s.secure.opener.open(unit));
    } catch {
      // Decryption failure means tampering or desync: drop the stream.
      this.closeStream(s.id);
      return;
    }
    void serveRpc(this.hub, req, { clientId: s.clientId!, deviceId: s.deviceId, channel: "app", local: false }).then((res) => this.sendSealed(s, res));
  }

  private sendSealed(s: Stream, msg: unknown): void {
    if (!s.secure || !this.streams.has(s.id)) return;
    this.send(buildFrame(T_DATA, s.id, s.secure.sealer.seal(JSON.stringify(msg))));
  }

  private touchDevice(deviceId: string): void {
    const list = this.devices();
    const d = list.find((x) => x.deviceId === deviceId);
    if (d) {
      d.lastSeen = Date.now();
      writeJson(this.devicesPath, list);
    }
  }

  private closeStream(id: number): void {
    this.send(buildFrame(T_CLOSE, id));
    this.dropStream(id);
  }

  private dropStream(id: number): void {
    const s = this.streams.get(id);
    if (s?.clientId) this.hub.detach(s.clientId);
    this.streams.delete(id);
  }

  connectedStreams(): number {
    return [...this.streams.values()].filter((s) => s.secure).length;
  }
}
