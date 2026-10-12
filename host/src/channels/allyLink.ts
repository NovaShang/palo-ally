import { b64url, clientHello, parseHandshake, sign, sshWirePubkey, type Identity, type Secure } from "../proto/e2e.ts";

// The client role on another host's daemon (docs/allies-prd.md §7.1): pair
// with its relay and open an E2E tunnel to it, the way the app reaches its
// own host. A host uses its own host key as the device key, the same one its
// phone pairs against.

/** One live Ally connection, in either direction. */
export interface AllyConn {
  send(msg: unknown): void;
  close(): void;
  readonly open: boolean;
}

export interface AllyConnHandlers {
  message(text: string): void; // one unit's plaintext
  closed(): void;
}

export interface AllyTarget {
  relay: string;
  daemonId: string;
  deviceId: string; // ours, on their daemon
  hostKey: Uint8Array; // theirs: the welcome must be signed with it
}

export interface PairAck {
  device_id: string;
  host_fingerprint?: string;
  daemon_label?: string;
}

/** A refused /v1/pair, with the relay's status (401 bad code, 503 offline, …). */
export class PairError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export type DialFn = (t: AllyTarget, me: Identity, h: AllyConnHandlers) => Promise<AllyConn>;
export type PairFn = (relay: string, daemonId: string, req: { code: string; identity: Identity; label: string; kind: string }) => Promise<PairAck>;

// pairAsClient submits a pairing code to another daemon's relay.
export const pairAsClient: PairFn = async (relay, daemonId, req) => {
  const r = await fetch(`${relay.replace(/\/$/, "")}/v1/pair?daemon_id=${encodeURIComponent(daemonId)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: req.code, device_pubkey: sshWirePubkey(req.identity.pub), device_label: req.label, device_kind: req.kind }),
    signal: AbortSignal.timeout(20_000),
  });
  const body: any = await r.json().catch(() => ({}));
  if (r.status !== 200 || body?.status !== "ok" || typeof body.device_id !== "string") {
    throw new PairError(r.status, String(body?.error ?? `pair failed (${r.status})`));
  }
  return body as PairAck;
};

// dialAlly opens the tunnel and runs the handshake; the host key from the
// invite (or the hello) must have signed the welcome. Resolves once sealed
// messages can flow. A daemon that's offline (relay 503), a revoked device
// (401) or a forged host all end up as a rejection here.
export const dialAlly: DialFn = (t, me, h) => {
  const ts = Math.floor(Date.now() / 1000);
  const sig = sign(me, `bento-device-attach:${t.daemonId}:${t.deviceId}:${ts}`);
  const url =
    t.relay.replace(/\/$/, "").replace(/^http/, "ws") +
    `/v1/tunnel?daemon_id=${encodeURIComponent(t.daemonId)}&device_id=${encodeURIComponent(t.deviceId)}&ts=${ts}&pubkey=${b64url(me.pub)}&sig=${b64url(sig)}`;
  return new Promise<AllyConn>((resolve, reject) => {
    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch (e) {
      reject(e);
      return;
    }
    ws.binaryType = "arraybuffer";
    const hello = clientHello(me, t.deviceId);
    let secure: Secure | null = null;
    let settled = false; // resolved or rejected
    let notified = false; // h.closed() called
    let open = true;
    const conn: AllyConn = {
      send(msg) {
        if (!open || !secure) return;
        try {
          ws.send(secure.sealer.seal(JSON.stringify(msg)));
        } catch {
          /* closed */
        }
      },
      close() {
        open = false;
        try {
          ws.close();
        } catch {
          /* already */
        }
      },
      get open() {
        return open && ws.readyState === WebSocket.OPEN;
      },
    };
    const fail = (e: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      conn.close();
      reject(e);
    };
    const timer = setTimeout(() => fail(new Error("连接对方超时")), 15_000);
    ws.onopen = () => ws.send(hello.unit);
    ws.onerror = () => fail(new Error("连不上对方"));
    ws.onclose = () => {
      open = false;
      if (!secure) return fail(new Error("连不上对方"));
      if (!notified) {
        notified = true;
        h.closed();
      }
    };
    ws.onmessage = (ev) => {
      const unit = new Uint8Array(ev.data as ArrayBuffer);
      if (!secure) {
        try {
          secure = hello.finish(parseHandshake(unit), t.hostKey);
        } catch (e) {
          fail(e instanceof Error ? e : new Error(String(e)));
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(conn);
        return;
      }
      let text: string;
      try {
        text = secure.opener.open(unit);
      } catch {
        // tampering or desync: drop the connection
        conn.close();
        return;
      }
      h.message(text);
    };
  });
};
