import type { HarnessDriver } from "./harness/types.ts";
import type { Watch } from "./types.ts";
import { onScheduledDay, type WatchStore } from "./watches.ts";
import { parseHHMM, truncate, zonedParts } from "./util.ts";

// How long after a missed schedule slot we still catch it up (host was asleep).
const CATCHUP_MS = 6 * 3600_000;

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
}

export const PROBE_SCHEMA = {
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
            description: "optional: one short line in Chinese for the owner on where this goal stands now (e.g. 「现在最低 ¥4,860」), only when you learned something concrete",
          },
        },
        required: ["watch_id", "triggered"],
      },
    },
  },
  required: ["results"],
} as const;

const PROBE_SYSTEM = `你是一个轻量探针，替一位私人助理检查几条「盯梢」(watch)。
对每条 watch，用你能用的工具按它的说明去查，判断自上次（cursor）以来有没有值得告诉主人的新情况。
规则：
- 只读，不做任何修改、发送、删除动作。
- 没有新情况就 triggered=false，别编造。
- 有新情况：triggered=true，key 填能唯一标识这件事的东西（如邮件 id、时间戳），summary 用一两句话说清楚是什么。
- cursor 填下次检查要用的游标（如最新看到的 id 或时间），没有就沿用旧的。
- 这些 watch 在主人那里显示为「目标」。如果查到了这个目标现在的具体状况（不论有没有新情况），progress 用一句很短的中文写给主人看（如「现在最低 ¥4,860」「还有 3 封没回」）；查不出就不填。
- 已经在 recent_keys 里的事不要再报。
- 尽快结束，不要做多余的探索。`;

// ProbeScheduler: small interval, short context (PRD §6.3.2). Ticks where no
// watch is due make zero model calls. Due check watches go to one cheap probe
// run; only triggers reach the main agent.
export class ProbeScheduler {
  private timer: ReturnType<typeof setInterval> | null = null;
  private running = false;

  constructor(private host: ProbeHost) {}

  start(intervalMinutes: number): void {
    this.stop();
    this.timer = setInterval(() => void this.tick(), intervalMinutes * 60_000);
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
      this.host.log("probe skipped: daily probe budget used up");
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
      systemPrompt: PROBE_SYSTEM,
      prompt,
      mcpServers: this.host.mcpServers(),
      tools: ["Read", "Glob", "Grep", "WebFetch", "WebSearch"],
      outputSchema: PROBE_SCHEMA as unknown as Record<string, unknown>,
      maxTurns: 12,
      strictMcp: !this.host.inheritConnectors(),
      env: this.host.env?.(),
    });
    this.host.spend(res.costUsd);
    this.host.log(`probe run: ${due.length} watch(es), $${res.costUsd.toFixed(4)} ${res.usage ? JSON.stringify(res.usage) : ""}`);
    if (res.error) {
      this.host.log(`probe error: ${res.error}`);
      // Don't hammer a failing probe: mark checked so it waits a full interval.
      for (const w of due) this.host.watches.touch(w.id, { lastCheckedAt: now });
      return { checked: due.length, triggered: 0 };
    }

    const results = parseResults(res.output);
    const triggers: ProbeTrigger[] = [];
    for (const w of due) {
      const r = results.find((x) => x.watch_id === w.id);
      const patch: Partial<Watch> = { lastCheckedAt: now };
      if (r?.cursor) patch.cursor = r.cursor;
      if (r?.triggered) {
        const key = r.key || r.summary || String(now);
        const recent = w.recentKeys ?? [];
        if (!recent.includes(key)) {
          patch.recentKeys = [...recent, key].slice(-20);
          patch.lastTriggeredAt = now;
          triggers.push({ watch: w, summary: truncate(r.summary || "有新情况", 500) });
        }
      }
      this.host.watches.touch(w.id, patch);
      // What the owner sees on the goal: the probe's own status line, or the
      // news it found. No extra model call.
      const own = typeof r?.progress === "string" ? r.progress.trim() : "";
      const line = own || (patch.lastTriggeredAt === now && typeof r?.summary === "string" ? r.summary : undefined);
      if (line) this.host.watches.progress(w.id, line);
    }
    if (triggers.length) this.host.onTriggers(triggers);
    return { checked: due.length, triggered: triggers.length };
  }
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
