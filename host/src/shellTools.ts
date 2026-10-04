import type { ArtifactLibrary } from "./artifacts.ts";
import type { Audit } from "./audit.ts";
import type { ChatLog } from "./chat.ts";
import type { ToolHandlers } from "./harness/types.ts";
import type { Router } from "./router.ts";
import type { TaskTracker } from "./tasks.ts";
import type { WatchStore } from "./watches.ts";

export interface ShellToolDeps {
  tasks: TaskTracker;
  watches: WatchStore;
  artifacts: ArtifactLibrary;
  chat: ChatLog;
  router: Router;
  audit: Audit;
}

// The tools the shell gives the main agent (the in-process `paloally` MCP
// server): things only the shell can do — show tasks, keep watches, register
// artifacts, reach the owner.
export function makeShellTools(d: ShellToolDeps): ToolHandlers {
  return {
    report_task: async ({ id, summary, status, title }) => {
      const t = d.tasks.report(id, summary, status, title);
      d.audit.log("report_task", { id, status, summary });
      return `ok: ${t.id} ${t.status}`;
    },
    register_watch: async ({ title, instruction, interval_minutes, at, kind }) => {
      const w = d.watches.add({ title, instruction, intervalMinutes: interval_minutes, at, kind }, "agent");
      d.audit.log("watch.registered", { id: w.id, title });
      return `ok: ${w.id}（${w.kind === "check" ? `每 ${w.intervalMinutes} 分钟检查` : `定时 ${w.at?.join(",") ?? `每 ${w.intervalMinutes} 分钟`}`}）`;
    },
    list_watches: async () =>
      JSON.stringify(
        d.watches.list().map((w) => ({ id: w.id, title: w.title, kind: w.kind, enabled: w.enabled, instruction: w.instruction, intervalMinutes: w.intervalMinutes, at: w.at })),
      ),
    remove_watch: async ({ id }) => (d.watches.remove(id) ? "ok" : "not found"),
    publish_artifact: async ({ slug, title, main_file, type, pinned }) => {
      const a = d.artifacts.publish(slug, title, main_file, type, pinned);
      return `ok: ${a.id}（${a.files.length} 个文件）`;
    },
    notify_user: async ({ text, urgent }) => {
      const msg = d.chat.add({ role: "assistant", kind: "notice", text, channel: "system", proactive: true });
      // Decide synchronously, deliver in the background: a slow push must never block the turn.
      const delivery = d.router.proactive(msg, { urgent });
      const r = await Promise.race([delivery, new Promise<null>((res) => setTimeout(() => res(null), 1500))]);
      if (r?.suppressed) return `已记入对话（${r.suppressed === "quiet" ? "免打扰时段" : "短时间内推送太多"}，未推送）`;
      return "已推送";
    },
  };
}
