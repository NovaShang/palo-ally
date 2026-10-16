import { t } from "./i18n/index.ts";
import type { HarnessDriver } from "./harness/types.ts";
import type { Watch } from "./types.ts";
import { onScheduledDay, type WatchStore } from "./watches.ts";
import { parseHHMM, truncate, zonedParts } from "./util.ts";

// How long after a missed schedule slot we still catch it up (host was asleep).
const CATCHUP_MS = 6 * 3600_000;
// The scheduler looks every minute. A tick with nothing due makes no model
// call, so this only decides how close to its interval a watch runs (a 5-minute
// check used to wait for the 10-minute tick).
const TICK_MS = 60_000;

export interface ProbeTrigger {
  watch: Watch;
  summary: string;
}

export interface ProbeHost {
  driver: HarnessDriver;
  watches: WatchStore;
  timezone(): string;
  probeModel(): string;
  cwd(): string;
  mcpServers(): Record<string, unknown>;
  inheritConnectors(): boolean;
  env?(): Record<string, string> | undefined;
  lastUserActivity(): number;
  budgetLeftUsd(): number; // probe budget remaining today
  spend(usd: number): void;
  // fire a schedule watch: the main agent runs its instruction
  onSchedule(watch: Watch): void;
  // a check watch found something: feed the main agent
  onTriggers(triggers: ProbeTrigger[]): void;
  log(msg: string): void;
  // the audit trail (probe.run / probe.error / probe.skipped)
  audit?(type: string, data: Record<string, unknown>): void;
  budgetUsd?(): number; // the day's probe budget, for the skip reason
  // Check watches are due but won't run today (the budget is used up). Called
  // once per day, so the owner hears about it instead of the goals going quiet.
  onPaused?(reason: string, watches: Watch[]): void;
}

export const probeSchema = () => ({
  type: "object",
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        properties: {
          watch_id: { type: "string" },
          triggered: { type: "boolean" },
          key: { type: "string", description: "stable id of what triggered (e.g. message id), for dedupe" },
          summary: { type: "string", description: "one or two sentences for the assistant, only when triggered" },
          cursor: { type: "string", description: "state to hand to the next check, e.g. newest seen id/time" },
          progress: {
            type: "string",
            description: t("probe.progressDesc"),
          },
        },
        required: ["watch_id", "triggered"],
      },
    },
  },
  required: ["results"],
});

const probeSystem = () => t("probe.system");

// ProbeScheduler: small interval, short context (PRD §6.3.2). Ticks where no
// watch is due make zero model calls. Due check watches go to one cheap probe
// run; only triggers reach the main agent.
export class ProbeScheduler {
  private timer: ReturnType<typeof setInterval> | null = null;
  private running = false;
  private pausedDay = ""; // the day the budget-used-up notice went out

  constructor(private host: ProbeHost) {}

