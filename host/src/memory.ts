import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import type { MemoryFile } from "./types.ts";
import { ensureDir } from "./util.ts";

// Core files are small and injected through CLAUDE.md (one injection path).
export const CORE_FILES = ["user.md", "soul.md"];
export const CORE_SOFT_LIMIT = 6 * 1024; // bytes; above this the core is too fat to load every session cheaply

// autoMemoryDir mirrors Claude Code's per-project auto memory location:
// <config dir>/projects/<cwd with non-alphanumerics → '-'>/memory.
export function autoMemoryDir(cwd: string, configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): string {
  return join(configDir, "projects", resolve(cwd).replace(/[^A-Za-z0-9]/g, "-"), "memory");
}

// MemoryView makes memory user-visible and editable (PRD §3 目标 5) without
// owning it: content and search stay with the harness' native auto memory.
export class MemoryView {
  constructor(private home: string, private autoDir: string) {}

  list(): MemoryFile[] {
    const out: MemoryFile[] = [];
    for (const name of CORE_FILES) {
      const p = join(this.home, name);
      if (existsSync(p)) {
        const st = statSync(p);
        out.push({ path: name, scope: "core", size: st.size, updatedAt: st.mtimeMs });
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
    return readFileSync(this.resolve(path), "utf8");
  }

  write(path: string, content: string): void {
    const full = this.resolve(path);
    if (full.startsWith(this.autoDir)) ensureDir(this.autoDir);
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
    return CORE_FILES.reduce((n, f) => {
      const p = join(this.home, f);
      return n + (existsSync(p) ? statSync(p).size : 0);
    }, 0);
  }

  private resolve(path: string): string {
    if (CORE_FILES.includes(path)) return join(this.home, path);
    const m = /^memory\/([^/]+\.md)$/.exec(path);
    if (m) {
      const full = resolve(this.autoDir, m[1]!);
      if (full.startsWith(resolve(this.autoDir) + sep)) return full;
    }
    throw new Error("只能读写核心文件（user.md / soul.md）或 memory/ 下的 .md 记忆");
  }
}
