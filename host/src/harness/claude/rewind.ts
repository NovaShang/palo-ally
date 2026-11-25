import { closeSync, existsSync, openSync } from "node:fs";
import { eachLine } from "./spend.ts";

// 回到这里重来 (docs/rewind-prd.md): what is read in a Claude Code transcript to
// take a conversation back to just before one of the owner's messages.

/**
 * The transcript's entries, in the order written. Only lines naming one of
 * `only` are parsed when given (a long transcript: just the user entries).
 * Read a piece at a time and without the pictures in it: a transcript with
 * many is hundreds of MB, and what a rewind looks at isn't in them.
 */
export function readTranscript(path: string | undefined, only?: string[]): any[] {
  if (!path || !existsSync(path)) return [];
  const out: any[] = [];
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return [];
  }
  const left = { partial: [] as Buffer[], partialBytes: 0 };
  const take = (line: Buffer) => {
    if (!line.length || (only && !only.some((s) => line.includes(s)))) return;
    try {
      out.push(withoutPictures(JSON.parse(line.toString("utf8"))));
    } catch {
      /* a torn last line */
    }
  };
  try {
    eachLine(fd, 0, left, take, Infinity);
    // The last line, when it has no end yet.
    if (left.partialBytes) take(Buffer.concat(left.partial));
  } catch {
    return out;
  } finally {
    closeSync(fd);
  }
  return out;
}

/** Long data in it (a picture's, what a tool gave, thinking) left out; the entry else as it is. */
export function withoutPictures(e: any): any {
  const cut = (c: any) => {
    if (!Array.isArray(c)) return;
    for (const b of c) {
      if (typeof b?.source?.data === "string" && b.source.data.length > 2000) b.source.data = "";
      if (b?.type === "tool_result") {
        if (typeof b.content === "string" && b.content.length > 2000) b.content = "";
        else cut(b.content);
      }
      if (b?.type === "thinking") b.thinking = b.signature = "";
      if (b?.type === "text" && typeof b.text === "string" && b.text.length > 200_000) b.text = "";
    }
  };
  cut(e?.message?.content);
  if (e?.toolUseResult) e.toolUseResult = {};
  return e;
}

/** The words of a user entry the owner (or the host for them) typed; null for anything else. */
export function ownerText(e: any): string | null {
  if (e?.type !== "user" || e.isSidechain || e.isMeta || e.isCompactSummary || e.toolUseResult !== undefined) return null;
  if (e.origin && e.origin.kind !== "human") return null;
  const c = e.message?.content;
  if (typeof c === "string") return c;
  if (!Array.isArray(c) || c.some((b: any) => b?.type === "tool_result")) return null;
  const t = c
    .filter((b: any) => b?.type === "text" && typeof b.text === "string")
    .map((b: any) => b.text)
    .join("\n");
  return t || null;
}

/**
 * The entry for the message the host sent under `uuid`: Claude Code writes
 * it under that uuid; one it took in mid-turn may only be an attachment
 * naming it as its source.
 */
export function findEntry(entries: any[], uuid: string): any | undefined {
  return entries.find((e) => e?.uuid === uuid) ?? entries.find((e) => e?.attachment?.source_uuid === uuid && typeof e.uuid === "string");
}

/**
 * The owner's entry with these words, written nearest to `ts` (within 30
 * minutes), skipping those already matched (`used`): for messages kept
 * before their uuid was (docs/rewind-prd.md §4.2).
 */
export function matchOwnerEntry(entries: any[], text: string, ts: number, used: Set<string> = new Set()): any | undefined {
  const want = text.trim();
  if (!want) return undefined;
  let best: any;
  let bestGap = 30 * 60_000;
  for (const e of entries) {
    if (typeof e?.uuid !== "string" || used.has(e.uuid)) continue;
    const t = ownerText(e);
    if (t === null || t.trim() !== want) continue;
    const gap = Math.abs((Date.parse(e.timestamp ?? "") || 0) - ts);
    if (gap <= bestGap) {
      best = e;
      bestGap = gap;
    }
  }
  return best;
}

/** Claude Code kept the files as they were right before this message (file checkpointing was on). */
export function hasFileCheckpoint(entries: any[], uuid: string): boolean {
  return entries.some((e) => e?.type === "file-history-snapshot" && (e.messageId === uuid || e.snapshot?.messageId === uuid));
}

/**
 * The conversation as Claude Code would load it resuming at `at`: from the
 * first entry to `at`, following each entry's parent (across a compaction,
 * the entry it summed up). Oldest first.
 */
export function chainTo(entries: any[], at: string | null): any[] {
  if (!at) return [];
  const byId = new Map<string, any>();
  for (const e of entries) if (typeof e?.uuid === "string") byId.set(e.uuid, e);
  const out: any[] = [];
  const seen = new Set<string>();
  for (let e = byId.get(at); e && !seen.has(e.uuid); ) {
    seen.add(e.uuid);
    out.push(e);
    const up = e.parentUuid ?? e.logicalParentUuid;
    e = typeof up === "string" ? byId.get(up) : undefined;
  }
  return out.reverse();
}

/** The last entry of the session's conversation (where a resume picks up). */
export function leafOf(entries: any[]): string | null {
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (typeof e?.uuid === "string" && !e.isSidechain && ["user", "assistant", "system", "attachment"].includes(e.type)) return e.uuid;
  }
  return null;
}

/**
 * Claude Code resumes a session from its last compaction on, so a fork point
 * before that can't be resumed at (resumeSessionAt: "No message found").
 * Such a rewind copies the conversation up to that point into a new session
 * with the SDK's forkSession instead (2026-10-16, live test).
 */
export function beforeCompaction(chain: any[], at: string | null): boolean {
  if (!at) return false;
  const i = chain.findIndex((e) => e.uuid === at);
  let last = -1;
  chain.forEach((e, j) => {
    if (e?.type === "system" && e.subtype === "compact_boundary") last = j;
  });
  return last >= 0 && i >= 0 && i < last;
}

/** The SDK's forkSession: a copy of the session up to one entry, as a new session (new uuids). */
export type ForkSession = (sessionId: string, o: { dir: string; upToMessageId: string; title?: string }) => Promise<{ sessionId: string }>;

/** A session forkSession copied: each copied entry's new uuid, by the uuid it had. */
export function forkedUuids(entries: any[]): Map<string, string> {
  const out = new Map<string, string>();
  for (const e of entries) {
    const from = e?.forkedFrom?.messageUuid;
    if (typeof from === "string" && typeof e.uuid === "string") out.set(from, e.uuid);
  }
  return out;
}
