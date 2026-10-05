// Integration against the real bento relay (Cloudflare Worker), run locally:
//   cd ~/code/bento/relay && npx wrangler dev --port 8789
// Override with RELAY_URL. Skipped when no relay is reachable.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { RelayChannel, buildFrame, loadHostIdentity, parseFrame } from "../src/channels/relay.ts";
import { newIdentity } from "../src/proto/e2e.ts";
import { AppClient, pairDevice, parsePairLink, waitFor } from "./relayClient.ts";
import { cleanup, makeHub } from "./helpers.ts";

const RELAY = process.env.RELAY_URL ?? "http://127.0.0.1:8789";
const up = await fetch(`${RELAY}/healthz`).then((r) => r.ok).catch(() => false);
const d = up ? describe : describe.skip;

test("frame codec", () => {
  const f = parseFrame(buildFrame(0x02, 0xdeadbeef, new Uint8Array([1, 2, 3])))!;
  expect(f).toEqual({ version: 1, type: 2, streamId: 0xdeadbeef, payload: new Uint8Array([1, 2, 3]) });
  expect(parseFrame(new Uint8Array([1, 2]))).toBeNull();
});

d(`relay integration (${RELAY})`, () => {
  const ctx = makeHub();
  let relay: RelayChannel;
  let daemonId: string;
  let hostPub: Uint8Array;

  beforeAll(async () => {
    const { id, daemonId: did } = loadHostIdentity(ctx.paths.identity);
    daemonId = did;
    hostPub = id.pub;
    relay = new RelayChannel(ctx.hub, RELAY, id, daemonId, ctx.paths.devices, () => {});
    await relay.start();
    await waitFor(() => relay.state === "connected");
  });

  afterAll(() => {
    relay.stop();
    cleanup(ctx.paths);
  });

  test("pairing rejects attaches when no window is open, then pairs with the code", async () => {
    const p = await relay.openPairing(60);
    const link = parsePairLink(p.link);
    expect(link.daemon).toBe(daemonId);
    expect(Buffer.from(link.hostkey).equals(Buffer.from(hostPub))).toBe(true);
    const bad = await pairDevice(RELAY, daemonId, p.code === "000000" ? "111111" : "000000");
    expect(bad.status).toBe(401);
    const ok = await pairDevice(RELAY, daemonId, p.code, "Nova 的 iPhone");
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe("ok");
    expect(ok.body.daemon_label).toBe(ctx.hub.config.hostName);
    expect(relay.devices().map((x) => x.label)).toEqual(["Nova 的 iPhone"]);
    // one device per window: the slot is burned
    const again = await pairDevice(RELAY, daemonId, p.code);
    expect(again.status).toBe(400);
  });

  test("E2E tunnel: RPC, chat streaming events, revoke", async () => {
    const p = await relay.openPairing(60);
    const paired = await pairDevice(RELAY, daemonId, p.code);
    const deviceId = paired.body.device_id;
    const app = await AppClient.connect(RELAY, daemonId, deviceId, paired.device, hostPub);

    const hello = await app.call("hello", { client: "ios", version: "test" });
    expect(hello.hostName).toBe(ctx.hub.config.hostName);
    const sent = await app.call("chat.send", { text: "从手机来的", clientMsgId: "local-1" });
    expect(sent.seq).toBeGreaterThan(0);
    await waitFor(() => app.events.some((e) => e.event === "chat.message" && e.data.role === "assistant"));
    expect(app.events.some((e) => e.event === "chat.delta")).toBe(true);
    const sync = await app.call("sync", { sinceSeq: 0 });
    expect(sync.messages.map((m: any) => m.text)).toContain("收到：从手机来的");
    expect(sync.messages.find((m: any) => m.role === "user").channel).toBe("app");
    expect(app.events.find((e) => e.event === "chat.message" && e.data.role === "user")!.data.clientMsgId).toBe("local-1");

    // admin methods are not reachable from the relay
    await expect(app.call("pair.open")).rejects.toThrow("unknown method");

    // two devices at once both get events
    const p2 = await relay.openPairing(60);
    const second = await pairDevice(RELAY, daemonId, p2.code, "iPad");
    const app2 = await AppClient.connect(RELAY, daemonId, second.body.device_id, second.device, hostPub);
    await app2.call("hello");
    ctx.hub.userMessage("from cli", "cli");
    await waitFor(() => app2.events.some((e) => e.event === "chat.message" && e.data.text === "from cli"));
    expect(relay.connectedStreams()).toBe(2);

    // revoke the first device: its stream is closed
    relay.removeDevice(deviceId);
    await waitFor(() => app.closed);
    expect(relay.connectedStreams()).toBe(1);
    app2.close();
  });

  test("a device key that doesn't match pairing is refused", async () => {
    const p = await relay.openPairing(60);
    const paired = await pairDevice(RELAY, daemonId, p.code);
    // relay pins the device key: a different key for the same device id is 401
    await expect(AppClient.connect(RELAY, daemonId, paired.body.device_id, newIdentity(), hostPub)).rejects.toThrow();
    // a forged host key on the client side fails the handshake
    await expect(AppClient.connect(RELAY, daemonId, paired.body.device_id, paired.device, newIdentity().pub)).rejects.toThrow("bad host signature");
  });

  // Needs a relay with the `push` control (bento relay-push). A local relay has
  // no APNs secrets, so a paired daemon gets NotConfigured; one without paired
  // devices is refused before APNs is ever involved.
  test("push via the relay: refused without a paired device, NotConfigured without secrets", async () => {
    const lone = makeHub();
    const { id, daemonId: loneId } = loadHostIdentity(lone.paths.identity);
    const other = new RelayChannel(lone.hub, RELAY, id, loneId, lone.paths.devices, () => {});
    await other.start();
    await waitFor(() => other.state === "connected");
    const req = { token: "ab".repeat(32), env: "sandbox", title: "PaloAlly", body: "test" };
    expect(await other.pushViaRelay(req)).toEqual({ ok: false, status: 0, reason: "NoPairedDevice" });
    other.stop();
    cleanup(lone.paths);
    // `relay` paired devices in the tests above
    expect(await relay.pushViaRelay(req)).toEqual({ ok: false, status: 0, reason: "NotConfigured" });
    expect(await relay.pushViaRelay({ ...req, token: "nothex" })).toMatchObject({ ok: false, status: 400 });
  });
});
