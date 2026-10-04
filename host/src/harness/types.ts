// Harness-agnostic driver interface (ACP-shaped; PRD §7.2.2). V1 ships one
// implementation (Claude Code via the Agent SDK) plus a scripted fake for
// tests. Only the Hub talks to a driver.

export type HarnessEvent =
  | { type: "init"; sessionId: string; model: string; tools: string[]; terminalCommands?: string[] }
  // the harness' slash commands (built-ins, skills, plugins…); replaces any earlier list
  | { type: "commands"; commands: SlashCommandInfo[] }
  | { type: "models"; models: ModelOption[] }
  | { type: "text_delta"; text: string }
  // the model began writing a tool call (its input may stream for minutes, e.g. a big Write)
  | { type: "tool_start"; name: string; parentToolUseId: string | null }
  | { type: "assistant_text"; text: string; parentToolUseId: string | null }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown>; parentToolUseId: string | null }
  | { type: "tool_result"; toolUseId: string; content: string; isError: boolean; parentToolUseId: string | null }
  | { type: "task_started"; taskId: string; toolUseId?: string; description: string; background?: boolean }
  | { type: "task_progress"; taskId: string; toolUseId?: string; summary?: string }
  | { type: "task_backgrounded"; taskId: string }
  | { type: "task_notification"; taskId: string; toolUseId?: string; status: "completed" | "failed" | "stopped"; summary: string }
  | { type: "compact"; trigger: string; preTokens: number; postTokens?: number }
  | {
      type: "result";
      isError: boolean;
      text: string;
      costUsd: number; // this turn only
      totalCostUsd: number; // running total for the session
      contextTokens: number;
      sessionId: string;
      consumedUuids?: string[]; // user messages this turn answered (absent on older CLIs)
    }
  | { type: "error"; message: string };

export interface ModelOption {
  value: string; // what to pass as model
  displayName: string;
  description: string;
  efforts: string[]; // supported effort levels, empty if the model has none
}

export interface SlashCommandInfo {
  name: string;
  description: string;
  argumentHint?: string;
}

export interface PermissionRequest {
  toolName: string;
  input: Record<string, unknown>;
  toolUseId?: string;
  title?: string;
  reason?: string;
  agentId?: string; // set when a subagent asks
  signal: AbortSignal;
  // the harness' own "always allow" rules for this call; return them to accept
  suggestions?: unknown[];
  // the harness says this one must not be approved casually / not remembered
  defaultToNo?: boolean;
  suppressAlwaysAllowRule?: boolean;
}

export type PermissionDecision =
  | { behavior: "allow"; updatedInput?: Record<string, unknown>; updatedPermissions?: unknown[] }
  | { behavior: "deny"; message: string };

export interface ToolHandlers {
  report_task(args: { id: string; summary: string; status: string; title?: string }): Promise<string>;
  register_watch(args: {
    title: string;
    instruction: string;
    interval_minutes?: number;
    at?: string[];
    kind?: "check" | "schedule";
  }): Promise<string>;
  list_watches(): Promise<string>;
  remove_watch(args: { id: string }): Promise<string>;
  publish_artifact(args: { slug: string; title: string; main_file: string; type?: string; pinned?: boolean }): Promise<string>;
  notify_user(args: { text: string; urgent?: boolean }): Promise<string>;
}

export interface MainSessionOptions {
  cwd: string;
  model?: string;
  effort?: string;
  resumeSessionId?: string;
  priorCostUsd?: number; // the resumed session's running total, so per-turn cost stays a delta
  permissionMode: string;
  appendSystemPrompt: string;
  tools: ToolHandlers;
  // the harness asks the owner something; safety decisions are the harness' own
  canUseTool: (req: PermissionRequest) => Promise<PermissionDecision>;
  mcpServers: Record<string, unknown>;
  sharedChrome?: boolean; // enable Claude in Chrome on the owner's own browser
  onEvent: (e: HarnessEvent) => void;
  stderr?: (s: string) => void;
}

// A long-lived main conversation. send() queues a user turn; turns run in
// order. The session survives across turns until close().
export interface MainSession {
  // Sends a user message now. While a turn is running the harness queues it
  // or folds it into that turn; `uuid` lets the result say which it answered.
  send(text: string, uuid: string): void;
  interrupt(): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  // live switches; take effect from the next model call
  setModel(model?: string): Promise<void>;
  setEffort(effort?: string): Promise<void>;
  close(): void;
  readonly closed: boolean;
}

export interface ProbeRequest {
  model: string;
  cwd: string;
  systemPrompt: string;
  prompt: string;
  mcpServers: Record<string, unknown>;
  tools: string[]; // which built-in tools to load (context size, not a safety list)
  outputSchema: Record<string, unknown>;
  maxTurns: number;
  // true: only mcpServers above (no claude.ai connectors / user config / skills) — keeps context ~2k tokens
  strictMcp: boolean;
}

export interface ProbeResult {
  output: unknown; // structured output, parsed
  costUsd: number;
  error?: string;
  usage?: Record<string, unknown>; // per-model token usage, for cost tuning
}

export interface HarnessDriver {
  readonly name: string;
  startMain(opts: MainSessionOptions): MainSession;
  runProbe(req: ProbeRequest): Promise<ProbeResult>;
}
