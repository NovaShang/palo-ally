import { CLAUDE_TOOLS } from "./claude/tools.ts";
import type { ToolVocabulary } from "./types.ts";

// The tool vocabulary of the harness in use, for the host's stateless helpers
// (activity words, card words, the Ally gate, tasks, the stall watchdog). One
// harness runs everything today (Claude Code); a second would set its own here.
export const tools: ToolVocabulary = CLAUDE_TOOLS;
