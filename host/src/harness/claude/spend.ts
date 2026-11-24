import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync } from "node:fs";
import { join } from "node:path";
import { transcriptPath } from "./paths.ts";
import { zonedParts } from "../../util.ts";

// What a Claude Code session spends per day, from its transcript (the
// usage Claude Code records with each reply). A Pal the assistant opened has
// a daily limit (docs/pals-prd.md §6); the host stops it past that.

// US dollars per million tokens: input, output; cache writes are 1.25× input
// (5 minutes) or 2× (1 hour); cache reads 0.1× input unless listed.
interface Price {
  input: number;
  output: number;
  cacheRead?: number;
}

const PRICES: [RegExp, Price][] = [
  [/fable-5-1|mythos-5-1/, { input: 10, output: 50, cacheRead: 0.25 }],
  [/fable|mythos/, { input: 10, output: 50 }],
  [/opus-5-5/, { input: 4, output: 20, cacheRead: 0.2 }],
  [/opus-(5|4-[5-9])/, { input: 5, output: 25 }],
  [/opus/, { input: 15, output: 75 }],
  [/sonnet-5/, { input: 2, output: 10 }],
  [/sonnet/, { input: 3, output: 15 }],
  [/haiku-4/, { input: 1, output: 5 }],
  [/haiku/, { input: 0.8, output: 4 }],
];

export function priceOf(model: string): Price {
  for (const [re, p] of PRICES) if (re.test(model)) return p;
  return { input: 5, output: 25 }; // unknown: priced like the current Opus
}

export function usageUsd(model: string, u: any): number {
  if (!u || typeof u !== "object") return 0;
  const p = priceOf(model);
  const cc = u.cache_creation && typeof u.cache_creation === "object" ? u.cache_creation : null;
  const write1h = cc ? Number(cc.ephemeral_1h_input_tokens ?? 0) : 0;
  const write5m = cc ? Number(cc.ephemeral_5m_input_tokens ?? 0) : Number(u.cache_creation_input_tokens ?? 0);
  const tokens =
    Number(u.input_tokens ?? 0) * p.input +
    Number(u.output_tokens ?? 0) * p.output +
    write5m * p.input * 1.25 +
    write1h * p.input * 2 +
    Number(u.cache_read_input_tokens ?? 0) * (p.cacheRead ?? p.input * 0.1);
  return tokens / 1e6;
}

/** What is read at a time: a transcript with many pictures in it is hundreds of MB, and is never held whole (11-24: 4.8 GB kept). */
export const CHUNK_BYTES = 4 << 20;
/** A line longer than this (pictures in it) isn't put together: it has no usage. */
const LINE_MAX = 16 << 20;

interface FileCursor {
  offset: number;
  /** The first day it holds all of (what came before wasn't read); undefined: all of it was. */
  since?: string;
  byDay: Record<string, number>;
  // One API message is written as several entries (one per content block),
  // each with the usage so far: the last one counts.
  seen: Map<string, { day: string; usd: number }>;
  /** The start of a line whose end isn't there yet. */
  partial: Buffer[];
  partialBytes: number;
}

/**
 * Every whole line from `offset` on, a chunk at a time (never the whole
 * file); a line over `lineMax` is skipped. `partial`: the start of a line
 * left by an earlier read, taken up and left again.
 */
export function eachLine(fd: number, offset: number, partial: { partial: Buffer[]; partialBytes: number }, each: (line: Buffer) => void, lineMax = LINE_MAX): number {
  const size = fstatSync(fd).size;
  const chunk = Buffer.allocUnsafe(Math.min(CHUNK_BYTES, Math.max(1, size - offset)));
  while (offset < size) {
    const n = readSync(fd, chunk, 0, Math.min(chunk.length, size - offset), offset);
    if (n <= 0) break;
    offset += n;
    let from = 0;
    for (let nl = chunk.indexOf(10, from); nl !== -1 && nl < n; nl = chunk.indexOf(10, from)) {
      const end = chunk.subarray(from, nl);
      if (partial.partialBytes === 0) each(end);
      else if (partial.partialBytes + end.length <= lineMax) each(Buffer.concat([...partial.partial, end]));
      partial.partial = [];
      partial.partialBytes = 0;
      from = nl + 1;
    }
    if (from < n) {
      partial.partialBytes += n - from;
      // (copied: the chunk is read into again)
      if (partial.partialBytes <= lineMax) partial.partial.push(Buffer.from(chunk.subarray(from, n)));
      else partial.partial = [];
    }
  }
  return offset;
}

