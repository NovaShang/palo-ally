import { join } from "node:path";
import { readdirSync } from "node:fs";
import type { AuditEntry } from "./types.ts";
import { appendJsonl, readJsonl, truncate } from "./util.ts";

// Audit is the append-only action log (PRD §6.5.5): every tool call, approval
// decision, outbound message, and kill/resume. One JSONL file per UTC day.
export class Audit {
  constructor(private dir: string) {}

  log(type: string, fields: Record<string, unknown> = {}): void {
    const entry: AuditEntry = { ts: Date.now(), type, ...sanitize(fields) };
    const day = new Date(entry.ts).toISOString().slice(0, 10);
    appendJsonl(join(this.dir, `${day}.jsonl`), entry);
  }

  tail(limit: number): AuditEntry[] {
    let files: string[];
    try {
      files = readdirSync(this.dir).filter((f) => f.endsWith(".jsonl")).sort();
    } catch {
      return [];
    }
    const out: AuditEntry[] = [];
    for (let i = files.length - 1; i >= 0 && out.length < limit; i--) {
      const entries = readJsonl<AuditEntry>(join(this.dir, files[i]!));
      out.unshift(...entries.slice(-(limit - out.length)));
    }
    return out.slice(-limit);
  }
}

// Long tool inputs/outputs are clipped so the log stays greppable.
function sanitize(fields: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(fields)) {
    if (typeof v === "string") out[k] = truncate(v, 2000);
    else if (v !== undefined && typeof v === "object") out[k] = truncate(JSON.stringify(v), 2000);
    else out[k] = v;
  }
  return out;
}
