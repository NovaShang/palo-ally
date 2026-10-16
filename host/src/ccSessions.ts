import { t } from "./i18n/index.ts";
import { existsSync, readdirSync, readFileSync, statSync, watch, type FSWatcher } from "node:fs";
import { basename, join } from "node:path";
import type { AgentEntry, ClaudeCli } from "./ccCli.ts";
import { readTail, transcriptPath } from "./handoffs.ts";
import type { CCMessage, CCSession, CCSessionKind, CCSessionStatus } from "./types.ts";
import { truncate } from "./util.ts";

// What the owner sees of the Claude Code sessions on this computer
// (docs/sessions-prd.md §6.1–6.2). Read only from what Claude Code keeps
// itself: its registry of live sessions (~/.claude/sessions/<pid>.json),
// `claude agents --json --all` for background sessions that aren't running,
// and each session's transcript. Events from PaloAlly's hooks come first;
// the registry is read again every 10 seconds for anything they missed.
// The background-session fields `state` / `detail` are written by the model
// and go stale, so they are never used.

export interface RegistryEntry {
  pid: number;
  sessionId: string;
  name: string;
  cwd: string;
  kind: string; // "interactive" | "bg"
  entrypoint?: string; // "cli" | "sdk-ts"
  status: string; // busy | idle | waiting | shell
  waitingFor?: string;
  statusAt?: number;
  jobId?: string;
  socketPath?: string;
  startedAt?: number;
  nameSource?: string; // "user" (named: -n, /rename) or "derived"
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}

export function readRegistry(dir: string, alive: (pid: number) => boolean = pidAlive): RegistryEntry[] {
  if (!existsSync(dir)) return [];
  const out: RegistryEntry[] = [];
  for (const f of readdirSync(dir)) {
    if (!/^\d+\.json$/.test(f)) continue;
    try {
      const o = JSON.parse(readFileSync(join(dir, f), "utf8"));
      const pid = Number(o.pid);
      if (!pid || typeof o.sessionId !== "string" || !alive(pid)) continue;
      out.push({
        pid,
        sessionId: o.sessionId,
        name: typeof o.name === "string" ? o.name : "",
        cwd: typeof o.cwd === "string" ? o.cwd : "",
        kind: typeof o.kind === "string" ? o.kind : "interactive",
        entrypoint: typeof o.entrypoint === "string" ? o.entrypoint : undefined,
        status: typeof o.status === "string" ? o.status : "idle",
        waitingFor: typeof o.waitingFor === "string" && o.waitingFor ? o.waitingFor : undefined,
        statusAt: typeof o.statusUpdatedAt === "number" ? o.statusUpdatedAt : typeof o.updatedAt === "number" ? o.updatedAt : undefined,
        jobId: typeof o.jobId === "string" ? o.jobId : undefined,
        socketPath: typeof o.messagingSocketPath === "string" ? o.messagingSocketPath : undefined,
        startedAt: typeof o.startedAt === "number" ? o.startedAt : undefined,
        nameSource: typeof o.nameSource === "string" ? o.nameSource : undefined,
      });
    } catch {
      // a file mid-write; the next read gets it
    }
  }
  return out;
}

// One session as the host keeps it.
export interface SessionRecord {
  sessionId: string;
  name: string;
  cwd: string;
  bg: boolean;
  entrypoint?: string;
  live: boolean; // a process is running it now
  pid?: number;
  socketPath?: string;
  shortId?: string;
  startedAt?: number;
  reg?: { status: string; waitingFor?: string; at: number };
  hook?: { status: CCSessionStatus; waitingFor?: string; at: number };
  lastLine?: string;
  lastLineAt?: number;
  contextTokens?: number;
  permissionMode?: string; // from its hooks
  transcript?: { size: number; mtime: number };
  ended?: boolean; // an interactive session that said SessionEnd
  seenInRegistry?: boolean;
}

export interface SessionWatchDeps {
  claudeDir: string;
  cli: ClaudeCli;
  /** PaloAlly's own sessions (the main one, probes, its Pals): never listed. */
  isOwn: (s: { sessionId: string; name: string; cwd: string; entrypoint?: string }) => boolean;
  /** pals.adopt waits for this one to quit in its terminal. */
  adopting?: (sessionId: string) => boolean;
  /** A session's open card on the phone, if any: it's waiting on the owner. */
  waitingCard: (sessionId: string) => string | undefined;
  onChange: (sessions: CCSession[]) => void;
  /** The registry says this session is (or isn't) waiting at the computer. */
  onRegistryStatus?: (sessionId: string, status: string) => void;
  now?: () => number;
  log?: (s: string) => void;
}

