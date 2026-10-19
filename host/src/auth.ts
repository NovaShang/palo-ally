import { spawn, type ChildProcess } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanSessionEnv, findClaude, loginEnv } from "./ccCli.ts";
import type { AuthStatus, LoginStatus } from "./types.ts";
import { readJson, writeJson } from "./util.ts";

// Claude Code's login, as the host sees it. When it runs out (the OAuth
// session can't be refreshed), every turn of the assistant, the Pals and the
// probe fails the same way. The first failure marks the login expired: the
// owner is told once, schedules and probes hold, and what failed is kept.
// The owner signs in again from the phone (Claude Code's own `claude auth
// login`, driven through expect: the link goes to the phone, the code comes
// back) or at the computer; then the host resumes what was held.
//
// The code the owner pastes goes straight to that process's terminal: never
// into the chat, the audit or a log.

/** What a failed turn or probe said, by the SDK's error kind or, failing that, its words. */
export function isAuthFailure(text?: string, category?: string): boolean {
  if (category === "authentication_failed") return true;
  return !!text && AUTH_WORDS.test(text);
}

const AUTH_WORDS =
  /authentication_failed|authentication_error|failed to authenticate|oauth (session|token) (has )?expired|could not be refreshed|please run \/login|not logged in|invalid (api|x-api) key/i;

/** What failed while the login was out, to resume once it's back. */
export interface Missed {
  palo: { text: string; at: number }[]; // the assistant's turns (the owner's words or what the turn was for)
  pals: Record<string, string>; // Pal id → name
  schedules: string[]; // watch ids whose run was held or failed
}

export type AuthFailure =
  | { kind: "palo"; text: string; watchId?: string }
  | { kind: "pal"; id: string; name: string }
  | { kind: "probe" }
  | { kind: "schedule"; watchId: string };

interface Saved {
  since?: number;
  missed?: Missed;
  notified?: boolean;
  stamp?: string | null;
}

export interface AuthDeps {
  path: string; // where the expired state is kept across restarts
  scriptDir: string; // where the expect script is written
  now?: () => number;
  /** Tells the owner (push, WeChat); true when it went out (not held for quiet hours). */
  notify: () => Promise<boolean>;
  /** The login is back: resume what was held. `how`: phone | computer | turn. */
  recovered: (missed: Missed, how: string, since: number) => void;
  changed: () => void;
  audit: (type: string, data?: Record<string, unknown>) => void;
  log: (s: string) => void;
  /** When Claude Code's stored login last changed (no secret), or null. */
  stamp?: () => Promise<string | null>;
  /** Whether Claude Code says it's logged in now. */
  loggedIn?: () => Promise<boolean>;
  /** Starts `claude auth login` under expect (tests fake it). */
  spawnLogin?: () => LoginProcess;
  pollMs?: number;
  loginTimeoutMs?: number;
}

/** The login process as AuthWatch drives it: lines out, a code in, an exit code. */
export interface LoginProcess {
  onLine(f: (line: string) => void): void;
  onExit(f: (code: number) => void): void;
  write(line: string): void;
  kill(): void;
}

const empty = (): Missed => ({ palo: [], pals: {}, schedules: [] });

export class AuthWatch {
  private since: number | null = null;
  private missed: Missed = empty();
  private notified = false;
  private stampAtExpiry: string | null = null;
  private login: (LoginStatus & { proc?: LoginProcess; timer?: ReturnType<typeof setTimeout> }) | null = null;
  private poll: ReturnType<typeof setInterval> | null = null;
  private now: () => number;

  constructor(private d: AuthDeps) {
    this.now = d.now ?? Date.now;
    const s = readJson<Saved>(d.path, {});
    if (s.since) {
      this.since = s.since;
      this.missed = { ...empty(), ...s.missed };
      this.notified = !!s.notified;
      this.stampAtExpiry = s.stamp ?? null;
    }
  }

  start(): void {
    if (this.since) this.startPolling();
  }

  stop(): void {
    if (this.poll) clearInterval(this.poll);
    this.poll = null;
    this.endLogin();
  }

  get expired(): boolean {
    return this.since !== null;
  }

  /** For the status: nothing while the login works and no sign-in is under way. */
  status(): AuthStatus | undefined {
    const l = this.login;
    if (this.since === null && !l) return undefined;
    const login: LoginStatus | undefined = l ? { state: l.state, startedAt: l.startedAt, ...(l.url ? { url: l.url } : {}), ...(l.error ? { error: l.error } : {}) } : undefined;
    return { state: this.since === null ? "ok" : "expired", ...(this.since !== null ? { since: this.since } : {}), ...(login ? { login } : {}) };
  }

  /** Something failed for want of a login. The first one marks it expired and tells the owner. */
  failed(f: AuthFailure): void {
    const first = this.since === null;
    if (first) {
      this.since = this.now();
      this.missed = empty();
      this.notified = false;
      this.d.log(`Claude Code login expired (${f.kind})`);
      this.d.audit("auth.expired", { by: f.kind });
    }
    this.keep(f);
    this.save();
    if (first) {
      void this.d.stamp?.().then((s) => {
        this.stampAtExpiry = s;
        this.save();
      });
      this.startPolling();
      void this.tell();
      this.d.changed();
    }
  }

