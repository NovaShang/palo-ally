// The parts the assistant's runtime and an agent's share (batch 7, step 11).
import { describe, expect, test } from "bun:test";
import { StreamAssembler } from "../src/agent/streamAssembler.ts";
import { TurnLedger } from "../src/agent/turnLedger.ts";

describe("TurnLedger", () => {
  test("adds, consumes in the order asked, expires, and splits what the harness took after a stall", () => {
    const l = new TurnLedger<{ text: string; at: number }>();
    l.add("a", { text: "一", at: 1 });
    l.add("b", { text: "二", at: 2 });
    l.add("c", { text: "三", at: 3 });
    expect(l.size).toBe(3);
    expect(l.uuids()).toEqual(["a", "b", "c"]);
    expect(l.consume(["c", "x", "a"]).map((p) => p.text)).toEqual(["三", "一"]);
    expect(l.uuids()).toEqual(["b"]);
    l.add("d", { text: "四", at: 4 });
    l.expire((_u, p) => p.at < 3);
    expect(l.uuids()).toEqual(["d"]);
    l.add("e", { text: "五", at: 5 });
    const s = l.split((u) => u === "d");
    expect(s.taken.map(([u]) => u)).toEqual(["d"]);
    expect(s.untaken.map(([u]) => u)).toEqual(["e"]);
    l.clear();
    expect(l.size).toBe(0);
  });
});

describe("StreamAssembler", () => {
  test("the reply so far for a reconnect; taking it closes it with what it had", () => {
    const s = new StreamAssembler();
    expect(s.current()).toBeNull();
    expect(s.take()).toBeNull();
    s.open("m1");
    expect(s.current()).toBeNull(); // nothing written yet
    s.append("你");
    s.append("好");
    expect(s.current()).toEqual({ id: "m1", text: "你好" });
    expect(s.take()).toEqual({ id: "m1", text: "你好" });
    expect(s.id).toBeNull();
    expect(s.current()).toBeNull();
  });
});
