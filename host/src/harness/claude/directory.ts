import { getSessionInfo, listSessions, renameSession } from "@anthropic-ai/claude-agent-sdk";
import { resolve } from "node:path";
import type { RecentSource } from "../types.ts";
import { claudeConfigDir } from "./paths.ts";

// The SDK reads Claude Code's own folder (CLAUDE_CONFIG_DIR or ~/.claude);
// for any other (a test's), there's nothing it could list.
/** Retitles a session that has no process (the SDK's renameSession): only in this computer's own Claude Code folder. */
export function sdkRename(claudeDir: string): (sessionId: string, title: string, dir: string) => Promise<void> {
  return async (sid, title, dir) => {
    if (resolve(claudeDir) !== resolve(claudeConfigDir())) return;
    await renameSession(sid, title, { dir });
  };
}

export function sdkSource(claudeDir: string): RecentSource {
  const same = () => resolve(claudeDir) === resolve(claudeConfigDir());
  return {
    list: async (o) => (same() ? listSessions(o) : []),
    info: async (sid, dir) => (same() ? getSessionInfo(sid, dir ? { dir } : {}) : undefined),
  };
}
