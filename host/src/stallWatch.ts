import { execFile } from "node:child_process";
import { existsSync, mkdirSync, openSync, readSync, readdirSync, closeSync, fstatSync, statSync, writeFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";

// The stall watchdog: a Claude Code process the host runs (the assistant's
// own, every Pal) that froze mid-work is ended and resumed, without waiting
// for someone to notice. Seen on a MacBook Air: the process stayed alive with
// no CPU, its connections to the API dead, for hours; it took no new input,
// answered no other session and ignored SIGTERM, so Claude Code's own stream
// timeouts never ran either. Only something outside it can get it going again.
//
// A session counts as stalled when the host has work in it (a turn running,
// or an owner message it hasn't taken yet) and for `stallMinutes` nothing
// moved: no message on its SDK stream and no growth of its transcript or its
// subagents' transcripts. A tool call that's legitimately quiet (a long Bash)
// gets `toolMinutes` instead. Every socket to the API closed while a turn
// runs with no tool open is a stall already after a few minutes (lsof, at
// most once a minute). Nothing is checked while it waits on the owner.
//
// Then: what the process looked like is kept (sample, lsof) in logs/stalls,
// it's killed, the same session resumes, the owner messages it never took
// are sent again, the turn it was in is asked to go on, and the owner hears
// it once. At most `maxRestartsPerHour` restarts per session an hour; after
// that the owner is told instead.

export interface StallTarget {
  key: string; // "main", or the Pal's id
  name: string; // as the owner knows it
  /** A turn running, or an owner message it hasn't taken yet. */
  busy(): boolean;
  /** A card of its is waiting on the owner: quiet is expected. */
  waiting(): boolean;
  /** Names of its tool calls without a result yet (main thread and subagents). */
  openTools(): string[];
  /** When it last said anything on its SDK stream (ms). */
  lastActivity(): number;
  pid(): number | undefined;
  /** Its transcript file, if it has one yet. */
  transcript(): string | undefined;
  /** Ends the stuck process, resumes the session and carries on. */
  recover(): Promise<StallRecovery>;
}

export interface StallRecovery {
  resent: number; // owner messages it never took, sent again
  continued: boolean; // the interrupted turn was asked to go on
}

export interface WatchdogConfig {
  enabled: boolean;
  stallMinutes: number;
  toolMinutes: number;
  maxRestartsPerHour: number;
}

export const WATCHDOG_DEFAULTS: WatchdogConfig = { enabled: true, stallMinutes: 10, toolMinutes: 60, maxRestartsPerHour: 3 };

/** Its TCP connections to port 443 (Claude Code's to the API), and how many are open. */
export interface ApiSockets {
  total: number;
  established: number;
}

export interface StallWatchDeps {
  targets: () => StallTarget[];
  config: () => WatchdogConfig;
  /** One line to the owner: lands in the conversation and is pushed. */
  notify: (text: string) => void;
  audit: (type: string, data: Record<string, unknown>) => void;
  sockets?: (pid: number) => Promise<ApiSockets | null>;
  /** Keeps what the stuck process looked like; returns where. */
  diagnose?: (pid: number, name: string) => Promise<string | null>;
  now?: () => number;
  intervalMs?: number;
  log: (s: string) => void;
}

// Tools whose progress shows by itself (a subagent writes its own transcript).
const SELF_REPORTING = new Set(["Agent", "Task"]);
const SOCKET_CHECK_MS = 60_000;
const HOUR = 3600_000;

interface WatchState {
  busySince: number | null;
  progressAt: number;
  sig: string;
  activity: number;
  socketCheckedAt: number;
  restarts: number[];
  toldAt: number; // the owner was told it's left stuck (after too many restarts)
  recovering: boolean;
}

export class StallWatch {
  private state = new Map<string, WatchState>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private ticking = false;

  constructor(private d: StallWatchDeps) {}

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.d.intervalMs ?? 60_000);
    (this.timer as any).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private st(key: string): WatchState {
    let s = this.state.get(key);
    if (!s) this.state.set(key, (s = { busySince: null, progressAt: 0, sig: "", activity: 0, socketCheckedAt: 0, restarts: [], toldAt: 0, recovering: false }));
    return s;
  }

  /** One look at every session (every minute; tests call it directly). */
  async tick(): Promise<void> {
    const cfg = { ...WATCHDOG_DEFAULTS, ...this.d.config() };
    if (!cfg.enabled || this.ticking) return;
    this.ticking = true;
    try {
      const targets = this.d.targets();
      const keys = new Set(targets.map((t) => t.key));
      for (const k of this.state.keys()) if (!keys.has(k)) this.state.delete(k);
      for (const t of targets) await this.check(t, cfg);
    } catch (e) {
      this.d.log(`watchdog: ${e instanceof Error ? e.message : e}`);
    } finally {
      this.ticking = false;
    }
  }

  private async check(t: StallTarget, cfg: WatchdogConfig): Promise<void> {
    const s = this.st(t.key);
    if (s.recovering) return;
    const now = this.now();
    if (!t.busy() || t.waiting()) {
      s.busySince = null;
      return;
    }
    const sig = growth(t.transcript());
    const activity = t.lastActivity();
    if (s.busySince === null) {
      s.busySince = now;
      s.progressAt = Math.max(now, activity);
      s.sig = sig;
      s.activity = activity;
      return;
    }
    if (sig !== s.sig) {
      s.sig = sig;
      s.progressAt = now;
    }
    if (activity > s.activity) {
      s.activity = activity;
      s.progressAt = Math.max(s.progressAt, activity);
    }
    const quiet = now - s.progressAt;
    const tools = t.openTools().filter((n) => !SELF_REPORTING.has(n));
    const limit = (tools.length ? cfg.toolMinutes : cfg.stallMinutes) * 60_000;
    if (quiet >= limit) return this.stalled(t, s, cfg, quiet, tools.length ? `tool ${tools[0]}` : "quiet");
    // Waiting on the API with every connection to it closed: dead already.
    const pid = t.pid();
    const socketAfter = Math.min(5 * 60_000, (cfg.stallMinutes * 60_000) / 2);
    if (tools.length || !pid || !this.d.sockets || quiet < socketAfter || now - s.socketCheckedAt < SOCKET_CHECK_MS) return;
    s.socketCheckedAt = now;
    const so = await this.d.sockets(pid).catch(() => null);
    if (so && so.total > 0 && so.established === 0) return this.stalled(t, s, cfg, quiet, "api sockets closed");
  }

  private async stalled(t: StallTarget, s: WatchState, cfg: WatchdogConfig, quiet: number, why: string): Promise<void> {
    const now = this.now();
    const minutes = Math.max(1, Math.round(quiet / 60_000));
    const pid = t.pid();
    s.restarts = s.restarts.filter((x) => now - x < HOUR);
    if (s.restarts.length >= cfg.maxRestartsPerHour) {
      if (now - s.toldAt < HOUR) return;
      s.toldAt = now;
      this.d.audit("stall.gave_up", { session: t.key, name: t.name, quietMin: minutes, why, pid, restarts: s.restarts.length });
      this.d.log(`watchdog: ${t.name} stuck ${minutes} min (${why}); ${s.restarts.length} restarts this hour, leaving it`);
      this.d.notify(`「${t.name}」又卡住了 ${minutes} 分钟。一小时里已经自动重启了 ${s.restarts.length} 次，这次先不重启，你看一下。`);
      return;
    }
    s.restarts.push(now);
    s.recovering = true;
    this.d.audit("stall.detected", { session: t.key, name: t.name, quietMin: minutes, why, pid });
    this.d.log(`watchdog: ${t.name} stuck ${minutes} min (${why}, pid ${pid ?? "?"}); restarting it`);
    try {
      const diag = pid && this.d.diagnose ? await this.d.diagnose(pid, t.name).catch(() => null) : null;
      const r = await t.recover();
      this.d.audit("stall.restarted", { session: t.key, name: t.name, quietMin: minutes, why, pid, ...r, ...(diag ? { diag } : {}) });
      this.d.notify(`「${t.name}」卡住了 ${minutes} 分钟，已经自动重启并续上。`);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.d.audit("stall.restart_failed", { session: t.key, name: t.name, quietMin: minutes, why, pid, error: msg });
      this.d.log(`watchdog: restarting ${t.name} failed: ${msg}`);
      this.d.notify(`「${t.name}」卡住了 ${minutes} 分钟，自动重启没成功：${msg}`);
    } finally {
      s.recovering = false;
      s.busySince = null;
    }
  }
}

