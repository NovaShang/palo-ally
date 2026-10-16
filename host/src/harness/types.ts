// Harness-agnostic driver interface (ACP-shaped; PRD §7.2.2). V1 ships one
// implementation (Claude Code via the Agent SDK) plus a scripted fake for
// tests. Only the Hub talks to a driver.

export type HarnessEvent =
  // permissionMode: the mode it actually runs in, which may not be the one
  // asked for (Claude Code quietly drops auto for a model without it)
  | { type: "init"; sessionId: string; model: string; tools: string[]; terminalCommands?: string[]; permissionMode?: string }
  // the harness' slash commands (built-ins, skills, plugins…); replaces any earlier list
  | { type: "commands"; commands: SlashCommandInfo[] }
  | { type: "models"; models: ModelOption[] }
  // messageId: the API message the text belongs to (a Pal's message id, the same in its transcript)
  | { type: "text_delta"; text: string; messageId?: string }
  // the model began writing a tool call (its input may stream for minutes, e.g. a big Write)
  | { type: "tool_start"; name: string; parentToolUseId: string | null }
  | { type: "assistant_text"; text: string; parentToolUseId: string | null; messageId?: string }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown>; parentToolUseId: string | null }
  | { type: "tool_result"; toolUseId: string; content: string; isError: boolean; parentToolUseId: string | null }
  | { type: "task_started"; taskId: string; toolUseId?: string; description: string; background?: boolean; taskType?: string }
  // the harness' full set of background tasks right now (replace, don't merge)
  | { type: "background_tasks"; taskIds: string[] }
  // the harness says this turn is answering these owner messages (by uuid)
  | { type: "answering"; uuids: string[] }
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
      errorCategory?: string; // the SDK's own error kind (rate_limit, billing_error, …) when the turn failed
      consumedUuids?: string[]; // user messages this turn answered (absent on older CLIs)
      startupFailure?: string; // why Claude Code refused to start (e.g. session_held_by_background)
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

// A host rule checked before every tool call of the session, whatever the
// harness' permission mode would decide (Claude Code: a PreToolUse hook, which
// runs before auto approvals and before canUseTool). A string denies the call
// with that message; null leaves it to the harness as usual.
export type ToolGate = (req: { toolName: string; input: Record<string, unknown>; agentId?: string; via: "hook" | "canUseTool" }) => string | null;

export type PermissionDecision =
  | { behavior: "allow"; updatedInput?: Record<string, unknown>; updatedPermissions?: unknown[] }
  | { behavior: "deny"; message: string };

export interface ToolHandlers {
  report_task(args: { id: string; summary: string; status: string; title?: string; peer?: string }): Promise<string>;
  register_watch(args: {
    id?: string;
    title?: string;
    instruction?: string;
    interval_minutes?: number;
    at?: string[];
    day_of_month?: number;
    kind?: "check" | "schedule";
  }): Promise<string>;
  list_watches(): Promise<string>;
  update_goal(args: { id: string; progress: string; state?: "tracking" | "waiting" | "done" | "paused"; ratio?: number; outcome?: string }): Promise<string>;
  remove_watch(args: { id: string }): Promise<string>;
  notify_user(args: { text: string; urgent?: boolean }): Promise<string>;
  copy_to_clipboard(args: { text: string; label?: string }): Promise<string>;
  SendUserFile(args: { files: string[]; caption?: string; status: "normal" | "proactive"; display?: "render" | "attach"; temporary?: boolean }): Promise<string>;
  Artifact(args: { file_path: string; title?: string; description?: string; files?: Record<string, string> }): Promise<string>;
  ally_list(): Promise<string>;
  ally_send(args: { to: string; text: string; urgent?: boolean; slots?: { start: string; end: string }[]; replyTo?: string }): Promise<string>;
  // Pals and the computer's other Claude Code sessions (docs/pals-prd.md §6).
  pals_list(): Promise<string>;
  pal_propose(args: { name: string; dir: string; duty: string; dailyUsd: number }): Promise<string>;
  // Words to a Pal, asleep or awake (§12): it's woken first if need be.
  pal_send(args: { name: string; text: string }): Promise<string>;
  // Conversations that ended on the computer, and taking one over (§10).
  pals_recent(args: { folder?: string }): Promise<string>;
  pal_adopt(args: { sessionId: string }): Promise<string>;
  // A link that pairs one more of the owner's devices (5 minutes, one device).
  pair_link(): Promise<string>;
}

