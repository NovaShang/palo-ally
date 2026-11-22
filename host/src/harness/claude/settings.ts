import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// The effort a session starts at when none was chosen for it in PaloAlly:
// what Claude Code's settings give it, as /effort writes them (the folder's
// local settings, its project settings, then the user's own in Claude Code's
// config dir; in each, the model's own entry before the general one). The
// host passes it to the session explicitly, so what the app shows is what the
// session runs at, as Zed's Claude Agent ACP does; each turn's Stop hook then
// reports the level actually applied.

const LEVELS = new Set(["low", "medium", "high", "xhigh", "max"]);

/** "Claude-Opus-5-5[1m]", "claude-opus-5-5-1m" or "claude-opus-5-5-20260101" → "claude-opus-5-5". */
export function canonicalModel(model: string): string {
  return model.trim().toLowerCase().replace(/\[[^\]]*\]$/, "").replace(/-\d+m$/, "").replace(/-\d{8}$/, "");
}

const cache = new Map<string, { stamp: string; data: any }>();

function readSettings(path: string): any {
  try {
    if (!existsSync(path)) return undefined;
    const st = statSync(path);
    const stamp = `${st.mtimeMs}:${st.size}`;
    const hit = cache.get(path);
    if (hit && hit.stamp === stamp) return hit.data;
    const data = JSON.parse(readFileSync(path, "utf8"));
    cache.set(path, { stamp, data });
    return data;
  } catch {
    return undefined;
  }
}

/** The effort Claude Code's settings give a session of `model` in `cwd`, if any. */
export function settingsEffort(model: string | undefined, cwd: string | undefined, claudeDir: string, env = process.env): string | undefined {
  const fromEnv = env.CLAUDE_CODE_EFFORT_LEVEL;
  if (fromEnv && LEVELS.has(fromEnv)) return fromEnv;
  const files = [
    ...(cwd ? [join(cwd, ".claude", "settings.local.json"), join(cwd, ".claude", "settings.json")] : []),
    join(claudeDir, "settings.json"),
  ];
  const key = model ? canonicalModel(model) : undefined;
  for (const f of files) {
    const s = readSettings(f);
    if (!s || typeof s !== "object") continue;
    const entry = key && s.modelSettings && typeof s.modelSettings === "object"
      ? Object.entries(s.modelSettings as Record<string, any>).find(([k]) => canonicalModel(k) === key)?.[1]
      : undefined;
    const own = entry?.effortLevel;
    if (typeof own === "string" && LEVELS.has(own)) return own;
    if (typeof s.effortLevel === "string" && LEVELS.has(s.effortLevel)) return s.effortLevel;
  }
  return undefined;
}

/**
 * The permission modes the owner can switch a session to (pals.setMode).
 * Not bypassPermissions (it skips every check, and a process not started with
 * it can't be switched into it) nor dontAsk (it refuses what isn't
 * pre-approved, with no prompt to the phone); a session already in one of
 * those still shows it.
 */
export const PAL_MODES = ["default", "auto", "acceptEdits", "plan"] as const;

/** The context window of a model (its id carries "[1m]" when it's the long one). */
export function contextWindowOf(model?: string): number {
  return model && /\[1m\]/i.test(model) ? 1_000_000 : 200_000;
}

/**
 * The window to measure a context against: what Claude Code reported, else
 * the guess from the model's id; a context already past the guess means the
 * long window (a model whose id doesn't say so).
 */
export function contextWindowFor(model: string | undefined, tokens: number | undefined, reported?: number): number {
  if (reported && reported > 0) return reported;
  const guess = contextWindowOf(model);
  return (tokens ?? 0) > guess ? 1_000_000 : guess;
}

/** Claude Code's own default permission mode for the owner's sessions. */
export function ownerMode(claudeDir: string): string {
  try {
    const s = JSON.parse(readFileSync(join(claudeDir, "settings.json"), "utf8"));
    const m = s?.permissions?.defaultMode;
    if (typeof m === "string" && m) return m;
  } catch {
    /* none */
  }
  return "default";
}
