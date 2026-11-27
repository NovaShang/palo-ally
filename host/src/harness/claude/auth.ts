import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { LimitHit, LoginAccount, LoginProcess } from "../types.ts";
import { cleanSessionEnv, findClaude, loginEnv } from "./cli.ts";
import { loginAccount } from "./usage.ts";
import { t } from "../../i18n/index.ts";

// Claude Code's login: what a failure says, whether it is logged in, when its
// stored login changed, and `claude auth login` driven through expect.

/** What a failed turn or probe said, by the SDK's error kind or, failing that, its words. */
export function isAuthFailure(text?: string, category?: string): boolean {
  if (category === "authentication_failed") return true;
  return !!text && AUTH_WORDS.test(text);
}

const AUTH_WORDS =
  /authentication_failed|authentication_error|failed to authenticate|oauth (session|token) (has )?expired|could not be refreshed|please run \/login|not logged in|invalid (api|x-api) key/i;

/**
 * A used-up limit by Claude Code's own error line (a process that said
 * nothing of limits): only ever read off a turn that failed, and only at its start.
 */
export function isLimitFailure(text?: string): LimitHit | null {
  const m = LIMIT_WORDS.exec((text ?? "").trim());
  if (!m) return null;
  const at = Number(/\|(\d{10,13})\b/.exec(text!)?.[1]);
  return Number.isFinite(at) ? { resetsAt: at < 1e12 ? at * 1000 : at } : {};
}

const LIMIT_WORDS = /^(?:claude (?:ai )?usage limit reached|you(?:'|’)?ve (?:hit|reached) your (?:[\w-]+ ){0,3}limit\b|(?:5-hour|session|weekly|opus|sonnet|opus weekly|sonnet weekly) limit reached)/i;

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

export function expectLogin(scriptDir: string): LoginProcess {
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
    // expect is part of macOS; on Linux it's a package of its own.
    const expect = ["/usr/bin/expect", "/usr/local/bin/expect", "/opt/homebrew/bin/expect"].find((p) => existsSync(p));
    if (!bin || !expect || (process.platform !== "darwin" && process.platform !== "linux")) {
      for (const f of lines) f(!bin ? "ERR claude not found" : !expect ? `ERR ${t("auth.noExpect")}` : `ERR ${t("auth.unsupported")}`);
      return exit(1);
    }
    proc = spawn(expect, ["-f", script, bin], { env, stdio: ["pipe", "pipe", "ignore"] });
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

/** `claude auth …`: its output and how it ended (null: it couldn't be run, or took too long). */
async function claudeAuth(args: string[]): Promise<{ out: string; code: number } | null> {
  const env = cleanSessionEnv(await loginEnv());
  const bin = findClaude(env);
  if (!bin) return null;
  return new Promise((resolve) => {
    const p = spawn(bin, ["auth", ...args], { env, stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    p.stdout.on("data", (d: Buffer) => (out += d.toString("utf8")));
    const timer = setTimeout(() => {
      p.kill("SIGKILL");
      resolve(null);
    }, 20_000);
    p.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ out, code: code ?? 1 });
    });
    p.on("error", () => resolve(null));
  });
}

/** `claude auth status`: logged in or not. */
export async function claudeLoggedIn(): Promise<boolean> {
  const r = await claudeAuth(["status"]);
  return !!r && saysLoggedIn(r.out);
}

function saysLoggedIn(out: string): boolean {
  try {
    return JSON.parse(out).loggedIn === true;
  } catch {
    return /"loggedIn":\s*true/.test(out);
  }
}

/** `claude auth status`: no login of any kind (no subscription, no key). */
export async function claudeNoLogin(): Promise<boolean> {
  const r = await claudeAuth(["status"]);
  if (!r) return false;
  try {
    const j = JSON.parse(r.out);
    return j.loggedIn === false && j.authMethod === "none";
  } catch {
    return false;
  }
}

/** `claude auth status`: whose login. */
export async function claudeAccount(): Promise<LoginAccount | null> {
  return statusAccount((await claudeAuth(["status"]))?.out);
}

/** What `claude auth status` printed, as an account. */
export function statusAccount(out?: string): LoginAccount | null {
  try {
    const j = JSON.parse(out ?? "");
    return j.loggedIn === true ? (loginAccount({ email: j.email, organization: j.orgName, subscriptionType: j.subscriptionType, apiProvider: j.apiProvider }) ?? null) : null;
  } catch {
    return null;
  }
}

/** A host may sign this computer out only as its own: not in a test, not one on another home (a second instance, to try things on). */
export function maySignOut(env: Record<string, string | undefined>, userHome: string): boolean {
  if (env.NODE_ENV === "test") return false;
  return !env.PALOALLY_HOME || resolve(env.PALOALLY_HOME) === join(userHome, ".paloally");
}

/** `claude auth logout`: every Claude Code on this computer is signed out. */
export async function claudeLogout(): Promise<boolean> {
  if (!maySignOut(process.env, homedir())) return false;
  return (await claudeAuth(["logout"]))?.code === 0;
}
