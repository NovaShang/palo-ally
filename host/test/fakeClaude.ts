// Stand-ins for Claude Code on the computer: its session registry, transcripts
// and the `claude` command line for background sessions. Lets the sessions
// logic run against a made-up computer without starting anything.
import { type ChildProcess, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentEntry, ClaudeCli } from "../src/ccCli.ts";
import { transcriptPath } from "../src/handoffs.ts";

export const DEAD_PID = 999_999;

export class FakeClaudeDir {
  readonly dir = mkdtempSync(join(tmpdir(), "paloally-claude-"));
  private n = 0;
  private files = new Map<string, string>(); // session id → registry file

  /** A live session in the registry (this test process stands in for its pid). */
  register(o: {
    sessionId: string;
    name: string;
    cwd: string;
    kind?: "interactive" | "bg";
    entrypoint?: "cli" | "sdk-ts";
    status?: string;
    waitingFor?: string;
    pid?: number;
    at?: number;
  }): void {
    mkdirSync(join(this.dir, "sessions"), { recursive: true });
    const file = this.files.get(o.sessionId) ?? join(this.dir, "sessions", `${10_000 + ++this.n}.json`);
    this.files.set(o.sessionId, file);
    writeFileSync(
      file,
      JSON.stringify({
        pid: o.pid ?? process.pid,
        sessionId: o.sessionId,
        cwd: o.cwd,
        kind: o.kind ?? "interactive",
        entrypoint: o.entrypoint ?? "cli",
        name: o.name,
        status: o.status ?? "idle",
        ...(o.waitingFor ? { waitingFor: o.waitingFor } : {}),
        messagingSocketPath: `/tmp/cc-socks/${o.sessionId.slice(0, 6)}.sock`,
        statusUpdatedAt: o.at ?? Date.now(),
        updatedAt: o.at ?? Date.now(),
      }),
    );
  }

  unregister(sessionId: string): void {
    const f = this.files.get(sessionId);
    if (f) rmSync(f, { force: true });
    this.files.delete(sessionId);
  }

  /** Lines in a session's transcript (Claude Code's JSONL). */
  transcript(cwd: string, sessionId: string, entries: unknown[]): string {
    const p = transcriptPath(this.dir, cwd, sessionId);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
    return p;
  }

  cleanup(): void {
    rmSync(this.dir, { recursive: true, force: true });
  }
}

/** An assistant transcript entry with usage. */
export function assistantEntry(text: string, o: { id?: string; model?: string; at?: string; usage?: Record<string, unknown> } = {}) {
  return {
    type: "assistant",
    uuid: `u-${Math.random().toString(36).slice(2)}`,
    timestamp: o.at ?? new Date().toISOString(),
    message: {
      id: o.id ?? `msg_${Math.random().toString(36).slice(2)}`,
      model: o.model ?? "claude-haiku-4-5-20251001",
      role: "assistant",
      content: [{ type: "text", text }],
      usage: o.usage ?? { input_tokens: 10, cache_creation_input_tokens: 2000, cache_read_input_tokens: 30000, output_tokens: 50 },
    },
  };
}

export class FakeCli implements ClaudeCli {
  agentsList: AgentEntry[] = [];
  calls: string[] = [];
  agentsCalls = 0;
  fail: Partial<Record<"stop", string>> = {};
  // `claude stop` that doesn't take (the process stays)
  stuck = false;

  constructor(private claude?: FakeClaudeDir) {}

  async agents(): Promise<AgentEntry[]> {
    this.agentsCalls++;
    return this.agentsList.map((a) => ({ ...a }));
  }

  private procs = new Map<string, ChildProcess>();

  /** A background session Claude Code's service runs (a stand-in process). */
  bg(o: { sessionId: string; name: string; cwd: string; status?: string }): string {
    const short = o.sessionId.slice(0, 8);
    const p = spawn("/bin/sleep", ["300"]);
    p.unref();
    this.procs.set(short, p);
    this.agentsList.push({ id: short, pid: p.pid, cwd: o.cwd, kind: "background", sessionId: o.sessionId, name: o.name, startedAt: Date.now() });
    this.claude?.register({ sessionId: o.sessionId, name: o.name, cwd: o.cwd, kind: "bg", status: o.status ?? "idle", pid: p.pid });
    return short;
  }

  async stop(short: string): Promise<void> {
    this.calls.push(`stop ${short}`);
    if (this.fail.stop) throw new Error(this.fail.stop);
    if (this.stuck) return;
    const a = this.agentsList.find((x) => x.id === short);
    if (a) {
      delete a.pid;
      this.claude?.unregister(a.sessionId);
    }
    this.procs.get(short)?.kill("SIGKILL");
  }

  /** Every stand-in process ends. */
  close(): void {
    for (const p of this.procs.values()) if (p.exitCode === null) p.kill("SIGKILL");
  }
}
