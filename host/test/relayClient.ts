// A minimal app-side client (what the iOS app does), used by integration tests.
import { b64url, clientHello, newIdentity, parseHandshake, sign, sshWirePubkey, type Identity, type Secure, unb64url } from "../src/proto/e2e.ts";

export async function pairDevice(relay: string, daemonId: string, code: string, label = "test-phone") {
  const device = newIdentity();
  const r = await fetch(`${relay}/v1/pair?daemon_id=${encodeURIComponent(daemonId)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, device_pubkey: sshWirePubkey(device.pub), device_label: label }),
  });
  const body: any = await r.json();
  return { status: r.status, body, device };
}

export function parsePairLink(link: string) {
  const u = new URL(link);
  return {
    relay: u.searchParams.get("relay")!,
    daemon: u.searchParams.get("daemon")!,
    code: u.searchParams.get("code")!,
    hostkey: unb64url(u.searchParams.get("hostkey")!),
  };
}

export class AppClient {
  private ws!: WebSocket;
  private secure: Secure | null = null;
  private nextId = 1;
  private pending = new Map<number, (m: any) => void>();
  events: { event: string; data: any }[] = [];
  closed = false;
  closeCode = 0;

  static async connect(relay: string, daemonId: string, deviceId: string, device: Identity, hostPub: Uint8Array): Promise<AppClient> {
    const c = new AppClient();
    const ts = Math.floor(Date.now() / 1000);
    const sig = sign(device, `bento-device-attach:${daemonId}:${deviceId}:${ts}`);
    const url =
      relay.replace(/^http/, "ws") +
      `/v1/tunnel?daemon_id=${encodeURIComponent(daemonId)}&device_id=${encodeURIComponent(deviceId)}&ts=${ts}&pubkey=${b64url(device.pub)}&sig=${b64url(sig)}`;
    c.ws = new WebSocket(url);
    c.ws.binaryType = "arraybuffer";
    const hello = clientHello(device, deviceId);
    await new Promise<void>((resolve, reject) => {
      c.ws.onopen = () => c.ws.send(hello.unit);
      c.ws.onerror = () => reject(new Error("ws error"));
      c.ws.onclose = (e) => {
        c.closed = true;
        c.closeCode = e.code;
        reject(new Error(`closed ${e.code}`));
      };
      c.ws.onmessage = (ev) => {
        const unit = new Uint8Array(ev.data as ArrayBuffer);
        if (!c.secure) {
          try {
            c.secure = hello.finish(parseHandshake(unit), hostPub);
            resolve();
          } catch (e) {
            reject(e);
          }
          return;
        }
        const msg = JSON.parse(c.secure.opener.open(unit));
        if (msg.event) c.events.push(msg);
        else c.pending.get(msg.id)?.(msg);
      };
    });
    c.ws.onclose = (e) => {
      c.closed = true;
      c.closeCode = e.code;
    };
    return c;
  }

  call(method: string, params: unknown = {}): Promise<any> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timeout ${method}`)), 10_000);
      this.pending.set(id, (m) => {
        clearTimeout(t);
        if (m.error) reject(new Error(m.error.message));
        else resolve(m.result);
      });
      this.ws.send(this.secure!.sealer.seal(JSON.stringify({ id, method, params })));
    });
  }

  close() {
    this.ws.close();
  }
}

export async function waitFor(cond: () => boolean, ms = 10_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > ms) throw new Error("waitFor timeout");
    await new Promise((r) => setTimeout(r, 25));
  }
}
