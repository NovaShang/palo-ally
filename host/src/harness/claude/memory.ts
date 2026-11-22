import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { projectDirName } from "./paths.ts";

// Where Claude Code keeps memory: a folder's instruction files and its per-project auto memory.

// An agent's: the folder's own instructions Claude Code loads every session.
// CLAUDE.md is always listed (the owner may start one); the others only when there.
export const AGENT_CORE_FILES = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"];

// autoMemoryDir mirrors Claude Code's per-project auto memory location:
// <config dir>/projects/<cwd, links resolved, with non-alphanumerics → '-'>/memory.
export function autoMemoryDir(cwd: string, configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): string {
  return join(configDir, "projects", projectDirName(cwd), "memory");
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
