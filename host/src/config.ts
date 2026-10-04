import { createHash } from "node:crypto";
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { readJson, writeJson } from "./util.ts";

export const VERSION = "0.1.0";

// Paths is the on-disk layout under the PaloAlly root (default ~/.paloally).
// `home` is the agent's working directory: CLAUDE.md, core files, artifacts.
export class Paths {
  constructor(readonly root: string) {}
  get home() { return join(this.root, "home"); }
  get artifacts() { return join(this.home, "artifacts"); }
  get claudeMd() { return join(this.home, "CLAUDE.md"); }
  get userMd() { return join(this.home, "user.md"); }
  get soulMd() { return join(this.home, "soul.md"); }
  get config() { return join(this.root, "config.json"); }
  get state() { return join(this.root, "state"); }
  get chat() { return join(this.state, "chat.jsonl"); }
  get tasks() { return join(this.state, "tasks.json"); }
  get taskActivity() { return join(this.state, "task-activity"); }
  get approvals() { return join(this.state, "approvals.json"); }
  get rules() { return join(this.state, "auto-rules.json"); }
  get watches() { return join(this.state, "watches.json"); }
  get runtime() { return join(this.state, "runtime.json"); }
  get usage() { return join(this.state, "usage.json"); }
  get metrics() { return join(this.state, "metrics.jsonl"); }
  get devices() { return join(this.state, "devices.json"); }
  get pushTokens() { return join(this.state, "push-tokens.json"); }
  get wechat() { return join(this.state, "wechat.json"); }
  get identity() { return join(this.root, "identity.json"); }
  get audit() { return join(this.root, "audit"); }
  get run() { return join(this.root, "run"); }
  // Unix socket paths are capped (~104 bytes on macOS); deep roots fall back to /tmp.
  get socket() {
    const p = join(this.run, "host.sock");
    if (Buffer.byteLength(p) <= 100) return p;
    return join("/tmp", `paloally-${createHash("sha256").update(this.root).digest("hex").slice(0, 16)}.sock`);
  }
  get logs() { return join(this.root, "logs"); }
  get browserProfile() { return join(this.root, "browser-profile"); }
}

export function defaultRoot(): string {
  return process.env.PALOALLY_HOME ?? join(homedir(), ".paloally");
}

export interface Settings {
  timezone: string;
  quietHours: { start: string; end: string } | null;
  maxProactivePerDay: number;
  probeIntervalMinutes: number;
  approvalTimeoutMinutes: number;
  wechatProactive: "off" | "hint" | "full";
}

export interface Config {
  hostName: string;
  model?: string; // main agent model; undefined = CLI default
  effort?: "low" | "medium" | "high" | "xhigh" | "max"; // undefined = the model's default
  probeModel: string; // cheap model for the probe
  // Let the probe see claude.ai connectors (Gmail, Calendar…) when logged in with a subscription.
  // Off by default: those connectors add ~100k tokens to every probe run.
  probeInheritConnectors: boolean;
  permissionMode: "default" | "auto" | "acceptEdits" | "dontAsk";
  session: {
    idleCloseMinutes: number; // close the CLI process after idle; resume on next message
    rollAfterTokens: number; // 0 = never roll to a fresh session (Phase 0: observe only)
  };
  budget: {
    probeDailyUsd: number; // probe stops for the day after this
    mainDailyUsd: number; // 0 = unlimited
  };
  relay: { enabled: boolean; url: string };
  wechat: { enabled: boolean; baseUrl: string };
  apns: {
    enabled: boolean;
    keyPath?: string;
    keyId?: string;
    teamId?: string;
    bundleId: string;
    host?: string; // override for tests
  };
  browser: {
    enabled: boolean;
    // shared: drive the owner's everyday Chrome through Claude in Chrome (needs a
    // claude.ai login + the extension); dedicated: a separate Playwright profile
    // (works with any model / API key).
    mode: "shared" | "dedicated";
    sensitiveDomains: string[]; // never navigated by the assistant's browser
    command?: string[]; // MCP server command; default Playwright MCP
  };
  extraMcpServers: Record<string, unknown>;
  // extra environment for the harness, e.g. ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN for third-party models
  env?: Record<string, string>;
  settings: Settings;
}

export function defaultConfig(): Config {
  return {
    hostName: hostname().replace(/\.local$/, ""),
    probeModel: "claude-haiku-4-5",
    probeInheritConnectors: false,
    // Claude Code's own classifier approves safe calls and asks only when it
    // can't tell; irreversible/outward actions always ask (our PreToolUse gate).
    permissionMode: "auto",
    session: { idleCloseMinutes: 30, rollAfterTokens: 0 },
    budget: { probeDailyUsd: 1, mainDailyUsd: 0 },
    relay: { enabled: true, url: "https://relay.bentoai.dev" },
    wechat: { enabled: false, baseUrl: "https://ilinkai.weixin.qq.com" },
    apns: { enabled: false, bundleId: "com.novashang.paloally" },
    browser: {
      enabled: true,
      mode: "shared",
      sensitiveDomains: [],
    },
    extraMcpServers: {},
    settings: {
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "America/Los_Angeles",
      quietHours: { start: "23:00", end: "08:00" },
      maxProactivePerDay: 8,
      probeIntervalMinutes: 10,
      approvalTimeoutMinutes: 30,
      wechatProactive: "hint",
    },
  };
}

// loadConfig deep-merges the saved file over defaults so new keys appear
// without a migration step.
export function loadConfig(paths: Paths): Config {
  const saved = readJson<Partial<Config>>(paths.config, {});
  return deepMerge(defaultConfig(), saved) as Config;
}

export function saveConfig(paths: Paths, cfg: Config): void {
  writeJson(paths.config, cfg);
}

function deepMerge(base: any, over: any): any {
  if (over === undefined) return base;
  if (base === null || typeof base !== "object" || Array.isArray(base)) return over;
  if (over === null || typeof over !== "object" || Array.isArray(over)) return over;
  const out: any = { ...base };
  for (const k of Object.keys(over)) out[k] = deepMerge(base[k], over[k]);
  return out;
}