const STOPPED_HIDE_MS = 7 * 86400_000;
const SWEEP_MS = 10_000;
const AGENTS_EVERY_MS = 60_000;

export class SessionWatch {
  private recs = new Map<string, SessionRecord>();
  private lastEmitted = "";
  private timer: ReturnType<typeof setInterval> | null = null;
  private watcher: FSWatcher | null = null;
  private debounce: ReturnType<typeof setTimeout> | null = null;
  private agentsAt = 0;
  private agentsRunning: Promise<void> | null = null;

  constructor(private d: SessionWatchDeps) {}

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  get registryDir(): string {
    return join(this.d.claudeDir, "sessions");
  }

  start(): void {
    void this.refresh({ agents: true });
    this.timer = setInterval(() => void this.refresh({ agents: this.now() - this.agentsAt >= AGENTS_EVERY_MS }), SWEEP_MS);
    (this.timer as any).unref?.();
    try {
      this.watcher = watch(this.registryDir, () => {
        if (this.debounce) clearTimeout(this.debounce);
        this.debounce = setTimeout(() => void this.refresh(), 300);
      });
    } catch {
      // no registry dir yet: the sweep covers it
    }
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    if (this.debounce) clearTimeout(this.debounce);
    this.watcher?.close();
    this.timer = null;
    this.watcher = null;
  }

  get(id: string): SessionRecord | undefined {
    return this.recs.get(id);
  }

  /** A session by id, short id or name (exact, then case-insensitive). */
  find(key: string): SessionRecord | undefined {
    const k = key.trim();
    if (!k) return undefined;
    const visible = this.visible();
    return (
      this.recs.get(k) ??
      visible.find((r) => r.shortId === k || r.sessionId.startsWith(k + "-")) ??
      visible.find((r) => r.name === k) ??
      visible.find((r) => r.name.toLowerCase() === k.toLowerCase())
    );
  }

  /**
   * Reads the registry (and `claude agents` when asked, or when its last
   * answer is older than `agentsMaxAgeMs`) and tells the hub if the list changed.
   */
  async refresh(o: { agents?: boolean; agentsMaxAgeMs?: number } = {}): Promise<void> {
    if (o.agents || (o.agentsMaxAgeMs !== undefined && this.now() - this.agentsAt >= o.agentsMaxAgeMs)) await this.refreshAgents();
    this.readRegistry();
    this.emitIfChanged();
  }

  private async refreshAgents(): Promise<void> {
    if (this.agentsRunning) return this.agentsRunning;
    this.agentsRunning = (async () => {
      try {
        const list = await this.d.cli.agents();
        this.agentsAt = this.now();
        this.mergeAgents(list);
      } catch (e) {
        this.d.log?.(`sessions: claude agents failed: ${e instanceof Error ? e.message : e}`);
      } finally {
        this.agentsRunning = null;
      }
    })();
    return this.agentsRunning;
  }

  private mergeAgents(list: AgentEntry[]): void {
    const seen = new Set<string>();
    for (const a of list) {
      if (this.d.isOwn({ sessionId: a.sessionId, name: a.name ?? "", cwd: a.cwd })) continue;
      seen.add(a.sessionId);
      const bg = a.kind === "background" || a.kind === "bg";
      const r = this.record(a.sessionId, { name: a.name ?? "", cwd: a.cwd, bg });
      if (a.name) r.name = a.name;
      if (a.cwd) r.cwd = a.cwd;
      r.bg = r.bg || bg;
      if (a.id) r.shortId = a.id;
      if (a.startedAt) r.startedAt = a.startedAt;
      // A background session listed with no process is stopped. (A live one
      // shows up in the registry too, which says more.)
      if (bg && !a.pid) r.live = false;
    }
    // Background sessions `claude agents` no longer lists were removed.
    for (const r of [...this.recs.values()]) {
      if (r.bg && !r.live && !seen.has(r.sessionId)) this.recs.delete(r.sessionId);
    }
  }

