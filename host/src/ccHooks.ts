import { chmodSync, existsSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { t } from "./i18n/index.ts";
import { dirname, join } from "node:path";
import type { Paths } from "./config.ts";
import { LineReader } from "./channels/local.ts";
import { ensureDir, readJson, writeJson } from "./util.ts";

// PaloAlly's global Claude Code hooks (docs/sessions-prd.md §6.3).
//
// The owner turns them on in the app; the host then appends its own entries
// to Claude Code's user settings (~/.claude/settings.json, or
// $CLAUDE_CONFIG_DIR/settings.json) and turning them off removes exactly
// those entries again. Hooks already there are never touched. Every entry runs
// one tiny script under ~/.paloally/bin that asks the host over a local
// socket; when the host isn't there it exits at once with no output, so
// Claude Code behaves as if PaloAlly weren't installed.

/** The events PaloAlly listens to, with each hook's time limit in seconds. */
export const HOOK_EVENTS: Record<string, number> = {
  PermissionRequest: 300,
  SessionStart: 5,
  Stop: 5,
  Notification: 5,
  SessionEnd: 5,
};

// Marks PaloAlly's entries in the settings file (a shell comment at the end
// of the command), so removing them never needs to guess.
const MARK = "# PaloAlly";

/** How long the hook waits for the host to say it's there before giving up. */
export const HOOK_ACK_MS = 350;

const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

export function hookCommand(paths: Paths, event: string): string {
  return `${shq(join(paths.bin, "cc-hook"))} ${event} ${MARK}`;
}

export function isPaloAllyHook(h: unknown): boolean {
  const cmd = (h as { command?: unknown })?.command;
  return typeof cmd === "string" && cmd.trimEnd().endsWith(MARK);
}

// The shell wrapper: PaloAlly's own sessions (PALOALLY_SESSION=1: the
// assistant, its probes and its Pals), a host that isn't running (no socket)
// and a missing bun leave at once, without starting anything.
function wrapperScript(bun: string, script: string, socket: string): string {
  return `#!/bin/sh
# PaloAlly's Claude Code hook (installed by PaloAlly; the app's 会话 switch removes it).
[ "$PALOALLY_SESSION" = "1" ] && exit 0
SOCK=${shq(socket)}
[ -S "$SOCK" ] || exit 0
BUN=${shq(bun)}
[ -x "$BUN" ] || exit 0
exec "$BUN" ${shq(script)} "$SOCK"
`;
}

// The hook itself. Fails open: no host, no socket, a slow host, bad input, an
// error of any kind — exit 0 with no output.
function hookScript(): string {
  return `// PaloAlly's Claude Code hook. Written by the PaloAlly host; edits are overwritten.
import { connect } from "node:net";
const SOCK = process.argv[2];
const ACK_MS = ${HOOK_ACK_MS};
let finished = false;
function done(out) {
  if (finished) return;
  finished = true;
  if (out) process.stdout.write(JSON.stringify(out) + "\\n", () => process.exit(0));
  else process.exit(0);
}
process.on("uncaughtException", () => done(null));
process.on("unhandledRejection", () => done(null));
const stdinTimer = setTimeout(() => done(null), 1000);
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (input += c));
process.stdin.on("error", () => done(null));
process.stdin.on("end", () => {
  clearTimeout(stdinTimer);
  let payload;
  try {
    payload = JSON.parse(input);
  } catch {
    return done(null);
  }
  const event = String(payload?.hook_event_name ?? "");
  const local = null;
  const waits = event === "PermissionRequest";
  const ackTimer = setTimeout(() => done(local), ACK_MS);
  const sock = connect(SOCK);
  let buf = "";
  sock.setEncoding("utf8");
  sock.on("connect", () => sock.write(JSON.stringify({ event, payload, env: { jobDir: process.env.CLAUDE_JOB_DIR || undefined } }) + "\\n"));
  sock.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let m;
      try {
        m = JSON.parse(line);
      } catch {
        return done(local);
      }
      if (m && m.ack) {
        clearTimeout(ackTimer);
        if (!waits) return done(local);
      } else if (m && "output" in m) {
        return done(m.output || local);
      }
    }
  });
  sock.on("error", () => done(local));
  sock.on("close", () => done(local));
});
`;
}

interface InstallRecord {
  // what PaloAlly's install created, so removing it leaves the file as it was
  created: { file: boolean; hooks: boolean; events: string[] };
  installedAt: number;
}

export interface HookInstallerOptions {
  paths: Paths;
  claudeDir: string;
  bun?: string; // the bun binary the hook runs on; default: the host's own
}

export class HookInstaller {
  constructor(private o: HookInstallerOptions) {}

  get settingsPath(): string {
    return join(this.o.claudeDir, "settings.json");
  }

  /** PaloAlly's entries are in the settings file (the switch's state). */
  installed(): boolean {
    let s: any;
    try {
      s = JSON.parse(readFileSync(this.settingsPath, "utf8"));
    } catch {
      return false;
    }
    const hooks = s?.hooks;
    if (!hooks || typeof hooks !== "object") return false;
    return Object.keys(HOOK_EVENTS).some((ev) => Array.isArray(hooks[ev]) && hooks[ev].some((g: any) => g?.hooks?.some?.(isPaloAllyHook)));
  }

  /**
   * At the host's start, with the hooks on: the scripts follow this host's
   * version, and entries an older version wrote are brought up to date
   * (the settings file is only written when something differs).
   */
  refresh(): void {
    if (!this.installed()) return;
    this.writeScripts();
    let s: any;
    try {
      s = JSON.parse(readFileSync(this.settingsPath, "utf8"));
    } catch {
      return;
    }
    const current = Object.entries(HOOK_EVENTS).every(([ev, timeout]) => {
      const ours = (Array.isArray(s.hooks?.[ev]) ? s.hooks[ev] : []).flatMap((g: any) => (Array.isArray(g?.hooks) ? g.hooks.filter(isPaloAllyHook) : []));
      return ours.length === 1 && ours[0].command === hookCommand(this.o.paths, ev) && ours[0].timeout === timeout;
    });
    if (!current) this.install();
  }

  /** (Re)writes the hook scripts; their content follows this host's version. */
  writeScripts(): void {
    const { paths } = this.o;
    ensureDir(paths.bin);
    const script = join(paths.bin, "cc-hook.mjs");
    const wrapper = join(paths.bin, "cc-hook");
    writeFileSync(script, hookScript(), { mode: 0o644 });
    writeFileSync(wrapper, wrapperScript(this.o.bun ?? process.execPath, script, paths.hookSocket), { mode: 0o755 });
    chmodSync(wrapper, 0o755);
  }

  install(): void {
    const { raw, settings } = this.read();
    this.writeScripts();
    const prev = readJson<InstallRecord | null>(this.o.paths.ccHooks, null);
    const stripped = removeOurs(settings);
    // A copy of the file as it was before PaloAlly touched it (not one that
    // already has PaloAlly's entries in it).
    const hadOurs = JSON.stringify(stripped) !== JSON.stringify(settings);
    if (raw !== null && !hadOurs) {
      ensureDir(dirname(this.o.paths.ccSettingsBackup));
      writeFileSync(this.o.paths.ccSettingsBackup, raw, { mode: 0o600 });
    }
    const created: InstallRecord["created"] = {
      file: raw === null || (prev?.created.file ?? false),
      hooks: !stripped.hooks || typeof stripped.hooks !== "object" || (prev?.created.hooks ?? false),
      events: [],
    };
    const next = { ...stripped };
    const hooks: Record<string, unknown[]> = next.hooks && typeof next.hooks === "object" ? { ...next.hooks } : {};
    for (const [ev, timeout] of Object.entries(HOOK_EVENTS)) {
      const list = Array.isArray(hooks[ev]) ? [...hooks[ev]!] : [];
      if (!Array.isArray(hooks[ev]) || prev?.created.events.includes(ev)) created.events.push(ev);
      list.push({ hooks: [{ type: "command", command: hookCommand(this.o.paths, ev), timeout }] });
      hooks[ev] = list;
    }
    next.hooks = hooks;
    this.write(next, raw);
    writeJson(this.o.paths.ccHooks, { created, installedAt: Date.now() } satisfies InstallRecord);
  }

  uninstall(): void {
    const { raw, settings } = this.read();
    if (raw === null) return;
    const rec = readJson<InstallRecord | null>(this.o.paths.ccHooks, null);
    const next = removeOurs(settings, rec?.created);
    if (rec?.created.file && Object.keys(next).length === 0) {
      unlinkSync(this.realPath());
    } else {
      // Nothing else changed since the install: put back the exact bytes.
      let backup: string | null = null;
      try {
        backup = readFileSync(this.o.paths.ccSettingsBackup, "utf8");
      } catch {
        /* no backup */
      }
      let same = false;
      try {
        same = backup !== null && JSON.stringify(JSON.parse(backup)) === JSON.stringify(next);
      } catch {
        same = false;
      }
      if (same) this.writeRaw(backup!);
      else this.write(next, raw);
    }
    try {
      unlinkSync(this.o.paths.ccHooks);
    } catch {
      /* not there */
    }
  }

  private realPath(): string {
    // A settings file that is a symlink (dotfiles) is written through, not replaced.
    try {
      return realpathSync(this.settingsPath);
    } catch {
      return this.settingsPath;
    }
  }

  private read(): { raw: string | null; settings: Record<string, any> } {
    let raw: string | null = null;
    try {
      raw = readFileSync(this.settingsPath, "utf8");
    } catch {
      return { raw: null, settings: {} };
    }
    if (!raw.trim()) return { raw, settings: {} };
    let settings: unknown;
    try {
      settings = JSON.parse(raw);
    } catch {
      throw new Error(t("hooks.badJson", { path: this.settingsPath }));
    }
    if (!settings || typeof settings !== "object" || Array.isArray(settings)) throw new Error(t("hooks.badContent", { path: this.settingsPath }));
    return { raw, settings: settings as Record<string, any> };
  }

  private write(value: Record<string, unknown>, like: string | null): void {
    // Same indentation and final newline as the file had.
    const indent = like ? (/\n([ \t]+)"/.exec(like)?.[1] ?? "  ") : "  ";
    const tail = like === null || like.endsWith("\n") ? "\n" : "";
    this.writeRaw(JSON.stringify(value, null, indent) + tail);
  }

  private writeRaw(text: string): void {
    const path = this.realPath();
    ensureDir(dirname(path));
    let mode = 0o600;
    try {
      mode = statSync(path).mode & 0o777;
    } catch {
      /* new file */
    }
    const tmp = `${path}.paloally.${process.pid}.tmp`;
    writeFileSync(tmp, text, { mode });
    renameSync(tmp, path);
  }
}

// removeOurs drops PaloAlly's hook commands; a matcher group left with no
// hooks goes, and so does an event list (or the whole `hooks` key) that
// PaloAlly's install created and that is empty again.
function removeOurs(settings: Record<string, any>, created?: InstallRecord["created"]): Record<string, any> {
  const out = { ...settings };
  if (!out.hooks || typeof out.hooks !== "object" || Array.isArray(out.hooks)) return out;
  const hooks: Record<string, unknown> = {};
  for (const [ev, list] of Object.entries(out.hooks as Record<string, unknown>)) {
    if (!Array.isArray(list)) {
      hooks[ev] = list;
      continue;
    }
    const kept = list.flatMap((g: any) => {
      if (!g || typeof g !== "object" || !Array.isArray(g.hooks) || !g.hooks.some(isPaloAllyHook)) return [g];
      const rest = g.hooks.filter((h: unknown) => !isPaloAllyHook(h));
      return rest.length ? [{ ...g, hooks: rest }] : [];
    });
    if (!kept.length && created?.events.includes(ev)) continue;
    hooks[ev] = kept;
  }
  if (!Object.keys(hooks).length && created?.hooks) delete out.hooks;
  else out.hooks = hooks;
  return out;
}

// ---------------- the host's end of the hook socket ----------------

export interface HookContext {
  /** Aborted when the hook went away first (Claude Code killed it: answered in the terminal, or the session ended). */
  signal: AbortSignal;
  env: { jobDir?: string };
}

export type HookHandler = (event: string, payload: Record<string, any>, ctx: HookContext) => Promise<unknown> | unknown;

// HookServer: one connection per hook run. It reads the hook's one line,
// says it's there at once (the hook gives up after HOOK_ACK_MS otherwise),
// then answers with the handler's output (null = print nothing).
export class HookServer {
  private server: ReturnType<typeof Bun.listen> | null = null;

  constructor(
    private path: string,
    private handler: HookHandler,
    private log: (s: string) => void = () => {},
  ) {}

  start(): void {
    ensureDir(dirname(this.path));
    if (existsSync(this.path)) unlinkSync(this.path);
    const handler = this.handler;
    const log = this.log;
    type Data = { reader: LineReader; started: boolean; abort: AbortController; closed: boolean };
    this.server = Bun.listen<Data>({
      unix: this.path,
      socket: {
        open(sock) {
          sock.data = { reader: new LineReader(), started: false, abort: new AbortController(), closed: false };
        },
        data(sock, chunk) {
          if (sock.data.started) return;
          const line = sock.data.reader.push(chunk)[0];
          if (line === undefined) return;
          sock.data.started = true;
          let msg: any;
          try {
            msg = JSON.parse(line);
          } catch {
            sock.end();
            return;
          }
          sock.write(JSON.stringify({ ack: true }) + "\n");
          const payload = msg?.payload && typeof msg.payload === "object" ? msg.payload : {};
          const event = String(msg?.event || payload.hook_event_name || "");
          Promise.resolve()
            .then(() => handler(event, payload, { signal: sock.data.abort.signal, env: msg?.env ?? {} }))
            .catch((e) => {
              log(`hook ${event} failed: ${e instanceof Error ? e.message : e}`);
              return null;
            })
            .then((output) => {
              if (sock.data.closed) return;
              sock.write(JSON.stringify({ output: output ?? null }) + "\n");
              sock.end();
            });
        },
        close(sock) {
          sock.data.closed = true;
          sock.data.abort.abort("closed");
        },
        error(sock) {
          sock.data.closed = true;
          sock.data.abort.abort("closed");
        },
      },
    });
    chmodSync(this.path, 0o600);
  }

  stop(): void {
    this.server?.stop(true);
    this.server = null;
    try {
      if (existsSync(this.path)) unlinkSync(this.path);
    } catch {
      /* ignore */
    }
  }
}
