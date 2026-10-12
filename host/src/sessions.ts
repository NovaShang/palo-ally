import { getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import type { ApprovalManager } from "./approvals.ts";
import type { Audit } from "./audit.ts";
import { AwayDetector } from "./away.ts";
import type { Bus } from "./bus.ts";
import { type ClaudeCli, RealClaudeCli } from "./ccCli.ts";
import { ASSISTANT_PREFIX, COURIER_NAME, HookInstaller, HookServer, type HookContext, OWNER_PREFIX } from "./ccHooks.ts";
import { HelperStore, MAX_HELPERS, type Helper, SpendMeter } from "./ccHelpers.ts";
import { type RawSessionMessage, SessionWatch, firstLine, pageMessages, toCCMessages, waitingWords } from "./ccSessions.ts";
import type { ChatLog } from "./chat.ts";
import type { Paths, Settings } from "./config.ts";
import { Courier, modeClass } from "./courier.ts";
import { describeInput, describeTool } from "./copy.ts";
import type { QuestionManager } from "./questions.ts";
import type { Router } from "./router.ts";
import type { CCMessage, CCSession, CardSource, ChatMessage, HelperProposal } from "./types.ts";
import { newId, truncate, zonedParts } from "./util.ts";

// Sessions: PaloAlly and the Mac's own Claude Code sessions
// (docs/sessions-prd.md). The list and each conversation; a session's
// permission prompts and questions on the phone while the owner is away from
// the computer; the owner's words into a session; and helpers, the
// background sessions PaloAlly opens and looks after for the owner.

/** How long a session's card waits on the phone: a little under the hook's 300 s. */
export const HOOK_WAIT_MS = 290_000;
const PUSH_EVERY_MS = 10 * 60_000;
const NOTE_AT_COMPUTER = "在电脑上等你";
const NOTE_HANDLED = "已在电脑上处理";

export interface SessionsDeps {
  paths: Paths;
  claudeDir: string;
  bus: Bus;
  chat: ChatLog;
  approvals: ApprovalManager;
  questions: QuestionManager;
  router: Router;
  audit: Audit;
  settings: () => Settings;
  /** The assistant's own main session (never listed). */
  mainSessionId: () => string | undefined;
  cli?: ClaudeCli;
  away?: AwayDetector;
  courier?: Courier;
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

const expandHome = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p);

function within(root: string, p: string): boolean {
  if (!p) return false;
  const r = resolve(root);
  const x = resolve(p);
  return x === r || x.startsWith(r + sep);
}

export class Sessions {
  readonly watch: SessionWatch;
  readonly installer: HookInstaller;
  readonly helpers: HelperStore;
  readonly away: AwayDetector;
  readonly courier: Courier;
  private readonly cli: ClaudeCli;
  private readonly server: HookServer;
  private readonly meter: SpendMeter;
  private cards = new Map<string, Map<string, OpenCard>>(); // session id → its open cards
  private lastPush = new Map<string, number>();
  private budgetTimer: ReturnType<typeof setInterval> | null = null;
  private budgetSoon: ReturnType<typeof setTimeout> | null = null;
  private started = false;

  constructor(private d: SessionsDeps) {
    this.cli = d.cli ?? new RealClaudeCli({ log: d.log });
    this.away = d.away ?? new AwayDetector();
    this.helpers = new HelperStore(d.paths.helpers);
    this.meter = new SpendMeter(d.claudeDir);
    this.installer = new HookInstaller({ paths: d.paths, claudeDir: d.claudeDir, bun: d.bun });
    this.courier = d.courier ?? new Courier({ cwd: d.paths.courier, log: d.log });
    this.watch = new SessionWatch({
      claudeDir: d.claudeDir,
      cli: this.cli,
      isOwn: (s) => this.isOwn(s),
      helper: (id) => {
        const h = this.helpers.get(id);
        return h ? { name: h.name, cwd: h.cwd, removed: false } : undefined;
      },
      helperIds: () => this.helpers.list().map((h) => h.sessionId),
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
    // A new host version may change the hook script: keep it current.
    try {
      if (this.installer.installed()) this.installer.writeScripts();
    } catch (e) {
      this.log(`hook script: ${e}`);
    }
    this.watch.start();
    // After a restart of the Mac its helpers aren't running: bring them back.
    setTimeout(() => void this.reviveAfterRestart(), 3_000).unref?.();
    this.budgetTimer = setInterval(() => void this.checkBudgets(), 60_000);
    (this.budgetTimer as any).unref?.();
  }

  stop(): void {
    this.started = false;
    this.server.stop();
    this.watch.stop();
    this.courier.close();
    if (this.budgetTimer) clearInterval(this.budgetTimer);
    if (this.budgetSoon) clearTimeout(this.budgetSoon);
  }

  // PaloAlly's own sessions: the main one, probes and the courier.
  isOwn(s: { sessionId: string; name: string; cwd: string; entrypoint?: string }): boolean {
    if (s.name === COURIER_NAME) return true;
    if (s.sessionId && s.sessionId === this.d.mainSessionId()) return true;
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
    const h = this.helpers.get(r?.sessionId ?? id);
    const sessionId = r?.sessionId ?? h?.sessionId;
    const cwd = r?.cwd || h?.cwd;
    if (!sessionId || !cwd) throw new Error("没有这个会话");
    const read = this.d.readMessages ?? ((sid: string, dir: string) => getSessionMessages(sid, { dir }) as Promise<RawSessionMessage[]>);
    const name = this.d.settings().assistantName || "Palo";
    const all = toCCMessages(await read(sessionId, cwd), name);
    // A helper's first message is the assistant's handover, typed in for it.
    if (h) {
      const first = all.find((m) => m.role === "owner");
      if (first && first.text === h.duty.trim()) Object.assign(first, { role: "palo", from: name });
    }
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
        if (event === "Stop" && this.helpers.get(sid)) this.checkBudgetsSoon();
        return null;
      default:
        return null;
    }
  }

  private nameOf(sid: string, cwd: string): string {
    const r = this.watch.get(sid);
    const h = this.helpers.get(sid);
    return r?.name || h?.name || (cwd ? cwd.split("/").filter(Boolean).at(-1) : "") || "会话";
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

  // ---------------- words into a session ----------------

  /** The owner's words (from the app) or the assistant's into a session, verbatim. */
  async send(id: string, text: string, by: "owner" | "assistant"): Promise<void> {
    const t = text.trim();
    if (!t) throw new Error("要说的话不能是空的");
    const r = this.watch.get(id) ?? this.watch.find(id);
    if (!r || !this.watch.list().some((s) => s.id === r.sessionId)) throw new Error("没有这个会话");
    const name = this.watch.toWire(r).name;
    if (!r.live) throw new Error(`${name}已经停了，先复活它`);
    const h = this.helpers.get(r.sessionId);
    const to = r.socketPath ? `uds:${r.socketPath}` : name;
    const message = (by === "owner" ? OWNER_PREFIX : ASSISTANT_PREFIX) + t;
    const res = await this.courier.send({ to, label: name, message, mode: modeClass(r.permissionMode ?? h?.permissionMode) });
    this.d.audit.log("session.send", { session: r.sessionId, sessionName: name, by, chars: t.length, costUsd: res.costUsd });
    // Delivered: the session's conversation has it once it reads its inbox.
    const later = (ms: number, force: boolean) =>
      setTimeout(() => {
        void this.watch.refresh().then(() => {
          if (force) this.d.bus.emit("sessions.updated", { sessions: this.list() });
        });
      }, ms).unref?.();
    later(800, true);
    later(4_000, false);
  }

  // ---------------- helpers ----------------

  /** Claude Code's own default permission mode for the owner's sessions. */
  private ownerMode(): string {
    try {
      const s = JSON.parse(readFileSync(this.installer.settingsPath, "utf8"));
      const m = s?.permissions?.defaultMode;
      if (typeof m === "string" && m) return m;
    } catch {
      /* none */
    }
    return "default";
  }

  private helperFor(id: string): Helper {
    const h = this.helpers.get(id) ?? this.helpers.get(this.watch.find(id)?.sessionId ?? "") ?? this.helpers.byName(id);
    if (!h) {
      if (this.watch.get(id) || this.watch.find(id)) throw new Error("只能管帮手（PaloAlly 开的会话）");
      throw new Error("没有这个会话");
    }
    return h;
  }

  private checkProposal(p: { name: string; cwd: string; duty: string; dailyUsd: number }): void {
    if (!p.name.trim()) throw new Error("帮手要有个名字");
    if ([...p.name].length > 30) throw new Error("帮手的名字太长了");
    if (!p.duty.trim()) throw new Error("要写清楚帮手负责什么");
    if (!(p.dailyUsd > 0) || p.dailyUsd > 1000) throw new Error("每天的花费上限要大于 0");
    let dir = false;
    try {
      dir = statSync(p.cwd).isDirectory();
    } catch {
      dir = false;
    }
    if (!dir) throw new Error(`找不到目录 ${p.cwd}`);
    if (within(this.d.paths.root, p.cwd)) throw new Error("帮手不能开在 PaloAlly 自己的目录里");
    const same = this.helpers.byName(p.name);
    if (same && same.state !== "removed") throw new Error(`已经有一个叫「${p.name}」的帮手了`);
  }

  /** helper_propose: a card in the conversation; the helper starts on the owner's 开吧. */
  propose(a: { name: string; dir: string; duty: string; dailyUsd: number }): string {
    const dir = String(a.dir ?? "").trim();
    if (!dir) return "没提：要给帮手一个项目目录";
    const p = { name: String(a.name ?? "").trim(), cwd: resolve(expandHome(dir)), duty: String(a.duty ?? "").trim(), dailyUsd: Number(a.dailyUsd) };
    try {
      this.checkProposal(p);
    } catch (e) {
      return `没提：${e instanceof Error ? e.message : e}`;
    }
    if (this.helpers.running().length >= MAX_HELPERS)
      return `已经有 ${MAX_HELPERS} 个帮手在跑了（最多 ${MAX_HELPERS} 个）。先问主人要停掉哪一个。`;
    const proposal: HelperProposal = { id: newId("hp_"), ...p, status: "pending" };
    const home = homedir();
    const where = p.cwd.startsWith(home + sep) ? `~/${p.cwd.slice(home.length + 1)}` : p.cwd;
    const msg = this.d.chat.add({ role: "assistant", kind: "helper", text: `开一个帮手「${p.name}」专门管 ${where}？`, channel: "system", proposal });
    this.helpers.addProposal({ ...proposal, createdAt: this.now(), messageId: msg.id });
    this.d.audit.log("helper.proposed", { id: proposal.id, name: p.name, cwd: p.cwd, dailyUsd: p.dailyUsd });
    return `已经给主人看了开帮手的卡片（${proposal.id}）。主人点「开吧」才会开，现在还没开，别说已经开了。`;
  }

  /** helper.decide: 开吧 starts it (and returns it), 不用 drops the proposal. */
  async decide(proposalId: string, action: string, by: string): Promise<{ session?: CCSession }> {
    const p = this.helpers.proposal(proposalId);
    if (!p) throw new Error("这个提议已经没有了");
    const sessionOf = (sid?: string) => (sid ? this.list().find((s) => s.id === sid) : undefined);
    if (p.status !== "pending") {
      const s = sessionOf(p.sessionId);
      return s ? { session: s } : {};
    }
    if (action === "discard") {
      this.settleProposal(p.id, { status: "discarded" });
      this.d.audit.log("helper.discarded", { id: p.id, by });
      return {};
    }
    if (action !== "create") throw new Error("看不懂这个操作");
    if (this.helpers.running().length >= MAX_HELPERS) throw new Error(`已经有 ${MAX_HELPERS} 个帮手在跑了，先停掉一个`);
    this.checkProposal(p);
    const h = await this.createHelper({ name: p.name, cwd: p.cwd, duty: p.duty, dailyUsd: p.dailyUsd });
    this.settleProposal(p.id, { status: "created", sessionId: h.sessionId });
    this.d.audit.log("helper.created", { id: p.id, session: h.sessionId, name: h.name, by });
    return { session: sessionOf(h.sessionId) ?? this.watch.toWire(this.watch.get(h.sessionId)!) };
  }

  private settleProposal(id: string, patch: Partial<HelperProposal>): void {
    const p = this.helpers.updateProposal(id, patch);
    if (!p?.messageId) return;
    const { createdAt: _c, messageId: _m, ...proposal } = p;
    this.d.chat.update(p.messageId, { proposal });
  }

  private async createHelper(o: { name: string; cwd: string; duty: string; dailyUsd: number }): Promise<Helper> {
    const permissionMode = this.ownerMode();
    const short = await this.cli.startBg({ cwd: o.cwd, name: o.name, permissionMode, prompt: o.duty });
    const sessionId = await this.sessionIdOf(short);
    const h: Helper = { sessionId, name: o.name, cwd: o.cwd, duty: o.duty, dailyUsd: o.dailyUsd, short, createdAt: this.now(), state: "active", permissionMode };
    this.helpers.add(h);
    await this.watch.refresh({ agents: true });
    return h;
  }

  // A background job's short id is the start of its session id; Claude Code's
  // list says which.
  private async sessionIdOf(short: string): Promise<string> {
    for (let i = 0; i < 20; i++) {
      try {
        const hit = (await this.cli.agents()).find((a) => a.id === short || a.sessionId.startsWith(short));
        if (hit) return hit.sessionId;
      } catch {
        /* try again */
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error("帮手开了，但找不到它的会话");
  }

  /** sessions.control: 停止 / 重启 / 删除 / 复活, helpers only. */
  async control(id: string, action: string, by: string): Promise<void> {
    const h = this.helperFor(id);
    switch (action) {
      case "stop":
        await this.cli.stop(h.short);
        this.helpers.update(h.sessionId, { state: "stopped", stoppedFor: "owner" });
        break;
      case "restart":
        if (h.state === "active" && this.watch.get(h.sessionId)?.live) await this.cli.respawn(h.short);
        else await this.revive(h);
        this.helpers.update(h.sessionId, { state: "active", stoppedFor: undefined });
        break;
      case "remove":
        await this.cli.rm(h.short).catch((e) => {
          // already gone from Claude Code's list is fine
          if (!/not found|no such|unknown/i.test(String(e))) throw e;
        });
        this.helpers.update(h.sessionId, { state: "removed", stoppedFor: undefined });
        break;
      case "revive":
        await this.revive(h);
        break;
      default:
        throw new Error("看不懂这个操作");
    }
    this.d.audit.log("helper.control", { session: h.sessionId, name: h.name, action, by });
    await this.watch.refresh({ agents: true });
  }

  // Back from its transcript: `claude --bg --resume <session id>`.
  private async revive(h: Helper): Promise<void> {
    if (h.state !== "active" && this.helpers.running().length >= MAX_HELPERS) throw new Error(`已经有 ${MAX_HELPERS} 个帮手在跑了，先停掉一个`);
    const short = await this.cli.resumeBg({ cwd: h.cwd, sessionId: h.sessionId });
    this.helpers.update(h.sessionId, { short, state: "active", stoppedFor: undefined });
  }

  private async reviveAfterRestart(): Promise<void> {
    const active = this.helpers.list().filter((h) => h.state === "active");
    if (!active.length) return;
    await this.watch.refresh({ agents: true });
    for (const h of active) {
      if (this.watch.get(h.sessionId)?.live) continue;
      try {
        await this.revive(h);
        this.d.audit.log("helper.revived", { session: h.sessionId, name: h.name, why: "restart" });
      } catch (e) {
        this.log(`couldn't revive ${h.name}: ${e instanceof Error ? e.message : e}`);
      }
    }
    await this.watch.refresh({ agents: true });
  }

  // helper_stop / helper_restart: the assistant asks, the owner taps.
  requestControl(name: string, action: "stop" | "restart"): string {
    let h: Helper;
    try {
      h = this.helperFor(name);
    } catch (e) {
      return e instanceof Error ? e.message : String(e);
    }
    const title = action === "stop" ? `停掉帮手「${h.name}」` : `重启帮手「${h.name}」`;
    const { result } = this.d.approvals.ask(
      { toolName: `helper_${action}`, input: { name: h.name }, signal: new AbortController().signal },
      { tool: `helper_${action}`, title, detail: h.cwd },
    );
    void result.then(async (d) => {
      if (d.behavior !== "allow") return;
      try {
        await this.control(h.sessionId, action, "assistant");
      } catch (e) {
        this.d.chat.add({ role: "system", kind: "notice", text: `${title}没成功：${e instanceof Error ? e.message : e}`, channel: "system" });
      }
    });
    return `已经请主人确认「${title}」，主人点头后才会执行。`;
  }

  // ---------------- spending ----------------

  private checkBudgetsSoon(): void {
    if (this.budgetSoon) return;
    this.budgetSoon = setTimeout(() => {
      this.budgetSoon = null;
      void this.checkBudgets();
    }, 5_000);
    (this.budgetSoon as any).unref?.();
  }

  /** Stops a helper that spent more than its daily limit today, and tells the owner. */
  async checkBudgets(): Promise<void> {
    const tz = this.d.settings().timezone;
    const day = zonedParts(this.now(), tz).dateKey;
    for (const h of this.helpers.list()) {
      if (h.state !== "active" || h.budgetDay === day) continue;
      const spent = this.meter.spentOn(h.cwd, h.sessionId, day, tz);
      if (spent <= h.dailyUsd) continue;
      try {
        await this.cli.stop(h.short);
      } catch (e) {
        this.log(`couldn't stop ${h.name} for spending: ${e}`);
      }
      this.helpers.update(h.sessionId, { state: "stopped", stoppedFor: "budget", budgetDay: day });
      this.d.audit.log("helper.budget", { session: h.sessionId, name: h.name, spentUsd: Number(spent.toFixed(2)), dailyUsd: h.dailyUsd });
      const msg = this.d.chat.add({
        role: "assistant",
        kind: "notice",
        text: `帮手「${h.name}」今天花了约 $${spent.toFixed(2)}，超过了每天 $${h.dailyUsd} 的上限，我先把它停了。要它接着做，在会话里重启它就行。`,
        channel: "system",
        proactive: true,
      });
      void this.d.router.proactive(msg, { title: "帮手停了" }).catch(() => {});
      await this.watch.refresh({ agents: true });
    }
  }

  /** What a helper spent today (for tests and `paloally status`). */
  spentToday(sessionId: string): number {
    const h = this.helpers.get(sessionId);
    if (!h) return 0;
    const tz = this.d.settings().timezone;
    return this.meter.spentOn(h.cwd, h.sessionId, zonedParts(this.now(), tz).dateKey, tz);
  }

  // ---------------- the assistant's tools ----------------

  async toolList(): Promise<string> {
    const list = await this.listFresh().catch(() => this.list());
    return JSON.stringify(
      list.map((s) => ({
        name: s.name,
        kind: s.kind === "helper" ? "帮手" : s.kind === "terminal" ? "终端" : "后台",
        status: s.status,
        dir: s.cwd,
        ...(s.waitingFor ? { waitingFor: s.waitingFor } : {}),
        ...(s.lastLine ? { lastLine: s.lastLine } : {}),
        ...(s.kind === "helper" ? { dailyUsd: this.helpers.get(s.id)?.dailyUsd } : {}),
      })),
    );
  }

  async toolSend(name: string, text: string): Promise<string> {
    const r = this.watch.find(name);
    if (!r) return `找不到叫「${name}」的会话（先用 sessions_list 看看有哪些）`;
    try {
      await this.send(r.sessionId, text, "assistant");
      return `已原样送到「${this.watch.toWire(r).name}」。`;
    } catch (e) {
      return `没送到：${e instanceof Error ? e.message : e}`;
    }
  }
}
