// Stand-ins for Claude Code on the computer: its session registry, transcripts
// and the `claude` command line for background sessions. Lets the sessions
// logic run against a made-up computer without starting anything.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentEntry, BgStart, ClaudeCli } from "../src/ccCli.ts";
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
  started: BgStart[] = [];
  agentsCalls = 0;
  fail: Partial<Record<"startBg" | "stop" | "respawn" | "rm" | "resumeBg", string>> = {};
  private n = 0;

  constructor(private claude?: FakeClaudeDir) {}

  async agents(): Promise<AgentEntry[]> {
    this.agentsCalls++;
    return this.agentsList.map((a) => ({ ...a }));
  }

  async startBg(o: BgStart): Promise<string> {
    this.calls.push(`startBg ${o.name}`);
    if (this.fail.startBg) throw new Error(this.fail.startBg);
    this.started.push(o);
    const short = `${(0xabc000 + ++this.n).toString(16)}0`.slice(0, 8).padEnd(8, "0");
    const sessionId = `${short}-0000-4000-8000-000000000000`;
    this.agentsList.push({ id: short, pid: process.pid, cwd: o.cwd, kind: "background", sessionId, name: o.name, startedAt: Date.now() });
    this.claude?.register({ sessionId, name: o.name, cwd: o.cwd, kind: "bg", status: "busy" });
    return short;
  }

  async resumeBg(o: { cwd: string; sessionId: string; prompt?: string }): Promise<string> {
    this.calls.push(`resumeBg ${o.sessionId.slice(0, 8)}`);
    if (this.fail.resumeBg) throw new Error(this.fail.resumeBg);
    const short = o.sessionId.slice(0, 8);
    const a = this.agentsList.find((x) => x.sessionId === o.sessionId);
    if (a) a.pid = process.pid;
    else this.agentsList.push({ id: short, pid: process.pid, cwd: o.cwd, kind: "background", sessionId: o.sessionId, name: "revived" });
    this.claude?.register({ sessionId: o.sessionId, name: a?.name ?? "revived", cwd: o.cwd, kind: "bg", status: "idle" });
    return short;
  }

  async stop(short: string): Promise<void> {
    this.calls.push(`stop ${short}`);
    if (this.fail.stop) throw new Error(this.fail.stop);
    const a = this.agentsList.find((x) => x.id === short);
    if (a) {
      delete a.pid;
      this.claude?.unregister(a.sessionId);
    }
  }

  async respawn(short: string): Promise<void> {
    this.calls.push(`respawn ${short}`);
    if (this.fail.respawn) throw new Error(this.fail.respawn);
  }

  async rm(short: string): Promise<void> {
    this.calls.push(`rm ${short}`);
    if (this.fail.rm) throw new Error(this.fail.rm);
    const a = this.agentsList.find((x) => x.id === short);
    if (a) this.claude?.unregister(a.sessionId);
    this.agentsList = this.agentsList.filter((x) => x.id !== short);
  }
}
