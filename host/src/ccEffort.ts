import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// The effort Claude Code starts a session at when none was chosen for it:
// what its settings say, as /effort writes them. The SDK doesn't report the
// applied effort to a host like this one, so it is read from the same files:
// the folder's local settings, its project settings, then the user's own in
// Claude Code's config dir; in each, the model's own entry (modelSettings)
// before the general one.

const LEVELS = new Set(["low", "medium", "high", "xhigh", "max"]);

/** "claude-opus-5-5[1m]" or "claude-opus-5-5-20260101" → "claude-opus-5-5". */
export function canonicalModel(model: string): string {
  return model.replace(/\[[^\]]*\]$/, "").replace(/-\d{8}$/, "");
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
    const own = key ? s.modelSettings?.[key]?.effortLevel : undefined;
    if (typeof own === "string" && LEVELS.has(own)) return own;
    if (typeof s.effortLevel === "string" && LEVELS.has(s.effortLevel)) return s.effortLevel;
  }
  return undefined;
}
