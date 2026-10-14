import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type StallTarget, StallWatch, WATCHDOG_DEFAULTS, growth, parseApiSockets, transcriptHas } from "../src/stallWatch.ts";

function setup(over: Partial<StallTarget> & { sockets?: { total: number; established: number } } = {}) {
  let now = 1_000_000;
  const dir = mkdtempSync(join(tmpdir(), "stall-"));
  const transcript = join(dir, "s.jsonl");
  writeFileSync(transcript, "{}\n");
  const notes: string[] = [];
  const audit: string[] = [];
  let recovers = 0;
  const target: StallTarget = {
    key: "pal_1",
    name: "网站",
    busy: () => true,
    waiting: () => false,
    openTools: () => [],
    lastActivity: () => 0,
    pid: () => 4242,
    transcript: () => transcript,
    recover: async () => {
      recovers++;
      return { resent: 1, continued: false };
    },
    ...over,
  };
  const w = new StallWatch({
    targets: () => [target],
    config: () => WATCHDOG_DEFAULTS,
    notify: (t) => notes.push(t),
    audit: (type) => audit.push(type),
    sockets: async () => over.sockets ?? null,
    now: () => now,
    log: () => {},
  });
  return {
    w,
    transcript,
    notes,
    audit,
    recovers: () => recovers,
    advance: (min: number) => (now += min * 60_000),
  };
}

describe("stall watchdog", () => {
  test("a busy session with no progress for 10 minutes is restarted once and the owner told", async () => {
    const s = setup();
    await s.w.tick(); // starts watching
    s.advance(9);
    await s.w.tick();
    expect(s.recovers()).toBe(0);
    s.advance(2);
    await s.w.tick();
    expect(s.recovers()).toBe(1);
    expect(s.audit).toEqual(["stall.detected", "stall.restarted"]);
    expect(s.notes[0]).toContain("已经自动重启并续上");
  });

  test("transcript growth counts as progress", async () => {
    const s = setup();
    await s.w.tick();
    for (let i = 0; i < 4; i++) {
      s.advance(4);
      appendFileSync(s.transcript, `{"n":${i}}\n`);
      await s.w.tick();
    }
    expect(s.recovers()).toBe(0);
  });

  test("a long tool call gets the longer limit; waiting on the owner and idle sessions are never touched", async () => {
    const tool = setup({ openTools: () => ["Bash"] });
    await tool.w.tick();
    tool.advance(30);
    await tool.w.tick();
    expect(tool.recovers()).toBe(0);
    tool.advance(31);
    await tool.w.tick();
    expect(tool.recovers()).toBe(1);

    const waiting = setup({ waiting: () => true });
    await waiting.w.tick();
    waiting.advance(120);
    await waiting.w.tick();
    expect(waiting.recovers()).toBe(0);

    const idle = setup({ busy: () => false });
    await idle.w.tick();
    idle.advance(120);
    await idle.w.tick();
    expect(idle.recovers()).toBe(0);
  });

  test("every API socket closed mid-turn restarts it after 5 minutes instead of 10", async () => {
    const s = setup({ sockets: { total: 3, established: 0 } });
    await s.w.tick();
    s.advance(4);
    await s.w.tick();
    expect(s.recovers()).toBe(0);
    s.advance(1.5);
    await s.w.tick();
    expect(s.recovers()).toBe(1);
  });

  test("at most 3 restarts an hour, then the owner is told once instead", async () => {
    const s = setup();
    for (let i = 0; i < 5; i++) {
      await s.w.tick();
      s.advance(11);
      await s.w.tick();
    }
    expect(s.recovers()).toBe(3);
    expect(s.audit.filter((a) => a === "stall.gave_up").length).toBe(1);
    expect(s.notes.at(-1)).toContain("这次先不重启");
  });

  test("helpers: socket parsing, transcript signature, taken messages", () => {
    const out = [
      "claude 1 nova 20u IPv4 TCP 10.0.0.2:5000->160.79.104.10:443 (CLOSED)",
      "claude 1 nova 21u IPv4 TCP 10.0.0.2:5001->160.79.104.10:443 (ESTABLISHED)",
      "claude 1 nova 22u IPv4 TCP 127.0.0.1:5002->127.0.0.1:8080 (ESTABLISHED)",
    ].join("\n");
    expect(parseApiSockets(out)).toEqual({ total: 2, established: 1 });
    const s = setup();
    const before = growth(s.transcript);
    appendFileSync(s.transcript, `{"uuid":"abc-123"}\n`);
    expect(growth(s.transcript)).not.toBe(before);
    expect(transcriptHas(s.transcript, "abc-123")).toBe(true);
    expect(transcriptHas(s.transcript, "zzz")).toBe(false);
  });
});
