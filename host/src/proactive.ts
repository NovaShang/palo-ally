import type { Audit } from "./audit.ts";
import type { ChatLog } from "./chat.ts";
import type { Settings } from "./config.ts";
import type { Turn } from "./conversation.ts";
import {
  PUSH_TITLE_APPROVAL,
  PUSH_TITLE_BACK,
  runawayNotice,
  approvalCardText,
  offlineNotice,
  probeTurnText,
  restartTurnText,
  scheduleTurnText,
  taskReceiptText,
  taskResultText,
} from "./copy.ts";
import type { ProbeTrigger } from "./probe.ts";
import type { Router } from "./router.ts";
import type { RuntimeState } from "./runtime.ts";
import type { Approval, Task, Watch } from "./types.ts";

const HEARTBEAT_MS = 60_000;
// After a restart, an owner message this recent with no reply is sent again.
const REDELIVER_WINDOW_MS = 30 * 60_000;

export interface ProactiveDeps {
  chat: ChatLog;
  router: Router;
  audit: Audit;
  runtime: RuntimeState;
  settings: () => Settings;
  enqueue: (turn: Turn) => void;
  hasQueued: (pred: (t: Turn) => boolean) => boolean;
  metric: (m: Record<string, unknown>) => void;
}

// Proactive is everything the assistant says without being asked: scheduled
// and probe-triggered turns, task receipts/results, approval cards, and the
// "I was offline / I restarted" notes. Anything that may interrupt the owner
// goes through the router (quiet hours, daily cap).
export class Proactive {
  private heartbeat: ReturnType<typeof setInterval> | null = null;

  constructor(private d: ProactiveDeps) {}

  // ---- turns for the main agent ----

  onSchedule(w: Watch): void {
    // One run of the same schedule waiting is enough.
    if (this.d.hasQueued((t) => t.label === w.title && t.origin === "schedule")) return;
    this.d.audit.log("schedule.fire", { id: w.id, title: w.title });
    this.d.enqueue({ text: scheduleTurnText(w), origin: "schedule", proactive: true, label: w.title, watchId: w.id });
  }

  onProbeTriggers(triggers: ProbeTrigger[]): void {
    this.d.audit.log("probe.triggered", { watches: triggers.map((t) => t.watch.id) });
    this.d.enqueue({ text: probeTurnText(triggers), origin: "probe", proactive: true, label: triggers.map((t) => t.watch.title).join(",") });
  }

  // ---- shell announcements ----

  onTaskTransition(t: Task, kind: "accepted" | "finished"): void {
    if (kind === "accepted") {
      this.d.chat.add({ role: "assistant", kind: "task", text: taskReceiptText(t), channel: "system", taskId: t.id });
      return;
    }
    const msg = this.d.chat.add({ role: "assistant", kind: "task", text: taskResultText(t), channel: "system", taskId: t.id, proactive: t.status !== "stopped" });
    if (t.status !== "stopped") void this.d.router.proactive(msg, { title: t.title });
  }

  onApprovalCreated(a: Approval): void {
    const msg = this.d.chat.add({
      role: "assistant",
      kind: "approval",
      text: approvalCardText(a),
      channel: "system",
      approvalId: a.id,
      taskId: a.taskId,
      proactive: true,
    });
    void this.d.router.proactive(msg, { title: PUSH_TITLE_APPROVAL });
  }

  // The runaway guard held a push back: say so once per window, in the chat only.
  private lastRunawayNote = 0;
  onRunaway(reason: "burst" | "duplicate"): void {
    if (reason !== "burst" || Date.now() - this.lastRunawayNote < 30 * 60_000) return;
    this.lastRunawayNote = Date.now();
    this.d.chat.add({ role: "system", kind: "notice", text: runawayNotice, channel: "system" });
  }

  // ---- liveness ----

  startHeartbeat(): void {
    this.beat();
    this.heartbeat = setInterval(() => this.beat(), HEARTBEAT_MS);
  }

  stopHeartbeat(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
  }

  private beat(): void {
    this.d.runtime.update({ lastHeartbeat: Date.now() });
  }

  // A restart cuts off work in flight. Tell the assistant what was lost and let
  // it pick things back up, rather than leaving a silent "stopped".
  recoverAfterRestart(orphaned: Task[]): void {
    const msgs = this.d.chat.recent(50);
    let lastOwner = -1;
    for (let i = msgs.length - 1; i >= 0; i--) {
      const m = msgs[i]!;
      if (m.role === "user" && (m.channel === "app" || m.channel === "cli" || m.channel === "wechat")) {
        lastOwner = i;
        break;
      }
    }
    const owner = lastOwner >= 0 ? msgs[lastOwner]! : undefined;
    const answered = msgs.slice(lastOwner + 1).some((m) => m.role === "assistant" && m.kind === "text" && !m.proactive);
    const redeliver = owner && !answered && Date.now() - owner.ts < REDELIVER_WINDOW_MS ? owner.text : undefined;
    const text = restartTurnText(orphaned.map((t) => t.title), redeliver);
    if (!text) return;
    this.d.audit.log("restart.recover", { orphaned: orphaned.length, redeliver: !!redeliver });
    this.d.enqueue({ text, origin: "system", proactive: true, label: "restart" });
  }

  detectOffline(): void {
    const last = this.d.runtime.data.lastHeartbeat;
    if (!last) return;
    const gap = Date.now() - last;
    const threshold = 2 * this.d.settings().probeIntervalMinutes * 60_000 + HEARTBEAT_MS;
    if (gap <= threshold) return;
    const msg = this.d.chat.add({
      role: "system",
      kind: "notice",
      text: offlineNotice(gap, last, Date.now(), this.d.settings().timezone),
      channel: "system",
      proactive: true,
    });
    this.d.metric({ type: "offline", gapMs: gap });
    void this.d.router.proactive(msg, { title: PUSH_TITLE_BACK });
  }
}
