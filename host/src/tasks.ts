import { join } from "node:path";
import type { Bus } from "./bus.ts";
import { activityLabel } from "./copy.ts";
import type { Task, TaskActivity, TaskStatus } from "./types.ts";
import { appendJsonl, newId, readJson, readJsonl, truncate, writeJson } from "./util.ts";

const SUBAGENT_TOOLS = new Set(["Agent", "Task"]); // Task was renamed Agent in CC v2.1.63; accept both
// report_task without a known id attaches to the newest unreported row this recent.
const LINK_WINDOW_MS = 10 * 60_000;
const REPORT_FIRST_WINDOW_MS = 2 * 60_000;
// The harness' note that a subagent's report went to the main agent (not a result).
const HANDBACK_NOTE = /SubagentHandback|report was delivered to you|agent's report was delivered/i;
const TERMINAL: TaskStatus[] = ["done", "failed", "stopped"];

export type TaskTransition = "accepted" | "finished";

// TaskTracker is the read-only projection of harness-native subagents
// (PRD §6.2, revised 2026-10-04: the harness' task events are authoritative).
//  - an Agent/Task tool_use on the main thread creates the row; task_started
//    links the harness' task id; task_progress keeps a live one-liner;
//    task_notification (or the foreground tool_result) finishes it;
//    background_tasks_changed says what is still running;
//  - report_task is optional: it only rewords the row and the chat receipt;
//  - messages carrying parent_tool_use_id are grouped as best-effort detail.
export class TaskTracker {
  private tasks: Task[];
  private reportIds = new Map<string, string>(); // report_task id → task id
  private toolUseToTask = new Map<string, string>(); // any tool_use id inside a task → task id
  private background = new Set<string>(); // task ids whose Agent call returned immediately
  // Completions seen this turn; applied at turn end so the main agent's
  // report_task summary (usually written right after) wins over raw output.
  private pendingFinish = new Map<string, { status: TaskStatus; summary: string }>();
  private lastWords = new Map<string, string>(); // task id → the subagent's latest text
  private liveSet: Set<string> | null = null; // harness task ids still running (null = not reported yet)

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
      // The subagent hands its final report back through this tool: that's the result.
      if (name === "SubagentHandback") {
        const report = Object.values(input).find((v) => typeof v === "string" && v.trim()) as string | undefined;
        if (report) this.lastWords.set(taskId, report.trim());
      }
      this.addActivity(taskId, { ts: Date.now(), kind: "tool_use", tool: name, label: activityLabel(name), text: summarizeInput(name, input) });
      return;
    }
    if (!SUBAGENT_TOOLS.has(name)) return;
    const title = String(input.description ?? "") || truncate(String(input.prompt ?? "后台任务"), 40);
    const now = Date.now();
    // The agent often reports first and dispatches right after: attach to that row.
    const reported = this.unlinkedReport();
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
    if (!taskId) return;
    if (text.trim()) this.lastWords.set(taskId, text.trim());
    this.addActivity(taskId, { ts: Date.now(), kind: "text", text: truncate(text, 1000) });
  }

  onTaskStarted(sdkTaskId: string, toolUseId: string | undefined, background: boolean | undefined): void {
    const task = toolUseId ? this.tasks.find((t) => t.toolUseId === toolUseId) : undefined;
    if (!task) return;
    task.sdkTaskId = sdkTaskId;
    if (background) this.background.add(task.id);
    this.save(task);
  }

  // A foreground subagent moved to the background: its tool_result was only a
  // "moved to background" notice, so wait for the real completion.
  onTaskBackgrounded(sdkTaskId: string): void {
    const task = this.tasks.find((t) => t.sdkTaskId === sdkTaskId);
    if (!task) return;
    this.background.add(task.id);
    this.pendingFinish.delete(task.id);
  }

  // live: subagents actually working right now. Background ones are whatever
  // the harness last listed; foreground ones run inside the current turn.
  // Excludes "needs_input" and rows the model reported but never dispatched.
  live(): Task[] {
    return this.tasks.filter(
      (t) =>
        t.status === "running" &&
        !!t.toolUseId &&
        Date.now() - t.updatedAt < 6 * 3600_000 &&
        !(this.liveSet && t.sdkTaskId && this.background.has(t.id) && !this.liveSet.has(t.sdkTaskId)),
    );
  }

  setLiveSet(sdkTaskIds: string[]): void {
    this.liveSet = new Set(sdkTaskIds);
  }

  // task_progress: the harness' own one-line summary of what the subagent is doing.
  onProgress(sdkTaskId: string, summary: string): void {
    const task = this.tasks.find((t) => t.sdkTaskId === sdkTaskId);
    if (!task || TERMINAL.includes(task.status) || task.summary === summary) return;
    task.summary = truncate(summary, 120);
    task.updatedAt = Date.now();
    this.save(task);
  }

  onTaskNotification(sdkTaskId: string, toolUseId: string | undefined, status: string, summary: string): void {
    const task = this.tasks.find((t) => t.sdkTaskId === sdkTaskId || (toolUseId && t.toolUseId === toolUseId));
    if (!task || TERMINAL.includes(task.status)) return;
    const s: TaskStatus = status === "completed" ? "done" : status === "stopped" ? "stopped" : "failed";
    // Newer harnesses hand the subagent's report straight to the main agent and
    // put only a delivery note here; then the subagent's last words are the result.
    const useful = summary && !HANDBACK_NOTE.test(summary) ? summary : (this.lastWords.get(task.id) ?? "");
    this.pendingFinish.set(task.id, { status: s, summary: truncate(firstLine(useful), 120) });
  }

  // ---- report_task ----

  report(reportId: string, summary: string, status: string, title?: string): Task {
    const st = normalizeStatus(status);
    let task = this.get(reportId);
    // A finished row isn't reopened by a reused id ("research" next week is a new task).
    if (task && TERMINAL.includes(task.status) && !TERMINAL.includes(st)) {
      this.reportIds.delete(reportId);
      task = undefined;
    }
    if (!task) {
      task = this.claimPlaceholder();
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

  // report_task(id, peer=…) on a row the host opened for a handoff: that id now names it.
  adoptReportId(reportId: string, taskId: string): void {
    if (!this.reportIds.has(reportId) && this.tasks.some((t) => t.id === taskId)) this.reportIds.set(reportId, taskId);
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

  // ---- work handed to another session (HandoffTracker drives these) ----

  openPeer(title: string, summary: string, peer: string): Task {
    const now = Date.now();
    const task: Task = { id: newId("t_"), title, summary, status: "running", source: "report", createdAt: now, updatedAt: now, activityCount: 0, peer };
    this.tasks.push(task);
    this.save(task);
    return task;
  }

  setPeer(id: string, peer: string): void {
    const task = this.get(id);
    if (!task || task.peer === peer) return;
    task.peer = peer;
    this.save(task);
  }

  updatePeer(id: string, status: "running" | "needs_input", summary: string): void {
    const task = this.get(id);
    if (!task || TERMINAL.includes(task.status)) return;
    if (task.status === status && task.summary === summary) return;
    task.status = status;
    task.summary = truncate(summary, 120);
    task.updatedAt = Date.now();
    this.save(task);
  }

  settlePeer(id: string, status: "done" | "failed" | "stopped", summary: string): void {
    const task = this.get(id);
    if (task && !TERMINAL.includes(task.status)) this.finish(task, status, truncate(summary, 120));
  }

  // On restart the harness process that ran these is gone. Work handed to
  // another session isn't: that session keeps going and the host keeps following it.
  orphanRunning(): Task[] {
    const orphaned = this.running().filter((t) => !t.peer);
    for (const t of orphaned) this.finish(t, "stopped", t.summary || "助理重启，任务中断");
    return orphaned;
  }

  // ---- internals ----

  private byReportId(id: string): Task | undefined {
    const tid = this.reportIds.get(id);
    return tid ? this.tasks.find((t) => t.id === tid) : undefined;
  }

  // The newest live, unclaimed harness row from the last few minutes.
  private claimPlaceholder(): Task | undefined {
    const claimed = new Set(this.reportIds.values());
    return this.tasks
      .filter((t) => t.source === "auto" && !claimed.has(t.id) && !TERMINAL.includes(t.status) && Date.now() - t.createdAt < LINK_WINDOW_MS)
      .sort((a, b) => b.createdAt - a.createdAt)[0];
  }

  // A report_task row the agent wrote just before dispatching its subagent.
  private unlinkedReport(): Task | undefined {
    return this.tasks
      .filter((t) => t.source === "report" && !t.toolUseId && t.status === "running" && Date.now() - t.createdAt < REPORT_FIRST_WINDOW_MS)
      .sort((a, b) => b.createdAt - a.createdAt)[0];
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
    const ids = new Set(this.tasks.map((t) => t.id));
    for (const [k, v] of this.reportIds) if (!ids.has(v)) this.reportIds.delete(k);
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
