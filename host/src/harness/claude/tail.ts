import { closeSync, fstatSync, openSync } from "node:fs";
import { getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { withoutPictures } from "./rewind.ts";
import { eachLine } from "./spend.ts";
import type { RawSessionMessage } from "./transcript.ts";

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
  Promise<{ messages: RawSessionMessage[]; complete: boolean; compacted: boolean }> {
  const fd = openSync(path, "r");
  const entries: any[] = [];
  let complete: boolean;
  let compacted = false;
  try {
    const start = Math.max(0, fstatSync(fd).size - bytes);
    complete = start === 0;
    // Read a piece at a time, and each entry kept without the pictures and
    // tool results in it, which a conversation's messages aren't made of: a
    // whole transcript of 468 MB as one string and all its entries was 3.6 GB.
    const left = { partial: [] as Buffer[], partialBytes: 0 };
    // A window that starts mid-line drops that partial line.
    let skip = !complete;
    const take = (line: Buffer) => {
      if (skip) {
        skip = false;
        return;
      }
      if (!line.length) return;
      let e: any;
      try {
        e = JSON.parse(line.toString("utf8"));
      } catch {
        return; // a line being written
      }
      if (e?.type === "system" && e.subtype === "compact_boundary" && !e.isSidechain) compacted = true;
      entries.push(withoutPictures(e));
    };
    eachLine(fd, start, left, take, Infinity);
    // The last line, when it has no end yet.
    if (left.partialBytes) take(Buffer.concat(left.partial));
  } finally {
    closeSync(fd);
  }
  const store = { load: async () => entries, append: async () => {} };
  const messages = (await getSessionMessages(sessionId, { dir: cwd, sessionStore: store as any })) as RawSessionMessage[];
  return { messages, complete, compacted };
}

/** The first window read: plenty for a page of most conversations. */
export const TAIL_FIRST_BYTES = 4 << 20;

/**
 * A page of a conversation (`page` over the converted messages) read from
 * the transcript's end, the window growing fourfold until the page has all
 * it should: `limit` messages before `before` with room to spare (the
 * window's first messages may be cut), or the whole file read. Past a
 * compaction there is nothing to find: the chain starts at it, and a larger
 * window that brings no more messages is the last one. (A session just
 * compacted has fewer messages than a page: each look at it read the whole
 * file, stalling the host until every app reconnected and asked again: 41 GB
 * and the host gone, 11-24.)
 */
export function pageFromTail<T extends { id: string; ts: number }>(
  path: string, sessionId: string, cwd: string,
  convert: (raw: RawSessionMessage[]) => T[],
  page: (all: T[]) => T[],
  before: string | number | undefined, limit: number,
  read = readTranscriptTail,
): Promise<T[]> {
  // One at a time: several apps asking at once don't add up in memory.
  const mine = reading.then(() => growing(path, sessionId, cwd, convert, page, before, limit, read));
  reading = mine.catch(() => {});
  return mine;
}

let reading: Promise<unknown> = Promise.resolve();

async function growing<T extends { id: string; ts: number }>(
  path: string, sessionId: string, cwd: string,
  convert: (raw: RawSessionMessage[]) => T[],
  page: (all: T[]) => T[],
  before: string | number | undefined, limit: number,
  read: typeof readTranscriptTail,
): Promise<T[]> {
  let last = -1;
  for (let bytes = TAIL_FIRST_BYTES; ; bytes *= 4) {
    const { messages, complete, compacted } = await read(path, sessionId, cwd, bytes);
    const all = convert(messages);
    if (complete || (compacted && messages.length === last)) return page(all);
    last = messages.length;
    let end = all.length;
    if (typeof before === "string" && before) end = all.findIndex((m) => m.id === before);
    else if (typeof before === "number" && Number.isFinite(before)) {
      end = all.findIndex((m) => m.ts >= before);
      if (end < 0) end = all.length;
    }
    if (end > limit) return page(all);
  }
}
