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

describe("TaskTracker review fixes", () => {
  test("a reused report id after completion starts a new row", () => {
    const { t, transitions, paths } = mk();
    const first = t.report("research", "查 A", "running", "研究");
    t.report("research", "A 查完", "done");
    const second = t.report("research", "查 B", "running", "研究");
    expect(second.id).not.toBe(first.id);
    expect(t.get(first.id)!.status).toBe("done");
    expect(transitions.filter(([, k]) => k === "accepted")).toHaveLength(2);
    cleanup(paths);
  });

  test("finished placeholders are never claimed; one row per task", () => {
    const { t, paths } = mk();
    t.onToolUse("tu0", "Agent", { description: "quick lookup" }, null);
    t.onToolResult("tu0", "done", false, null);
    t.finalizePending();
    const r = t.report("hotel", "订酒店", "running", "订酒店");
    t.onToolUse("tu1", "Agent", { description: "订酒店" }, null);
    expect(t.list().filter((x) => x.title === "订酒店")).toHaveLength(1);
    expect(t.get(r.id)!.toolUseId).toBe("tu1");
    cleanup(paths);
  });

  test("moved to background: the 'moved' tool_result doesn't finish it", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "long" }, null);
    t.onTaskStarted("sdk1", "tu1", false);
    t.onTaskBackgrounded("sdk1");
    t.onToolResult("tu1", "moved to background", false, null);
    t.finalizePending();
    expect(t.list()[0]!.status).toBe("running");
    t.onTaskNotification("sdk1", "tu1", "completed", "done for real");
    t.finalizePending();
    expect(t.list()[0]!.status).toBe("done");
    cleanup(paths);
  });

  test("live() ignores needs_input and report-only rows", () => {
    const { t, paths } = mk();
    t.report("q", "等你回答", "needs_input", "问你");
    t.report("solo", "自己在做", "running", "自己");
    expect(t.live()).toHaveLength(0);
    t.onToolUse("tu9", "Agent", { description: "sub" }, null);
    expect(t.live()).toHaveLength(1);
    cleanup(paths);
  });
});

describe("TaskTracker: harness task events are authoritative", () => {
  test("rows appear without report_task; progress summaries update them; notification finishes", () => {
    const { t, transitions, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "整理周报", run_in_background: true }, null);
    t.onTaskStarted("sdk1", "tu1", true);
    t.onProgress("sdk1", "在读本周的会议纪要");
    expect(t.list()[0]).toMatchObject({ title: "整理周报", summary: "在读本周的会议纪要", status: "running", source: "auto" });
    t.onTaskNotification("sdk1", "tu1", "completed", "周报写好了");
    t.finalizePending();
    expect(t.list()[0]).toMatchObject({ status: "done", summary: "周报写好了" });
    expect(transitions.filter(([, k]) => k === "finished")).toHaveLength(1);
    cleanup(paths);
  });

  test("live() follows the harness' background set", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "a", run_in_background: true }, null);
    t.onTaskStarted("sdk1", "tu1", true);
    expect(t.live()).toHaveLength(1);
    t.setLiveSet([]); // the harness says nothing is running in the background any more
    expect(t.live()).toHaveLength(0);
    cleanup(paths);
  });

  test("report_task without an id attaches to the newest live harness row, not by title", () => {
    const { t, paths } = mk();
    t.onToolUse("tu1", "Agent", { description: "查机票" }, null);
    const r = t.report("anything", "去比价", "running", "完全不同的标题");
    expect(t.list()).toHaveLength(1);
    expect(r.toolUseId).toBe("tu1");
    expect(r.title).toBe("完全不同的标题");
    cleanup(paths);
  });
});

test("a handback note isn't shown as the result: the subagent's last words are", () => {
  const { t, paths } = mk();
  t.onToolUse("tu1", "Agent", { description: "算和", run_in_background: true }, null);
  t.onTaskStarted("sdk1", "tu1", true);
  t.onSubagentText("1 到 50 的和是 1275。\n过程：…", "tu1");
  t.onTaskNotification("sdk1", "tu1", "completed", "This agent's report was delivered to you as a message from \"abc\" (its SubagentHandback call). Read it there");
  t.finalizePending();
  expect(t.list()[0]!.summary).toBe("1 到 50 的和是 1275。");
  cleanup(paths);
});

test("the report handed back via SubagentHandback becomes the result", () => {
  const { t, paths } = mk();
  t.onToolUse("tu1", "Agent", { description: "算和", run_in_background: true }, null);
  t.onTaskStarted("sdk1", "tu1", true);
  t.onToolUse("h1", "SubagentHandback", { message: "和是 1275" }, "tu1");
  t.onTaskNotification("sdk1", "tu1", "completed", "This agent's report was delivered to you as a message (its SubagentHandback call)");
  t.finalizePending();
  expect(t.list()[0]!.summary).toBe("和是 1275");
  cleanup(paths);
});
