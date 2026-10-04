import { join } from "node:path";
import type { Bus } from "./bus.ts";
import type { Task, TaskActivity, TaskStatus } from "./types.ts";
import { appendJsonl, newId, readJson, readJsonl, truncate, writeJson } from "./util.ts";

const SUBAGENT_TOOLS = new Set(["Agent", "Task"]); // Task was renamed Agent in CC v2.1.63; accept both
const LINK_WINDOW_MS = 15 * 60_000;
const TERMINAL: TaskStatus[] = ["done", "failed", "stopped"];

export type TaskTransition = "accepted" | "finished";

// TaskTracker is the read-only projection of harness-native subagents
// (PRD §6.2). The harness owns their lifecycle; we only watch:
//  - an Agent/Task tool_use on the main thread creates a placeholder row
//    ("不漏": detection guarantees completeness),
//  - report_task from the main agent fills in the semantic one-liner
//    (the authoritative source for list, chat receipts, and push),
//  - messages carrying parent_tool_use_id are grouped as best-effort detail.
export class TaskTracker {
  private tasks: Task[];
  private reportIds = new Map<string, string>(); // report_task id → task id
  private toolUseToTask = new Map<string, string>(); // any tool_use id inside a task → task id
  private background = new Set<string>(); // task ids whose Agent call returned immediately
  // Completions seen this turn; applied at turn end so the main agent's
  // report_task summary (usually written right after) wins over raw output.
  private pendingFinish = new Map<string, { status: TaskStatus; summary: string }>();

  constructor(
    private path: string,
    private activityDir: string,
    private bus: Bus,
    private onTransition: (t: Task, kind: TaskTransition) => void = () => {},
  ) {
    const saved = readJson<{ tasks: Task[]; reportIds: [string, string][] }>(path, { tasks: [], reportIds: [] });
    this.tasks = saved.tasks;
    this.reportIds = new Map(saved.reportIds);
    for (const t of this.tasks) if (t.toolUseId) this.toolUseToTask.set(t.toolUseId, t.id);
  }

