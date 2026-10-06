import type { ArtifactLibrary } from "./artifacts.ts";
import type { Audit } from "./audit.ts";
import type { ChatLog } from "./chat.ts";
import type { ToolHandlers } from "./harness/types.ts";
import type { Router } from "./router.ts";
import { notifyResultText } from "./copy.ts";
import type { TaskTracker } from "./tasks.ts";
import { scheduleText, type WatchStore } from "./watches.ts";
import { nextRunAt } from "./probe.ts";
import { zonedParts } from "./util.ts";
import type { WechatChannel } from "./channels/types.ts";
import type { MediaStore } from "./media.ts";
import { join, resolve } from "node:path";
import { mimeOf } from "./artifacts.ts";
import type { Attachment, Channel, Watch } from "./types.ts";

/** How long notify_user waits for the delivery outcome (tests shorten it). */
export const notifyWait = { ms: 7_000 };

export interface ShellToolDeps {
  tasks: TaskTracker;
  watches: WatchStore;
  artifacts: ArtifactLibrary;
  chat: ChatLog;
  router: Router;
  audit: Audit;
  wechat?: WechatChannel | null;
  media: MediaStore;
  /** Where the owner is talking from in the current turn. */
  ownerChannel: () => Channel;
  /** The assistant's working directory: relative paths resolve against it. */
  cwd: string;
  /** The owner's time zone, for times in tool replies. */
  timezone?: () => string;
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
    register_watch: async ({ id, title, instruction, interval_minutes, at, day_of_month, kind }) => {
      if (id) {
        // Change an existing goal's timing or instruction in place: its
        // progress and history stay. day_of_month 0 clears the monthly day.
        const patch: Partial<Watch> = { title, instruction, kind };
        if (interval_minutes !== undefined) patch.intervalMinutes = interval_minutes;
        if (at !== undefined) patch.at = at;
        if (day_of_month !== undefined) patch.dayOfMonth = day_of_month;
        for (const k of Object.keys(patch) as (keyof Watch)[]) if (patch[k] === undefined) delete patch[k];
        try {
          const w = d.watches.update(id, patch);
          d.audit.log("watch.updated", { id: w.id, title: w.title });
          return `ok: ${w.id}（${scheduleText(w)}）`;
        } catch (e) {
          return `没改：${e instanceof Error ? e.message : e}`;
        }
      }
      const w = d.watches.add({ title: title ?? "", instruction: instruction ?? "", intervalMinutes: interval_minutes, at, dayOfMonth: day_of_month, kind }, "agent");
      d.audit.log("watch.registered", { id: w.id, title });
      // A new check runs on the scheduler's next minute tick.
      return `ok: ${w.id}（${scheduleText(w)}${w.kind === "check" ? " · 一分钟内先查第一次" : ""}）`;
    },
    list_watches: async () =>
      JSON.stringify(
        d.watches.list().map((w) => ({
          id: w.id,
          title: w.title,
          kind: w.kind,
          state: w.state,
          progress: w.progress,
          instruction: w.instruction,
          intervalMinutes: w.intervalMinutes,
          at: w.at,
          dayOfMonth: w.dayOfMonth,
          when: scheduleText(w),
          ...(w.kind === "check" ? { health: checkHealth(w, d.timezone?.() ?? "UTC") } : {}),
        })),
      ),
    update_goal: async ({ id, progress, state, ratio, outcome }) => {
      try {
        const w = d.watches.progress(id, progress, { state, ratio, outcome });
        d.audit.log("goal.progress", { id, state: w.state });
        return `ok: 「${w.title}」${w.state === "done" ? "已完成" : w.state === "waiting" ? "等主人" : w.state === "paused" ? "已暂停" : "进行中"} · ${w.progress ?? ""}`;
      } catch (e) {
        return `没更新：${e instanceof Error ? e.message : e}`;
      }
    },
    remove_watch: async ({ id }) => (d.watches.remove(id) ? "ok" : "not found"),
    // Modelled on Claude Code's own SendUserFile (same parameters, plus
    // `temporary`): each file is kept in the library unless the assistant is
    // sure it's throwaway, shown in the conversation as a card, pushed when
    // proactive, and sent to WeChat when the owner is there.
    SendUserFile: async ({ files, caption, status, display, temporary }) => {
      const atts: Attachment[] = [];
      const sent: string[] = [];
      for (const f of files) {
        const path = resolve(d.cwd, f);
        try {
          if (temporary) {
            atts.push({ ...d.media.saveFile(path), ...(display ? { display } : {}) });
          } else {
            const a = d.artifacts.publishFile(path);
            const size = a.files.find((x) => x.path === a.mainFile)?.size;
            atts.push({ id: a.id, kind: "artifact", mediaType: mimeOf(path), name: a.title, ...(size != null ? { size } : {}), ...(display ? { display } : {}) });
          }
          sent.push(path);
        } catch (e) {
          return `没发出去（${f}）：${e instanceof Error ? e.message : e}`;
        }
      }
      const proactive = status === "proactive";
      const msg = d.chat.add({
        role: "assistant",
        kind: "text",
        text: caption?.trim() ?? "",
        channel: d.ownerChannel(),
        attachments: atts,
        ...(proactive ? { proactive: true } : {}),
      });
      d.audit.log("file.sent", { files: sent, temporary: !!temporary, proactive });
      if (proactive) void d.router.proactive(msg);
      const target = d.ownerChannel() === "wechat" ? d.wechat?.ownerTarget?.() : null;
      if (target && d.wechat?.sendFile) {
        for (const p of sent) await d.wechat.sendFile(target, p).catch(() => false);
      }
      return temporary ? "已发给主人" : "已发给主人，也存进了产出物库";
    },
    // Modelled on Claude Code's own Artifact publish: a page or document the
    // owner keeps and revisits; same path again = an update of the same one.
    Artifact: async ({ file_path, title, description, files }) => {
      try {
        const a = d.artifacts.publishFile(resolve(d.cwd, file_path), { title, files });
        d.chat.add({
          role: "assistant",
          kind: "text",
          text: description?.trim() ?? "",
          channel: d.ownerChannel(),
          attachments: [{ id: a.id, kind: "artifact", mediaType: mimeOf(join(a.id, a.mainFile)), name: a.title, display: "render" }],
        });
        d.audit.log("artifact.published", { id: a.id, files: a.files.length });
        return `已发布：${a.title}（${a.files.length} 个文件，在主人的产出物库里）`;
      } catch (e) {
        return `没发布成功：${e instanceof Error ? e.message : e}`;
      }
    },
    // The app copies a live clipboard message to the phone's pasteboard as it
    // arrives (and shows a card with a copy button either way). On WeChat the
    // text goes out on its own so it can be long-pressed and copied.
    copy_to_clipboard: async ({ text, label }) => {
      if (!text) return "没有要复制的内容";
      const channel = d.ownerChannel();
      const l = label?.trim();
      d.chat.add({ role: "assistant", kind: "clipboard", text, channel, ...(l ? { label: l } : {}) });
      d.audit.log("clipboard", { chars: text.length, label: l });
      const target = channel === "wechat" ? d.wechat?.ownerTarget?.() : null;
      if (target && d.wechat) await d.wechat.reply(target, text).catch(() => {});
      return "已放到主人的手机剪贴板（若主人当时不在 App 里，对话里有一键复制的卡片）";
    },
    notify_user: async ({ text, urgent }) => {
      const msg = d.chat.add({ role: "assistant", kind: "notice", text, channel: "system", proactive: true });
      // Wait for the real outcome (pushes give up after ~5 s), but never longer
      // than notifyWait: a hung pusher must not stall the turn.
      const delivery = d.router.proactive(msg, { urgent });
      const r = await Promise.race([delivery, new Promise<null>((res) => setTimeout(() => res(null), notifyWait.ms))]);
      return notifyResultText(r);
    },
  };
}

// One line on how a check watch is doing: when it last ran, how that went,
// and when it runs next. Skips and errors show here instead of going quiet.
function checkHealth(w: Watch, tz: string, now = Date.now()): string {
  const at = (ms: number) => {
    const p = zonedParts(ms, tz);
    return `${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
  };
  if (!w.enabled) return "已暂停";
  const last = w.lastCheckedAt ? `上次 ${at(w.lastCheckedAt)}` : "还没查过";
  const result = w.lastResult ? (w.lastResult.ok ? "正常" : `没查成：${w.lastResult.reason ?? "出错"}`) : "";
  const next = nextRunAt(w, now);
  return [last, result, next ? `下次约 ${at(next)}` : ""].filter(Boolean).join(" · ");
}
