import { t } from "./i18n/index.ts";
import { existsSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Audit } from "./audit.ts";
import type { TaskTracker } from "./tasks.ts";
import { claudeConfigDir, transcriptPath } from "./harness/claude/paths.ts";
import { type PeerSession, SessionRegistry } from "./harness/claude/registry.ts";
import { HOME_TO, type TailSummary, readHead, readTail, summarizeTail, tailLine as firstLine } from "./harness/claude/transcript.ts";

// (Moved under harness/claude/; kept here for the modules and tests that import them from here.)
export { claudeConfigDir, transcriptPath, SessionRegistry, readHead, readTail, summarizeTail };
export type { PeerSession, TailSummary };
import { newId, pidAlive, readJson, truncate, writeJson } from "./util.ts";

// HandoffTracker: 任务交出去了，外壳负责盯进度 (PRD §6.2).
//
// When the main assistant hands work to another Claude Code session on this
// machine (SendMessage to a peer), the owner should see that work move in the
// app without the assistant narrating it. The host links a task row to the
// peer and checks on it itself, reading only what the harness already keeps:
//  - ~/.claude/sessions/<pid>.json: Claude Code's registry of live sessions
//    (name, status busy / idle / waiting + what it waits for);
//  - ~/.claude/projects/<cwd>/<sessionId>.jsonl: that session's transcript
//    (its latest words, an open AskUserQuestion, its replies to the assistant).
// Both are read, never written. Questions for the owner go through the
// assistant (the peer messages it; it asks with its choice card); if a peer
// asks in its own terminal anyway, the owner gets a push to go answer there.


// ---- what counts as a handoff ----

