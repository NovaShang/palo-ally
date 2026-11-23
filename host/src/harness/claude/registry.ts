import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pidAlive } from "../../util.ts";

// Claude Code's registry of live sessions on this computer (<config>/sessions/<pid>.json),
// read, never written.

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
