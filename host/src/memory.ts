import { existsSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { t } from "./i18n/index.ts";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import type { MemoryFile } from "./types.ts";
import { ensureDir } from "./util.ts";

// Core files are small and injected through CLAUDE.md (one injection path).
export const CORE_FILES = ["user.md", "soul.md"];
export const CORE_SOFT_LIMIT = 6 * 1024; // bytes; above this the core is too fat to load every session cheaply

// An agent's: the folder's own instructions Claude Code loads every session.
// CLAUDE.md is always listed (the owner may start one); the others only when there.
export const AGENT_CORE_FILES = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"];

// autoMemoryDir mirrors Claude Code's per-project auto memory location:
// <config dir>/projects/<cwd with non-alphanumerics → '-'>/memory.
export function autoMemoryDir(cwd: string, configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): string {
  return join(configDir, "projects", resolve(cwd).replace(/[^A-Za-z0-9]/g, "-"), "memory");
}

/**
 * The project an agent's folder belongs to, as Claude Code keys its auto
 * memory: the git repository's root (a worktree's main checkout, so every
 * worktree and subfolder shares one), else the folder itself; links resolved
 * (/tmp is /private/tmp on a Mac).
 */
export function memoryProjectRoot(cwd: string): string {
  let dir: string;
  try {
    dir = realpathSync(cwd);
  } catch {
    return resolve(cwd);
  }
  for (let d = dir; ; d = dirname(d)) {
    const git = join(d, ".git");
    try {
      const st = statSync(git);
      if (st.isDirectory()) return d;
      // A worktree: ".git" names its git dir, whose commondir is the main repository's.
      const m = /^gitdir:\s*(.+)$/m.exec(readFileSync(git, "utf8"));
      if (!m) return d;
      const gitdir = resolve(d, m[1]!.trim());
      const commondir = join(gitdir, "commondir");
      const common = existsSync(commondir) ? resolve(gitdir, readFileSync(commondir, "utf8").trim()) : gitdir;
      return common.endsWith(`${sep}.git`) ? dirname(common) : d;
    } catch {
      // no .git here
    }
    if (dirname(d) === d) return dir;
  }
}

/** Where Claude Code keeps an agent's project memory for its folder. */
export function agentMemoryDir(cwd: string, configDir?: string): string {
  return autoMemoryDir(memoryProjectRoot(cwd), configDir);
}

export interface MemoryViewOptions {
  /** The always-loaded files, relative to the root (the assistant's user.md / soul.md). */
  core?: string[];
  /** Core files listed (and read as empty) while they don't exist yet. */
  listedWhenMissing?: string[];
  /** Who the refusal says changed a file since the editor opened it. */
  changedKey?: "rpc.err.fileChanged" | "rpc.err.fileChangedAgent";
  /** The refusal for a path outside these files. */
  onlyKey?: "memory.onlyCore" | "memory.onlyAgentFiles";
}

// MemoryView makes memory user-visible and editable (PRD §3 目标 5) without
// owning it: content and search stay with the harness' native auto memory.
// The assistant's (its home's core files and auto memory) or an agent's (its
// folder's CLAUDE.md and Claude Code's project memory for that folder).
export class MemoryView {
  private readonly core: string[];
  private readonly listedWhenMissing: string[];
  private readonly changedKey: NonNullable<MemoryViewOptions["changedKey"]>;
  private readonly onlyKey: NonNullable<MemoryViewOptions["onlyKey"]>;

  constructor(private home: string, private autoDir: string, o: MemoryViewOptions = {}) {
    this.core = o.core ?? CORE_FILES;
    this.listedWhenMissing = o.listedWhenMissing ?? [];
    this.changedKey = o.changedKey ?? "rpc.err.fileChanged";
    this.onlyKey = o.onlyKey ?? "memory.onlyCore";
  }

  /** An agent's: `cwd`'s CLAUDE.md files and Claude Code's project memory for it. */
  static forAgent(cwd: string, configDir?: string): MemoryView {
    return new MemoryView(cwd, agentMemoryDir(cwd, configDir), {
      core: AGENT_CORE_FILES,
      listedWhenMissing: ["CLAUDE.md"],
      changedKey: "rpc.err.fileChangedAgent",
      onlyKey: "memory.onlyAgentFiles",
    });
  }

  list(): MemoryFile[] {
    const out: MemoryFile[] = [];
    for (const name of this.core) {
      const p = join(this.home, name);
      if (existsSync(p)) {
        const st = statSync(p);
        out.push({ path: name, scope: "core", size: st.size, updatedAt: st.mtimeMs });
      } else if (this.listedWhenMissing.includes(name)) {
        out.push({ path: name, scope: "core", size: 0, updatedAt: 0, missing: true });
      }
    }
    if (existsSync(this.autoDir)) {
      for (const name of readdirSync(this.autoDir).sort()) {
        if (!name.endsWith(".md")) continue;
        const st = statSync(join(this.autoDir, name));
        out.push({ path: `memory/${name}`, scope: "auto", size: st.size, updatedAt: st.mtimeMs });
      }
    }
    return out;
  }

  read(path: string): string {
    const full = this.resolve(path);
    if (this.listedWhenMissing.includes(path) && !existsSync(full)) return "";
    return readFileSync(full, "utf8");
  }

  /**
   * Writes one file. `baseUpdatedAt` (the `updatedAt` it was read at) refuses
   * the write when the file changed since: the assistant, the agent or
   * someone else wrote it while the owner's editor was open.
   */
  write(path: string, content: string, baseUpdatedAt?: number): void {
    const full = this.resolve(path);
    if (typeof baseUpdatedAt === "number" && this.mtime(path) > baseUpdatedAt + 1) throw new Error(t(this.changedKey));
    ensureDir(dirname(full));
    writeFileSync(full, content);
  }

  mtime(path: string): number {
    try {
      return statSync(this.resolve(path)).mtimeMs;
    } catch {
      return 0;
    }
  }

  coreSize(): number {
    return this.core.reduce((n, f) => {
      const p = join(this.home, f);
      return n + (existsSync(p) ? statSync(p).size : 0);
    }, 0);
  }

  private resolve(path: string): string {
    if (this.core.includes(path)) return join(this.home, path);
    const m = /^memory\/([^/]+\.md)$/.exec(path);
    if (m) {
      const full = resolve(this.autoDir, m[1]!);
      if (full.startsWith(resolve(this.autoDir) + sep)) return full;
    }
    throw new Error(t(this.onlyKey));
  }
}
