// The parts the assistant's runtime and an agent's share (batch 7, step 11).
import { describe, expect, test } from "bun:test";
import { StreamAssembler } from "../src/agent/streamAssembler.ts";
import { TurnLedger } from "../src/agent/turnLedger.ts";
import { RecordTasks } from "../src/agent/taskProjection.ts";
import { TranscriptSink } from "../src/agent/outputSink.ts";

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

describe("RecordTasks", () => {
  test("an agent's subagents and background tasks: shown while they run, kept with its record when they end, all stopped with its process", () => {
    const rec: { pastTasks?: import("../src/agent/taskProjection.ts").PastPalTask[] } = {};
    let saves = 0;
    const t = new RecordTasks(rec, { save: () => saves++, now: () => 1000 });
    expect(t.onEvent({ type: "task_started", taskId: "a", toolUseId: "tu_a", description: "查资料", taskType: "local_agent" })).toBe(true);
    expect(t.onEvent({ type: "task_started", taskId: "b", description: "npm test", taskType: "local_bash" })).toBe(true);
    expect(t.wire().map((x) => x.id)).toEqual(["a"]); // a foreground command isn't a task
    expect(t.onEvent({ type: "task_backgrounded", taskId: "b" })).toBe(true);
    expect(t.background).toBe(1);
    expect(t.onEvent({ type: "task_progress", taskId: "a", summary: "读到第 3 页" })).toBe(true);
    expect(t.onEvent({ type: "task_progress", taskId: "a", summary: "读到第 3 页" })).toBe(false);
    t.onEvent({ type: "tool_result", toolUseId: "tu_a", content: "", isError: false, parentToolUseId: null });
    expect(rec.pastTasks?.map((p) => `${p.id}:${p.status}:${p.summary}`)).toEqual(["a:done:读到第 3 页"]);
    t.processEnded();
    expect(t.background).toBe(0);
    expect(rec.pastTasks?.map((p) => `${p.id}:${p.status}`)).toEqual(["b:stopped", "a:done"]);
    expect(saves).toBe(2);
  });
});

describe("OutputSink", () => {
  test("the assistant's goes into its chat log; an agent's goes out as events with its id", () => {
    const events: { event: string; data: any }[] = [];
    const sink = new TranscriptSink("pal_1", { emit: (event, data) => events.push({ event, data }), now: () => 5 });
    sink.delta("m1", "你");
    const m = sink.message({ id: "m1", role: "assistant", kind: "text", text: "你好" });
    expect(m).toEqual({ seq: 5, ts: 5, channel: "app", id: "m1", role: "assistant", kind: "text", text: "你好", pal: "pal_1" });
    expect(events.map((e) => e.event)).toEqual(["chat.delta", "chat.message"]);
    expect(events[0]!.data).toEqual({ id: "m1", text: "你", pal: "pal_1" });
  });
});