export interface ImageInput {
  mediaType: string;
  data: string; // base64
}

// How to start the Claude Code process: given the command line the SDK
// built, start it (through PaloAlly Helper, or directly) and hand back the
// process. `onPid` gets Claude Code's own pid once it's known.
export interface SpawnRequest {
  command: string;
  args: string[];
  cwd?: string;
  env: Record<string, string | undefined>;
  signal?: AbortSignal;
}
export type Spawner = (req: SpawnRequest) => import("@anthropic-ai/claude-agent-sdk").SpawnedProcess;

// What every long-lived session takes: the assistant's own (MainSessionOptions)
// and a Pal (docs/pals-prd.md §7.1), one of the owner's Claude Code sessions
// the host runs.
export interface SessionOptions {
  cwd: string;
  model?: string;
  effort?: string;
  resumeSessionId?: string;
  sessionId?: string; // a new session with this id (not with resumeSessionId)
  priorCostUsd?: number; // the resumed session's running total, so per-turn cost stays a delta
  permissionMode: string;
  appendSystemPrompt?: string;
  // the harness asks the owner something; safety decisions are the harness' own
  canUseTool: (req: PermissionRequest) => Promise<PermissionDecision>;
  toolGate?: ToolGate; // the assistant's own session: 「只说话不动手」 in an Ally's turn
  mcpServers?: Record<string, unknown>;
  env?: Record<string, string>; // extra environment for the harness only (e.g. third-party model endpoint)
  // The environment the process starts from (default: the host's own). A Pal
  // starts from the owner's login shell, as a terminal session would.
  baseEnv?: Record<string, string>;
  name?: string; // the session's name, which other sessions SendMessage it by
  spawn?: Spawner; // default: the SDK starts Claude Code itself
  ownerOrigin?: boolean; // what send() puts in is the owner's own words (origin "human" in the transcript)
  onEvent: (e: HarnessEvent) => void;
  // The process ended by itself (crashed, killed, refused to start), not through close().
  onExit?: (error?: string) => void;
  stderr?: (s: string) => void;
}

export interface MainSessionOptions extends SessionOptions {
  appendSystemPrompt: string;
  tools: ToolHandlers;
  mcpServers: Record<string, unknown>;
  sharedChrome?: boolean; // enable Claude in Chrome on the owner's own browser
}

// A long-lived main conversation. send() queues a user turn; turns run in
// order. The session survives across turns until close().
export interface MainSession {
  // Sends a user message now. While a turn is running the harness queues it
  // or folds it into that turn; `uuid` lets the result say which it answered.
  send(text: string, uuid: string, images?: ImageInput[]): void;
  interrupt(): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  // live switches; take effect from the next model call
  setModel(model?: string): Promise<void>;
  setEffort(effort?: string): Promise<void>;
  // Retitles the session in this process (Claude Code's own rename; a Pal, pals-prd §13).
  rename?(title: string, sessionId?: string): Promise<void>;
  // Resolves once Claude Code is up (it answered the SDK's first request);
  // rejects with its reason when it refused to start.
  ready(): Promise<void>;
  close(): void;
  readonly closed: boolean;
  // When the process last said anything on its SDK stream (any message, ms):
  // the stall watchdog's sign of life.
  readonly lastActivity?: number;
}

export interface ProbeRequest {
  model: string;
  cwd: string;
  systemPrompt: string;
  prompt: string;
  mcpServers: Record<string, unknown>;
  tools: string[]; // which built-in tools to load (context size, not a safety list); web ones among them are pre-approved
  outputSchema: Record<string, unknown>;
  maxTurns: number;
  // true: only mcpServers above (no claude.ai connectors / user config / skills) — keeps context ~2k tokens
  strictMcp: boolean;
  env?: Record<string, string>;
}

export interface ProbeResult {
  output: unknown; // structured output, parsed
  costUsd: number;
  error?: string;
  usage?: Record<string, unknown>; // per-model token usage, for cost tuning
  denied?: string[]; // tools the harness refused this run, by name
}

export interface HarnessDriver {
  readonly name: string;
  startMain(opts: MainSessionOptions): MainSession;
  // One of the owner's own sessions (a Pal): no PaloAlly tools or prompt.
  startPal(opts: SessionOptions): MainSession;
  runProbe(req: ProbeRequest): Promise<ProbeResult>;
}