  private readRegistry(): void {
    let entries: RegistryEntry[];
    try {
      entries = readRegistry(this.registryDir);
    } catch (e) {
      this.d.log?.(`sessions: can't read the registry: ${e}`);
      return;
    }
    const live = new Set<string>();
    for (const e of entries) {
      if (this.d.isOwn({ sessionId: e.sessionId, name: e.name, cwd: e.cwd, entrypoint: e.entrypoint })) continue;
      live.add(e.sessionId);
      const bg = e.kind === "bg" || e.kind === "background";
      const r = this.record(e.sessionId, { name: e.name, cwd: e.cwd, bg });
      const wasLive = r.live;
      r.live = true;
      r.ended = false;
      r.seenInRegistry = true;
      r.bg = r.bg || bg;
      if (e.name) r.name = e.name;
      if (e.cwd) r.cwd = e.cwd;
      r.pid = e.pid;
      r.entrypoint = e.entrypoint;
      r.socketPath = e.socketPath;
      if (e.jobId) r.shortId = e.jobId;
      if (e.startedAt) r.startedAt = e.startedAt;
      const prev = r.reg?.status;
      r.reg = { status: e.status, waitingFor: e.waitingFor, at: e.statusAt ?? this.now() };
      if (prev !== e.status || !wasLive) this.d.onRegistryStatus?.(e.sessionId, e.status);
      this.readTranscript(r);
    }
    // Gone from the registry: an interactive session ended; a background one stopped.
    for (const r of [...this.recs.values()]) {
      if (live.has(r.sessionId) || !r.live) continue;
      // Only heard of through its hooks so far: the registry catches up in a moment.
      if (!r.seenInRegistry && r.hook && this.now() - r.hook.at < 5_000) continue;
      r.live = false;
      r.reg = undefined;
      this.d.onRegistryStatus?.(r.sessionId, "gone");
      if (!r.bg) this.recs.delete(r.sessionId);
    }
  }

  private record(id: string, base: { name: string; cwd: string; bg: boolean }): SessionRecord {
    let r = this.recs.get(id);
    if (!r) {
      r = { sessionId: id, name: base.name, cwd: base.cwd, bg: base.bg, live: false };
      this.recs.set(id, r);
    }
    return r;
  }

  // The last words and the context size, from the transcript's tail; read
  // again only when the file changed.
  private readTranscript(r: SessionRecord): void {
    if (!r.cwd) return;
    const path = transcriptPath(this.d.claudeDir, r.cwd, r.sessionId);
    let st: { size: number; mtimeMs: number };
    try {
      st = statSync(path);
    } catch {
      return;
    }
    if (r.transcript && r.transcript.size === st.size && r.transcript.mtime === st.mtimeMs) return;
    r.transcript = { size: st.size, mtime: st.mtimeMs };
    const tail = summarizeTranscript(readTail(path, 96 * 1024));
    if (tail.lastLine && (!r.lastLineAt || (tail.lastLineAt ?? 0) >= r.lastLineAt)) {
      r.lastLine = tail.lastLine;
      r.lastLineAt = tail.lastLineAt ?? st.mtimeMs;
    }
    if (tail.contextTokens) r.contextTokens = tail.contextTokens;
  }

  // ---- hook events (they come first) ----

  onHook(event: string, p: Record<string, any>, env: { jobDir?: string } = {}): void {
    const id = typeof p.session_id === "string" ? p.session_id : "";
    if (!id) return;
    const at = this.now();
    const cwd = typeof p.cwd === "string" ? p.cwd : "";
    const r = this.recs.get(id) ?? this.record(id, { name: "", cwd, bg: !!env.jobDir });
    if (cwd && !r.cwd) r.cwd = cwd;
    // Background sessions run with CLAUDE_JOB_DIR=~/.claude/jobs/<short id>.
    if (env.jobDir) {
      r.bg = true;
      r.shortId = basename(env.jobDir);
    }
    if (typeof p.permission_mode === "string") r.permissionMode = p.permission_mode;
    if (typeof p.session_title === "string" && p.session_title && !r.name) r.name = p.session_title;
    // A hook runs inside a live session.
    if (event !== "SessionEnd") {
      r.live = true;
      r.ended = false;
    }
    switch (event) {
      case "SessionStart":
        r.live = true;
        r.ended = false;
        r.hook = { status: "idle", at };
        if (typeof p.context_tokens === "number") r.contextTokens = p.context_tokens;
        break;
      case "Stop":
        r.hook = { status: "idle", at };
        if (typeof p.last_assistant_message === "string" && p.last_assistant_message.trim()) {
          r.lastLine = firstLine(p.last_assistant_message);
          r.lastLineAt = at;
        }
        break;
      case "Notification":
        if (p.notification_type === "permission_prompt") r.hook = { status: "waiting", waitingFor: shortWords(p.message), at };
        else if (p.notification_type === "idle_prompt") r.hook = { status: "idle", at };
        break;
      case "PermissionRequest":
        r.hook = { status: "waiting", waitingFor: waitingWords(p), at };
        break;
      case "PostToolUse":
        r.hook = { status: "busy", at };
        break;
      case "SessionEnd":
        r.hook = { status: r.bg ? "stopped" : "idle", at };
        if (!r.bg) {
          r.ended = true;
          r.live = false;
        }
        break;
    }
    this.emitIfChanged();
  }

