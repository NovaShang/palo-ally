import type { ArtifactLibrary } from "./artifacts.ts";
import type { Audit } from "./audit.ts";
import type { ChatLog } from "./chat.ts";
import type { DeliveryToolHandlers, ToolHandlers } from "./harness/types.ts";
import type { Router } from "./router.ts";
import { notifyResultText } from "./copy.ts";
import type { TaskTracker } from "./tasks.ts";
import type { HandoffTracker } from "./handoffs.ts";
import { scheduleText, type WatchStore } from "./watches.ts";
import { nextRunAt } from "./probe.ts";
import { zonedParts } from "./util.ts";
import type { WechatChannel } from "./channels/types.ts";
import type { MediaStore } from "./media.ts";
import type { Allies } from "./allies.ts";
import type { Pals } from "./pals.ts";
import { join, resolve } from "node:path";
import { mimeOf } from "./artifacts.ts";
import type { Attachment, Channel, ChatMessage, Watch } from "./types.ts";
import { t } from "./i18n/index.ts";

/** How long notify_user waits for the delivery outcome (tests shorten it). */
export const notifyWait = { ms: 7_000 };

export interface ShellToolDeps {
  tasks: TaskTracker;
  handoffs?: HandoffTracker;
  watches: WatchStore;
  artifacts: ArtifactLibrary;
  chat: ChatLog;
  router: Router;
  audit: Audit;
  wechat?: WechatChannel | null;
  media: MediaStore;
  allies?: Allies;
  pals?: Pals;
  /** Where the owner is talking from in the current turn. */
  ownerChannel: () => Channel;
  /** The assistant's working directory: relative paths resolve against it. */
  cwd: string;
  /** The owner's time zone, for times in tool replies. */
  timezone?: () => string;
  /** Opens a pairing window for one more of the owner's devices. */
  pairInvite?: () => Promise<{ link: string; expiresAt: number }>;
}

// The tools the shell gives the main agent (the in-process `paloally` MCP
// server): things only the shell can do — show tasks, keep watches, register
// artifacts, reach the owner.
export function makeShellTools(d: ShellToolDeps): ToolHandlers {
  return {
    report_task: async ({ id, summary, status, title, peer }) => {
      // The host may already follow this peer (it saw the SendMessage): name that row.
      const followed = peer ? d.handoffs?.forPeer(peer) : undefined;
      if (followed) d.tasks.adoptReportId(id, followed.taskId);
      const t = d.tasks.report(id, summary, status, title);
      d.audit.log("report_task", { id, status, summary, ...(peer ? { peer } : {}) });
      const linked = peer && d.handoffs && !followed ? `；${d.handoffs.link(t.id, peer, summary)}` : "";
      return `ok: ${t.id} ${t.status}${linked}`;
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
          return `ok: ${w.id}${t("tool.paren", { x: scheduleText(w) })}`;
        } catch (e) {
          return t("tool.notChanged", { err: e instanceof Error ? e.message : String(e) });
        }
      }
      const w = d.watches.add({ title: title ?? "", instruction: instruction ?? "", intervalMinutes: interval_minutes, at, dayOfMonth: day_of_month, kind }, "agent");
      d.audit.log("watch.registered", { id: w.id, title });
      // A new check runs on the scheduler's next minute tick.
      return `ok: ${w.id}${t("tool.paren", { x: scheduleText(w) + (w.kind === "check" ? t("tool.firstCheck") : "") })}`;
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
        return `ok: 「${w.title}」${t(w.state === "done" ? "goal.done" : w.state === "waiting" ? "goal.waiting" : w.state === "paused" ? "goal.paused" : "goal.active")} · ${w.progress ?? ""}`;
      } catch (e) {
        return t("tool.notUpdated", { err: e instanceof Error ? e.message : String(e) });
      }
    },
    remove_watch: async ({ id }) => (d.watches.remove(id) ? "ok" : "not found"),
    ...makeDeliveryTools(d),
    // Allies: the list, and a draft for the owner to send. Nothing reaches
    // another assistant without the owner's tap on the card.
    ally_list: async () => d.allies?.toolList() ?? "[]",
    ally_send: async (args) => d.allies?.toolSend(args) ?? t("ally.tool.none"),
    // Pals: the assistant talks to them with SendMessage itself; it only
    // lists them here, and proposes a new one or taking over a conversation
    // that ended (either happens on the owner's tap).
    pal_propose: async (a) => d.pals?.propose(a) ?? t("tool.noPals"),
    pal_send: async (a) => (d.pals ? await d.pals.toolSend(a) : t("tool.noPals")),
    pals_recent: async (a) => (d.pals ? await d.pals.toolRecent(a) : "{}"),
    pal_adopt: async (a) => (d.pals ? await d.pals.proposeAdopt(a) : t("tool.noPals")),
    // A new device of the owner's: the assistant hands the link over in the
    // conversation; clicked on that device, the app opens and pairs.
    pair_link: async () => {
      if (!d.pairInvite) return t("hub.err.noRemote");
      try {
        const { link, expiresAt } = await d.pairInvite();
        const minutes = Math.max(1, Math.round((expiresAt - Date.now()) / 60_000));
        return t("tool.pairLink", { minutes, link });
      } catch (e) {
        return t("tool.pairFail", { err: e instanceof Error ? e.message : String(e) });
      }
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
  if (!w.enabled) return t("goal.paused");
  const last = w.lastCheckedAt ? t("check.last", { at: at(w.lastCheckedAt) }) : t("check.never");
  const result = w.lastResult ? (w.lastResult.ok ? t("check.ok") : t("check.failed", { reason: w.lastResult.reason ?? t("check.error") })) : "";
  const next = nextRunAt(w, now);
  return [last, result, next ? t("check.next", { at: at(next) }) : ""].filter(Boolean).join(" · ");
}

