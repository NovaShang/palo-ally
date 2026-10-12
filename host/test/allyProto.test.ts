// The host-to-host messages of an Ally stream and the invite link
// (docs/allies-prd.md §7.3, §7.6). Allies itself: allies.test.ts.
import { describe, expect, test } from "bun:test";
import { ALLY_LIMITS, allowedRelay, allyInviteLink, parseAllyInvite, parseAllyWire, validSlots } from "../src/proto/ally.ts";
import { b64url, newIdentity } from "../src/proto/e2e.ts";

describe("ally protocol", () => {
  test("only the four messages parse; RPC calls and anything malformed don't", () => {
    expect(parseAllyWire(JSON.stringify({ type: "ally.hello", name: "家人", assistantName: "Palo", kind: "family", version: "1" }))).toMatchObject({ type: "ally.hello" });
    expect(parseAllyWire(JSON.stringify({ type: "ally.message", id: "ae_1", text: "hi", urgent: true, ts: 1 }))).toMatchObject({ urgent: true });
    expect(parseAllyWire(JSON.stringify({ type: "ally.receipt", id: "ae_1", state: "seen" }))).toMatchObject({ state: "seen" });
    expect(parseAllyWire(JSON.stringify({ type: "ally.bye" }))).toEqual({ type: "ally.bye" });
    for (const bad of [
      { id: 1, method: "chat.send", params: { text: "x" } },
      { id: 2, method: "sync", params: {} },
      { type: "ally.message", id: "../etc", text: "x", ts: 1 },
      { type: "ally.message", id: "a", text: 5, ts: 1 },
      { type: "ally.receipt", id: "a", state: "read" },
      { type: "ally.hello", name: "x", assistantName: "y", kind: "boss", version: "1" },
      { type: "ally.hello", name: "x", assistantName: "y", kind: "mine", version: "1", relay: "http://evil.example" },
      { type: "ally.exec", cmd: "ls" },
    ]) {
      expect(parseAllyWire(JSON.stringify(bad))).toBeNull();
    }
    expect(parseAllyWire("not json")).toBeNull();
    expect(parseAllyWire(JSON.stringify({ type: "ally.message", id: "a", text: "x".repeat(ALLY_LIMITS.unitBytes), ts: 1 }))).toBeNull();
  });

  test("slots need a time zone and an end after the start", () => {
    expect(validSlots([{ start: "2026-10-17T14:00:00+08:00", end: "2026-10-17T16:00:00+08:00" }])).toHaveLength(1);
    expect(validSlots([{ start: "2026-10-17T14:00:00", end: "2026-10-17T16:00:00" }])).toBeNull();
    expect(validSlots([{ start: "2026-10-17T16:00:00Z", end: "2026-10-17T14:00:00Z" }])).toBeNull();
    expect(validSlots(Array(6).fill({ start: "2026-10-17T14:00:00Z", end: "2026-10-17T15:00:00Z" }))).toBeNull();
  });

  test("invite link round trip; relays only https or this machine", () => {
    const hostKey = newIdentity().pub;
    const link = allyInviteLink({ relay: "https://relay.bentoai.dev", daemonId: "pa-1", code: "123456", hostKey, name: "家人 A", exp: 99 });
    expect(link.startsWith("paloally://ally?")).toBe(true);
    const back = parseAllyInvite(link);
    expect(back).toMatchObject({ relay: "https://relay.bentoai.dev", daemonId: "pa-1", code: "123456", name: "家人 A", exp: 99 });
    expect(Buffer.from(back.hostKey).equals(Buffer.from(hostKey))).toBe(true);
    expect(() => parseAllyInvite("paloally://pair?relay=x")).toThrow("不是 Ally 邀请");
    expect(() => parseAllyInvite(link.replace("code=123456", "code=12"))).toThrow("不完整");
    expect(() => parseAllyInvite(`paloally://ally?relay=http%3A%2F%2Fevil.example&daemon=pa-1&code=123456&hostkey=${b64url(hostKey)}`)).toThrow("不完整");
    expect(allowedRelay("http://127.0.0.1:8789")).toBe(true);
    expect(allowedRelay("http://10.0.0.1")).toBe(false);
    expect(allowedRelay("https://user:pw@relay.example")).toBe(false);
  });
});
