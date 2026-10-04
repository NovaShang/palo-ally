import { describe, expect, test } from "bun:test";
import { Bus } from "../src/bus.ts";
import { TaskTracker, type TaskTransition } from "../src/tasks.ts";
import type { Task } from "../src/types.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

function mk() {
  const paths = tmpPaths();
  const transitions: [string, TaskTransition, string][] = [];
  const t = new TaskTracker(paths.tasks, paths.taskActivity, new Bus(), (task: Task, k) => transitions.push([task.id, k, task.status]));
  return { t, transitions, paths };
}

describe("TaskTracker", () => {
  test("Agent tool_use creates a placeholder; report_task claims it", () => {
    const { t, transitions, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "查机票", prompt: "..." }, null);
    expect(t.list()).toHaveLength(1);
    expect(t.list()[0]!.source).toBe("auto");
    const r = t.report("flights", "在比较三家航司的价格", "running", "查机票");
    expect(r.id).toBe(t.list()[0]!.id);
    expect(r.source).toBe("report");
    expect(transitions).toEqual([[r.id, "accepted", "running"]]);
    // report by the agent's own id resolves to the same row
    expect(t.get("flights")!.id).toBe(r.id);
    cleanup(paths);
  });

  test("report first, dispatch after: one row, activity attached", () => {
    const { t, paths } = mk();
    const r = t.report("sum", "派人去算", "running", "算和");
    t.onToolUse("tu1", "Agent", { description: "计算和", run_in_background: true }, null);
    expect(t.list()).toHaveLength(1);
    t.onSubagentText("= 1275", "tu1");
    t.onTaskStarted("sdk1", "tu1", true);
    t.onTaskNotification("sdk1", "tu1", "completed", "1275");
    t.report("sum", "和是 1275", "done");
    t.finalizePending();
    const task = t.get(r.id)!;
    expect(task.status).toBe("done");
    expect(task.summary).toBe("和是 1275");
    expect(task.activityCount).toBe(1);
    expect(task.sdkTaskId).toBe("sdk1");
    cleanup(paths);
  });

  test("legacy Task tool name is also detected", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Task", { description: "x" }, null);
    expect(t.list()).toHaveLength(1);
    t.onToolUse("tu2", "Bash", { command: "ls" }, null);
    expect(t.list()).toHaveLength(1);
    cleanup(paths);
  });

  test("subagent activity groups by parent_tool_use_id, including nested", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "研究" }, null);
    const id = t.list()[0]!.id;
    t.onToolUse("c1", "WebSearch", { query: "q" }, "tu1");
    t.onToolResult("c1", "results", false, "tu1");
    t.onSubagentText("thinking out loud", "tu1");
    t.onToolUse("n1", "Agent", { description: "nested" }, "tu1");
    t.onToolUse("n2", "Read", { file_path: "/a" }, "n1"); // grandchild rolls up
    const act = t.activity(id);
    expect(act.map((a) => a.kind)).toEqual(["tool_use", "tool_result", "text", "tool_use", "tool_use"]);
    expect(act[4]!.text).toBe("/a");
    expect(t.get(id)!.activityCount).toBe(5);
    expect(t.list()).toHaveLength(1); // nested agent doesn't create a second row
    cleanup(paths);
  });

  test("foreground completion waits for turn end so report_task's summary wins", () => {
    const { t, transitions, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "写周报" }, null);
    t.report("weekly", "开始写周报", "running");
    t.onToolResult("tu1", "Here is the raw subagent output\nmore", false, null);
    expect(t.get("weekly")!.status).toBe("running");
    t.report("weekly", "周报写好了，放在资料库", "done");
    t.finalizePending();
    const task = t.get("weekly")!;
    expect(task.status).toBe("done");
    expect(task.summary).toBe("周报写好了，放在资料库");
    expect(transitions.filter(([, k]) => k === "finished")).toHaveLength(1);
    cleanup(paths);
  });

  test("unreported completion still finishes (不漏)", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "x" }, null);
    t.onToolResult("tu1", "final answer line", true, null);
    t.finalizePending();
    expect(t.list()[0]!.status).toBe("failed");
    expect(t.list()[0]!.summary).toBe("final answer line");
    cleanup(paths);
  });

  test("background tasks finish on task_notification, not on the immediate tool_result", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "bg", run_in_background: true }, null);
    t.onTaskStarted("sdk1", "tu1", true);
    t.onToolResult("tu1", "launched", false, null);
    t.finalizePending();
    expect(t.list()[0]!.status).toBe("running");
    t.onTaskNotification("sdk1", undefined, "completed", "all good");
    t.finalizePending();
    expect(t.list()[0]!.status).toBe("done");
    expect(t.list()[0]!.sdkTaskId).toBe("sdk1");
    cleanup(paths);
  });

  test("report without a placeholder creates a row; status words normalize", () => {
    const { t, paths } = mk();
    const r = t.report("self", "我自己在查", "进行中");
    expect(r.status).toBe("running");
    t.report("self", "查完了", "completed");
    expect(t.get("self")!.status).toBe("done");
    cleanup(paths);
  });

  test("persists and orphans running tasks on restart", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "long" }, null);
    t.report("long", "跑着", "running");
    const t2 = new TaskTracker(paths.tasks, paths.taskActivity, new Bus());
    expect(t2.get("long")!.status).toBe("running");
    t2.orphanRunning();
    expect(t2.get("long")!.status).toBe("stopped");
    cleanup(paths);
  });
});
