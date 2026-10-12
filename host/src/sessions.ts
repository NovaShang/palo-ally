import { getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { resolve, sep } from "node:path";
import type { ApprovalManager } from "./approvals.ts";
import type { Audit } from "./audit.ts";
import { AwayDetector } from "./away.ts";
import type { Bus } from "./bus.ts";
import { type ClaudeCli, RealClaudeCli } from "./ccCli.ts";
import { HookInstaller, HookServer, type HookContext } from "./ccHooks.ts";
import { type RawSessionMessage, SessionWatch, firstLine, pageMessages, toCCMessages, waitingWords } from "./ccSessions.ts";
import type { Paths, Settings } from "./config.ts";
import { describeInput, describeTool } from "./copy.ts";
import type { QuestionManager } from "./questions.ts";
import type { Router } from "./router.ts";
import type { CCMessage, CCSession, CardSource, ChatMessage } from "./types.ts";
import { newId, truncate } from "./util.ts";

// Sessions: the Mac's own Claude Code sessions that PaloAlly doesn't run
// (docs/sessions-prd.md, as kept by docs/pals-prd.md). The list (with each
// session's state) and each conversation, and their permission prompts and
// questions on the phone while the owner is away from the computer, through
// PaloAlly's global hooks. Pals, the sessions the host runs itself, are
// pals.ts; they aren't in this list.

/** How long a session's card waits on the phone: a little under the hook's 300 s. */
export const HOOK_WAIT_MS = 290_000;
const PUSH_EVERY_MS = 10 * 60_000;
const NOTE_AT_COMPUTER = "在电脑上等你";
const NOTE_HANDLED = "已在电脑上处理";

export interface SessionsDeps {
  paths: Paths;
  claudeDir: string;
  bus: Bus;
  approvals: ApprovalManager;
  questions: QuestionManager;
  router: Router;
  audit: Audit;
  settings: () => Settings;
  /** The assistant's own main session (never listed). */
  mainSessionId: () => string | undefined;
  /** A Pal's session: the host runs it, so it isn't one of these. */
  isPal?: (sessionId: string) => boolean;
  /** pals.adopt is waiting for this one to quit in its terminal. */
  adopting?: (sessionId: string) => boolean;
  /** The assistant's SendMessage name: its words in a conversation show as the assistant's. */
  paloName?: () => string;
  cli?: ClaudeCli;
  away?: AwayDetector;
  readMessages?: (sessionId: string, dir: string) => Promise<RawSessionMessage[]>;
  hookWaitMs?: number;
  bun?: string; // the bun the hook runs on
  now?: () => number;
  log?: (s: string) => void;
}

interface OpenCard {
  id: string;
  waitingFor: string;
  abort: AbortController;
  sawWaiting: boolean; // the registry said "waiting" since the card opened
}

function within(root: string, p: string): boolean {
  if (!p) return false;
  const r = resolve(root);
  const x = resolve(p);
  return x === r || x.startsWith(r + sep);
}

export class Sessions {
  readonly watch: SessionWatch;
  readonly installer: HookInstaller;
  readonly away: AwayDetector;
  readonly cli: ClaudeCli;
  private readonly server: HookServer;
  private cards = new Map<string, Map<string, OpenCard>>(); // session id → its open cards
  private lastPush = new Map<string, number>();
  private started = false;

  constructor(private d: SessionsDeps) {
    this.cli = d.cli ?? new RealClaudeCli({ log: d.log });
    this.away = d.away ?? new AwayDetector();
    this.installer = new HookInstaller({ paths: d.paths, claudeDir: d.claudeDir, bun: d.bun });
    this.watch = new SessionWatch({
      claudeDir: d.claudeDir,
      cli: this.cli,
      isOwn: (s) => this.isOwn(s),
      adopting: (id) => d.adopting?.(id) ?? false,
      waitingCard: (id) => {
        const open = this.cards.get(id);
        return open?.size ? [...open.values()].at(-1)!.waitingFor : undefined;
      },
      onChange: (sessions) => d.bus.emit("sessions.updated", { sessions }),
      onRegistryStatus: (id, status) => this.onRegistryStatus(id, status),
      now: d.now,
      log: d.log,
    });
    this.server = new HookServer(d.paths.hookSocket, (event, payload, ctx) => this.onHook(event, payload, ctx), (s) => this.log(s));
  }

  private log(s: string): void {
    this.d.log?.(`sessions: ${s}`);
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  // ---------------- lifecycle ----------------

  start(): void {
    if (this.started) return;
    this.started = true;
    try {
      this.server.start();
    } catch (e) {
      this.log(`hook socket: ${e}`);
    }
    // A new host version may change the hook script or its entries: keep them current.
    try {
      this.installer.refresh();
    } catch (e) {
      this.log(`hook script: ${e}`);
    }
    this.watch.start();
  }

  stop(): void {
    this.started = false;
    this.server.stop();
    this.watch.stop();
  }

  // PaloAlly's own sessions: the main one, probes, and the Pals it runs.
  isOwn(s: { sessionId: string; name: string; cwd: string; entrypoint?: string }): boolean {
    if (s.sessionId && s.sessionId === this.d.mainSessionId()) return true;
    if (s.sessionId && this.d.isPal?.(s.sessionId)) return true;
    return within(this.d.paths.root, s.cwd) && (s.entrypoint === undefined || s.entrypoint === "sdk-ts");
  }

  // ---------------- the list and the conversations ----------------

  list(): CCSession[] {
    return this.watch.list();
  }

  /** The list, read again first (sessions.list). */
  async listFresh(): Promise<CCSession[]> {
    await this.watch.refresh({ agentsMaxAgeMs: 10_000 });
    return this.list();
  }

  async history(id: string, before?: string | number, limit = 50): Promise<CCMessage[]> {
    const r = this.watch.get(id) ?? this.watch.find(id);
    if (!r?.sessionId || !r.cwd) throw new Error("没有这个会话");
    const read = this.d.readMessages ?? ((sid: string, dir: string) => getSessionMessages(sid, { dir }) as Promise<RawSessionMessage[]>);
    const name = this.d.settings().assistantName || "Palo";
    const all = toCCMessages(await read(r.sessionId, r.cwd), name, this.d.paloName?.() ?? "Palo");
    return pageMessages(all, before, Math.max(1, Math.min(Number(limit) || 50, 200)));
  }

  // ---------------- the global hooks ----------------

  hooksEnabled(): boolean {
    return this.installer.installed();
  }

  setHooks(enabled: boolean, by: string): boolean {
    if (enabled) this.installer.install();
    else this.installer.uninstall();
    const now = this.installer.installed();
    this.d.audit.log("sessions.hooks", { enabled: now, by, settings: this.installer.settingsPath });
    return now;
  }

  // One hook run. The return value is what the hook prints (null: nothing).
  async onHook(event: string, p: Record<string, any>, ctx: HookContext): Promise<unknown> {
    const sid = typeof p.session_id === "string" ? p.session_id : "";
    if (!sid) return null;
    const cwd = typeof p.cwd === "string" ? p.cwd : "";
    if (this.isOwn({ sessionId: sid, name: this.watch.get(sid)?.name ?? "", cwd, entrypoint: this.watch.get(sid)?.entrypoint })) return null;
    this.watch.onHook(event, p, ctx.env);
    switch (event) {
      case "PermissionRequest":
        return await this.permission(sid, p, ctx);
      case "Stop":
      case "SessionEnd":
      case "PostToolUse":
        // It went on: whatever it asked was answered at the computer.
        this.dismiss(sid);
        return null;
      default:
        return null;
    }
  }

  private nameOf(sid: string, cwd: string): string {
    const r = this.watch.get(sid);
    return r?.name || (cwd ? cwd.split("/").filter(Boolean).at(-1) : "") || "会话";
  }

  // A permission prompt or a question. At the computer: nothing (the terminal
  // asks as usual). Away: a card on the phone, and the owner's answer goes
  // back as the hook's decision. No answer in time: nothing, and the terminal
  // keeps asking.
  private async permission(sid: string, p: Record<string, any>, ctx: HookContext): Promise<unknown> {
    const tool = String(p.tool_name ?? "");
    const input = p.tool_input && typeof p.tool_input === "object" ? (p.tool_input as Record<string, unknown>) : {};
    if (!this.away.isAway()) {
      const name = this.nameOf(sid, String(p.cwd ?? ""));
      this.d.audit.log("session.prompt", { session: sid, sessionName: name, tool, at: "computer" });
      return null;
    }
    // Its name as Claude Code has it (a session may be newer than the last look).
    if (!this.watch.get(sid)?.name) await this.watch.refresh();
    const name = this.nameOf(sid, String(p.cwd ?? ""));
    const source: CardSource = { kind: "session", id: sid, name };
    const abort = new AbortController();
    if (ctx.signal.aborted) return null; // the hook is already gone
    ctx.signal.addEventListener("abort", () => abort.abort());
    const card: OpenCard = { id: "", waitingFor: waitingWords(p), abort, sawWaiting: false };
    const opts = { source, timeoutMs: this.d.hookWaitMs ?? HOOK_WAIT_MS, timeoutNote: NOTE_AT_COMPUTER, abortNote: NOTE_HANDLED, abortBy: "computer", notify: false };
    const req = { toolName: tool, input, signal: abort.signal };

    if (tool === "AskUserQuestion") {
      const asked = this.d.questions.ask(req, opts);
      if (!asked) return null;
      card.id = asked.question.id;
      this.open(sid, card);
      const first = asked.question.items[0]!.question;
      this.pushWaiting(sid, name, `问你：${first}`, { questionId: asked.question.id, kind: "question" });
      const d = await asked.result;
      this.close(sid, card);
      if (asked.question.status !== "answered" || d.behavior !== "allow") return null;
      return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow", updatedInput: d.updatedInput } } };
    }

    // The whole command, never cut short (PRD §8).
    const detail = tool === "Bash" && typeof input.command === "string" ? truncate(input.command, 100_000) : describeInput(tool, input);
    const asked = this.d.approvals.ask(req, { ...opts, title: describeTool(tool, input), detail });
    card.id = asked.approval.id;
    this.open(sid, card);
    const what = tool === "Bash" && typeof input.command === "string" ? `想运行：${firstLine(input.command)}` : asked.approval.title;
    this.pushWaiting(sid, name, what, { approvalId: asked.approval.id, kind: "approval" });
    await asked.result;
    this.close(sid, card);
    const a = asked.approval;
    if (a.status === "allowed") return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } };
    if (a.status === "denied")
      return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "deny", message: "主人在手机上拒绝了" } } };
    return null;
  }

  private open(sid: string, card: OpenCard): void {
    let m = this.cards.get(sid);
    if (!m) this.cards.set(sid, (m = new Map()));
    m.set(card.id, card);
    this.watch.emitIfChanged();
  }

  private close(sid: string, card: OpenCard): void {
    const m = this.cards.get(sid);
    m?.delete(card.id);
    if (m && !m.size) this.cards.delete(sid);
    // Answered here, or at the computer: either way it carries on, unless
    // it's still asking in its terminal (the card timed out).
    const a = this.d.approvals.get(card.id);
    const q = this.d.questions.get(card.id);
    if ((a ?? q)?.note !== NOTE_AT_COMPUTER) this.watch.carryOn(sid);
    else this.watch.emitIfChanged();
  }

  // The session went on without the phone: its open cards go.
  private dismiss(sid: string): void {
    for (const c of this.cards.get(sid)?.values() ?? []) c.abort.abort();
  }

  private onRegistryStatus(sid: string, status: string): void {
    const open = this.cards.get(sid);
    if (!open?.size) return;
    if (status === "waiting") {
      for (const c of open.values()) c.sawWaiting = true;
      return;
    }
    if (status === "gone" || [...open.values()].some((c) => c.sawWaiting)) this.dismiss(sid);
  }

  // 「X 在等你」: at most once per session every 10 minutes.
  private pushWaiting(sid: string, name: string, body: string, ids: { approvalId?: string; questionId?: string; kind: "approval" | "question" }): void {
    const now = this.now();
    if (now - (this.lastPush.get(sid) ?? 0) < PUSH_EVERY_MS) return;
    this.lastPush.set(sid, now);
    const msg: ChatMessage = {
      seq: 0,
      id: newId("m_"),
      role: "assistant",
      kind: ids.kind,
      text: body,
      channel: "system",
      ts: now,
      ...(ids.approvalId ? { approvalId: ids.approvalId } : {}),
      ...(ids.questionId ? { questionId: ids.questionId } : {}),
    };
    void this.d.router.proactive(msg, { title: `${name} 在等你` }).catch(() => {});
  }
}