/** How much its transcript and its subagents' transcripts have grown (a signature, compared tick to tick). */
export function growth(transcript: string | undefined): string {
  if (!transcript) return "";
  let main = "-";
  try {
    const st = statSync(transcript);
    main = `${st.size}:${Math.round(st.mtimeMs)}`;
  } catch {
    /* none yet */
  }
  let sub = 0;
  const dir = join(transcript.replace(/\.jsonl$/, ""), "subagents");
  try {
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".jsonl")) continue;
      try {
        sub += statSync(join(dir, f)).size;
      } catch {
        /* gone */
      }
    }
  } catch {
    /* no subagents */
  }
  return `${main}|${sub}`;
}

/** Whether the transcript (its last `maxBytes`) mentions this message uuid: the session took that message. */
export function transcriptHas(path: string | undefined, uuid: string, maxBytes = 8 * 1024 * 1024): boolean {
  if (!path || !existsSync(path)) return false;
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - maxBytes);
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    return buf.toString("utf8").includes(uuid);
  } finally {
    closeSync(fd);
  }
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** SIGTERM, then SIGKILL: a frozen Claude Code never runs its SIGTERM handler. */
export async function killHard(pid: number | undefined, waitMs = 3_000): Promise<void> {
  if (!pid || !alive(pid)) return;
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
  for (let i = 0; i < waitMs / 100 && alive(pid); i++) await sleep(100);
  if (!alive(pid)) return;
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    return;
  }
  for (let i = 0; i < 30 && alive(pid); i++) await sleep(100);
}

