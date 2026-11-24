import { afterAll, describe, expect, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, openSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { CHUNK_BYTES, SpendMeter, eachLine, usageUsd } from "../src/harness/claude/spend.ts";
import { transcriptPath } from "../src/harness/claude/paths.ts";
import { ownerText, readTranscript } from "../src/harness/claude/rewind.ts";

const dir = mkdtempSync(join(tmpdir(), "spend-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const usage = (out: number) => ({ input_tokens: 10, output_tokens: out });
const entry = (id: string, at: string, out: number, text = "x") =>
  JSON.stringify({ type: "assistant", uuid: `${id}-${out}`, timestamp: at, message: { id, model: "claude-opus-5-5", usage: usage(out), content: [{ type: "text", text }] } }) + "\n";
const picture = (bytes: number, at = "2026-11-20T10:00:00.000Z") =>
  JSON.stringify({ type: "user", timestamp: at, message: { content: [{ type: "image", source: { type: "base64", data: "A".repeat(bytes) } }] } }) + "\n";
const usd = (out: number) => usageUsd("claude-opus-5-5", usage(out));
function transcript(name: string, text: string): string {
  const p = transcriptPath(dir, "/w", name);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
  return p;
}

describe("a transcript read a piece at a time", () => {
  test("every line comes whole, over the edge of a piece, with words of more than one byte", () => {
    const lines = Array.from({ length: 40 }, (_, i) => `${i} ${"字".repeat(CHUNK_BYTES / 30 + i)}`);
    const p = join(dir, "lines");
    writeFileSync(p, lines.join("\n") + "\nlast");
    const left = { partial: [] as Buffer[], partialBytes: 0 };
    const got: string[] = [];
    const fd = openSync(p, "r");
    eachLine(fd, 0, left, (l) => got.push(l.toString("utf8")));
    expect(got).toEqual(lines);
    expect(Buffer.concat(left.partial).toString("utf8")).toBe("last");
  });

  test("a line over the limit is skipped, the next ones aren't", () => {
    const p = join(dir, "long");
    writeFileSync(p, `a\n${"b".repeat(CHUNK_BYTES * 2 + 10)}\nc\n`);
    const got: string[] = [];
    eachLine(openSync(p, "r"), 0, { partial: [], partialBytes: 0 }, (l) => got.push(l.toString()), CHUNK_BYTES);
    expect(got).toEqual(["a", "c"]);
  });
});

describe("what a session spent on a day", () => {
  test("the last usage of each message counts; what's appended is added, a line not whole yet included once it is", () => {
    const p = transcript("s1", entry("m1", "2026-11-23T10:00:00.000Z", 5) + entry("m2", "2026-11-24T10:00:00.000Z", 5) + entry("m2", "2026-11-24T10:00:01.000Z", 9));
    const m = new SpendMeter(dir);
    expect(m.spentOn("/w", "s1", "2026-11-24", "UTC")).toBeCloseTo(usd(9), 9);
    const more = entry("m3", "2026-11-24T11:00:00.000Z", 20);
    appendFileSync(p, more.slice(0, 30));
    expect(m.spentOn("/w", "s1", "2026-11-24", "UTC")).toBeCloseTo(usd(9), 9);
    appendFileSync(p, more.slice(30));
    expect(m.spentOn("/w", "s1", "2026-11-24", "UTC")).toBeCloseTo(usd(9) + usd(20), 9);
    // an earlier day, the whole of it here
    expect(m.spentOn("/w", "s1", "2026-11-23", "UTC")).toBeCloseTo(usd(5), 9);
  });

  test("a long one is read from its end back to before the day, and for an earlier day again", () => {
    let text = entry("old", "2026-11-19T10:00:00.000Z", 50);
    for (let i = 0; i < 5; i++) text += picture(CHUNK_BYTES - 2000);
    text += entry("m1", "2026-11-24T00:30:00.000Z", 7);
    for (let i = 0; i < 3; i++) text += picture(CHUNK_BYTES, "2026-11-24T01:00:00.000Z");
    text += entry("m2", "2026-11-24T02:00:00.000Z", 8);
    transcript("s2", text);
    const m = new SpendMeter(dir);
    expect(m.spentOn("/w", "s2", "2026-11-24", "UTC")).toBeCloseTo(usd(7) + usd(8), 9);
    expect(m.spentOn("/w", "s2", "2026-11-19", "UTC")).toBeCloseTo(usd(50), 9);
    expect(m.spentOn("/w", "s2", "2026-11-24", "UTC")).toBeCloseTo(usd(7) + usd(8), 9);
  });

  test("rewritten shorter: read anew; gone: nothing", () => {
    const p = transcript("s3", entry("m1", "2026-11-24T10:00:00.000Z", 5) + entry("m2", "2026-11-24T10:00:00.000Z", 6));
    const m = new SpendMeter(dir);
    m.spentOn("/w", "s3", "2026-11-24", "UTC");
    writeFileSync(p, entry("m9", "2026-11-24T10:00:00.000Z", 3));
    expect(m.spentOn("/w", "s3", "2026-11-24", "UTC")).toBeCloseTo(usd(3), 9);
    expect(m.spentOn("/w", "none", "2026-11-24", "UTC")).toBe(0);
  });
});

test("a rewind's entries come without the pictures in them, the rest as it is", () => {
  const p = join(dir, "r.jsonl");
  const said = { type: "user", uuid: "u1", message: { content: [{ type: "text", text: "看这张" }, { type: "image", source: { type: "base64", data: "A".repeat(9000) } }] } };
  const tool = { type: "user", uuid: "u2", toolUseResult: { file: "B".repeat(9000) }, message: { content: [{ type: "tool_result", content: [{ type: "image", source: { data: "C".repeat(9000) } }] }] } };
  writeFileSync(p, [said, tool].map((x) => JSON.stringify(x)).join("\n") + '\n{"type":"assist');
  const got = readTranscript(p);
  expect(got.map((e) => e.uuid)).toEqual(["u1", "u2"]);
  expect(ownerText(got[0])).toBe("看这张");
  expect(ownerText(got[1])).toBeNull();
  expect(JSON.stringify(got).length).toBeLessThan(1000);
  expect(readTranscript(p, ['"u2"']).map((e) => e.uuid)).toEqual(["u2"]);
});
