import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { join } from "node:path";
import { stripTldrMarker } from "../../tldr.ts";
import { truncate } from "../../util.ts";

// Reading Claude Code's transcripts (<config>/projects/<cwd>/<session>.jsonl):
// their tail and head, a summary of the last words, and what its user entries mean.


export function firstLine(s: string): string {
  const line =
    stripTldrMarker(s)
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l && !/^```/.test(l)) ?? "";
  return truncate(line.replace(/^[#>*\-\s]+/, "").replace(/\*\*/g, ""), 120);
}

// ---- a transcript's tail and head ----

export function readTail(path: string, maxBytes = 256 * 1024): any[] {
  if (!existsSync(path)) return [];
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - maxBytes);
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    const lines = buf.toString("utf8").split("\n");
    if (start > 0) lines.shift(); // a partial first line
    const out: any[] = [];
    for (const l of lines) {
      if (!l.trim()) continue;
      try {
        out.push(JSON.parse(l));
      } catch {
        // a line still being written
      }
    }
    return out;
  } finally {
    closeSync(fd);
  }
}

/** The entries in a transcript's first `maxBytes`. */
export function readHead(path: string, maxBytes = 256 * 1024): any[] {
  if (!existsSync(path)) return [];
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(Math.min(maxBytes, fstatSync(fd).size));
    readSync(fd, buf, 0, buf.length, 0);
    const lines = buf.toString("utf8").split("\n");
    if (buf.length === maxBytes) lines.pop(); // a partial last line
    const out: any[] = [];
    for (const l of lines) {
      if (!l.trim()) continue;
      try {
        out.push(JSON.parse(l));
      } catch {
        // a line still being written
      }
    }
    return out;
  } finally {
    closeSync(fd);
  }
}

export interface TranscriptSummary {
  lastLine?: string;
  lastLineAt?: number;
  contextTokens?: number;
}

/** The session's last words and its context size, from transcript entries. */
export function summarizeTranscript(entries: any[]): TranscriptSummary {
  const out: TranscriptSummary = {};
  for (const e of entries) {
    if (e?.isSidechain || e?.type !== "assistant") continue;
    const m = e.message;
    const at = Date.parse(e.timestamp ?? "") || undefined;
    for (const b of Array.isArray(m?.content) ? m.content : []) {
      if (b?.type === "text" && typeof b.text === "string" && b.text.trim()) {
        out.lastLine = firstLine(b.text);
        out.lastLineAt = at;
      }
    }
    const u = m?.usage;
    if (u && m?.model !== "<synthetic>") {
      const t = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      if (t > 0) out.contextTokens = t;
    }
  }
  return out;
}

// ---- transcript entries (what palHistory.ts reads them with) ----

/** Claude Code's summary after compacting, by its opening words. */
export function isCompactSummaryText(text: string): boolean {
  return text.trimStart().startsWith("This session is being continued from a previous conversation");
}

export interface RawSessionMessage {
  type: string;
  uuid: string;
  message?: any;
  timestamp?: string;
  origin?: any;
  parent_tool_use_id?: string | null;
}

// A peer message's own words: the SDK keeps them as `origin.body`; older
// entries only have them inside the <cross-session-message> wrapper.
export function peerBody(origin: any, content: string): string {
  if (typeof origin?.body === "string") return origin.body;
  const m = /<cross-session-message[^>]*>\n?([\s\S]*?)\n?<\/cross-session-message>/.exec(content);
  let body = m?.[1] ?? content;
  const inner = /<\\?agent-message[^>]*>\n?([\s\S]*?)\n?<\\?\/agent-message>/.exec(body);
  if (inner) body = inner[1]!;
  return body.trim();
}

/** A user entry's text; null for a tool result. */
export function userText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  if (content.some((b: any) => b?.type === "tool_result")) return null;
  const t = content
    .filter((b: any) => b?.type === "text" && typeof b.text === "string")
    .map((b: any) => b.text)
    .join("\n");
  return t || null;
}

// ---- the stall watchdog's signs (stallWatch.ts) ----

/** How much its transcript and its subagents' transcripts have grown (a signature, compared tick to tick). */
export function growth(transcript: string | undefined): string {
  if (!transcript) return "";
  let main = "-";
  try {
    const st = statSync(transcript);
    main = `${st.size}:${Math.round(st.mtimeMs)}`;
  } catch {
    /* none yet */
  }
  let sub = 0;
  const dir = join(transcript.replace(/\.jsonl$/, ""), "subagents");
  try {
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".jsonl")) continue;
      try {
        sub += statSync(join(dir, f)).size;
      } catch {
        /* gone */
      }
    }
  } catch {
    /* no subagents */
  }
  return `${main}|${sub}`;
}

/** Whether the transcript (its last `maxBytes`) mentions this message uuid: the session took that message. */
export function transcriptHas(path: string | undefined, uuid: string, maxBytes = 8 * 1024 * 1024): boolean {
  if (!path || !existsSync(path)) return false;
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - maxBytes);
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    return buf.toString("utf8").includes(uuid);
  } finally {
    closeSync(fd);
  }
}