function run(cmd: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve(err && !stdout ? `(${cmd} failed: ${err.message.split("\n")[0]})\n${stderr ?? ""}` : String(stdout));
    });
  });
}

/** Parses `lsof -a -n -P -p <pid> -iTCP`: its connections to port 443 and how many are open. */
export function parseApiSockets(out: string): ApiSockets {
  let total = 0;
  let established = 0;
  for (const line of out.split("\n")) {
    if (!/->\S*:443\b/.test(line)) continue;
    total++;
    if (/\(ESTABLISHED\)/.test(line)) established++;
  }
  return { total, established };
}

export async function apiSockets(pid: number): Promise<ApiSockets | null> {
  if (process.platform !== "darwin" && process.platform !== "linux") return null;
  return new Promise((resolve) => {
    execFile("lsof", ["-a", "-n", "-P", "-p", String(pid), "-iTCP"], { timeout: 10_000 }, (err, stdout) => {
      // lsof exits 1 when nothing matches: no TCP sockets at all
      if (err && !stdout) return resolve((err as any).code === 1 ? { total: 0, established: 0 } : null);
      resolve(parseApiSockets(String(stdout)));
    });
  });
}

/** Keeps a stuck process' stacks (macOS `sample`), open files and child processes in `dir`; the newest 20 stay. */
export async function diagnoseInto(dir: string, pid: number, name: string): Promise<string | null> {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${new Date().toISOString().replace(/[:.]/g, "-")}-${name.replace(/[^\w.-]+/g, "_").slice(0, 40)}-${pid}.txt`);
  const parts: string[] = [`pid ${pid} (${name}) at ${new Date().toISOString()}`];
  parts.push("== ps", await run("ps", ["-o", "pid,ppid,stat,%cpu,time,lstart,command", "-p", String(pid)], 5_000));
  const kids = await run("ps", ["-axo", "pid,ppid,stat,%cpu,time,command"], 5_000);
  parts.push("== children", kids.split("\n").filter((l) => l.trim().split(/\s+/)[1] === String(pid)).join("\n"));
  parts.push("== lsof", await run("lsof", ["-n", "-P", "-p", String(pid)], 10_000));
  if (process.platform === "darwin") parts.push("== sample", await run("sample", [String(pid), "2"], 30_000));
  writeFileSync(file, parts.join("\n"));
  try {
    const old = readdirSync(dir).filter((f) => f.endsWith(".txt")).sort();
    for (const f of old.slice(0, Math.max(0, old.length - 20))) unlinkSync(join(dir, f));
  } catch {
    /* keep them */
  }
  return file;
}