/** Where a session's own tools put what they deliver: its conversation, not the assistant's. */
export interface SessionSink {
  /** The session's id: the `source` of what it publishes. */
  id: string;
  /** What the owner calls it, the title of its pushes. */
  name: () => string;
  /** A message into the session's own conversation (shown live, kept in its history). */
  card: (msg: Omit<ChatMessage, "seq" | "id" | "ts">, tool: string) => ChatMessage;
  /** A message only to push: it isn't put in the conversation. */
  notice: (text: string) => ChatMessage;
}

export type DeliveryDeps = Pick<ShellToolDeps, "artifacts" | "chat" | "router" | "audit" | "wechat" | "media" | "pals" | "ownerChannel" | "cwd"> & {
  /** Set for a session's tools; absent for the assistant's. */
  session?: SessionSink;
};

export function makeDeliveryTools(d: DeliveryDeps): DeliveryToolHandlers {
  const session = d.session;
  const source = session?.id ?? "palo";
  const pushTitle = () => (session ? { title: session.name() } : {});
  const post = (tool: string, m: Omit<ChatMessage, "seq" | "id" | "ts">): ChatMessage => (session ? session.card(m, tool) : d.chat.add(m));
  return {
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
            const a = d.artifacts.publishFile(path, { source });
            const size = a.files.find((x) => x.path === a.mainFile)?.size;
            atts.push({ id: a.id, kind: "artifact", mediaType: mimeOf(path), name: a.title, ...(size != null ? { size } : {}), ...(display ? { display } : {}) });
          }
          sent.push(path);
        } catch (e) {
          return t("tool.notSent", { file: f, err: e instanceof Error ? e.message : String(e) });
        }
      }
      const proactive = status === "proactive";
      const msg = post("SendUserFile", {
        role: "assistant",
        kind: "text",
        text: caption?.trim() ?? "",
        channel: d.ownerChannel(),
        attachments: atts,
        ...(proactive ? { proactive: true } : {}),
      });
      d.audit.log("file.sent", { files: sent, temporary: !!temporary, proactive });
      if (proactive) void d.router.proactive(msg, pushTitle());
      const target = d.ownerChannel() === "wechat" ? d.wechat?.ownerTarget?.() : null;
      if (target && d.wechat?.sendFile) {
        for (const p of sent) await d.wechat.sendFile(target, p).catch(() => false);
      }
      return temporary ? t("tool.sentTemp") : t("tool.sentSaved");
    },
    // Modelled on Claude Code's own Artifact publish: a page or document the
    // owner keeps and revisits; same path again = an update of the same one.
    Artifact: async ({ file_path, title, description, files, folder }) => {
      try {
        const a = d.artifacts.publishFile(resolve(d.cwd, file_path), { title, files, folder, source });
        post("Artifact", {
          role: "assistant",
          kind: "text",
          text: description?.trim() ?? "",
          channel: d.ownerChannel(),
          attachments: [{ id: a.id, kind: "artifact", mediaType: mimeOf(join(a.id, a.mainFile)), name: a.title, display: "render" }],
        });
        d.audit.log("artifact.published", { id: a.id, files: a.files.length });
        return t("tool.published", { title: a.title, n: a.files.length });
      } catch (e) {
        return t("tool.notPublished", { err: e instanceof Error ? e.message : String(e) });
      }
    },
    // The app copies a live clipboard message to the phone's pasteboard as it
    // arrives (and shows a card with a copy button either way). On WeChat the
    // text goes out on its own so it can be long-pressed and copied.
    copy_to_clipboard: async ({ text, label }) => {
      if (!text) return t("tool.nothingToCopy");
      const channel = d.ownerChannel();
      const l = label?.trim();
      post("copy_to_clipboard", { role: "assistant", kind: "clipboard", text, channel, ...(l ? { label: l } : {}) });
      d.audit.log("clipboard", { chars: text.length, label: l });
      const target = channel === "wechat" ? d.wechat?.ownerTarget?.() : null;
      if (target && d.wechat) await d.wechat.reply(target, text).catch(() => {});
      return t("tool.copied");
    },
    pals_list: async () => (d.pals ? await d.pals.toolList() : "{}"),
    notify_user: async ({ text, urgent }) => {
      // A session's push isn't a message in anyone's conversation: it opens the session.
      const msg = session ? session.notice(text) : d.chat.add({ role: "assistant", kind: "notice", text, channel: "system", proactive: true });
      // Wait for the real outcome (pushes give up after ~5 s), but never longer
      // than notifyWait: a hung pusher must not stall the turn.
      const delivery = d.router.proactive(msg, { urgent, ...pushTitle() });
      const r = await Promise.race([delivery, new Promise<null>((res) => setTimeout(() => res(null), notifyWait.ms))]);
      return notifyResultText(r);
    },
  };
}