  /** A card was settled on the phone or at the computer: it isn't waiting on us any more. */
  carryOn(id: string): void {
    const r = this.recs.get(id);
    if (!r) return;
    r.hook = { status: "busy", at: this.now() };
    this.emitIfChanged();
  }

  // ---- what the app sees ----

  private visible(): SessionRecord[] {
    const now = this.now();
    return [...this.recs.values()].filter((r) => {
      if (r.ended) return false;
      if (this.d.isOwn({ sessionId: r.sessionId, name: r.name, cwd: r.cwd, entrypoint: r.entrypoint })) return false;
      if (r.live) return true;
      if (!r.bg) return false;
      // Background sessions stopped more than a week ago drop off the list.
      const last = Math.max(r.transcript?.mtime ?? 0, r.startedAt ?? 0, r.hook?.at ?? 0);
      return now - last < STOPPED_HIDE_MS;
    });
  }

  list(): CCSession[] {
    // The most recently active first.
    return this.visible()
      .map((r) => this.toWire(r))
      .sort((a, b) => b.updatedAt - a.updatedAt);
  }

  toWire(r: SessionRecord): CCSession {
    const kind: CCSessionKind = r.bg ? "background" : "terminal";
    let status: CCSessionStatus;
    let waitingFor: string | undefined;
    const card = this.d.waitingCard(r.sessionId);
    if (!r.live) status = "stopped";
    else if (card) {
      status = "waiting";
      waitingFor = card;
    } else {
      // The newer of the hook's word and the registry's.
      const hookNewer = !!r.hook && (!r.reg || r.hook.at >= r.reg.at);
      const raw = hookNewer ? r.hook!.status : (r.reg?.status ?? "idle");
      status = raw === "busy" || raw === "shell" ? "busy" : raw === "waiting" ? "waiting" : raw === "stopped" ? "stopped" : "idle";
      if (status === "waiting") waitingFor = (hookNewer ? r.hook!.waitingFor : r.reg?.waitingFor) ?? r.hook?.waitingFor;
    }
    const updatedAt = Math.max(r.reg?.at ?? 0, r.hook?.at ?? 0, r.lastLineAt ?? 0, r.transcript?.mtime ?? 0, r.startedAt ?? 0) || this.now();
    return {
      id: r.sessionId,
      name: r.name || basename(r.cwd || "") || t("sessions.unnamed"),
      cwd: r.cwd || "",
      kind,
      status,
      ...(waitingFor ? { waitingFor } : {}),
      ...(r.lastLine ? { lastLine: r.lastLine } : {}),
      ...(r.contextTokens ? { contextTokens: r.contextTokens } : {}),
      updatedAt: Math.round(updatedAt),
      ...(this.d.adopting?.(r.sessionId) ? { adopting: true } : {}),
    };
  }

  emitIfChanged(): void {
    const list = this.list();
    const key = JSON.stringify(list);
    if (key === this.lastEmitted) return;
    this.lastEmitted = key;
    this.d.onChange(list);
  }
}

// ---- transcripts ----

