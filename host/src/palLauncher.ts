import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { loginEnv } from "./ccCli.ts";
import type { Spawner } from "./harness/types.ts";

// How a Pal's Claude Code process starts (docs/pals-prd.md §7.3): through
// PaloAlly Helper, a small signed app (host/helper), so macOS holds the
// helper responsible for it and checks the helper's privacy permissions
// (the owner gives it Full Disk Access once) instead of the host's. Without
// the helper, the host starts Claude Code itself, and a Pal can only reach
// what the host can. Either way it starts from the owner's login-shell
// environment, as a terminal session would, without the variables of any
// running session.

// A helper without Full Disk Access is worse than none: macOS holds a Claude
// Code process it started at the first protected file it touches, asks for
// approval, denies it, and the process never moves again (no CPU, deaf to
// SIGTERM; seen three times on 2026-10-13, each at a sandboxd "request
// approval" for kTCCServiceSystemPolicyAllFiles attributed to the helper).
// So in "auto" the helper is used only once it can read a file only Full
// Disk Access opens; until then Pals start directly, as the assistant does.

export const HELPER_APP = "PaloAlly Helper.app";
const HELPER_EXE = "Contents/MacOS/PaloAllyHelper";
const HELPER_VERSION = "1";

/** Where the helper may be: the configured app, then the usual places. */
export function helperCandidates(root: string, configured?: string): string[] {
  return [configured, join(homedir(), "Applications", HELPER_APP), join("/Applications", HELPER_APP), join(root, HELPER_APP)].filter(
    (p): p is string => !!p,
  );
}

/** The helper's executable, if one of the candidates is a helper that runs. */
export function findHelper(candidates: string[]): string | null {
  for (const app of candidates) {
    const exe = app.endsWith(".app") ? join(app, HELPER_EXE) : app;
    if (!existsSync(exe)) continue;
    const r = spawnSync(exe, ["--version"], { encoding: "utf8", timeout: 5_000 });
    if (r.status === 0 && r.stdout.trim() === HELPER_VERSION) return exe;
  }
  return null;
}

export interface PalLaunch {
  helper: string | null; // the helper's executable; null = the host starts Claude Code itself
  env: Record<string, string>;
}

export interface SpawnHooks {
  /** Claude Code's own pid (through the helper: the grandchild's, as the helper reports it). */
  onPid: (pid: number) => void;
  /** The process the host started is gone (for the helper: Claude Code is too). */
  onExit?: () => void;
  stderr?: (s: string) => void;
}

/** A spawner for the SDK: Claude Code through the helper, or directly. */
export function makeSpawner(helper: string | null, hooks: SpawnHooks): Spawner {
  return (req) => {
    const cmd = helper ?? req.command;
    const args = helper ? ["--", req.command, ...req.args] : req.args;
    const p = spawn(cmd, args, {
      cwd: req.cwd,
      env: req.env as NodeJS.ProcessEnv,
      stdio: ["pipe", "pipe", "pipe", helper ? "pipe" : "ignore"],
    });
    if (!helper && p.pid) hooks.onPid(p.pid);
    if (helper) {
      let buf = "";
      (p.stdio[3] as NodeJS.ReadableStream | null)?.on("data", (d: Buffer) => {
        buf += String(d);
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          try {
            const m = JSON.parse(line);
            if (typeof m.pid === "number" && m.pid > 0) hooks.onPid(m.pid);
          } catch {
            /* not ours */
          }
        }
      });
    }
    p.stderr?.on("data", (d) => hooks.stderr?.(String(d)));
    p.on("error", (e) => hooks.stderr?.(`spawn: ${e.message}`));
    p.on("exit", () => hooks.onExit?.());
    req.signal?.addEventListener("abort", () => {
      if (p.exitCode === null && p.signalCode === null) p.kill("SIGTERM");
    });
    return p as unknown as ReturnType<Spawner>;
  };
}

