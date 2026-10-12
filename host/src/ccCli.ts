import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir, tmpdir, userInfo } from "node:os";
import { join } from "node:path";

// The `claude` command line, for what only it does: listing sessions
// (`claude agents --json`, which doesn't start Claude Code's background
// service) and starting, stopping, restarting, removing and reviving
// background sessions (docs/sessions-prd.md §6.5).
//
// Commands run in the owner's login-shell environment, not the host's: the
// first background session starts Claude Code's background service, and
// every later one inherits that environment. Variables a running Claude Code
// session sets for its children (CLAUDE_CODE_*, CLAUDECODE, PALOALLY_SESSION…)
// are taken out, so nothing of the host's own sessions leaks in.

export interface AgentEntry {
  pid?: number;
  id?: string; // a background session's short id
  cwd: string;
  kind: string; // "interactive" | "background"
  startedAt?: number;
  sessionId: string;
  name?: string;
  status?: string;
  state?: string; // written by the model; not trusted (PRD §6.1)
}

export interface BgStart {
  cwd: string;
  name: string;
  permissionMode: string;
  prompt: string;
  model?: string; // default: the owner's own default model
}

export interface ClaudeCli {
  /** `claude agents --json --all`: live sessions and background ones, stopped too. */
  agents(): Promise<AgentEntry[]>;
  /** `claude --bg -n <name> --permission-mode <mode> "<prompt>"` in `cwd`; resolves the short id. */
  startBg(o: BgStart): Promise<string>;
  /** `claude --bg --resume <sessionId> ["<prompt>"]` in `cwd`; resolves the short id. */
  resumeBg(o: { cwd: string; sessionId: string; prompt?: string }): Promise<string>;
  stop(short: string): Promise<void>;
  respawn(short: string): Promise<void>;
  rm(short: string): Promise<void>;
}

// Set by Claude Code for the processes a session runs; never passed on.
// (Settings the owner exports, like CLAUDE_CODE_USE_BEDROCK, stay.)
const SESSION_VARS =
  /^(CLAUDECODE|CLAUDE_CODE_(ENTRYPOINT|SESSION_ID|SESSION_ATTENDED|CHILD_SESSION|MESSAGING_.*|BRIDGE_.*|EXECPATH|SSE_PORT)|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_JOB_DIR|CLAUDE_AGENT_SDK_.*|CLAUDE_PROJECT_DIR|CLAUDE_ENV_FILE|PALOALLY_.*)$/;

/** The environment without a running session's own variables (CLAUDE_CONFIG_DIR stays). */
export function cleanSessionEnv(env: Record<string, string | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined && !SESSION_VARS.test(k)) out[k] = v;
  return out;
}

/** "backgrounded · 03ed50f2 · name" → "03ed50f2". */
export function parseBackgrounded(out: string): string | null {
  return /backgrounded\s*·\s*([0-9a-z-]{4,})/i.exec(out)?.[1] ?? null;
}

export function parseAgents(out: string): AgentEntry[] {
  let raw: unknown;
  try {
    raw = JSON.parse(out);
  } catch {
    return [];
  }
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((e: any) => {
    if (!e || typeof e !== "object" || typeof e.sessionId !== "string" || typeof e.cwd !== "string") return [];
    return [
      {
        ...(typeof e.pid === "number" ? { pid: e.pid } : {}),
        ...(typeof e.id === "string" ? { id: e.id } : {}),
        cwd: e.cwd,
        kind: String(e.kind ?? ""),
        ...(typeof e.startedAt === "number" ? { startedAt: e.startedAt } : {}),
        sessionId: e.sessionId,
        ...(typeof e.name === "string" ? { name: e.name } : {}),
        ...(typeof e.status === "string" ? { status: e.status } : {}),
        ...(typeof e.state === "string" ? { state: e.state } : {}),
      },
    ];
  });
}

interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

