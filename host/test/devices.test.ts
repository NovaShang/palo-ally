// The owner's devices paired with this computer (docs/devices-prd.md):
// device.list and device.remove for the owner's own apps.
import { describe, expect, test } from "bun:test";
import { handleRpc } from "../src/rpc.ts";
import { makeHub } from "./helpers.ts";

function setup() {
  const t = makeHub();
  const paired = [
    { deviceId: "dev-phone", label: "iPhone", pairedAt: 1, lastSeen: 10 },
    { deviceId: "dev-mac", label: "Mac", pairedAt: 2, lastSeen: 20 },
    { deviceId: "dev-pad", label: "iPad", pairedAt: 3 },
  ];
  const removed: string[] = [];
  t.hub.devices = {
    list: () => paired.filter((d) => !removed.includes(d.deviceId)),
    remove: (id) => (removed.push(id), true),
  };
  const as = (deviceId?: string, local = false) => (method: string, params: unknown = {}) =>
    handleRpc(t.hub, { method, params }, { clientId: deviceId ? `app_3_${deviceId}` : "cli", ...(deviceId ? { deviceId } : {}), channel: deviceId ? "app" : "cli", local }) as Promise<any>;
  return { ...t, removed, as };
}

describe("the owner's devices", () => {
  test("device.list: every paired device, the asking one first and marked, each with the platform its app said and when it was last here; online while connected", async () => {
    const t = setup();
    const phone = t.as("dev-phone");
    await phone("hello", { client: "ios", version: "1" });
    await t.as("dev-mac")("hello", { client: "mac", version: "1" });
    t.hub.attach({ id: "app_7_dev-mac", kind: "app", send: () => {} } as any);
    const { devices } = await phone("device.list");
    expect(devices.map((d: any) => [d.deviceId, d.current, d.platform ?? null, d.online])).toEqual([
      ["dev-phone", true, "ios", false],
      ["dev-mac", false, "mac", true],
      ["dev-pad", false, null, false],
    ]);
    expect(devices[1].lastSeen).toBeGreaterThan(20);
    expect(devices[2].lastSeen).toBeUndefined();
    t.hub.detach("app_7_dev-mac");
  });

  test("device.remove: another device is unpaired and audited; never the asking one (that's device.unpair), nor one that isn't there", async () => {
    const t = setup();
    const phone = t.as("dev-phone");
    expect(await phone("device.remove", { deviceId: "dev-pad" })).toEqual({ ok: true });
    expect(t.removed).toEqual(["dev-pad"]);
    expect(t.hub.audit.tail(5).find((e) => e.type === "device.removed")).toMatchObject({ deviceId: "dev-pad", label: "iPad", by: "dev-phone" });
    await expect(phone("device.remove", { deviceId: "dev-phone" })).rejects.toThrow("解除配对");
    await expect(phone("device.remove", { deviceId: "dev-pad" })).rejects.toThrow("没有这台设备");
    expect(t.removed).toEqual(["dev-pad"]);
    expect((await phone("device.list")).devices.map((d: any) => d.deviceId)).toEqual(["dev-phone", "dev-mac"]);
  });

  test("only the owner's own devices and the local CLI: a connection without a device can't list or remove", async () => {
    const t = setup();
    const stranger = (method: string, params: unknown = {}) => handleRpc(t.hub, { method, params }, { clientId: "x", channel: "app", local: false });
    await expect(stranger("device.list")).rejects.toThrow("主人自己的设备");
    await expect(stranger("device.remove", { deviceId: "dev-mac" })).rejects.toThrow("主人自己的设备");
    expect(t.removed).toEqual([]);
    expect((await t.as(undefined, true)("device.list")).devices).toHaveLength(3);
  });

  test("no relay: nothing paired to list, and removing says so", async () => {
    const t = makeHub();
    const phone = (method: string, params: unknown = {}) => handleRpc(t.hub, { method, params }, { clientId: "app_1_dev-phone", deviceId: "dev-phone", channel: "app", local: false }) as Promise<any>;
    expect(await phone("device.list")).toEqual({ devices: [] });
    await expect(phone("device.remove", { deviceId: "dev-mac" })).rejects.toThrow("远程连接");
  });
});
