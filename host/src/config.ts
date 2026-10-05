import { createHash } from "node:crypto";
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { isValidTimeZone, parseHHMM, readJson, writeJson } from "./util.ts";

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
  get watches() { return join(this.state, "watches.json"); }
  get runtime() { return join(this.state, "runtime.json"); }
  get usage() { return join(this.state, "usage.json"); }
  get metrics() { return join(this.state, "metrics.jsonl"); }
  get devices() { return join(this.state, "devices.json"); }
  get pushTokens() { return join(this.state, "push-tokens.json"); }
  get wechat() { return join(this.state, "wechat.json"); }
  get media() { return join(this.state, "media"); }
  get suggestions() { return join(this.state, "suggestions.json"); }
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
  probeIntervalMinutes: number;
  approvalTimeoutMinutes: number;
  wechatProactive: "off" | "hint" | "full";
  // The assistant's identity, chosen by the owner after the first pairing.
  // "" = not chosen yet (the app asks once). The name also lives in soul.md.
  assistantName: string;
  avatar: string; // one of AVATARS, "" = default
}

// Code-drawn liquid-glass forms; the app renders each id.
export const AVATARS = ["drop", "orb", "petal", "wave", "pebble", "bloom", "comet", "twin"] as const;

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
    // Claude Code's own classifier approves safe calls and asks the owner only
    // when it can't tell. Safety is the harness' job (PRD §6.5).
    permissionMode: "auto",
    session: { idleCloseMinutes: 30 },
    budget: { probeDailyUsd: 1, mainDailyUsd: 0 },
    relay: { enabled: true, url: "https://relay.bentoai.dev" },
    wechat: { enabled: false, baseUrl: "https://ilinkai.weixin.qq.com" },
    apns: { enabled: false, bundleId: "com.novashang.paloally" },
    browser: {
      enabled: true,
      mode: "shared",
    },
    extraMcpServers: {},
    settings: {
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "America/Los_Angeles",
      quietHours: { start: "23:00", end: "08:00" },
      probeIntervalMinutes: 10,
      approvalTimeoutMinutes: 30,
      wechatProactive: "hint",
      assistantName: "",
      avatar: "",
    },
  };
}

// validateSettings checks a settings patch merged over the current settings
// and returns the result, or throws a message the owner can act on.
export function validateSettings(current: Settings, patch: Record<string, unknown>): Settings {
  const allowed = new Set(Object.keys(defaultConfig().settings));
  for (const k of Object.keys(patch)) if (!allowed.has(k)) throw new Error(`没有这个设置：${k}`);
  const next = { ...current, ...patch } as Settings;
  if (!isValidTimeZone(next.timezone)) throw new Error(`时区不认识：${String(next.timezone)}（例如 Asia/Shanghai、America/Los_Angeles）`);
  if (next.quietHours !== null) {
    const q = next.quietHours as any;
    if (!q || typeof q !== "object" || parseHHMM(String(q.start ?? "")) === null || parseHHMM(String(q.end ?? "")) === null)
      throw new Error("免打扰时段要写成开始和结束两个时间，例如 23:00-08:00");
    next.quietHours = { start: String(q.start), end: String(q.end) };
  }
  const int = (v: unknown, min: number, max: number, name: string) => {
    if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max) throw new Error(`${name}要在 ${min} 到 ${max} 之间`);
    return Math.round(v);
  };
  next.probeIntervalMinutes = int(next.probeIntervalMinutes, 1, 1440, "检查间隔（分钟）");
  next.approvalTimeoutMinutes = int(next.approvalTimeoutMinutes, 1, 24 * 60, "确认等待时间（分钟）");
  if (!["off", "hint", "full"].includes(next.wechatProactive)) throw new Error("微信主动消息只能是 off / hint / full");
  if (typeof next.assistantName !== "string") throw new Error("名字要是一段文字");
  next.assistantName = next.assistantName.replace(/[\r\n]+/g, " ").trim();
  if ([...next.assistantName].length > 20) throw new Error("名字最多 20 个字");
  if (next.avatar !== "" && !(AVATARS as readonly string[]).includes(next.avatar)) throw new Error(`没有这个形象：${String(next.avatar)}`);
  return next;
}

// loadConfig deep-merges the saved file over defaults so new keys appear
// without a migration step.
export function loadConfig(paths: Paths): Config {
  const saved = readJson<Partial<Config>>(paths.config, {});
  const cfg = deepMerge(defaultConfig(), saved) as Config;
  delete (cfg.settings as any).maxProactivePerDay; // removed 2026-10-04 (runaway guard instead)
  // A hand-edited bad value falls back to its default instead of crash-looping.
  const defaults = defaultConfig().settings as any;
  for (const k of Object.keys(defaults)) {
    try {
      validateSettings({ ...defaults, [k]: (cfg.settings as any)[k] }, {});
    } catch {
      (cfg.settings as any)[k] = defaults[k];
    }
  }
  return cfg;
}

// patchConfig re-reads the file, applies `mutate`, and saves, so a daemon
// holding an older copy never clobbers what the CLI wrote meanwhile.
export function patchConfig(paths: Paths, mutate: (c: Config) => void): Config {
  const disk = loadConfig(paths);
  mutate(disk);
  saveConfig(paths, disk);
  return disk;
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
