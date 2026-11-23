import { execFile } from "node:child_process";
import { chmodSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir, userInfo } from "node:os";
import { join } from "node:path";

// 「在终端打开」: an agent's session in the owner's own terminal. A small
// .command file (what Finder opens in the default terminal, with no
// Automation permission asked), run once: it takes itself away, leaves out
// whatever the host's own sessions set, goes to the folder and runs the
// harness' resume line through the owner's login shell, as if typed there.

/** There's no desktop to open a window on (not a Mac). */
export class NoDesktop extends Error {}

/** What a terminal runs to open a session (the harness says): a fixed line with nothing of the owner's in it. */
export interface TerminalRun {
  command: string;
  /** The variables of the harness' own sessions (an extended regular expression on the whole name): not handed on. */
  unset: string;
  /** Set for it (where the harness keeps its state, when the host was told). */
  env?: Record<string, string>;
}

/** A word for /bin/sh, whatever is in it. */
export const shWord = (s: string): string => `'${s.replace(/'/g, `'\\''`)}'`;

/** The .command file's words. */
export function terminalScript(cwd: string, run: TerminalRun, o: { shell?: string } = {}): string {
  const shell = o.shell && /^\/[\w./+-]+$/.test(o.shell) ? o.shell : "/bin/zsh";
  // The folder goes to the login shell in a variable, and is entered after
  // its startup files ran (they may cd); the line itself is the same for any
  // shell (fish has its own quoting). csh takes no -l or -i with -c.
  const line = shWord(`cd "$PALO_TERMINAL_DIR" && ${run.command}`);
  return [
    "#!/bin/sh",
    "{",
    'rm -f -- "$0"',
    `for v in $(/usr/bin/env | /usr/bin/sed -nE 's/^(${run.unset})=.*/\\1/p'); do unset "$v"; done`,
    ...Object.entries(run.env ?? {}).map(([k, v]) => `export ${k}=${shWord(v)}`),
    `export PALO_TERMINAL_DIR=${shWord(cwd)}`,
    'cd -- "$PALO_TERMINAL_DIR" || exit 1',
    `s="\${SHELL:-${shell}}"`,
    `[ -x "$s" ] || s=/bin/zsh`,
    `case "$s" in`,
    `*/csh | */tcsh) exec "$s" -c ${line} ;;`,
    `*) exec "$s" -l -i -c ${line} ;;`,
    "esac",
    "}",
    "",
  ].join("\n");
}

const PREFIX = "terminal-";

export function terminalFile(dir: string, id: string): string {
  return join(dir, `${PREFIX}${id.replace(/[^\w-]/g, "")}.command`);
}

/** Written for the owner only (it runs as them). */
export function writeTerminalFile(file: string, script: string, dir: string): void {
  mkdirSync(dir, { recursive: true });
  rmSync(file, { force: true });
  writeFileSync(file, script, { mode: 0o700 });
  chmodSync(file, 0o700);
}

export function removeTerminalFile(file: string): void {
  try {
    rmSync(file, { force: true });
  } catch {
    /* gone */
  }
}

/** Ones no terminal ever started (the host stopped meanwhile). */
export function sweepTerminalFiles(dir: string, olderThanMs: number, now: number): void {
  try {
    for (const f of readdirSync(dir)) {
      if (!f.startsWith(PREFIX) || !f.endsWith(".command")) continue;
      const p = join(dir, f);
      if (now - statSync(p).mtimeMs > olderThanMs) removeTerminalFile(p);
    }
  } catch {
    /* no folder yet */
  }
}

/** The owner's login shell (what the .command file falls back to without $SHELL). */
export function loginShell(): string | undefined {
  try {
    return userInfo().shell ?? undefined;
  } catch {
    return undefined;
  }
}

/**
 * macOS: `open <file>` starts it in the owner's default terminal. A terminal
 * not running yet takes over open's environment, so it gets a bare one.
 */
export function defaultOpenTerminal(file: string): Promise<void> {
  if (process.platform !== "darwin") return Promise.reject(new NoDesktop());
  let user = process.env.USER ?? "";
  try {
    user = userInfo().username;
  } catch {
    /* keep */
  }
  const shell = loginShell();
  const env: Record<string, string> = {
    HOME: homedir(),
    USER: user,
    LOGNAME: user,
    TMPDIR: process.env.TMPDIR ?? tmpdir(),
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    ...(shell ? { SHELL: shell } : {}),
  };
  return new Promise((ok, fail) => execFile("/usr/bin/open", [file], { env, timeout: 15_000 }, (err) => (err ? fail(err) : ok())));
}
