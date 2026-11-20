// The app straight to the computer, without the relay (channels/localTunnel.ts):
// the same E2E handshake and RPC as through the relay, on a local WebSocket.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { LocalTunnel, directAddrs, isTailscaleV4 } from "../src/channels/localTunnel.ts";
import { RelayChannel, loadHostIdentity } from "../src/channels/relay.ts";
import { b64, newIdentity } from "../src/proto/e2e.ts";
import { writeJson } from "../src/util.ts";
import { AppClient, waitFor } from "./relayClient.ts";
import { cleanup, makeHub } from "./helpers.ts";

test("addresses: loopback first, then the local network, then Tailscale", () => {
  const iface = (address: string, internal = false) => ({ address, internal, family: "IPv4" as const, netmask: "", mac: "", cidr: null });
  const addrs = directAddrs({
    lo0: [iface("127.0.0.1", true)],
    utun4: [iface("100.101.102.103")],
    en0: [iface("192.168.1.20"), { ...iface("fe80::1"), family: "IPv6" as const, scopeid: 0 }],
    en5: [iface("169.254.3.4")],
  });
  expect(addrs).toEqual(["127.0.0.1", "192.168.1.20", "100.101.102.103"]);
  expect(isTailscaleV4("100.64.0.1")).toBe(true);
  expect(isTailscaleV4("100.127.255.1")).toBe(true);
  expect(isTailscaleV4("100.128.0.1")).toBe(false);
  expect(isTailscaleV4("10.0.0.1")).toBe(false);
});

describe("local tunnel", () => {
  const ctx = makeHub();
  let relay: RelayChannel;
  let tunnel: LocalTunnel;
  let daemonId: string;
  let hostPub: Uint8Array;
  const device = newIdentity();
  const deviceId = "dev-local1";
  let base: string;

  beforeAll(() => {
    const { id, daemonId: did } = loadHostIdentity(ctx.paths.identity);
    daemonId = did;
    hostPub = id.pub;
    // Never started: the relay socket isn't needed for a direct stream.
    relay = new RelayChannel(ctx.hub, "http://127.0.0.1:1", id, daemonId, ctx.paths.devices, () => {});
    writeJson(ctx.paths.devices, [{ deviceId, pub: b64(device.pub), label: "test-phone", pairedAt: Date.now() }]);
    tunnel = new LocalTunnel(relay, () => {});
    tunnel.start(47890, "127.0.0.1");
    base = `http://127.0.0.1:${tunnel.port}`;
    ctx.hub.directEndpoints = () => tunnel.endpoints();
  });

  afterAll(() => {
    tunnel.stop();
    cleanup(ctx.paths);
  });

  test("a paired device handshakes and calls the RPC; hello tells where to find the computer", async () => {
    const app = await AppClient.connect(base, daemonId, deviceId, device, hostPub);
    const hello = await app.call("hello", { client: "ios", version: "test" });
    expect(hello.hostName).toBe(ctx.hub.config.hostName);
    expect(hello.direct.port).toBe(tunnel.port);
    expect(hello.direct.addrs[0]).toBe("127.0.0.1");
    expect(relay.connectedStreams()).toBe(1);
    const sync = await app.call("sync", {});
    expect(typeof sync.seq).toBe("number");
    // Seen as an app client of the hub, i.e. the device is online.
    expect([...(ctx.hub as any).clients.keys()].some((k: string) => k.startsWith("app_l") && k.endsWith(deviceId))).toBe(true);
    app.close();
    await waitFor(() => relay.connectedStreams() === 0);
    expect([...(ctx.hub as any).clients.keys()].some((k: string) => k.startsWith("app_l"))).toBe(false);
  });

  test("an unpaired device is refused and closed", async () => {
    const stranger = newIdentity();
    await expect(AppClient.connect(base, daemonId, "dev-nobody", stranger, hostPub)).rejects.toThrow();
    await waitFor(() => relay.connectedStreams() === 0);
  });

  test("another computer's daemon id is turned away before the WebSocket opens", async () => {
    await expect(AppClient.connect(base, "pa-someoneelse", deviceId, device, hostPub)).rejects.toThrow();
    const r = await fetch(`${base}/v1/tunnel?daemon_id=pa-someoneelse&device_id=${deviceId}`);
    expect(r.status).toBe(404);
  });

  test("unpairing a device drops its direct stream", async () => {
    const app = await AppClient.connect(base, daemonId, deviceId, device, hostPub);
    await app.call("hello", {});
    relay.removeDevice(deviceId);
    await waitFor(() => app.closed);
    expect(relay.connectedStreams()).toBe(0);
  });

  test("a port that is taken moves on to the next one", () => {
    const other = new LocalTunnel(relay, () => {});
    try {
      expect(other.start(tunnel.port, "127.0.0.1")).toBe(tunnel.port + 1);
    } finally {
      other.stop();
    }
  });
});