function run(cmd: string, args: string[], o: { cwd?: string; env: Record<string, string>; timeoutMs: number }): Promise<RunResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let p: ReturnType<typeof spawn>;
    try {
      p = spawn(cmd, args, { cwd: o.cwd, env: o.env, stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      resolve({ code: -1, stdout: "", stderr: String(e) });
      return;
    }
    const timer = setTimeout(() => p.kill("SIGKILL"), o.timeoutMs);
    p.stdout?.on("data", (d) => (stdout += d));
    p.stderr?.on("data", (d) => (stderr += d));
    p.on("error", (e) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: stderr + String(e) });
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

let loginEnvCache: { at: number; env: Record<string, string> } | null = null;

/**
 * The owner's login-shell environment (`zsh -lc env`), started from a bare
 * environment so none of the host's variables are in it, with session
 * variables taken out. Cached for ten minutes.
 */
export async function loginEnv(): Promise<Record<string, string>> {
  if (loginEnvCache && Date.now() - loginEnvCache.at < 10 * 60_000) return loginEnvCache.env;
  const shellEnv = process.env.SHELL ?? "";
  const shell = /^\/.*\/(zsh|bash)$/.test(shellEnv) && existsSync(shellEnv) ? shellEnv : "/bin/zsh";
  let user = process.env.USER ?? "";
  try {
    user = userInfo().username;
  } catch {
    /* keep */
  }
  const bare: Record<string, string> = {
    HOME: homedir(),
    USER: user,
    LOGNAME: user,
    SHELL: shell,
    TMPDIR: process.env.TMPDIR ?? tmpdir(),
    LANG: process.env.LANG ?? "en_US.UTF-8",
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
  };
  const r = await run(shell, ["-lc", "env -0"], { env: bare, timeoutMs: 15_000 });
  const env: Record<string, string> = { ...bare };
  if (r.code === 0) {
    for (const kv of r.stdout.split("\0")) {
      const i = kv.indexOf("=");
      if (i > 0) env[kv.slice(0, i)] = kv.slice(i + 1);
    }
  }
  const clean = cleanSessionEnv(env);
  // Where the host's Claude Code keeps its state, if it was told.
  if (process.env.CLAUDE_CONFIG_DIR) clean.CLAUDE_CONFIG_DIR = process.env.CLAUDE_CONFIG_DIR;
  loginEnvCache = { at: Date.now(), env: clean };
  return clean;
}

export function findClaude(env: Record<string, string>): string | null {
  const viaPath = Bun.which("claude", { PATH: env.PATH ?? "" }) ?? Bun.which("claude");
  if (viaPath) return viaPath;
  for (const p of [join(homedir(), ".local/bin/claude"), join(homedir(), ".claude/local/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) {
    if (existsSync(p)) return p;
  }
  return null;
}

export class RealClaudeCli implements ClaudeCli {
  constructor(
    private o: {
      env?: () => Promise<Record<string, string>>;
      bin?: string;
      log?: (s: string) => void;
    } = {},
  ) {}

  private async exec(args: string[], cwd?: string, timeoutMs = 30_000): Promise<RunResult> {
    const env = await (this.o.env ?? loginEnv)();
    const bin = this.o.bin ?? findClaude(env);
    if (!bin) throw new Error("这台电脑上找不到 claude 命令");
    const r = await run(bin, args, { cwd, env, timeoutMs });
    if (r.code !== 0) {
      const why = (r.stderr || r.stdout).trim().split("\n").slice(-3).join(" ").slice(0, 300);
      throw new Error(`claude ${args[0]} 没成功${why ? `：${why}` : ""}`);
    }
    return r;
  }

  async agents(): Promise<AgentEntry[]> {
    const r = await this.exec(["agents", "--json", "--all"], undefined, 15_000);
    return parseAgents(r.stdout);
  }

  async startBg(o: BgStart): Promise<string> {
    const model = o.model ? ["--model", o.model] : [];
    const r = await this.exec(["--bg", "-n", o.name, "--permission-mode", o.permissionMode, ...model, o.prompt], o.cwd, 60_000);
    const short = parseBackgrounded(r.stdout + "\n" + r.stderr);
    if (!short) throw new Error("后台会话没开起来");
    return short;
  }

  async resumeBg(o: { cwd: string; sessionId: string; prompt?: string }): Promise<string> {
    const r = await this.exec(["--bg", "--resume", o.sessionId, ...(o.prompt ? [o.prompt] : [])], o.cwd, 60_000);
    const short = parseBackgrounded(r.stdout + "\n" + r.stderr);
    if (!short) throw new Error("后台会话没复活");
    return short;
  }

  async stop(short: string): Promise<void> {
    await this.exec(["stop", short]);
  }

  async respawn(short: string): Promise<void> {
    await this.exec(["respawn", short], undefined, 60_000);
  }

  async rm(short: string): Promise<void> {
    await this.exec(["rm", short]);
  }
}
