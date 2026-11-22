import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pidAlive } from "../../util.ts";

// Claude Code's registry of live sessions on this computer (<config>/sessions/<pid>.json),
// read, never written.

export interface PeerSession {
  pid: number;
  sessionId: string;
  name: string;
  cwd: string;
  status: string; // busy | idle | shell | waiting (Claude Code's own)
  waitingFor?: string;
  statusUpdatedAt?: number;
  tmux?: string;
}

// SessionRegistry reads Claude Code's own list of live sessions on this machine.
export class SessionRegistry {
  constructor(
    private dir: string,
    private alive: (pid: number) => boolean = pidAlive,
  ) {}

  list(): PeerSession[] {
    if (!existsSync(this.dir)) return [];
    const out: PeerSession[] = [];
    for (const f of readdirSync(this.dir)) {
      if (!/^\d+\.json$/.test(f)) continue;
      try {
        const o = JSON.parse(readFileSync(join(this.dir, f), "utf8"));
        const pid = Number(o.pid);
        if (!pid || !o.sessionId || !this.alive(pid)) continue;
        out.push({
          pid,
          sessionId: String(o.sessionId),
          name: String(o.name ?? ""),
          cwd: String(o.cwd ?? ""),
          status: String(o.status ?? "idle"),
          waitingFor: typeof o.waitingFor === "string" ? o.waitingFor : undefined,
          statusUpdatedAt: typeof o.statusUpdatedAt === "number" ? o.statusUpdatedAt : undefined,
          tmux: typeof o.tmux === "string" ? o.tmux : undefined,
        });
      } catch {
        // a file mid-write; next check
      }
    }
    return out;
  }

  // A SendMessage `to`: a name (optionally "name [ref]") or "uds:<socket>".
  resolve(to: string, list = this.list()): PeerSession | undefined {
    const t = to.trim();
    const uds = /^uds:.*\/(\d+)\.sock$/.exec(t);
    if (uds) return list.find((s) => s.pid === Number(uds[1]));
    const name = t.replace(/\s*\[[^\]]*\]\s*$/, "");
    return list.find((s) => s.name === name);
  }
}

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
