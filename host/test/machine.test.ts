import { describe, expect, test } from "bun:test";
import { computeMachineId, machineHash, machineId, normalizedHostName, platformUUID } from "../src/machine.ts";

describe("machine identity", () => {
  test("reads the hardware UUID out of ioreg's output", () => {
    const out = `+-o J316sAP  <class IOPlatformExpertDevice>\n    {\n      "IOPlatformSerialNumber" = "X"\n      "IOPlatformUUID" = "0a1b2c3d-1111-2222-3333-444455556666"\n    }`;
    expect(platformUUID(() => out)).toBe("0A1B2C3D-1111-2222-3333-444455556666");
    expect(platformUUID(() => "")).toBeUndefined();
  });

  test("the hash is the app's: 32 hex characters of SHA-256 over the prefixed id", () => {
    // The same value MachineIdentityTests checks on the Swift side.
    expect(machineHash("00000000-0000-0000-0000-000000000000")).toBe("ad6f26fe10e6f1f161f28bae8901efe4");
    expect(machineHash("A")).toMatch(/^[0-9a-f]{32}$/);
    expect(machineHash("A")).not.toBe(machineHash("B"));
  });

  test("a UUID wins; without one the computer's name, normalized", () => {
    expect(computeMachineId({ uuid: () => "ABC", name: () => "whatever" })).toBe(machineHash("ABC"));
    expect(computeMachineId({ uuid: () => undefined, linuxId: () => "f00d" })).toBe(machineHash("linux:f00d"));
    expect(normalizedHostName(" Home-Mac.local ")).toBe("home-mac");
    expect(computeMachineId({ uuid: () => undefined, linuxId: () => "", name: () => "Home-Mac.local" })).toBe(machineHash("host:home-mac"));
  });

  test("this machine's, stable across calls", () => {
    expect(machineId()).toMatch(/^[0-9a-f]{32}$/);
    expect(machineId()).toBe(machineId());
  });
});
