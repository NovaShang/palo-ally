import { t } from "./i18n/index.ts";
import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { TaskTracker } from "./tasks.ts";
import type { Pal } from "./types.ts";
import { newId, readJson, writeJson } from "./util.ts";

// HandoffTracker: 任务交出去了，外壳负责盯进度 (PRD §6.2).
//
// When the assistant gives an agent work (pal_send), the owner sees it move
// in the app without the assistant narrating it: a task row, kept by the
// agent's own events, nothing read from Claude Code's files:
//  - pals.updated: the agent's line in the list (it works, it waits on the
//    owner, its turn is over, it's asleep, stopped or archived);
//  - palo_send: its words back to the assistant.
// It's done when it has replied and its turn is over. The assistant tells the
// owner the result; if it says nothing for a few minutes, the host does,
// briefly. What an agent asks the owner is on their phone already (its cards)
// or comes through the assistant. Words to a session that isn't an agent
// (SendMessage) are not followed.

// ---- what counts as a handoff ----

// A message that asks for something (vs. thanks, results, acks).
const ASK = /\b(please|pls|could you|can you|would you|let me know|tell me|ping me|when it'?s (done|live|fixed))\b|请|帮我|帮忙|麻烦|能不能|能否|需要你|告诉我|跟我说|回我|修一下|看一下|查一下/i;
const ACK = /^\s*(thanks|thank you|thx|got it|ok(ay)?|noted|ack|收到|好的|好嘞|谢谢|明白)[\s.!。！,，]*$/i;

export function isRequest(message: string): boolean {
  const m = message.trim();
  return !!m && !ACK.test(m) && ASK.test(m);
}

// The agent asks the owner something (through the assistant) rather than reporting back.
const QUESTION = /[?？]\s*$|要不要|选哪|哪个好|请决定|等你决定|需要.*决定|which (one|option)|should i|do you want/im;

export function isQuestion(text: string): boolean {
  return QUESTION.test(text.trim());
}

// ---- tracker ----

export type HandoffState = "working" | "waiting" | "asking" | "idle" | "closed";

export interface Handoff {
  id: string;
  taskId: string;
  /** Who has it: the agent's id (`sessionId` alone in a file from before: it's looked up at start). */
  peer: { name: string; pal?: string; sessionId?: string };
  createdAt: number;
  state: HandoffState;
  lastLine: string;
  lineBefore?: string; // its last words when it was given the work (not about this)
  idleSince?: number; // its turn is over since then, with nothing reported (or a question asked)
  lastReplyAt?: number;
  question?: boolean; // its last reply asks the owner something
  doneAt?: number; // it reported back and stopped; the assistant should relay it
  relayDueAt?: number; // no relay from the assistant by then: tell the owner briefly
}

export interface HandoffDeps {
  path: string; // state file
  tasks: TaskTracker;
  bus: Pick<Bus, "on">;
  /** An agent by its id, its session's id or its name. */
  agent: (key: string) => Pal | undefined;
  /** What an agent that waits on the owner asks them. */
  waitsFor?: (pal: string) => string | undefined;
  // tell the owner (chat card + push): finished work went unrelayed. A short
  // line in the owner's language only, never the agent's raw text.
  notify: (taskId: string, title: string, body: string) => void;
  // when the assistant last said something to the owner (0 if never)
  assistantSpokeAt?: () => number;
  audit: Audit;
  now?: () => number;
}

const MIN = 60_000;
const IDLE_GIVE_UP_MS = 24 * 3600_000; // stopped this long with nothing more: no longer followed
const RELAY_GRACE_MS = 5 * MIN; // the assistant relays a result itself; fall back after this

export class HandoffTracker {
  private handoffs: Handoff[];
  private timer: ReturnType<typeof setInterval> | null = null;
  private off: () => void;

  constructor(private d: HandoffDeps) {
    this.handoffs = readJson<{ handoffs?: Handoff[] }>(d.path, {}).handoffs ?? [];
    this.off = d.bus.on((event) => {
      if (event === "pals.updated" && this.open().length) this.checkAll();
    });
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  open(): Handoff[] {
    return this.handoffs.filter((h) => h.state !== "closed");
  }

  /** The open handoff to the agent report_task's `peer` names, if any. */
  forPeer(to: string): Handoff | undefined {
    const pal = this.agent(to);
    return pal && this.forAgent(pal.id);
  }

  forTask(taskId: string): Handoff | undefined {
    return this.open().find((h) => h.taskId === taskId);
  }

  private forAgent(pal: string): Handoff | undefined {
    return this.open().find((h) => h.peer.pal === pal);
  }

  // A SendMessage-style name ("name [ref]") is the name.
  private agent(to: string): Pal | undefined {
    return this.d.agent(to.replace(/\s*\[[^\]]*\]\s*$/, ""));
  }

  // Work the assistant is waiting on: keeps native compaction from firing mid-handoff.
  inFlight(): boolean {
    return this.open().some((h) => !h.idleSince);
  }

  // ---- what goes out, what comes back ----

  /** pal_send went in. */
  sent(pal: Pal, text: string): void {
    const h = this.forAgent(pal.id);
    if (!h) {
      if (!isRequest(text)) return;
      // The assistant names the row with report_task(peer, title); until then a
      // neutral title, never the first line of an (often English) message.
      const title = t("handoff.title", { name: pal.name });
      const task = this.d.tasks.openPeer(title, t("handoff.waitStart"), pal.name);
      this.handoffs.push(this.newHandoff(task.id, pal));
      this.save();
      this.d.audit.log("handoff.opened", { taskId: task.id, peer: pal.name, title });
      return;
    }
    // More work for the same agent (its earlier reply isn't about this), or
    // the owner's answer relayed back: it's working again.
    if (h.question || isRequest(text)) h.lastReplyAt = undefined;
    h.question = undefined;
    h.idleSince = undefined;
    h.state = "working";
    this.d.tasks.updatePeer(h.taskId, "running", h.lastLine || t("handoff.working"));
    this.save();
  }

  /** palo_send came in: the agent's words to the assistant. */
  replied(pal: Pal, text: string): void {
    const h = this.forAgent(pal.id);
    if (!h) return;
    h.lastReplyAt = this.now();
    h.question = isQuestion(text);
    h.idleSince = undefined;
    this.check(h, pal);
    this.save();
  }

  // report_task(peer=…): the assistant links a row to an agent explicitly.
  // Another session's row only says whose it is: it's the assistant's to end.
  link(taskId: string, to: string): string {
    const pal = this.agent(to);
    if (!pal) {
      this.d.tasks.setPeer(taskId, to);
      return t("handoff.noPeer", { to });
    }
    this.d.tasks.setPeer(taskId, pal.name);
    const h = this.forTask(taskId);
    if (h) h.peer = peerRef(pal);
    else {
      this.handoffs.push(this.newHandoff(taskId, pal));
      this.d.audit.log("handoff.linked", { taskId, peer: pal.name });
    }
    this.save();
    return t("handoff.following", { name: pal.name });
  }

  private newHandoff(taskId: string, pal: Pal): Handoff {
    return {
      id: newId("h_"),
      taskId,
      peer: peerRef(pal),
      createdAt: this.now(),
      state: "working",
      lastLine: "",
      ...(pal.lastLine ? { lineBefore: pal.lastLine } : {}),
    };
  }

  // ---- checking ----

  start(): void {
    if (this.timer) return;
    // Open ones from before the host followed agents alone: an agent's goes
    // on, another session's ends here.
    for (const h of this.open()) {
      if (h.peer.pal) continue;
      const pal = h.peer.sessionId ? this.d.agent(h.peer.sessionId) : undefined;
      if (pal) h.peer = peerRef(pal);
      else this.settle(h, "stopped", t("handoff.notAgent"), "not an agent");
      this.save();
    }
    this.timer = setInterval(() => this.tick(), MIN);
    (this.timer as any).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.off();
  }

  tick(): void {
    if (this.relayFallbacks(this.now())) this.save();
    this.checkAll();
  }

  private checkAll(): void {
    let changed = false;
    for (const h of this.open()) if (h.peer.pal && this.check(h, this.d.agent(h.peer.pal))) changed = true;
    if (changed) this.save();
  }

  // Brings one handoff up to where its agent is; returns true if anything changed.
  private check(h: Handoff, pal: Pal | undefined): boolean {
    const before = JSON.stringify(h);
    this.follow(h, pal);
    return JSON.stringify(h) !== before;
  }

  private follow(h: Handoff, pal: Pal | undefined): void {
    // The owner dismissed the row, or the assistant closed it with report_task.
    const task = this.d.tasks.get(h.taskId);
    if (!task || ["done", "failed", "stopped"].includes(task.status)) return this.close(h, "row closed");
    const reported = !!h.lastReplyAt && !h.question;
    if (!pal) {
      // Archived. With a reply in hand it finished; otherwise it just stopped.
      return this.settle(h, reported ? "done" : "stopped", reported ? h.lastLine || t("handoff.done") : t("handoff.endedSilent"), "archived");
    }
    switch (pal.status) {
      case "waiting": // its card is on the owner's phone already
        h.idleSince = undefined;
        return this.show(h, "waiting", "needs_input", t("handoff.waitApp", { what: this.d.waitsFor?.(pal.id) ?? t("handoff.needConfirm") }));
      case "busy":
        // Asked, stopped, and at work again: it has its answer (the owner may have given it themselves).
        if (h.idleSince) {
          if (h.question) h.lastReplyAt = undefined;
          h.question = undefined;
          h.idleSince = undefined;
        }
        return this.working(h, pal);
      case "idle":
      case "asleep": {
        if (reported) {
          // It reported back and stopped: done.
          this.settle(h, "done", t("handoff.done"), "replied");
          this.d.audit.log("handoff.done", { taskId: h.taskId, peer: h.peer.name });
          h.doneAt = this.now();
          h.relayDueAt = h.doneAt + RELAY_GRACE_MS;
          return;
        }
        if (pal.status === "idle" && pal.tasksRunning) return this.working(h, pal); // its background tasks go on
        h.idleSince ??= this.now();
        if (this.now() - h.idleSince >= IDLE_GIVE_UP_MS) return this.settle(h, "stopped", t("handoff.gaveUp"), "gave up");
        if (h.question) return this.show(h, "asking", "needs_input", t("handoff.asking"));
        if (pal.status === "asleep") return this.settle(h, "stopped", t("handoff.stopped"), "asleep without a reply");
        return this.show(h, "idle", "running", t("handoff.stopped"));
      }
      case "stopped":
        // Stopped for good, and it says why (between two processes it doesn't): couldn't start, open in a terminal.
        if (pal.note) this.settle(h, reported ? "done" : "stopped", reported ? t("handoff.done") : t("handoff.endedSilent"), "stopped");
        return;
    }
  }

  private working(h: Handoff, pal: Pal): void {
    if (h.question) return this.show(h, "asking", "needs_input", t("handoff.asking"));
    h.idleSince = undefined;
    const words = pal.lastLine && pal.lastLine !== h.lineBefore ? pal.lastLine : "";
    this.show(h, "working", "running", (h.lastReplyAt ? t("handoff.repliedBusy") : words) || t("handoff.working"));
  }

  private show(h: Handoff, state: HandoffState, status: "running" | "needs_input", line: string): void {
    h.state = state;
    h.lastLine = line;
    this.d.tasks.updatePeer(h.taskId, status, line);
  }

  private settle(h: Handoff, status: "done" | "stopped", line: string, why: string): void {
    h.lastLine = line;
    this.d.tasks.settlePeer(h.taskId, status, line);
    this.close(h, why);
  }

  private close(h: Handoff, why: string): void {
    h.state = "closed";
    this.d.audit.log("handoff.closed", { taskId: h.taskId, peer: h.peer.name, why });
  }

  // An agent finished: the assistant normally tells the owner in its own words.
  // If it hasn't said anything to the owner a few minutes later, a short line.
  // (It may have while the agent's turn was still winding down: what counts is
  // since the agent's reply.)
  private relayFallbacks(now: number): boolean {
    let changed = false;
    for (const h of this.handoffs) {
      if (!h.relayDueAt || !h.doneAt) continue;
      const spoke = this.d.assistantSpokeAt?.() ?? 0;
      if (spoke > (h.lastReplyAt ?? h.doneAt)) {
        h.relayDueAt = undefined;
        changed = true;
      } else if (now >= h.relayDueAt) {
        h.relayDueAt = undefined;
        changed = true;
        const title = this.d.tasks.get(h.taskId)?.title ?? t("handoff.title", { name: h.peer.name });
        this.d.audit.log("handoff.relay_fallback", { taskId: h.taskId, peer: h.peer.name });
        this.d.notify(h.taskId, t("handoff.doneTitle"), t("handoff.doneBody", { title }));
      }
    }
    return changed;
  }

  private save(): void {
    // Keep a month of closed ones for the record.
    const cutoff = this.now() - 30 * 86400_000;
    this.handoffs = this.handoffs.filter((h) => h.state !== "closed" || (h.doneAt ?? h.createdAt) > cutoff);
    writeJson(this.d.path, { handoffs: this.handoffs });
  }
}

function peerRef(p: Pal): Handoff["peer"] {
  return { name: p.name, pal: p.id, sessionId: p.sessionId };
}
