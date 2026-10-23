import { statSync, watch, type FSWatcher } from "node:fs";
import { basename, dirname } from "node:path";
import type { Bus } from "./bus.ts";
import { scopeLabel, type FileBrowser, type FileScope } from "./files.ts";

// Previews that follow the file on disk (like an editor's). The app says which
// file it is showing (`files.watch {scope, path}`) and renews that every half
// minute while the preview is on screen; a watch nobody renews lapses, so a
// device that went away needs no goodbye (`files.unwatch` is only quicker).
// The host watches the file's folder (an editor that saves by writing a new
// file and renaming it over the old one still counts) and, in case that
// misses, compares each file's size, mtime and inode every two seconds. A
// change is reported once things settle (~200 ms) as `files.changed` with the
// scope and path exactly as the app gave them, so it can match its preview.

export interface FileWatchDeps {
  files: FileBrowser;
  bus: Bus;
  now?: () => number;
  /** How long a watch lives without a renewal. */
  leaseMs?: number;
  /** The stat sweep behind the folder watch. */
  pollMs?: number;
  /** Changes this close together are one. */
  settleMs?: number;
  /** A test can turn the folder watch off to exercise the sweep alone. */
  folderWatch?: boolean;
}

export interface FileChanged {
  scope: FileScope;
  path: string;
  size: number;
  mtime: number;
  /** The file is gone (deleted or moved away); a later change brings it back. */
  gone?: boolean;
}

interface Entry {
  key: string;
  scope: FileScope;
  path: string;
  real: string;
  sig: string;
  expires: number;
}

/** At most this many files watched at once (the oldest lease goes first). */
const MAX_WATCHES = 64;

export class FileWatches {
  private readonly entries = new Map<string, Entry>();
  private readonly folders = new Map<string, FSWatcher>();
  private readonly settling = new Map<string, ReturnType<typeof setTimeout>>();
  private sweep?: ReturnType<typeof setInterval>;
  private readonly now: () => number;
  readonly leaseMs: number;

  constructor(private readonly d: FileWatchDeps) {
    this.now = d.now ?? Date.now;
    this.leaseMs = d.leaseMs ?? 90_000;
  }

  /** Start (or renew) watching one file; answers its current size and mtime. */
  watch(scope: FileScope, path: string): { size: number; mtime: number; lease: number } {
    const st = this.d.files.stat(scope, path);
    const key = keyOf(scope, path);
    const had = this.entries.get(key);
    const expires = this.now() + this.leaseMs;
    if (had && had.real === st.real) {
      had.expires = expires;
    } else {
      if (had) this.drop(key);
      this.entries.set(key, { key, scope, path, real: st.real, sig: signature(st.real) ?? "", expires });
      this.trim();
      this.follow(dirname(st.real));
      this.startSweep();
    }
    return { size: st.size, mtime: st.mtime, lease: this.leaseMs };
  }

  unwatch(scope: FileScope, path: string): void {
    this.drop(keyOf(scope, path));
  }

  /** How many files are watched (tests). */
  get count(): number {
    return this.entries.size;
  }

  /** Compare every watched file now; lapsed leases end. Returns what changed. */
  check(only?: Set<string>): FileChanged[] {
    const out: FileChanged[] = [];
    const now = this.now();
    for (const e of [...this.entries.values()]) {
      if (e.expires <= now) {
        this.drop(e.key);
        continue;
      }
      if (only && !only.has(e.key)) continue;
      const sig = signature(e.real);
      if ((sig ?? "") === e.sig) continue;
      e.sig = sig ?? "";
      let st: { size: number; mtimeMs: number } | null = null;
      try {
        st = statSync(e.real);
      } catch {
        st = null;
      }
      const change: FileChanged = st
        ? { scope: e.scope, path: e.path, size: st.size, mtime: Math.round(st.mtimeMs) }
        : { scope: e.scope, path: e.path, size: 0, mtime: 0, gone: true };
      out.push(change);
      this.d.bus.emit("files.changed", change);
    }
    return out;
  }

  stop(): void {
    for (const k of [...this.entries.keys()]) this.drop(k);
    if (this.sweep) clearInterval(this.sweep);
    this.sweep = undefined;
  }

  // ---------------- internals ----------------

  private drop(key: string): void {
    const e = this.entries.get(key);
    if (!e) return;
    this.entries.delete(key);
    const t = this.settling.get(key);
    if (t) clearTimeout(t);
    this.settling.delete(key);
    const dir = dirname(e.real);
    if (![...this.entries.values()].some((x) => dirname(x.real) === dir)) {
      this.folders.get(dir)?.close();
      this.folders.delete(dir);
    }
    if (!this.entries.size && this.sweep) {
      clearInterval(this.sweep);
      this.sweep = undefined;
    }
  }

  private trim(): void {
    while (this.entries.size > MAX_WATCHES) {
      const oldest = [...this.entries.values()].sort((a, b) => a.expires - b.expires)[0]!;
      this.drop(oldest.key);
    }
  }

  /** One fs.watch per folder holding watched files. */
  private follow(dir: string): void {
    if (this.d.folderWatch === false || this.folders.has(dir)) return;
    try {
      const w = watch(dir, { persistent: false }, (_event, name) => {
        const hit = [...this.entries.values()].filter((e) => dirname(e.real) === dir && (!name || String(name) === basename(e.real)));
        for (const e of hit) this.settle(e.key);
      });
      w.on("error", () => {
        w.close();
        this.folders.delete(dir);
      });
      this.folders.set(dir, w);
    } catch {
      // Not watchable (a network volume, no permission): the sweep still sees it.
    }
  }

  private settle(key: string): void {
    const t = this.settling.get(key);
    if (t) clearTimeout(t);
    const timer = setTimeout(() => {
      this.settling.delete(key);
      this.check(new Set([key]));
    }, this.d.settleMs ?? 200);
    (timer as any).unref?.();
    this.settling.set(key, timer);
  }

  private startSweep(): void {
    if (this.sweep) return;
    this.sweep = setInterval(() => this.check(), this.d.pollMs ?? 2000);
    (this.sweep as any).unref?.();
  }
}

function keyOf(scope: FileScope, path: string): string {
  return `${scopeLabel(scope)}\0${path}`;
}

/** What says the file changed: size, mtime (ns-ish) and inode; null when it's gone. */
function signature(real: string): string | null {
  try {
    const st = statSync(real);
    return `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch {
    return null;
  }
}