export function firstLine(s: string): string {
  const line =
    s
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l && !/^```/.test(l)) ?? "";
  return truncate(line.replace(/^[#>*\-\s]+/, "").replace(/\*\*/g, ""), 120);
}

function shortWords(s: unknown): string | undefined {
  return typeof s === "string" && s.trim() ? truncate(s.trim(), 80) : undefined;
}

// What a session waits for, in a few words: the command it wants to run, the
// question it asks, or the tool.
export function waitingWords(p: Record<string, any>): string {
  const tool = String(p.tool_name ?? "");
  const input = p.tool_input && typeof p.tool_input === "object" ? p.tool_input : {};
  if (tool === "AskUserQuestion") {
    const q = Array.isArray(input.questions) ? input.questions[0]?.question : undefined;
    return truncate(t("sessions.askYou", { q: typeof q === "string" ? q : t("sessions.aQuestion") }), 80);
  }
  if (tool === "Bash" && typeof input.command === "string") return truncate(t("sessions.wantRunShort", { cmd: input.command.split("\n")[0]! }), 80);
  if ((tool === "Write" || tool === "Edit") && typeof input.file_path === "string") return truncate(t("sessions.wantEdit", { file: basename(input.file_path) }), 80);
  return truncate(t("sessions.wantUse", { tool: tool || t("sessions.aTool") }), 80);
}

export interface TranscriptSummary {
  lastLine?: string;
  lastLineAt?: number;
  contextTokens?: number;
}

/** The session's last words and its context size, from transcript entries. */
export function summarizeTranscript(entries: any[]): TranscriptSummary {
  const out: TranscriptSummary = {};
  for (const e of entries) {
    if (e?.isSidechain || e?.type !== "assistant") continue;
    const m = e.message;
    const at = Date.parse(e.timestamp ?? "") || undefined;
    for (const b of Array.isArray(m?.content) ? m.content : []) {
      if (b?.type === "text" && typeof b.text === "string" && b.text.trim()) {
        out.lastLine = firstLine(b.text);
        out.lastLineAt = at;
      }
    }
    const u = m?.usage;
    if (u && m?.model !== "<synthetic>") {
      const t = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      if (t > 0) out.contextTokens = t;
    }
  }
  return out;
}

// ---- history (getSessionMessages → what the app shows) ----

export interface RawSessionMessage {
  type: string;
  uuid: string;
  message?: any;
  timestamp?: string;
  origin?: any;
  parent_tool_use_id?: string | null;
}

// A peer message's own words: the SDK keeps them as `origin.body`; older
// entries only have them inside the <cross-session-message> wrapper.
export function peerBody(origin: any, content: string): string {
  if (typeof origin?.body === "string") return origin.body;
  const m = /<cross-session-message[^>]*>\n?([\s\S]*?)\n?<\/cross-session-message>/.exec(content);
  let body = m?.[1] ?? content;
  const inner = /<\\?agent-message[^>]*>\n?([\s\S]*?)\n?<\\?\/agent-message>/.exec(body);
  if (inner) body = inner[1]!;
  return body.trim();
}

function userText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  if (content.some((b: any) => b?.type === "tool_result")) return null;
  const t = content
    .filter((b: any) => b?.type === "text" && typeof b.text === "string")
    .map((b: any) => b.text)
    .join("\n");
  return t || null;
}

/**
 * Turns a session's messages into what the app shows (CCMessage), oldest
 * first. Words from the assistant's own session (SendMessage, by its name)
 * are "palo"; other sessions' are "peer".
 */
export function toCCMessages(raw: RawSessionMessage[], assistantName: string, paloName = "Palo"): CCMessage[] {
  const out: CCMessage[] = [];
  for (const m of raw) {
    if (m.parent_tool_use_id) continue; // a subagent's
    const ts = Date.parse(m.timestamp ?? "") || 0;
    const content = m.message?.content;
    if (m.type === "assistant") {
      if (!Array.isArray(content)) continue;
      const text = content
        .filter((b: any) => b?.type === "text" && typeof b.text === "string")
        .map((b: any) => b.text)
        .join("\n\n")
        .trim();
      if (text && m.message?.model !== "<synthetic>") out.push({ id: m.uuid, ts, role: "assistant", text });
      continue;
    }
    if (m.type !== "user" || (m as any).isCompactSummary) continue;
    const text = userText(content);
    if (text === null) continue;
    const origin = m.origin;
    if (origin?.kind === "peer") {
      const from = typeof origin.name === "string" ? origin.name : "";
      const body = peerBody(origin, text);
      if (from && from === paloName) out.push({ id: m.uuid, ts, role: "palo", text: body, from: assistantName });
      else out.push({ id: m.uuid, ts, role: "peer", text: body, ...(from ? { from } : {}) });
      continue;
    }
    // Only what the owner typed; Claude Code's own notices and reminders aren't.
    if (origin && origin.kind !== "human") continue;
    const cmd = /^<command-name>(.*?)<\/command-name>/s.exec(text.trim());
    if (cmd) {
      const args = /<command-args>([\s\S]*?)<\/command-args>/.exec(text)?.[1]?.trim();
      out.push({ id: m.uuid, ts, role: "owner", text: `${cmd[1]!.trim()}${args ? ` ${args}` : ""}` });
      continue;
    }
    const t = text.trim();
    if (!t || /^(<local-command-|<system-reminder>|<command-message>|Caveat: )/.test(t)) continue;
    out.push({ id: m.uuid, ts, role: "owner", text: t });
  }
  return out;
}

/** A page of messages: the `limit` before message `before` (or the newest), oldest first. */
export function pageMessages(all: CCMessage[], before: string | number | undefined, limit: number): CCMessage[] {
  let end = all.length;
  if (typeof before === "string" && before) {
    const i = all.findIndex((m) => m.id === before);
    if (i >= 0) end = i;
  } else if (typeof before === "number" && Number.isFinite(before)) {
    end = all.findIndex((m) => m.ts >= before);
    if (end < 0) end = all.length;
  }
  return all.slice(Math.max(0, end - limit), end);
}
