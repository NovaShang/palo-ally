import type { Paths } from "./config.ts";
import type { ChatMessage, Task } from "./types.ts";
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

  return [
    `最近 ${days} 天`,
    `主动消息：共 ${pushes.reduce((a, b) => a + b, 0)} 条，日均 ${(pushes.reduce((a, b) => a + b, 0) / days).toFixed(1)}，单日最多 ${Math.max(0, ...pushes)}`,
    `主动触发：${proactiveTurns.length} 次，其中判断「不值得打扰」${skips} 次`,
    `任务：${tasks.length} 个（完成 ${count("done")} / 失败 ${count("failed")} / 等你 ${count("needs_input")} / 停止 ${count("stopped")}）；由 report_task 登记 ${tasks.filter((t) => t.source === "report").length} 个`,
    `对话：${turns.length} 轮，上下文最大 ${ctxMax} tokens；自动压缩 ${compacts.length} 次${compacts.length ? `（压缩前平均 ${Math.round(compacts.reduce((n, m) => n + m.preTokens, 0) / compacts.length)} tokens）` : ""}`,
    `换新会话 ${metrics.filter((m) => m.type === "roll").length} 次；掉线 ${metrics.filter((m) => m.type === "offline").length} 次`,
    `主对话花费约 $${cost.toFixed(2)}`,
  ].join("\n");
}
