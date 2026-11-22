import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

// Where Claude Code keeps its own things: its config folder and a session's transcript.

export function claudeConfigDir(): string {
  return process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude");
}

/**
 * A folder's name under <config>/projects: its path with every non-alphanumeric
 * turned into '-'. Claude Code names it from the resolved folder (/tmp is
 * /private/tmp on a Mac), so links are resolved here too; a folder that is
 * gone keeps its path as given.
 */
export function projectDirName(cwd: string): string {
  let dir: string;
  try {
    dir = realpathSync(cwd);
  } catch {
    dir = resolve(cwd);
  }
  return dir.replace(/[^A-Za-z0-9]/g, "-");
}

export function transcriptPath(claudeDir: string, cwd: string, sessionId: string): string {
  return join(claudeDir, "projects", projectDirName(cwd), `${sessionId}.jsonl`);
}
