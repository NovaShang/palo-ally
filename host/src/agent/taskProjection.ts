// A session's subagents and background tasks as the owner sees them, fed by
// the harness' events (docs/harness-adapter-design.md §1.1 row 14). The
// assistant's go to the host's TaskTracker (tasks.json, activity files,
// report_task, its notices); an agent's are kept in its own record (running
// ones, and the last 30 that ended). Both runtimes hand every event to one.
import type { HarnessEvent } from "../harness/types.ts";
import type { TaskTracker } from "../tasks.ts";
import { truncate } from "../util.ts";

export interface TaskProjection {
  /** A harness event (most aren't about tasks). True: what the owner sees of its tasks changed. */
  onEvent(e: HarnessEvent): boolean;
  /** A turn ended: what it finished settles. */
  turnEnded(): void;
  /** Its process ended: what was still running ends with it. */
  processEnded(): void;
}

/** The assistant's: the host's TaskTracker. */
export class TrackerTasks implements TaskProjection {
  constructor(readonly tracker: TaskTracker) {}

  onEvent(e: HarnessEvent): boolean {
    const tasks = this.tracker;
    switch (e.type) {
      case "assistant_text":
        if (e.parentToolUseId) tasks.onSubagentText(e.text, e.parentToolUseId);
        break;
      case "tool_use":
        tasks.onToolUse(e.id, e.name, e.input, e.parentToolUseId);
        break;
      case "tool_result":
        tasks.onToolResult(e.toolUseId, e.content, e.isError, e.parentToolUseId);
        break;
      case "task_started":
        tasks.onTaskStarted(e.taskId, e.toolUseId, e.background);
        break;
      case "task_progress":
        if (e.summary) tasks.onProgress(e.taskId, e.summary);
        break;
      case "background_tasks":
        tasks.setLiveSet(e.taskIds);
        break;
      case "task_backgrounded":
        tasks.onTaskBackgrounded(e.taskId);
        break;
      case "task_notification":
        tasks.onTaskNotification(e.taskId, e.toolUseId, e.status, e.summary);
        break;
    }
    return false; // the tracker tells the app itself
  }

  turnEnded(): void {
    this.tracker.finalizePending();
  }

  processEnded(): void {}
}

/** A background task or subagent of a session (pals.detail.tasks). */
export interface PalTask {
  id: string;
  title: string;
  kind: "subagent" | "bg";
  startedAt: number;
  summary?: string;
}

/** One of its tasks that has ended (pals.detail.pastTasks). */
export interface PastPalTask extends PalTask {
  endedAt: number;
  status: "done" | "failed" | "stopped";
}

const PAST_TASKS = 30;

/** An agent's: kept with its record (pastTasks). */
export class RecordTasks implements TaskProjection {
  private bg = new Set<string>(); // its background tasks still running (a subagent in the background)
  private tasks = new Map<string, PalTask & { toolUseId?: string; backgrounded: boolean }>(); // subagents and background tasks, by the harness' task id

  constructor(
    private rec: { pastTasks?: PastPalTask[] },
    private d: { save: () => void; now: () => number },
  ) {}

  /** Background tasks still running: it isn't idle while there are. */
  get background(): number {
    return this.bg.size;
  }

  has(id: string): boolean {
    return this.tasks.has(id);
  }

  /**
   * Its tasks as the owner sees them: subagents, and shell commands running
   * in the background. A foreground command is a step of the turn, not a task
   * (Claude Code reports every Bash call as one), until it is backgrounded.
   */
  running() {
    return [...this.tasks.values()].filter((t) => t.kind === "subagent" || t.backgrounded);
  }

  /** The running ones for pals.detail. */
  wire(): PalTask[] {
    return this.running().map(({ id, title, kind, startedAt, summary }) => ({ id, title, kind, startedAt, ...(summary ? { summary } : {}) }));
  }

  /** A task is over: it leaves the running ones and goes on top of its history. False: not one of them. */
  private end(id: string, status: PastPalTask["status"], summary?: string): boolean {
    const t = this.tasks.get(id);
    if (!t) return false;
    this.tasks.delete(id);
    if (t.kind !== "subagent" && !t.backgrounded) return false; // a foreground command: no history
    const words = (summary && truncate(summary, 200)) || t.summary;
    const past: PastPalTask = { id: t.id, title: t.title, kind: t.kind, startedAt: t.startedAt, endedAt: this.d.now(), status, ...(words ? { summary: words } : {}) };
    this.rec.pastTasks = [past, ...(this.rec.pastTasks ?? []).filter((p) => p.id !== id)].slice(0, PAST_TASKS);
    this.d.save();
    return true;
  }

  onEvent(e: HarnessEvent): boolean {
    switch (e.type) {
      case "tool_result":
        // a foreground subagent ends with its tool result
        for (const [id, t] of this.tasks) if (t.toolUseId === e.toolUseId && !t.backgrounded) this.end(id, e.isError ? "failed" : "done");
        return false;
      case "background_tasks": {
        this.bg = new Set(e.taskIds);
        let gone = false;
        for (const [id, t] of this.tasks) if (t.backgrounded && !this.bg.has(id)) gone = this.end(id, "done") || gone;
        return gone;
      }
      case "task_started": {
        const agent = e.taskType ? /agent/i.test(e.taskType) : true;
        this.tasks.set(e.taskId, {
          id: e.taskId,
          title: truncate(e.description || e.taskId, 80),
          kind: agent ? "subagent" : "bg",
          startedAt: this.d.now(),
          ...(e.toolUseId ? { toolUseId: e.toolUseId } : {}),
          backgrounded: !!e.background,
        });
        if (e.background) this.bg.add(e.taskId);
        return true;
      }
      case "task_progress": {
        const t = this.tasks.get(e.taskId);
        if (t && e.summary && t.summary !== e.summary) {
          t.summary = truncate(e.summary, 120);
          return true;
        }
        return false;
      }
      case "task_backgrounded": {
        const t = this.tasks.get(e.taskId);
        let shown = false;
        if (t && !t.backgrounded) {
          t.backgrounded = true;
          shown = true; // a command sent to the background is a task now
        }
        this.bg.add(e.taskId);
        return shown;
      }
      case "task_notification":
        this.bg.delete(e.taskId);
        return this.end(e.taskId, e.status === "completed" ? "done" : e.status, e.summary);
    }
    return false;
  }

  turnEnded(): void {}

  processEnded(): void {
    this.bg.clear();
    for (const id of [...this.tasks.keys()]) this.end(id, "stopped");
  }
}