// A message that asks the peer to do something (vs. thanks, results, acks).
const ASK = /\b(please|pls|could you|can you|would you|let me know|tell me|ping me|when it'?s (done|live|fixed))\b|请|帮我|帮忙|麻烦|能不能|能否|需要你|告诉我|跟我说|回我|修一下|看一下|查一下/i;
const ACK = /^\s*(thanks|thank you|thx|got it|ok(ay)?|noted|ack|收到|好的|好嘞|谢谢|明白)[\s.!。！,，]*$/i;

export function isRequest(message: string): boolean {
  const m = message.trim();
  return !!m && !ACK.test(m) && ASK.test(m);
}

// The peer asks the owner something (through the assistant) rather than reporting back.
const QUESTION = /[?？]\s*$|要不要|选哪|哪个好|请决定|等你决定|需要.*决定|which (one|option)|should i|do you want/im;

export function isQuestion(text: string): boolean {
  return QUESTION.test(text.trim());
}

// ---- tracker ----

export type HandoffState = "working" | "waiting" | "asking" | "idle" | "closed";

export interface Handoff {
  id: string;
  taskId: string;
  peer: { name: string; pid?: number; sessionId?: string; cwd?: string; tmux?: string };
  request: string; // first line of what was asked
  createdAt: number;
  state: HandoffState;
  lastLine: string;
  checkedAt: number;
  nextCheckAt: number;
  idleSince?: number;
  lastReplyAt?: number;
  notifiedKey?: string; // the waiting episode the owner was already told about
  doneAt?: number; // when the peer reported back; the assistant should relay it
  relayDueAt?: number; // no relay from the assistant by then: tell the owner briefly
  seen?: { size?: number; mtime?: number; statusUpdatedAt?: number; status?: string };
}

export interface HandoffDeps {
  path: string; // state file
  claudeDir: string;
  homeCwd: () => string;
  selfSessionId: () => string | undefined;
  tasks: TaskTracker;
  // tell the owner (chat card + push): a peer is blocked on them, or its
  // finished work went unrelayed. Short Chinese only, never raw peer text.
  notify: (taskId: string, title: string, body: string) => void;
  // when the assistant last said something to the owner (0 if never)
  assistantSpokeAt?: () => number;
  audit: Audit;
  log: (s: string) => void;
  now?: () => number;
  registry?: SessionRegistry;
  /** A Pal (the host runs it): its cards reach the owner's phone by themselves. */
  isPal?: (sessionId: string) => boolean;
}

const MIN = 60_000;
const CHECK_WORKING_MS = 2 * MIN;
const CHECK_WAITING_MS = 5 * MIN;
const IDLE_NOTE_MS = 2 * 3600_000; // idle this long with no reply: say so, check rarely
const IDLE_GIVE_UP_MS = 24 * 3600_000; // then stop following it
const RELAY_GRACE_MS = 5 * MIN; // the assistant relays a peer's result itself; fall back after this

export class HandoffTracker {
  private handoffs: Handoff[];
  private homePids: Set<number>; // the assistant's own sessions (its pid changes with restarts)
  private pendingSends = new Map<string, { to: string; message: string }>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private registry: SessionRegistry;

  constructor(private d: HandoffDeps) {
    const saved = readJson<{ handoffs: Handoff[]; homePids: number[] }>(d.path, { handoffs: [], homePids: [] });
    this.handoffs = saved.handoffs;
    this.homePids = new Set(saved.homePids);
    this.registry = d.registry ?? new SessionRegistry(join(d.claudeDir, "sessions"));
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  open(): Handoff[] {
    return this.handoffs.filter((h) => h.state !== "closed");
  }

  // The open handoff to the session a SendMessage `to` names, if any.
  forPeer(to: string): Handoff | undefined {
    const peer = this.registry.resolve(to);
    return peer ? this.open().find((h) => h.peer.sessionId === peer.sessionId) : undefined;
  }

  forTask(taskId: string): Handoff | undefined {
    return this.handoffs.find((h) => h.taskId === taskId && h.state !== "closed");
  }

  // Work the assistant is waiting on: keeps native compaction from firing mid-handoff.
  inFlight(): boolean {
    return this.open().some((h) => h.state !== "idle");
  }

  // ---- inputs from the harness stream ----

  onSend(toolUseId: string, input: Record<string, unknown>): void {
    const to = typeof input.to === "string" ? input.to : "";
    const message = typeof input.message === "string" ? input.message : "";
    if (to && message) this.pendingSends.set(toolUseId, { to, message });
  }

  onSendResult(toolUseId: string, content: string, isError: boolean): void {
    const send = this.pendingSends.get(toolUseId);
    if (!send) return;
    this.pendingSends.delete(toolUseId);
    if (isError || /"success"\s*:\s*false/.test(content) || /^(没送|Not sent)/.test(content)) return;
    const peer = this.registry.resolve(send.to);
    if (!peer || this.isHome(peer)) return;
    const existing = this.open().find((h) => h.peer.sessionId === peer.sessionId);
    if (existing) {
      // More work for the same peer, or the owner's answer relayed back: it's working again.
      existing.state = "working";
      existing.idleSince = undefined;
      existing.nextCheckAt = this.now() + CHECK_WORKING_MS;
      this.d.tasks.updatePeer(existing.taskId, "running", existing.lastLine || t("handoff.working"));
      this.save();
      return;
    }
    if (!isRequest(send.message)) return;
    this.start(peer, send.message);
  }

  // report_task(peer=…): the assistant links a row to a peer explicitly.
  link(taskId: string, to: string, request = ""): string {
    const peer = this.registry.resolve(to);
    if (!peer) return t("handoff.noPeer", { to });
    if (this.isHome(peer)) return t("handoff.self");
    const h = this.forTask(taskId);
    if (h) {
      h.peer = peerRef(peer);
      this.save();
      return t("handoff.following", { name: peer.name });
    }
    this.handoffs.push(this.newHandoff(taskId, peer, request));
    this.d.tasks.setPeer(taskId, peer.name);
    this.save();
    this.d.audit.log("handoff.linked", { taskId, peer: peer.name });
    return t("handoff.following", { name: peer.name });
  }

  private start(peer: PeerSession, message: string): void {
    // The assistant names the row with report_task(peer, title); until then a
    // neutral title, never the first line of an (often English) peer message.
    const title = t("handoff.title", { name: peer.name });
    const task = this.d.tasks.openPeer(title, t("handoff.waitStart"), peer.name);
    const h = this.newHandoff(task.id, peer, firstLine(message));
    this.handoffs.push(h);
    this.save();
    this.d.audit.log("handoff.opened", { taskId: task.id, peer: peer.name, title });
  }

  private newHandoff(taskId: string, peer: PeerSession, request: string): Handoff {
    const now = this.now();
    return {
      id: newId("h_"),
      taskId,
      peer: peerRef(peer),
      request,
      createdAt: now,
      state: "working",
      lastLine: "",
      checkedAt: 0,
      nextCheckAt: now + CHECK_WORKING_MS,
    };
  }

  // ---- checking ----

  startTimer(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.tick(), MIN);
    (this.timer as any).unref?.();
    setTimeout(() => this.tick(), 10_000).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  tick(): void {
    const now = this.now();
    if (this.relayFallbacks(now)) this.save();
    const open = this.open();
    if (!open.length) return;
    let sessions: PeerSession[];
    try {
      sessions = this.registry.list();
    } catch (e) {
      this.d.log(`handoff: can't read the session registry: ${e}`);
      return;
    }
    this.rememberHome(sessions);
    let changed = false;
    for (const h of open) {
      try {
        if (this.check(h, sessions, now)) changed = true;
      } catch (e) {
        this.d.log(`handoff ${h.id}: check failed: ${e}`);
      }
    }
    if (changed) this.save();
  }

  // check updates one handoff; returns true if anything changed.
  check(h: Handoff, sessions: PeerSession[], now = this.now()): boolean {
    // The owner dismissed the row, or the assistant closed it with report_task.
    const task = this.d.tasks.get(h.taskId);
    if (!task || ["done", "failed", "stopped"].includes(task.status)) return this.close(h, "row closed");
    if (now < h.nextCheckAt) return false;
    h.checkedAt = now;

    const peer =
      sessions.find((s) => s.sessionId === h.peer.sessionId) ??
      (h.peer.pid ? sessions.find((s) => s.pid === h.peer.pid) : undefined);
    if (!peer) {
      // The session ended. With a reply in hand it finished; otherwise it just stopped.
      if (h.lastReplyAt) this.d.tasks.settlePeer(h.taskId, "done", h.lastLine || t("handoff.done"));
      else this.d.tasks.settlePeer(h.taskId, "stopped", t("handoff.endedSilent"));
      return this.close(h, "session ended");
    }
    h.peer = peerRef(peer);

    // Cheap signals first: the registry status and the transcript's size.
    const tpath = transcriptPath(this.d.claudeDir, peer.cwd, peer.sessionId);
    let size: number | undefined;
    let mtime: number | undefined;
    try {
      const st = statSync(tpath);
      size = st.size;
      mtime = st.mtimeMs;
    } catch {
      // no transcript (yet): status alone
    }
    const seen = h.seen ?? {};
    const same =
      seen.size === size && seen.mtime === mtime && seen.statusUpdatedAt === peer.statusUpdatedAt && seen.status === peer.status;
    h.seen = { size, mtime, statusUpdatedAt: peer.statusUpdatedAt, status: peer.status };
    // Unchanged and not idle: nothing to read. (Idle ones still age toward "停下了".)
    if (same && peer.status !== "idle" && peer.status !== "shell") {
      h.nextCheckAt = now + this.interval(h, now);
      return true;
    }

    const tail = size !== undefined ? summarizeTail(readTail(tpath)) : { replies: [] as TailSummary["replies"] };
    const replies = tail.replies.filter((r) => this.isHomeTarget(r.to, sessions) && r.at >= h.createdAt);
    const reply = replies.at(-1);
    if (reply && (!h.lastReplyAt || reply.at > h.lastReplyAt)) h.lastReplyAt = reply.at;
    const before = { state: h.state, line: h.lastLine };

    if (peer.status === "waiting") {
      // Blocked on the owner: a Pal's card is on the phone already; any
      // other session asks in its own terminal.
      const pal = this.d.isPal?.(peer.sessionId) ?? false;
      const what = tail.pendingQuestion?.text || peer.waitingFor || t("handoff.needConfirm");
      h.state = "waiting";
      h.lastLine = t(pal ? "handoff.waitApp" : "handoff.waitComputer", { what });
      const key = tail.pendingQuestion?.id ?? String(peer.statusUpdatedAt ?? "");
      this.d.tasks.updatePeer(h.taskId, "needs_input", h.lastLine);
      if (pal) h.notifiedKey = key;
      if (h.notifiedKey !== key) {
        h.notifiedKey = key;
        this.d.audit.log("handoff.waiting", { taskId: h.taskId, peer: peer.name });
        this.d.notify(h.taskId, t("handoff.askTitle"), t("handoff.askBody", { title: task.title, peer: peer.name }));
      }
    } else if (reply && isQuestion(reply.text)) {
      // It asked the owner through the assistant; the assistant relays the choice.
      h.state = "asking";
      h.lastLine = t("handoff.asking");
      this.d.tasks.updatePeer(h.taskId, "needs_input", h.lastLine);
    } else if (reply && (peer.status === "idle" || peer.status === "shell")) {
      // It reported back and stopped: done.
      h.lastLine = tail.apiError ? t("handoff.failed") : t("handoff.done");
      this.d.tasks.settlePeer(h.taskId, tail.apiError ? "failed" : "done", h.lastLine);
      this.d.audit.log("handoff.done", { taskId: h.taskId, peer: peer.name });
      h.doneAt = now;
      h.relayDueAt = now + RELAY_GRACE_MS;
      return this.close(h, "replied");
    } else if (peer.status === "busy") {
      h.state = "working";
      h.idleSince = undefined;
      h.lastLine = (reply ? t("handoff.repliedBusy") : tail.lastText) || h.lastLine || t("handoff.working");
      this.d.tasks.updatePeer(h.taskId, "running", h.lastLine);
    } else {
      // idle / shell with no reply yet
      const since = h.idleSince ?? peer.statusUpdatedAt ?? now;
      h.idleSince = since;
      const idleFor = now - since;
      if (idleFor >= IDLE_GIVE_UP_MS) {
        this.d.tasks.settlePeer(h.taskId, "stopped", t("handoff.gaveUp"));
        return this.close(h, "gave up");
      }
      h.state = idleFor >= IDLE_NOTE_MS ? "idle" : "working";
      h.lastLine = idleFor >= IDLE_NOTE_MS ? t("handoff.stopped") : tail.lastText || h.lastLine || t("handoff.working");
      this.d.tasks.updatePeer(h.taskId, "running", h.lastLine);
    }
    h.nextCheckAt = now + this.interval(h, now);
    if (before.state !== h.state || before.line !== h.lastLine) this.d.audit.log("handoff.checked", { taskId: h.taskId, peer: peer.name, state: h.state });
    return true;
  }

  // A peer finished: the assistant normally tells the owner in its own words.
  // If it hasn't said anything to the owner a few minutes later, a short line.
  private relayFallbacks(now: number): boolean {
    let changed = false;
    for (const h of this.handoffs) {
      if (!h.relayDueAt || !h.doneAt) continue;
      const spoke = this.d.assistantSpokeAt?.() ?? 0;
      if (spoke > h.doneAt) {
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

  private interval(h: Handoff, now: number): number {
    if (h.state === "working") return CHECK_WORKING_MS;
    if (h.state === "waiting" || h.state === "asking") return CHECK_WAITING_MS;
    // idle: back off with how long it's been quiet (5 → 30 minutes)
    const quiet = now - (h.idleSince ?? now);
    return Math.min(30 * MIN, Math.max(5 * MIN, quiet / 6));
  }

  private close(h: Handoff, why: string): boolean {
    h.state = "closed";
    this.d.audit.log("handoff.closed", { taskId: h.taskId, peer: h.peer.name, why });
    return true;
  }

  // ---- who is "the assistant" ----

  private isHome(s: PeerSession): boolean {
    if (s.sessionId === this.d.selfSessionId()) return true;
    if (resolve(s.cwd) === resolve(this.d.homeCwd())) return true;
    return false;
  }

  private rememberHome(sessions: PeerSession[]): void {
    for (const s of sessions) if (this.isHome(s)) this.homePids.add(s.pid);
  }

  // A peer's SendMessage `to` that means the assistant (its name changes with restarts).
  private isHomeTarget(to: string, sessions: PeerSession[]): boolean {
    const t = to.trim();
    if (t === HOME_TO) return true;
    const uds = /^uds:.*\/(\d+)\.sock$/.exec(t);
    if (uds) return this.homePids.has(Number(uds[1]));
    const s = this.registry.resolve(t, sessions);
    if (s) return this.isHome(s);
    return /^home(-[0-9a-z]+)?(\s*\[[^\]]*\])?$/i.test(t);
  }

  private save(): void {
    // Keep a month of closed ones for the record.
    const cutoff = this.now() - 30 * 86400_000;
    this.handoffs = this.handoffs.filter((h) => h.state !== "closed" || h.checkedAt > cutoff || h.createdAt > cutoff);
    writeJson(this.d.path, { handoffs: this.handoffs, homePids: [...this.homePids].slice(-20) });
  }
}

function peerRef(p: PeerSession): Handoff["peer"] {
  return { name: p.name, pid: p.pid, sessionId: p.sessionId, cwd: p.cwd, tmux: p.tmux };
}
