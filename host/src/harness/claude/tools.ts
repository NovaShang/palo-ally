import type { ToolClass, ToolFamily, ToolVocabulary } from "../types.ts";

// What Claude Code's tool names mean (docs/harness-adapter-design.md §2): the
// host keeps the words it shows and its rules; which names are a shell
// command, a file read, a subagent… is said here only.

const FAMILY = new Map<string, ToolFamily>(Object.entries({
  Read: "read",
  Grep: "search",
  Glob: "search",
  LS: "list",
  NotebookRead: "list",
  Write: "write",
  Edit: "edit",
  NotebookEdit: "notebook-edit",
  MultiEdit: "multi-edit",
  Bash: "run",
  BashOutput: "run-more",
  KillShell: "run-more",
  KillBash: "run-more",
  Monitor: "run-more",
  WebSearch: "web-search",
  WebFetch: "web-fetch",
  Agent: "agent",
  Task: "agent", // Task was renamed Agent in CC v2.1.63; both are accepted
  TaskOutput: "agent-more",
  TaskStop: "agent-more",
  TaskCreate: "agent-more",
  TaskUpdate: "agent-more",
  SendMessage: "message",
  SendUserFile: "deliver",
  Artifact: "deliver",
  // tools that are plumbing, not a step worth a status line of its own
  AskUserQuestion: "plumbing",
  ToolSearch: "plumbing",
  TodoWrite: "quiet",
  ListAgents: "quiet",
  ExitPlanMode: "quiet",
  EnterPlanMode: "quiet",
} satisfies Record<string, ToolFamily>));

const str = (v: unknown) => (typeof v === "string" ? v : undefined);

function classify(name: string, input: Record<string, unknown> = {}): ToolClass {
  const family = FAMILY.get(name);
  if (family) {
    const c: ToolClass = { family, name };
    if (name === "Bash") c.command = str(input.command);
    if (name === "Read" || name === "Write" || name === "Edit") c.path = str(input.file_path);
    // a search: where it looks, and the filter it takes (Grep: a glob of files; Glob: a pattern of paths)
    if (name === "Grep") Object.assign(c, { path: input.path, filter: input.glob, filterIsPath: false });
    if (name === "Glob") Object.assign(c, { path: input.path, filter: input.pattern, filterIsPath: true });
    if (name === "WebFetch") c.url = str(input.url);
    return c;
  }
  const m = /^mcp__(.+?)__(.+)$/.exec(name);
  if (m) return { family: "mcp", name, server: m[1]!, tool: m[2]! };
  return { family: "other", name };
}

export const CLAUDE_TOOLS: ToolVocabulary = {
  ask: "AskUserQuestion",
  subagent: new Set(["Agent", "Task"]),
  handback: "SubagentHandback",
  handbackNote: /SubagentHandback|report was delivered to you|agent's report was delivered/i,
  selfReporting: new Set(["Agent", "Task"]),
  peerSend: "SendMessage",
  shell: "Bash",
  qualified: (server, tool) => `mcp__${server}__${tool}`,
  classify,
  // Claude Code's always-allow rules name a tool and what it covers (Bash's command prefix, a file tool's path).
  ruleScope: (toolName, content) => {
    if (toolName === "Bash" && content) return `cmd:${content.replace(/:\*$/, "").replace(/\s*\*$/, "")}`;
    if (content.startsWith("domain:")) return content;
    if (/^(Read|Write|Edit|NotebookEdit|Glob|Grep)$/.test(toolName) && content) return `path:${content.replace(/\/\*\*$/, "").replace(/^\/\//, "/")}`;
    return `tool:${toolName}`;
  },
};