/** Where a transcript's last `bytes` start that still reach back before `day` (0: the whole file). */
function startBefore(fd: number, day: string, tz: string): number {
  const size = fstatSync(fd).size;
  const buf = Buffer.allocUnsafe(Math.min(CHUNK_BYTES, size));
  for (let end = size; end > 0; ) {
    const start = Math.max(0, end - buf.length);
    const n = readSync(fd, buf, 0, end - start, start);
    // The first entry with a time in this part.
    const m = /"timestamp":"([^"]{10,40})"/.exec(buf.subarray(0, n).toString("latin1"));
    const at = m ? Date.parse(m[1]!) : NaN;
    if (at && zonedParts(at, tz).dateKey < day) return start;
    end = start;
  }
  return 0;
}

// SpendMeter adds up a session's spending per day from its transcripts (and
// its subagents'), reading only what was appended since the last look; the
// first time, from the end back to before the day asked for.
export class SpendMeter {
  private files = new Map<string, FileCursor>();

  constructor(private claudeDir: string) {}

  /** The session's spending on `day` (YYYY-MM-DD in `tz`). */
  spentOn(cwd: string, sessionId: string, day: string, tz: string): number {
    const main = transcriptPath(this.claudeDir, cwd, sessionId);
    const subDir = join(main.replace(/\.jsonl$/, ""), "subagents");
    const paths = [main];
    if (existsSync(subDir)) for (const f of readdirSync(subDir)) if (f.endsWith(".jsonl")) paths.push(join(subDir, f));
    let total = 0;
    for (const p of paths) total += this.scan(p, day, tz)[day] ?? 0;
    return total;
  }

  private scan(path: string, day: string, tz: string): Record<string, number> {
    let fd: number;
    try {
      fd = openSync(path, "r");
    } catch {
      return this.files.get(path)?.byDay ?? {};
    }
    try {
      let cur = this.files.get(path);
      const { size, mtimeMs } = fstatSync(fd);
      // Not written to since before the day: nothing of it there.
      if (!cur && zonedParts(mtimeMs, tz).dateKey < day) return {};
      // Rewritten, or an earlier day than it holds: read anew.
      if (!cur || size < cur.offset || (cur.since !== undefined && day < cur.since)) {
        const offset = startBefore(fd, day, tz);
        cur = { offset, ...(offset > 0 ? { since: day } : {}), byDay: {}, seen: new Map(), partial: [], partialBytes: 0 };
        this.files.set(path, cur);
      }
      const c = cur;
      c.offset = eachLine(fd, c.offset, c, (line) => this.line(c, line, tz));
      return c.byDay;
    } finally {
      closeSync(fd);
    }
  }

  private line(cur: FileCursor, line: Buffer, tz: string): void {
    if (!line.includes('"usage"')) return;
    let e: any;
    try {
      e = JSON.parse(line.toString("utf8"));
    } catch {
      return; // (the first one read may be cut off)
    }
    const m = e?.message;
    if (e?.type !== "assistant" || !m?.usage || m.model === "<synthetic>") return;
    const at = Date.parse(e.timestamp ?? "");
    if (!at) return;
    const day = zonedParts(at, tz).dateKey;
    const usd = usageUsd(String(m.model ?? ""), m.usage);
    const id = String(m.id ?? e.uuid ?? "");
    const before = id ? cur.seen.get(id) : undefined;
    if (before) cur.byDay[before.day] = (cur.byDay[before.day] ?? 0) - before.usd;
    if (id) cur.seen.set(id, { day, usd });
    cur.byDay[day] = (cur.byDay[day] ?? 0) + usd;
  }
}
