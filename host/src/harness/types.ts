// Harness-agnostic driver interface (ACP-shaped; PRD §7.2.2). V1 ships one
// implementation (Claude Code via the Agent SDK) plus a scripted fake for
// tests. Only the Hub talks to a driver.

export type HarnessEvent =
  | { type: "init"; sessionId: string; model: string; tools: string[] }
  | { type: "text_delta"; text: string }
  | { type: "assistant_text"; text: string; parentToolUseId: string | null }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown>; parentToolUseId: string | null }
  | { type: "tool_result"; toolUseId: string; content: string; isError: boolean; parentToolUseId: string | null }
  | { type: "task_started"; taskId: string; toolUseId?: string; description: string; background?: boolean }
  | { type: "task_progress"; taskId: string; toolUseId?: string; summary?: string }
  | { type: "task_notification"; taskId: string; toolUseId?: string; status: "completed" | "failed" | "stopped"; summary: string }
  | { type: "compact"; trigger: string; preTokens: number; postTokens?: number }
  | {
      type: "result";
      isError: boolean;
      text: string;
      costUsd: number;
      contextTokens: number;
      sessionId: string;
    }
  | { type: "error"; message: string };

export interface PermissionRequest {
  toolName: string;
  input: Record<string, unknown>;
  toolUseId?: string;
  title?: string;
  reason?: string;
  agentId?: string; // set when a subagent asks
  signal: AbortSignal;
}

export type PermissionDecision =
  | { behavior: "allow"; updatedInput?: Record<string, unknown> }
  | { behavior: "deny"; message: string };

// PreToolGate runs before every tool call (main thread and subagents) and can
// force a prompt or deny regardless of the harness' own rules.
export type PreToolGate = (call: {
  toolName: string;
  input: Record<string, unknown>;
  toolUseId: string;
  agentId?: string;
}) => { decision: "allow" | "deny" | "ask" | "pass"; reason?: string };

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
  resumeSessionId?: string;
  permissionMode: string;
  appendSystemPrompt: string;
  tools: ToolHandlers;
  canUseTool: (req: PermissionRequest) => Promise<PermissionDecision>;
  preToolGate: PreToolGate;
  postToolUse: (call: { toolName: string; input: unknown; response: unknown; toolUseId: string; agentId?: string }) => void;
  mcpServers: Record<string, unknown>;
  onEvent: (e: HarnessEvent) => void;
  stderr?: (s: string) => void;
}

// A long-lived main conversation. send() queues a user turn; turns run in
// order. The session survives across turns until close().
export interface MainSession {
  send(text: string): void;
  interrupt(): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  close(): void;
  readonly closed: boolean;
}

export interface ProbeRequest {
  model: string;
  cwd: string;
  systemPrompt: string;
  prompt: string;
  mcpServers: Record<string, unknown>;
  allowedTools: string[];
  outputSchema: Record<string, unknown>;
  maxTurns: number;
  canUseTool: (req: PermissionRequest) => Promise<PermissionDecision>;
  preToolGate: PreToolGate;
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