  list(): Task[] {
    return [...this.tasks].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  get(id: string): Task | undefined {
    return this.tasks.find((t) => t.id === id) ?? this.byReportId(id);
  }

  activity(id: string): TaskActivity[] {
    return readJsonl<TaskActivity>(join(this.activityDir, `${id}.jsonl`));
  }

  // ---- harness event inputs ----

  onToolUse(id: string, name: string, input: Record<string, unknown>, parentToolUseId: string | null): void {
    if (parentToolUseId) {
      const taskId = this.toolUseToTask.get(parentToolUseId);
      if (!taskId) return;
      this.toolUseToTask.set(id, taskId); // nested calls (incl. nested subagents) roll up to the root task
      this.addActivity(taskId, { ts: Date.now(), kind: "tool_use", tool: name, text: summarizeInput(name, input) });
      return;
    }
    if (!SUBAGENT_TOOLS.has(name)) return;
    const title = String(input.description ?? "") || truncate(String(input.prompt ?? "后台任务"), 40);
    const now = Date.now();
    // The agent often reports first and dispatches right after: attach to that row.
    const reported = this.unlinkedReport(title);
    if (reported) {
      reported.toolUseId = id;
      this.toolUseToTask.set(id, reported.id);
      if (input.run_in_background === true) this.background.add(reported.id);
      this.save(reported);
      return;
    }
    const task: Task = {
      id: newId("t_"),
      title,
      summary: "",
      status: "running",
      source: "auto",
      createdAt: now,
      updatedAt: now,
      activityCount: 0,
      toolUseId: id,
    };
    this.tasks.push(task);
    this.toolUseToTask.set(id, task.id);
    if (input.run_in_background === true) this.background.add(task.id);
    this.save(task);
  }

  onToolResult(toolUseId: string, content: string, isError: boolean, parentToolUseId: string | null): void {
    if (parentToolUseId) {
      const taskId = this.toolUseToTask.get(parentToolUseId);
      if (taskId) this.addActivity(taskId, { ts: Date.now(), kind: "tool_result", text: truncate(content, 500) });
      return;
    }
    const task = this.tasks.find((t) => t.toolUseId === toolUseId);
    if (!task || this.background.has(task.id) || TERMINAL.includes(task.status)) return;
    // Foreground subagent finished: its tool_result is the final report.
    this.pendingFinish.set(task.id, { status: isError ? "failed" : "done", summary: truncate(firstLine(content), 120) });
  }

  onSubagentText(text: string, parentToolUseId: string): void {
    const taskId = this.toolUseToTask.get(parentToolUseId);
    if (taskId) this.addActivity(taskId, { ts: Date.now(), kind: "text", text: truncate(text, 1000) });
  }

  onTaskStarted(sdkTaskId: string, toolUseId: string | undefined, background: boolean | undefined): void {
    const task = toolUseId ? this.tasks.find((t) => t.toolUseId === toolUseId) : undefined;
    if (!task) return;
    task.sdkTaskId = sdkTaskId;
    if (background) this.background.add(task.id);
    this.save(task);
  }

  onTaskNotification(sdkTaskId: string, toolUseId: string | undefined, status: string, summary: string): void {
    const task = this.tasks.find((t) => t.sdkTaskId === sdkTaskId || (toolUseId && t.toolUseId === toolUseId));
    if (!task || TERMINAL.includes(task.status)) return;
    const s: TaskStatus = status === "completed" ? "done" : status === "stopped" ? "stopped" : "failed";
    this.pendingFinish.set(task.id, { status: s, summary: truncate(summary, 120) });
  }

  // ---- report_task ----

  report(reportId: string, summary: string, status: string, title?: string): Task {
    const st = normalizeStatus(status);
    let task = this.get(reportId);
    if (!task) {
      task = this.claimPlaceholder(title);
      if (task) {
        this.reportIds.set(reportId, task.id);
      } else {
        const now = Date.now();
        task = {
          id: newId("t_"),
          title: title || truncate(summary, 40),
          summary: "",
          status: "running",
          source: "report",
          createdAt: now,
          updatedAt: now,
          activityCount: 0,
        };
        this.tasks.push(task);
        this.reportIds.set(reportId, task.id);
      }
    }
    const firstReport = task.source === "auto" || !task.summary;
    task.source = "report";
    if (title) task.title = title;
    if (summary) task.summary = summary;
    if (TERMINAL.includes(st)) {
      if (!TERMINAL.includes(task.status)) {
        this.finish(task, st, summary || task.summary);
        return task;
      }
      task.status = st;
    } else {
      task.status = st;
    }
    task.updatedAt = Date.now();
    this.save(task);
    if (firstReport && !TERMINAL.includes(st)) this.onTransition(task, "accepted");
    return task;
  }

  // finalizePending applies completions the main agent didn't report itself.
  finalizePending(): void {
    for (const [id, p] of this.pendingFinish) {
      const task = this.tasks.find((t) => t.id === id);
      if (task && !TERMINAL.includes(task.status)) {
        // A running-status summary describes the plan, not the result.
        this.finish(task, p.status, p.summary || task.summary);
      }
    }
    this.pendingFinish.clear();
  }

  taskIdForToolUse(toolUseId: string): string | undefined {
    return this.toolUseToTask.get(toolUseId);
  }

  markStopped(id: string): Task | undefined {
    const task = this.get(id);
    if (task && !TERMINAL.includes(task.status)) this.finish(task, "stopped", task.summary || "已停止");
    return task;
  }

  running(): Task[] {
    return this.tasks.filter((t) => !TERMINAL.includes(t.status));
  }

  // On restart the harness process that ran these is gone.
  orphanRunning(): Task[] {
    const orphaned = this.running();
    for (const t of orphaned) this.finish(t, "stopped", t.summary || "助理重启，任务中断");
    return orphaned;
  }

  // ---- internals ----

  private byReportId(id: string): Task | undefined {
    const tid = this.reportIds.get(id);
    return tid ? this.tasks.find((t) => t.id === tid) : undefined;
  }

  // An auto placeholder not yet claimed by any report_task id. Prefer a title
  // match, else the newest recent one.
  private claimPlaceholder(title?: string): Task | undefined {
    const claimed = new Set(this.reportIds.values());
    const cands = this.tasks.filter(
      (t) => t.source === "auto" && !claimed.has(t.id) && Date.now() - t.createdAt < LINK_WINDOW_MS,
    );
    if (title) {
      const m = cands.find((t) => t.title === title);
      if (m) return m;
    }
    return cands.sort((a, b) => b.createdAt - a.createdAt)[0];
  }

  // A report_task row with no subagent attached yet, from the last few minutes.
  private unlinkedReport(title: string): Task | undefined {
    const cands = this.tasks.filter(
      (t) => t.source === "report" && !t.toolUseId && !TERMINAL.includes(t.status) && Date.now() - t.createdAt < LINK_WINDOW_MS,
    );
    return cands.find((t) => t.title === title) ?? cands.sort((a, b) => b.createdAt - a.createdAt)[0];
  }

  private finish(task: Task, status: TaskStatus, summary: string): void {
    task.status = status;
    task.summary = summary;
    task.updatedAt = Date.now();
    this.save(task);
    this.onTransition(task, "finished");
  }

  private addActivity(taskId: string, a: TaskActivity): void {
    const task = this.tasks.find((t) => t.id === taskId);
    if (!task) return;
    appendJsonl(join(this.activityDir, `${taskId}.jsonl`), a);
    task.activityCount++;
    task.updatedAt = Date.now();
    this.save(task);
  }

  private save(changed: Task): void {
    // Keep the list bounded: finished tasks older than 30 days drop off.
    const cutoff = Date.now() - 30 * 86400_000;
    this.tasks = this.tasks.filter((t) => !TERMINAL.includes(t.status) || t.updatedAt > cutoff);
    writeJson(this.path, { tasks: this.tasks, reportIds: [...this.reportIds] });
    this.bus.emit("task.updated", changed);
  }
}

function normalizeStatus(s: string): TaskStatus {
  const v = s.toLowerCase();
  if (["done", "completed", "complete", "success", "完成"].includes(v)) return "done";
  if (["failed", "error", "失败"].includes(v)) return "failed";
  if (["needs_input", "blocked", "waiting", "需要你"].includes(v)) return "needs_input";
  if (["stopped", "cancelled", "canceled"].includes(v)) return "stopped";
  return "running";
}

function firstLine(s: string): string {
  return s.split("\n").find((l) => l.trim()) ?? s;
}

export function summarizeInput(tool: string, input: Record<string, unknown>): string {
  const pick = input.command ?? input.url ?? input.file_path ?? input.path ?? input.pattern ?? input.query ?? input.description;
  if (typeof pick === "string") return truncate(pick, 200);
  return truncate(JSON.stringify(input), 200);
}