  /** A schedule came due while the login is out: held, run once it's back. */
  hold(watchId: string): void {
    this.keep({ kind: "schedule", watchId });
    this.save();
  }

  /** A turn went through: the login works again (signed in at the computer, say). */
  worked(): void {
    if (this.since !== null && !this.login) this.recover("turn");
  }

  // ---------------- signing in from the phone ----------------

  /** auth.login.start: starts Claude Code's login and gives back its link. */
  async startLogin(by: string): Promise<AuthStatus | undefined> {
    if (this.login && this.login.state !== "failed") return this.status();
    this.endLogin();
    const spawnLogin = this.d.spawnLogin ?? (() => expectLogin(this.d.scriptDir));
    const proc = spawnLogin();
    const login: NonNullable<AuthWatch["login"]> = { state: "starting", startedAt: this.now(), proc };
    this.login = login;
    this.d.audit("auth.login.start", { by });
    proc.onLine((line) => {
      if (this.login !== login) return;
      if (line.startsWith("URL ")) {
        login.url = line.slice(4).trim();
        login.state = "waiting";
      } else if (line === "INVALID") {
        login.state = "invalid";
        this.d.audit("auth.login.invalid", {});
      } else if (line.startsWith("ERR")) {
        login.error = line.slice(3).trim() || "failed";
      } else return;
      this.d.changed();
    });
    proc.onExit((code) => {
      if (this.login !== login) return;
      login.proc = undefined;
      if (code === 0) void this.afterLogin(login);
      else this.loginFailed(login, login.error || `exit ${code}`);
    });
    login.timer = setTimeout(() => {
      if (this.login === login) this.loginFailed(login, "timeout");
    }, this.d.loginTimeoutMs ?? 15 * 60_000);
    this.d.changed();
    return this.status();
  }

  /** auth.login.code: the code the authorization page showed, typed into the login. */
  submitCode(code: string): AuthStatus | undefined {
    const l = this.login;
    const c = String(code ?? "").trim();
    if (!l?.proc || (l.state !== "waiting" && l.state !== "invalid")) throw new Error("no login waiting for a code");
    if (!c || c.length > 2000 || /[\r\n]/.test(c)) throw new Error("bad code");
    l.state = "checking";
    l.proc.write(c);
    this.d.audit("auth.login.code", {});
    this.d.changed();
    return this.status();
  }

  /** auth.login.cancel */
  cancelLogin(): AuthStatus | undefined {
    if (this.login) this.d.audit("auth.login.cancel", {});
    this.endLogin();
    this.d.changed();
    return this.status();
  }

  private async afterLogin(login: NonNullable<AuthWatch["login"]>): Promise<void> {
    const ok = this.d.loggedIn ? await this.d.loggedIn().catch(() => false) : true;
    if (this.login !== login) return;
    if (!ok) return this.loginFailed(login, "still not logged in");
    this.d.audit("auth.login.done", {});
    this.endLogin();
    if (this.since !== null) this.recover("phone");
    else this.d.changed();
  }

  private loginFailed(login: NonNullable<AuthWatch["login"]>, why: string): void {
    login.proc?.kill();
    login.proc = undefined;
    if (login.timer) clearTimeout(login.timer);
    login.state = "failed";
    login.error = why;
    this.d.audit("auth.login.failed", { why });
    this.d.changed();
  }

  private endLogin(): void {
    const l = this.login;
    this.login = null;
    if (!l) return;
    if (l.timer) clearTimeout(l.timer);
    l.proc?.kill();
  }

  // ---------------- internals ----------------

  private keep(f: AuthFailure): void {
    const m = this.missed;
    if (f.kind === "palo") {
      if (f.watchId) {
        if (!m.schedules.includes(f.watchId)) m.schedules.push(f.watchId);
      } else if (f.text.trim() && m.palo.length < 20) m.palo.push({ text: f.text.trim().slice(0, 300), at: this.now() });
    } else if (f.kind === "pal") m.pals[f.id] = f.name;
    else if (f.kind === "schedule" && !m.schedules.includes(f.watchId)) m.schedules.push(f.watchId);
  }

  private recover(how: string): void {
    const since = this.since ?? this.now();
    const missed = this.missed;
    this.since = null;
    this.missed = empty();
    this.notified = false;
    this.stampAtExpiry = null;
    if (this.poll) clearInterval(this.poll);
    this.poll = null;
    this.save();
    this.d.log(`Claude Code login is back (${how})`);
    this.d.audit("auth.recovered", { how, minutes: Math.round((this.now() - since) / 60_000), palo: missed.palo.length, pals: Object.keys(missed.pals).length, schedules: missed.schedules.length });
    this.d.changed();
    this.d.recovered(missed, how, since);
  }

  // Told once; held for quiet hours, it goes out on a later poll.
  private async tell(): Promise<void> {
    if (this.notified || this.since === null) return;
    this.notified = true; // no second try while this one is out
    const sent = await this.d.notify().catch(() => false);
    if (!sent && this.since !== null) this.notified = false;
    this.save();
  }

