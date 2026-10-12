// An in-memory stand-in for the relay between Ally hosts: one pairing slot
// per daemon, pinned and revoked devices, and tunnels that check what the
// E2E handshake checks (the device is known to the host, the welcome comes
// from the expected host key). Lets the Allies logic run fast and
// deterministically; test/allies.relay.test.ts runs it over the real relay.
import { writeFileSync } from "node:fs";
import type { AllyRelay } from "../src/allies.ts";
import { type AllyConn, type AllyConnHandlers, type AllyTarget, PairError } from "../src/channels/allyLink.ts";
import type { RelayState } from "../src/channels/relay.ts";
import type { Config } from "../src/config.ts";
import { type Identity, b64, fingerprint, newIdentity } from "../src/proto/e2e.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { makeHub, testConfig, tick } from "./helpers.ts";

export const NET_URL = "https://relay.test";

export class NetHost implements AllyRelay {
  state: RelayState = "connected";
  readonly relayUrl = NET_URL;
  readonly identity: Identity = newIdentity();
  slot: { code: string; until: number } | null = null;
  lastCode: string | null = null;
  devices = new Map<string, string>(); // device id → pinned key (b64)
  revoked = new Set<string>();
  conns = new Set<{ deviceId: string; from: string; client: MemConn; server: MemConn }>();
  windows: { code: string; ttl: number }[] = [];
  keepCodes = true; // false: an old relay that mints its own code

  constructor(readonly net: AllyNet, readonly daemonId: string, readonly ctx: ReturnType<typeof makeHub>) {}

  get hub() {
    return this.ctx.hub;
  }

  async openAllyWindow(code: string, ttlSec: number) {
    const c = this.keepCodes ? code : String(Math.floor(Math.random() * 1e6)).padStart(6, "0");
    this.slot = { code: c, until: Date.now() + ttlSec * 1000 };
    this.lastCode = c;
    this.windows.push({ code: c, ttl: ttlSec });
    return { code: c, ttl: ttlSec };
  }

  windowCode() {
    return this.lastCode;
  }

  async revokeDevice(deviceId: string) {
    if (this.state !== "connected") return false;
    this.devices.delete(deviceId);
    this.revoked.add(deviceId);
    for (const c of [...this.conns]) if (c.deviceId === deviceId) c.client.close();
    return true;
  }

  /** The host goes down: its tunnels, in and out, drop and nothing reaches it. */
  goOffline(): void {
    this.state = "disconnected";
    for (const h of this.net.hosts.values()) for (const c of [...h.conns]) if (h === this || c.from === this.daemonId) c.client.close();
  }

  /** Back up: like RelayChannel on (re)connect. */
  goOnline(): void {
    this.state = "connected";
    this.hub.allies.onRelayConnected();
  }
}

// One end of an in-memory tunnel; units arrive on the next macrotask, like
// network messages.
export class MemConn implements AllyConn {
  peer!: MemConn;
  handlers!: AllyConnHandlers;
  private live = true;
  sent: unknown[] = [];

  get open() {
    return this.live;
  }

  send(msg: unknown): void {
    if (!this.live) return;
    this.sent.push(msg);
    const text = JSON.stringify(msg);
    setTimeout(() => this.peer.live && this.peer.handlers.message(text), 0);
  }

  /** Raw text, as a misbehaving peer would send it. */
  sendRaw(text: string): void {
    setTimeout(() => this.peer.live && this.peer.handlers.message(text), 0);
  }

  close(): void {
    if (!this.live) return;
    this.live = false;
    this.handlers.closed();
    this.peer.close();
  }
}

export class AllyNet {
  hosts = new Map<string, NetHost>();
  labels: string[] = []; // what the relay saw as device_label / daemon_label
  private n = 0;

  // add makes a hub on this net. `name` goes into user.md as the owner's 称呼.
  add(name: string, opts: { config?: (c: Config) => void; now?: () => number; script?: FakeScript } = {}): NetHost {
    const daemonId = `pa-test-${++this.n}`;
    let host: NetHost;
    const ctx = makeHub({
      script: opts.script,
      config: testConfig((c) => {
        c.settings.assistantName = `${name}的Palo`;
        opts.config?.(c);
      }),
      allies: { dial: (t, me, h) => this.dial(t, me, h), pair: (relay, id, req) => this.pair(relay, id, req), ...(opts.now ? { now: opts.now } : {}) },
    });
    writeFileSync(ctx.paths.userMd, `# 关于主人\n\n- 称呼：${name}\n`);
    host = new NetHost(this, daemonId, ctx);
    ctx.hub.allies.setRelay(host);
    this.hosts.set(daemonId, host);
    return host;
  }

  async pair(_relay: string, daemonId: string, req: { code: string; identity: Identity; label: string; kind: string }) {
    const h = this.hosts.get(daemonId);
    if (!h || h.state !== "connected") throw new PairError(503, "daemon offline");
    if (!h.slot || Date.now() > h.slot.until) throw new PairError(400, "no pairing window open");
    if (h.slot.code !== req.code) throw new PairError(401, "bad code");
    h.slot = null;
    if (req.kind !== "ally") throw new PairError(502, "not an ally");
    const r = h.hub.allies.onPairAttach(req.identity.pub);
    if ("error" in r) throw new PairError(502, r.error);
    h.devices.set(r.deviceId, b64(req.identity.pub));
    this.labels.push(req.label, r.label);
    return { device_id: r.deviceId, host_fingerprint: fingerprint(h.identity.pub), daemon_label: r.label };
  }

  async dial(t: AllyTarget, me: Identity, handlers: AllyConnHandlers): Promise<AllyConn> {
    await tick(0);
    const from = [...this.hosts.values()].find((x) => b64(x.identity.pub) === b64(me.pub));
    if (from && from.state !== "connected") throw new Error("we're offline");
    const h = this.hosts.get(t.daemonId);
    if (!h || h.state !== "connected") throw new Error("daemon offline"); // relay 503
    if (h.revoked.has(t.deviceId) || h.devices.get(t.deviceId) !== b64(me.pub)) throw new Error("device refused"); // relay 401
    if (!h.hub.allies.inboundKey(t.deviceId)) throw new Error("unknown device"); // host's handshake
    if (b64(t.hostKey) !== b64(h.identity.pub)) throw new Error("bad host signature"); // our check of the welcome
    const client = new MemConn();
    const server = new MemConn();
    client.peer = server;
    server.peer = client;
    client.handlers = handlers;
    const rec = { deviceId: t.deviceId, from: from?.daemonId ?? "", client, server };
    h.conns.add(rec);
    const inner = h.hub.allies.attachInbound(t.deviceId, server);
    server.handlers = {
      message: inner.message,
      closed: () => {
        h.conns.delete(rec);
        inner.closed();
      },
    };
    return client;
  }
}

/** Pairs b into a's invite (b's owner scans a's QR code). */
export async function befriend(a: NetHost, b: NetHost, kind: "family" | "mine" = "family") {
  const { link } = await a.hub.allies.invite();
  const ally = await b.hub.allies.accept(link, kind);
  await tick(5);
  return { link, ally };
}