  start(): void {
    this.stop();
    this.timer = setInterval(() => void this.tick(), TICK_MS);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  async tick(now = Date.now()): Promise<{ scheduled: number; checked: number; triggered: number }> {
    const out = { scheduled: 0, checked: 0, triggered: 0 };
    if (this.running) return out;
    this.running = true;
    try {
      out.scheduled = this.fireSchedules(now);
      const r = await this.runChecks(now);
      out.checked = r.checked;
      out.triggered = r.triggered;
    } finally {
      this.running = false;
    }
    return out;
  }

  // ---- schedule watches (no probe; fixed times or intervals) ----

  private fireSchedules(now: number): number {
    let fired = 0;
    const tz = this.host.timezone();
    for (const w of this.host.watches.list()) {
      if (!w.enabled || w.kind !== "schedule") continue;
      const slot = dueSlot(w, now, tz);
      if (!slot) continue;
      const firedSlots = [...(w.firedSlots ?? []), slot].slice(-50);
      const active = w.skipIfActiveMinutes && now - this.host.lastUserActivity() < w.skipIfActiveMinutes * 60_000;
      this.host.watches.touch(w.id, { firedSlots, lastCheckedAt: now, ...(active ? {} : { lastTriggeredAt: now }) });
      if (active) {
        this.host.log(`schedule ${w.title} skipped: user active`);
        continue;
      }
      fired++;
      this.host.onSchedule(w);
    }
    return fired;
  }

  // ---- check watches (one probe run for all due ones) ----

  private async runChecks(now: number): Promise<{ checked: number; triggered: number }> {
    const due = this.host.watches
      .list()
      .filter((w) => w.enabled && w.kind === "check" && now - (w.lastCheckedAt ?? 0) >= (w.intervalMinutes ?? 60) * 60_000);
    if (!due.length) return { checked: 0, triggered: 0 };
    if (this.host.budgetLeftUsd() <= 0) {
      const budget = this.host.budgetUsd?.();
      const reason = t("probe.budgetUsed", { budget: budget !== undefined ? t("probe.budgetAmount", { n: budget }) : "" });
      for (const w of due)
        if (w.lastResult?.reason !== reason) this.host.watches.touch(w.id, { lastResult: { at: now, ok: false, reason } });
      const day = zonedParts(now, this.host.timezone()).dateKey;
      if (this.pausedDay !== day) {
        this.pausedDay = day;
        this.host.log(`probe skipped: daily probe budget used up (${due.length} due)`);
        this.host.audit?.("probe.skipped", { reason: "budget", budgetUsd: budget, watches: due.map((w) => w.id) });
        this.host.onPaused?.(reason, due);
      }
      return { checked: 0, triggered: 0 };
    }

    const prompt = JSON.stringify(
      {
        now: new Date(now).toISOString(),
        watches: due.map((w) => ({
          watch_id: w.id,
          title: w.title,
          instruction: w.instruction,
          cursor: w.cursor ?? null,
          recent_keys: w.recentKeys ?? [],
        })),
      },
      null,
      1,
    );

    const res = await this.host.driver.runProbe({
      model: this.host.probeModel(),
      cwd: this.host.cwd(),
      systemPrompt: probeSystem(),
      prompt,
      mcpServers: this.host.mcpServers(),
      tools: ["Read", "Glob", "Grep", "WebFetch", "WebSearch"],
      outputSchema: probeSchema() as unknown as Record<string, unknown>,
      maxTurns: 12,
      strictMcp: !this.host.inheritConnectors(),
      env: this.host.env?.(),
    });
    this.host.spend(res.costUsd);
    this.host.log(`probe run: ${due.length} watch(es), $${res.costUsd.toFixed(4)} ${res.usage ? JSON.stringify(res.usage) : ""}`);
    // A refused tool doesn't fail the run (the probe answers "nothing new"), so say it here.
    const denied = res.denied?.length ? { denied: [...new Set(res.denied)] } : {};
    if (denied.denied) this.host.log(`probe tools refused: ${denied.denied.join(", ")}`);
    if (res.error) {
      const reason = truncate(res.error, 300);
      this.host.log(`probe error: ${reason}`);
      this.host.audit?.("probe.error", { reason, watches: due.map((w) => w.id), costUsd: res.costUsd, ...denied });
      // Don't hammer a failing probe: mark checked so it waits a full interval.
      for (const w of due) this.host.watches.touch(w.id, { lastCheckedAt: now, lastResult: { at: now, ok: false, reason } });
      return { checked: due.length, triggered: 0 };
    }

    const results = parseResults(res.output);
    const triggers: ProbeTrigger[] = [];
    for (const w of due) {
      const r = results.find((x) => x.watch_id === w.id);
      const patch: Partial<Watch> = { lastCheckedAt: now, lastResult: { at: now, ok: true } };
      if (r?.cursor) patch.cursor = r.cursor;
      if (r?.triggered) {
        const key = r.key || r.summary || String(now);
        const recent = w.recentKeys ?? [];
        if (!recent.includes(key)) {
          patch.recentKeys = [...recent, key].slice(-20);
          patch.lastTriggeredAt = now;
          triggers.push({ watch: w, summary: truncate(r.summary || t("probe.news"), 500) });
        }
      }
      this.host.watches.touch(w.id, patch);
      // What the owner sees on the goal: the probe's own status line, or the
      // news it found. No extra model call.
      const own = typeof r?.progress === "string" ? r.progress.trim() : "";
      const line = own || (patch.lastTriggeredAt === now && typeof r?.summary === "string" ? r.summary : undefined);
      if (line) this.host.watches.progress(w.id, line);
    }
    this.host.audit?.("probe.run", { watches: due.map((w) => w.id), triggered: triggers.length, costUsd: res.costUsd, ...denied });
    if (triggers.length) this.host.onTriggers(triggers);
    return { checked: due.length, triggered: triggers.length };
  }
}

/** When a check watch is next due (it runs on the first minute tick after). */
export function nextRunAt(w: Watch, now = Date.now()): number | undefined {
  if (!w.enabled || w.kind !== "check") return undefined;
  const due = (w.lastCheckedAt ?? 0) + (w.intervalMinutes ?? 60) * 60_000;
  return Math.max(due, now);
}

export interface ProbeHealth {
  checks: number; // enabled check watches
  lastRunAt?: number; // the latest probe attempt that ran
  failing: number; // check watches whose last attempt failed or was skipped
  stale: number; // check watches not run within twice their interval
  reasons: string[]; // distinct failure reasons
}

/** What `paloally status` / doctor show about the probes. */
export function probeHealth(watches: Watch[], now = Date.now()): ProbeHealth {
  const checks = watches.filter((w) => w.enabled && w.kind === "check");
  const ran = checks.map((w) => w.lastCheckedAt ?? 0).filter((t) => t > 0);
  const failing = checks.filter((w) => w.lastResult && !w.lastResult.ok);
  const stale = checks.filter((w) => now - (w.lastCheckedAt ?? w.createdAt ?? now) > 2 * (w.intervalMinutes ?? 60) * 60_000);
  return {
    checks: checks.length,
    lastRunAt: ran.length ? Math.max(...ran) : undefined,
    failing: failing.length,
    stale: stale.length,
    reasons: [...new Set(failing.map((w) => w.lastResult!.reason ?? t("check.error")))],
  };
}

interface ProbeRow {
  watch_id: string;
  triggered: boolean;
  key?: string;
  summary?: string;
  cursor?: string;
  progress?: string;
}

function parseResults(output: unknown): ProbeRow[] {
  let o = output;
  if (typeof o === "string") {
    try {
      o = JSON.parse(o);
    } catch {
      return [];
    }
  }
  const rows = (o as { results?: unknown })?.results;
  if (!Array.isArray(rows)) return [];
  return rows.filter((r): r is ProbeRow => !!r && typeof r === "object" && typeof (r as ProbeRow).watch_id === "string");
}

// dueSlot returns the slot key to fire now, or null. `at` slots fire once per
// day at/after their time (within the catch-up window), or only on the
// month's `dayOfMonth`; interval schedules fire every intervalMinutes.
export function dueSlot(w: Watch, now: number, tz: string): string | null {
  const fired = new Set(w.firedSlots ?? []);
  if (w.at?.length) {
    // Check today's and yesterday's slots (a slot just before midnight may be caught up after it).
    for (const dayOffset of [0, -1]) {
      const p = zonedParts(now + dayOffset * 86400_000, tz);
      if (!onScheduledDay(w, p)) continue;
      const nowP = zonedParts(now, tz);
      for (const t of w.at) {
        const m = parseHHMM(t);
        if (m === null) continue;
        const key = `${p.dateKey} ${t}`;
        if (fired.has(key)) continue;
        // minutes elapsed since the slot, in zone wall time
        const nowMin = nowP.hour * 60 + nowP.minute + (dayOffset === -1 ? 1440 : 0);
        const elapsed = (nowMin - m) * 60_000;
        // Slots from before the watch existed never fire.
        if (elapsed >= 0 && elapsed <= CATCHUP_MS && now - elapsed >= (w.createdAt ?? 0) - 60_000) return key;
      }
    }
    return null;
  }
  if (w.intervalMinutes) {
    if (now - (w.lastCheckedAt ?? 0) >= w.intervalMinutes * 60_000) return `iv ${now}`;
  }
  return null;
}