  // While expired: signed in at the computer shows as a changed stored login.
  private startPolling(): void {
    if (this.poll) return;
    this.poll = setInterval(() => void this.check(), this.d.pollMs ?? 30_000);
    (this.poll as any).unref?.();
  }

  private ticks = 0;
  private async check(): Promise<void> {
    if (this.since === null || this.login) return;
    if (++this.ticks % 20 === 0) void this.tell(); // every 10 minutes, if quiet hours held it
    const now = await this.d.stamp?.().catch(() => null);
    if (!now || !this.stampAtExpiry || now === this.stampAtExpiry) return;
    const ok = this.d.loggedIn ? await this.d.loggedIn().catch(() => false) : true;
    if (ok && this.since !== null && !this.login) this.recover("computer");
  }

  private save(): void {
    if (this.since === null) writeJson(this.d.path, {});
    else writeJson(this.d.path, { since: this.since, missed: this.missed, notified: this.notified, stamp: this.stampAtExpiry } satisfies Saved);
  }
}

// ---------------- the real thing (macOS) ----------------

// `claude auth login` under expect (part of macOS): its link out as
// "URL …", each code typed in with Enter, "INVALID" when it wasn't taken;
// it exits with the login's own status. The link is the hyperlink it prints.
const LOGIN_EXP = `log_user 0
set timeout 60
spawn -noecho [lindex $argv 0] auth login
expect {
  -re {(https://[^\\s\\x07\\x1b]+/oauth/authorize[^\\s\\x07\\x1b]+)} { puts "URL $expect_out(1,string)"; flush stdout }
  timeout { puts "ERR no link"; flush stdout; exit 2 }
  eof { puts "ERR ended"; flush stdout; exit 3 }
}
while {1} {
  set timeout -1
  if {[gets stdin code] < 0} { exit 4 }
  send -- $code
  sleep 0.3
  send -- "\\r"
  set timeout 90
  expect {
    -re {Invalid code} { puts "INVALID"; flush stdout }
    eof { break }
    timeout { puts "ERR no answer"; flush stdout; exit 5 }
  }
}
lassign [wait] pid spawnid oserr status
exit $status
`;

function expectLogin(scriptDir: string): LoginProcess {
  const script = join(scriptDir, "claude-login.exp");
  writeFileSync(script, LOGIN_EXP);
  const lines: ((l: string) => void)[] = [];
  const exits: ((c: number) => void)[] = [];
  let proc: ChildProcess | null = null;
  let buf = "";
  let done = false;
  const exit = (c: number) => {
    if (done) return;
    done = true;
    for (const f of exits) f(c);
  };
  void (async () => {
    const env = cleanSessionEnv({ ...(await loginEnv()), BROWSER: "/usr/bin/true" });
    const bin = findClaude(env);
    if (!bin || process.platform !== "darwin") {
      for (const f of lines) f(bin ? "ERR only on macOS" : "ERR claude not found");
      return exit(1);
    }
    proc = spawn("/usr/bin/expect", ["-f", script, bin], { env, stdio: ["pipe", "pipe", "ignore"] });
    proc.stdout!.on("data", (d: Buffer) => {
      buf += d.toString("utf8");
      let i: number;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).replace(/\r$/, "");
        buf = buf.slice(i + 1);
        for (const f of lines) f(line);
      }
    });
    proc.on("exit", (code) => exit(code ?? 1));
    proc.on("error", () => exit(1));
  })();
  return {
    onLine: (f) => void lines.push(f),
    onExit: (f) => void exits.push(f),
    write: (line) => void proc?.stdin?.write(line + "\n"),
    kill: () => {
      try {
        proc?.kill("SIGKILL");
      } catch {
        /* gone */
      }
    },
  };
}

/** When Claude Code's stored login last changed: the keychain item's date (macOS), never the secret. */
export async function credentialsStamp(): Promise<string | null> {
  if (process.platform !== "darwin") return null;
  return new Promise((resolve) => {
    const p = spawn("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials"], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    p.stdout.on("data", (d: Buffer) => (out += d.toString("utf8")));
    p.on("exit", () => resolve(/"mdat"<timedate>=\S+\s+"([^"\\]+)/.exec(out)?.[1] ?? null));
    p.on("error", () => resolve(null));
  });
}

/** `claude auth status`: logged in or not. */
export async function claudeLoggedIn(): Promise<boolean> {
  const env = cleanSessionEnv(await loginEnv());
  const bin = findClaude(env);
  if (!bin) return false;
  return new Promise((resolve) => {
    const p = spawn(bin, ["auth", "status"], { env, stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    p.stdout.on("data", (d: Buffer) => (out += d.toString("utf8")));
    const timer = setTimeout(() => p.kill("SIGKILL"), 20_000);
    p.on("exit", () => {
      clearTimeout(timer);
      try {
        resolve(JSON.parse(out).loggedIn === true);
      } catch {
        resolve(/"loggedIn":\s*true/.test(out));
      }
    });
    p.on("error", () => resolve(false));
  });
}
