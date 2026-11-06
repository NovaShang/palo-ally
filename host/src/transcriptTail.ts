import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import { getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import type { RawSessionMessage } from "./ccSessions.ts";

/**
 * A conversation's messages from the end of its Claude Code transcript,
 * without parsing the whole file: a transcript with many pictures in it
 * grows to hundreds of MB, and `getSessionMessages` parsed all of it for
 * every page, 20 s each (11-06: pages came up empty, and the host, busy,
 * lost the relay again and again).
 *
 * The last `bytes` of the file are handed to `getSessionMessages` as its
 * session store, so the conversation is put together by the SDK's own rules
 * (the chain from the latest message, compaction, parallel tool results);
 * only what lies before the window is missing. `complete`: the window is
 * the whole file.
 */
export async function readTranscriptTail(path: string, sessionId: string, cwd: string, bytes: number):
  Promise<{ messages: RawSessionMessage[]; complete: boolean }> {
  const fd = openSync(path, "r");
  let text: string;
  let complete: boolean;
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - bytes);
    const buf = Buffer.alloc(size - start);
    let read = 0;
    while (read < buf.length) {
      const n = readSync(fd, buf, read, buf.length - read, start + read);
      if (n <= 0) break;
      read += n;
    }
    text = buf.subarray(0, read).toString("utf8");
    complete = start === 0;
    // A window that starts mid-line drops that partial line.
    if (!complete) text = text.slice(text.indexOf("\n") + 1);
  } finally {
    closeSync(fd);
  }
  const entries: any[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line));
    } catch {
      /* a line being written */
    }
  }
  const store = { load: async () => entries, append: async () => {} };
  const messages = (await getSessionMessages(sessionId, { dir: cwd, sessionStore: store as any })) as RawSessionMessage[];
  return { messages, complete };
}

/** The first window read: plenty for a page of most conversations. */
export const TAIL_FIRST_BYTES = 4 << 20;

/**
 * A page of a conversation (`page` over the converted messages) read from
 * the transcript's end, the window growing fourfold until the page has all
 * it should: `limit` messages before `before` with room to spare (the
 * window's first messages may be cut), or the whole file read.
 */
export async function pageFromTail<T extends { id: string; ts: number }>(
  path: string, sessionId: string, cwd: string,
  convert: (raw: RawSessionMessage[]) => T[],
  page: (all: T[]) => T[],
  before: string | number | undefined, limit: number,
): Promise<T[]> {
  for (let bytes = TAIL_FIRST_BYTES; ; bytes *= 4) {
    const { messages, complete } = await readTranscriptTail(path, sessionId, cwd, bytes);
    const all = convert(messages);
    if (complete) return page(all);
    let end = all.length;
    if (typeof before === "string" && before) end = all.findIndex((m) => m.id === before);
    else if (typeof before === "number" && Number.isFinite(before)) {
      end = all.findIndex((m) => m.ts >= before);
      if (end < 0) end = all.length;
    }
    if (end > limit) return page(all);
  }
}
