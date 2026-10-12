import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync } from "node:fs";
import { join } from "node:path";
import { transcriptPath } from "./handoffs.ts";
import type { HelperProposal } from "./types.ts";
import { readJson, writeJson, zonedParts } from "./util.ts";

// Helpers (docs/sessions-prd.md §6.5): background Claude Code sessions the
// host opened for the owner, one per long-running project. Claude Code runs
// them (`claude --bg`); the host keeps their record in state/helpers.json —
// name, folder, job short id, session id, daily spending limit, when made —
// so it can stop, restart, remove and revive them, bring them back after the
// Mac restarts, and stop one that spends more than its limit in a day.

export const MAX_HELPERS = 3;

export interface Helper {
  sessionId: string;
  name: string;
  cwd: string;
  duty: string;
  dailyUsd: number;
  short: string; // Claude Code's job id (`claude stop <short>`)
  createdAt: number;
  // active: should be running (revived after a restart of the Mac);
  // stopped: the owner (or its spending limit) stopped it; removed: `claude rm`.
  state: "active" | "stopped" | "removed";
  stoppedFor?: "owner" | "budget";
  budgetDay?: string; // the day it was stopped for spending (once a day)
  permissionMode: string;
}

interface HelperFile {
  helpers: Helper[];
  proposals: (HelperProposal & { createdAt: number; messageId?: string })[];
}

export class HelperStore {
  private data: HelperFile;

  constructor(private path: string) {
    const d = readJson<Partial<HelperFile>>(path, {});
    this.data = { helpers: Array.isArray(d.helpers) ? d.helpers : [], proposals: Array.isArray(d.proposals) ? d.proposals : [] };
  }

  list(): Helper[] {
    return this.data.helpers;
  }

  get(sessionId: string): Helper | undefined {
    return this.data.helpers.find((h) => h.sessionId === sessionId);
  }

  byName(name: string): Helper | undefined {
    const n = name.trim();
    const live = this.data.helpers.filter((h) => h.state !== "removed");
    return live.find((h) => h.name === n) ?? live.find((h) => h.name.toLowerCase() === n.toLowerCase()) ?? this.data.helpers.find((h) => h.name === n);
  }

  /** Helpers that count toward the limit of three. */
  running(): Helper[] {
    return this.data.helpers.filter((h) => h.state === "active");
  }

  add(h: Helper): void {
    this.data.helpers = [...this.data.helpers.filter((x) => x.sessionId !== h.sessionId), h];
    this.save();
  }

  update(sessionId: string, patch: Partial<Helper>): Helper | undefined {
    const h = this.get(sessionId);
    if (!h) return undefined;
    Object.assign(h, patch);
    for (const k of Object.keys(patch) as (keyof Helper)[]) if (patch[k] === undefined) delete h[k];
    this.save();
    return h;
  }

  proposals(): HelperFile["proposals"] {
    return this.data.proposals;
  }

  proposal(id: string): HelperFile["proposals"][number] | undefined {
    return this.data.proposals.find((p) => p.id === id);
  }

  addProposal(p: HelperFile["proposals"][number]): void {
    this.data.proposals = [...this.data.proposals, p].slice(-50);
    this.save();
  }

  updateProposal(id: string, patch: Partial<HelperProposal> & { messageId?: string }): HelperFile["proposals"][number] | undefined {
    const p = this.proposal(id);
    if (!p) return undefined;
    Object.assign(p, patch);
    for (const k of Object.keys(patch) as (keyof typeof patch)[]) if (patch[k] === undefined) delete (p as any)[k];
    this.save();
    return p;
  }

  private save(): void {
    writeJson(this.path, this.data);
  }
}

// ---------------- what a helper spends ----------------

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
