import type { Paths } from "./config.ts";
import type { ChatMessage, Task } from "./types.ts";
import { t } from "./i18n/index.ts";
import { readJson, readJsonl, zonedParts } from "./util.ts";

// Phase 0 acceptance numbers (PRD §12): proactive volume, task outcomes,
// long-session stability (compactions), and cost — computed from local state.
export function phase0Report(paths: Paths, days: number, timeZone: string, now = Date.now()): string {
  const since = now - days * 86400_000;
  const metrics = readJsonl<any>(paths.metrics).filter((m) => m.ts >= since);
  const chat = readJsonl<ChatMessage>(paths.chat).filter((m) => m.ts >= since);
  const tasks = readJson<{ tasks: Task[] }>(paths.tasks, { tasks: [] }).tasks.filter((t) => t.createdAt >= since);

  const perDay = new Map<string, number>();
  for (const m of chat) if (m.proactive) perDay.set(zonedParts(m.ts, timeZone).dateKey, (perDay.get(zonedParts(m.ts, timeZone).dateKey) ?? 0) + 1);
  const pushes = [...perDay.values()];
  const turns = metrics.filter((m) => m.type === "turn");
  const proactiveTurns = turns.filter((m) => m.proactive);
  const skips = metrics.filter((m) => m.type === "skip").length;
  const compacts = metrics.filter((m) => m.type === "compact");
  const cost = turns.reduce((n, m) => n + (m.costUsd ?? 0), 0);
  const ctxMax = turns.reduce((n, m) => Math.max(n, m.contextTokens ?? 0), 0);
  const count = (s: string) => tasks.filter((t) => t.status === s).length;

  const pushTotal = pushes.reduce((a, b) => a + b, 0);
  const reported = tasks.filter((k) => k.source === "report").length;
  const compactAvg = compacts.length ? t("metrics.compactAvg", { n: Math.round(compacts.reduce((n, m) => n + m.preTokens, 0) / compacts.length) }) : "";
  return [
    t("metrics.days", { days }),
    t("metrics.pushes", { total: pushTotal, avg: (pushTotal / days).toFixed(1), max: Math.max(0, ...pushes) }),
    t("metrics.proactiveTurns", { n: proactiveTurns.length, skips }),
    t("metrics.tasks", { n: tasks.length, done: count("done"), failed: count("failed"), needs: count("needs_input"), stopped: count("stopped"), reported }),
    t("metrics.turns", { turns: turns.length, ctx: ctxMax, compacts: compacts.length, avg: compactAvg }),
    t("metrics.offline", { n: metrics.filter((m) => m.type === "offline").length }),
    t("metrics.cost", { cost: `$${cost.toFixed(2)}` }),
  ].join("\n");
}
