import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pageFromTail, readTranscriptTail, TAIL_FIRST_BYTES } from "../src/harness/claude/tail.ts";

const SID = "11111111-2222-4333-8444-555555555555";
const uid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

/** A transcript: `old` messages before a compaction (none: 0), each with a `pad`-byte picture a tool gave, then `fresh` after. */
function transcript(old: number, fresh: number, pad: number): { dir: string; path: string } {
  const lines: string[] = [];
  let parent: string | null = null;
  let n = 0;
  const add = (e: any) => {
    const uuid = uid(++n);
    lines.push(JSON.stringify({ uuid, parentUuid: parent, sessionId: SID, isSidechain: false, cwd: "/tmp", version: "2.1.0",
      timestamp: new Date(1_790_000_000_000 + n * 1000).toISOString(), ...e }));
    parent = uuid;
  };
  const say = (text: string) => add({ type: "user", message: { role: "user", content: text } });
  for (let i = 0; i < old; i++) {
    say(`old ${i}`);
    add({ type: "assistant", message: { role: "assistant", id: `m${i}`, content: [{ type: "tool_use", id: `t${i}`, name: "Read", input: {} }] } });
    add({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: `t${i}`,
      content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: "A".repeat(pad) } }] }] } });
  }
  if (old > 0 && fresh > 0) {
    parent = null;
    add({ type: "system", subtype: "compact_boundary", content: "Conversation compacted", isMeta: false, compactMetadata: { trigger: "auto", preTokens: 1 } });
    say("This session is being continued from a previous conversation that ran out of context.");
  }
  for (let i = 0; i < fresh; i++) say(`new ${i}`);
  const dir = mkdtempSync(join(tmpdir(), "tail-"));
  const path = join(dir, `${SID}.jsonl`);
  writeFileSync(path, lines.join("\n") + "\n");
  return { dir, path };
}

const convert = (raw: any[]) => raw.map((m) => ({ id: m.uuid as string, ts: Date.parse(m.timestamp ?? "") || 0, text: typeof m.message?.content === "string" ? m.message.content : "" }));

async function page(path: string, before?: string, limit = 100) {
  const windows: number[] = [];
  const all = await pageFromTail(path, SID, "/tmp", convert, (a) => a, before, limit, (p, s, c, bytes) => {
    windows.push(bytes);
    return readTranscriptTail(p, s, c, bytes);
  });
  return { all, windows };
}

test("a session just compacted: its few messages, not the whole file read for a page's worth", async () => {
  const { dir, path } = transcript(80, 3, 1 << 20); // 80 MB before the compaction
  try {
    const { all, windows } = await page(path);
    expect(all.filter((m) => m.text.startsWith("new ")).map((m) => m.text)).toEqual(["new 0", "new 1", "new 2"]);
    expect(all.some((m) => m.text.startsWith("old "))).toBe(false);
    expect(windows).toEqual([TAIL_FIRST_BYTES, TAIL_FIRST_BYTES * 4]);
    // Before its oldest, or before a message from before the compaction: the same.
    expect((await page(path, all[0]!.id)).windows.length).toBe(2);
    expect((await page(path, uid(1))).windows.length).toBe(2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("without a compaction the window still grows to what was asked for", async () => {
  const { dir, path } = transcript(60, 0, 1 << 18); // 15 MB
  try {
    const { all, windows } = await page(path, undefined, 170);
    expect(all.filter((m) => m.text.startsWith("old ")).length).toBe(60);
    expect(windows.at(-1)).toBeGreaterThanOrEqual(TAIL_FIRST_BYTES * 4);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("pictures tools gave aren't kept", async () => {
  const { dir, path } = transcript(2, 0, 1 << 20);
  try {
    const { messages } = await readTranscriptTail(path, SID, "/tmp", 64 << 20);
    expect(JSON.stringify(messages).length).toBeLessThan(20_000);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("pages asked for at once are read one at a time", async () => {
  const { dir, path } = transcript(2, 3, 100);
  let now = 0;
  let most = 0;
  try {
    await Promise.all(Array.from({ length: 6 }, () => pageFromTail(path, SID, "/tmp", convert, (a) => a, undefined, 100, async (p, s, c, b) => {
      most = Math.max(most, ++now);
      await Bun.sleep(5);
      try {
        return await readTranscriptTail(p, s, c, b);
      } finally {
        now--;
      }
    })));
    expect(most).toBe(1);
    // One that fails doesn't hold up the next.
    await expect(pageFromTail(path, SID, "/tmp", convert, (a) => a, undefined, 100, async () => { throw new Error("no"); })).rejects.toThrow("no");
    expect((await page(path)).all.length).toBeGreaterThan(0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
