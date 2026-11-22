import { homedir } from "node:os";
import { join, resolve } from "node:path";

// Where Claude Code keeps its own things: its config folder and a session's transcript.

export function claudeConfigDir(): string {
  return process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude");
}

export function transcriptPath(claudeDir: string, cwd: string, sessionId: string): string {
  return join(claudeDir, "projects", resolve(cwd).replace(/[^A-Za-z0-9]/g, "-"), `${sessionId}.jsonl`);
}