/** A file only Full Disk Access can read (macOS keeps it for every user). */
export const FDA_PROBE = join(homedir(), "Library/Application Support/com.apple.TCC/TCC.db");

/**
 * Whether the helper holds Full Disk Access: it reads one byte of FDA_PROBE
 * through itself. A probe macOS holds is killed after `timeoutMs` and counts
 * as no.
 */
export function helperHasFullDiskAccess(exe: string, timeoutMs = 3_000, probe = FDA_PROBE): Promise<boolean> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (ok: boolean) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(ok);
    };
    const p = spawn(exe, ["--", "/usr/bin/head", "-c", "1", probe], { stdio: "ignore" });
    const timer = setTimeout(() => {
      try {
        p.kill("SIGKILL");
      } catch {
        /* gone */
      }
      finish(false);
    }, timeoutMs);
    p.on("error", () => finish(false));
    p.on("exit", (code) => finish(code === 0));
  });
}

export interface LauncherOptions {
  root: string;
  helperApp?: () => string | undefined; // config.pals.helperApp
  mode?: () => "auto" | "helper" | "direct"; // config.pals.launch
  env?: () => Promise<Record<string, string>>; // default: the owner's login shell
  find?: (candidates: string[]) => string | null;
  /** Whether the helper holds Full Disk Access (tests fake it). */
  fda?: (exe: string) => Promise<boolean>;
  log?: (s: string) => void;
}

// PalLauncher looks for the helper (again after a minute, so installing it
// takes effect without a restart) and remembers when it couldn't start
// anything, to start Claude Code directly from then on.
export class PalLauncher {
  private found: { at: number; exe: string | null } | null = null;
  private broken: string | null = null;
  private access: { at: number; exe: string; ok: boolean } | null = null;

  constructor(private o: LauncherOptions) {}

  private helperExe(): string | null {
    const mode = this.o.mode?.() ?? "auto";
    if (mode === "direct" || this.broken) return null;
    if (!this.found || Date.now() - this.found.at > 60_000) {
      const exe = (this.o.find ?? findHelper)(helperCandidates(this.o.root, this.o.helperApp?.()));
      if (exe !== this.found?.exe) this.o.log?.(exe ? `pals start through ${exe}` : "PaloAlly Helper not found: Pals start directly");
      this.found = { at: Date.now(), exe };
    }
    return this.found.exe;
  }

  /** Whether Pals start through the helper now (as of the last check of its access). */
  get usesHelper(): boolean {
    const exe = this.helperExe();
    if (!exe) return false;
    if ((this.o.mode?.() ?? "auto") === "helper") return true;
    return !!this.access && this.access.exe === exe && this.access.ok;
  }

  /** The helper to start through, if it may be used: in "auto", only with Full Disk Access (checked again every minute). */
  private async usableHelper(): Promise<string | null> {
    const exe = this.helperExe();
    if (!exe || (this.o.mode?.() ?? "auto") === "helper") return exe;
    if (!this.access || this.access.exe !== exe || Date.now() - this.access.at > 60_000) {
      const ok = await (this.o.fda ?? helperHasFullDiskAccess)(exe).catch(() => false);
      if (ok !== this.access?.ok) {
        this.o.log?.(ok ? "PaloAlly Helper has Full Disk Access: Pals start through it" : "PaloAlly Helper has no Full Disk Access yet: Pals start directly");
      }
      this.access = { at: Date.now(), exe, ok };
    }
    return this.access.ok ? exe : null;
  }

  /** The helper itself failed (not Claude Code): start directly from now on. */
  markBroken(why: string): void {
    if (this.broken) return;
    this.broken = why;
    this.o.log?.(`PaloAlly Helper failed (${why}); Pals start directly`);
  }

  async launch(): Promise<PalLaunch> {
    return { helper: await this.usableHelper(), env: await (this.o.env ?? loginEnv)() };
  }
}

/** The helper's own failure (it couldn't start anything), as it reports it. */
export function isHelperFailure(message: string): boolean {
  return /PaloAlly Helper:/.test(message);
}
