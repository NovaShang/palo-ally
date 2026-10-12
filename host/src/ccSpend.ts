import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync } from "node:fs";
import { join } from "node:path";
import { transcriptPath } from "./handoffs.ts";
import { zonedParts } from "./util.ts";

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

interface FileCursor {
  offset: number;
  byDay: Record<string, number>;
  // One API message is written as several entries (one per content block),
  // each with the usage so far: the last one counts.
  seen: Map<string, { day: string; usd: number }>;
  partial: string;
}

// SpendMeter adds up a session's spending per day from its transcripts (and
// its subagents'), reading only what was appended since the last look.
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
    for (const p of paths) total += this.scan(p, tz)[day] ?? 0;
    return total;
  }

  private scan(path: string, tz: string): Record<string, number> {
    let cur = this.files.get(path);
    if (!cur) {
      cur = { offset: 0, byDay: {}, seen: new Map(), partial: "" };
      this.files.set(path, cur);
    }
    let fd: number;
    try {
      fd = openSync(path, "r");
    } catch {
      return cur.byDay;
    }
    try {
      const size = fstatSync(fd).size;
      if (size < cur.offset) {
        // rewritten: start over
        cur.offset = 0;
        cur.byDay = {};
        cur.seen = new Map();
        cur.partial = "";
      }
      if (size === cur.offset) return cur.byDay;
      const buf = Buffer.alloc(size - cur.offset);
      readSync(fd, buf, 0, buf.length, cur.offset);
      cur.offset = size;
      const lines = (cur.partial + buf.toString("utf8")).split("\n");
      cur.partial = lines.pop() ?? "";
      for (const l of lines) {
        if (!l.includes('"usage"')) continue;
        let e: any;
        try {
          e = JSON.parse(l);
        } catch {
          continue;
        }
        const m = e?.message;
        if (e?.type !== "assistant" || !m?.usage || m.model === "<synthetic>") continue;
        const at = Date.parse(e.timestamp ?? "");
        if (!at) continue;
        const day = zonedParts(at, tz).dateKey;
        const usd = usageUsd(String(m.model ?? ""), m.usage);
        const id = String(m.id ?? e.uuid ?? "");
        const before = id ? cur.seen.get(id) : undefined;
        if (before) cur.byDay[before.day] = (cur.byDay[before.day] ?? 0) - before.usd;
        if (id) cur.seen.set(id, { day, usd });
        cur.byDay[day] = (cur.byDay[day] ?? 0) + usd;
      }
      return cur.byDay;
    } finally {
      closeSync(fd);
    }
  }
}
