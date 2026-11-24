// Harness-agnostic driver interface (ACP-shaped; PRD §7.2.2). V1 ships one
// implementation (Claude Code via the Agent SDK) plus a scripted fake for
// tests. Only the Hub talks to a driver.

export type HarnessEvent =
  // permissionMode: the mode it actually runs in, which may not be the one
  // asked for (Claude Code quietly drops auto for a model without it)
  | { type: "init"; sessionId: string; model: string; tools: string[]; terminalCommands?: string[]; permissionMode?: string; effort?: string }
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
  // Where a message put in stands with the harness: waiting for a step to end, being read, answered (or never to be).
  | { type: "words"; uuid: string; state: "queued" | "read" | "done" }
  | { type: "task_notification"; taskId: string; toolUseId?: string; status: "completed" | "failed" | "stopped"; summary: string }
  | { type: "compact"; trigger: string; preTokens: number; postTokens?: number }
  | {
      type: "result";
      isError: boolean;
      text: string;
      costUsd: number; // this turn only
      totalCostUsd: number; // running total for the session
      contextTokens: number;
      contextWindow?: number; // the main model's context window as Claude Code reports it (absent on older CLIs)
      sessionId: string;
      errorCategory?: string; // the SDK's own error kind (rate_limit, billing_error, …) when the turn failed
      consumedUuids?: string[]; // user messages this turn answered (absent on older CLIs)
      startupFailure?: string; // why Claude Code refused to start (e.g. session_held_by_background)
    }
  // a limit of the plan, as the harness now knows it (blocked: used up, turns fail on it)
  | ({ type: "limit"; blocked: boolean } & LimitHit)
  | { type: "error"; message: string }
  // the effort the turn runs at, as Claude Code's hooks report it
  | { type: "effort"; level: string }
  // the permission mode it says it runs in now (a turn's end, or its status after a switch)
  | { type: "mode"; mode: string };

/** The login a harness runs on, as the owner knows it: shown in the owner's own apps only. */
export interface LoginAccount {
  email?: string;
  organization?: string;
  plan?: string; // the subscription ("pro", "max", …); none for a key or another provider
  provider?: string; // not the harness' own maker's ("bedrock", "vertex", …)
  apiKeySource?: string; // a key instead of a login, and where it's set
}

/** One of the plan's limits. */
export interface PlanLimit {
  kind: string; // "session", "weekly_all", "weekly_scoped"; new ones come as they are
  group: string; // "session" | "weekly"
  used: number; // 0 to 100
  resetsAt?: number; // ms
  windowMs?: number; // how long its window is, when known
  scope?: string; // the model (or surface) it's for, by the server's name
}

/**
 * The plan's limits and the login they're for. plan: "limits"; "none" (this
 * login has none: a key, another provider); "hidden" (a subscription whose
 * login may not see them); "unreadable" (no answer this time); "unsupported"
 * (the harness can't be asked).
 */
export interface PlanReport {
  plan: "limits" | "none" | "hidden" | "unreadable" | "unsupported";
  limits: PlanLimit[];
  extraUsage?: boolean; // past the limits it goes on, paid by use
  account?: LoginAccount;
}

/** A limit of the plan a turn can fail on: which (as PlanLimit has it) and when it resets. */
export interface LimitHit {
  kind?: string;
  scope?: string;
  resetsAt?: number; // ms
}

export interface ModelOption {
  value: string; // what to pass as model
  displayName: string;
  description: string;
  efforts: string[]; // supported effort levels, empty if the model has none
  resolved?: string; // the full model id the value stands for ("opus[1m]" → "claude-opus-5-5[1m]")
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

/** 待办 (backlog.ts): the folder's list, for the assistant and every session alike. */
export const BACKLOG_TOOLS = ["backlog_add", "backlog_list", "backlog_done"] as const;

/** The tools that reach the owner: the assistant has them, and so does every session (scoped to it). */
export const DELIVERY_TOOLS = ["SendUserFile", "Artifact", "copy_to_clipboard", "notify_user", "pals_list", "add_pending", "resolve_pending", ...BACKLOG_TOOLS] as const;
export type DeliveryToolHandlers = Pick<ToolHandlers, (typeof DELIVERY_TOOLS)[number]>;

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
  // 等你的事 (pending.ts): a decision for the owner, kept by the host; non-blocking.
  add_pending(args: { title: string; context?: string; options?: string[] }): Promise<string>;
  resolve_pending(args: { id: string; conclusion: string }): Promise<string>;
  // 待办 (backlog.ts): the list of the folder it works in (or another, by path).
  backlog_add(args: { text: string; note?: string; folder?: string }): Promise<string>;
  backlog_list(args: { folder?: string }): Promise<string>;
  backlog_done(args: { id: string; folder?: string }): Promise<string>;
  copy_to_clipboard(args: { text: string; label?: string }): Promise<string>;
  SendUserFile(args: { files: string[]; caption?: string; status: "normal" | "proactive"; display?: "render" | "attach"; temporary?: boolean }): Promise<string>;
  Artifact(args: { file_path: string; title?: string; description?: string; files?: Record<string, string>; folder?: string }): Promise<string>;
  ally_list(): Promise<string>;
  ally_send(args: { to: string; text: string; urgent?: boolean; slots?: { start: string; end: string }[]; replyTo?: string }): Promise<string>;
  // Pals and the computer's other Claude Code sessions (docs/pals-prd.md §6).
  pals_list(): Promise<string>;
  pal_propose(args: { name: string; dir: string; duty: string }): Promise<string>;
  // Words to a Pal, asleep or awake (§12): it's woken first if need be.
  pal_send(args: { name: string; text: string }): Promise<string>;
  // Conversations that ended on the computer, and taking one over (§10).
  pals_recent(args: { folder?: string }): Promise<string>;
  pal_adopt(args: { sessionId: string }): Promise<string>;
  // Putting one away (归档, as the app does; refused while it works unless force) and naming one.
  pal_archive(args: { name: string; force?: boolean }): Promise<string>;
  pal_rename(args: { name: string; newName: string }): Promise<string>;
  // A link that pairs one more of the owner's devices (5 minutes, one device).
  pair_link(): Promise<string>;
}

/** One of PaloAlly's own tools, harness-neutral: the adapter offers it the harness' way (Claude Code: an MCP tool). */
export interface ToolSpec {
  name: string;
  description: string;
  schema: import("zod").ZodRawShape; // its parameters
  run(args: any): Promise<string>; // what the model is told back
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
  // Rewound (docs/rewind-prd.md §4.1): `sessionId` is a new session forked
  // from this one, its conversation cut after the entry `at` (the original
  // is left as it is). Not with resumeSessionId.
  fork?: { fromSessionId: string; at: string };
  // Claude Code keeps a copy of each file before a turn changes it, so the
  // files can go back to how they were before any of the owner's messages (a Pal).
  fileCheckpointing?: boolean;
  priorCostUsd?: number; // the resumed session's running total, so per-turn cost stays a delta
  permissionMode: string;
  appendSystemPrompt?: string;
  // the harness asks the owner something; safety decisions are the harness' own
  canUseTool: (req: PermissionRequest) => Promise<PermissionDecision>;
  toolGate?: ToolGate; // the assistant's own session: 「只说话不动手」 in an Ally's turn
  mcpServers?: Record<string, unknown>;
  // A Pal's one tool, palo_send (docs/pals-prd.md §16): its words to the assistant, routed by the host.
  paloSend?: (text: string) => Promise<string>;
  // ...and the tools that reach the owner, scoped to this session (Artifact, SendUserFile, notify_user, copy_to_clipboard, pals_list).
  sessionTools?: DeliveryToolHandlers;
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
  // Claude Code autocompacts at about this minus 33k tokens (its autoCompactWindow, for this session only); 0/absent: its default.
  compactWindowTokens?: number;
}

// A long-lived main conversation. send() queues a user turn; turns run in
// order. The session survives across turns until close().
export interface MainSession {
  // Sends a user message now. While a turn is running the harness queues it
  // or folds it into that turn; `uuid` lets the result say which it answered.
  send(text: string, uuid: string, images?: ImageInput[]): void;
  interrupt(): Promise<void>;
  // The steps running in the foreground (commands, subagents) go on in the background.
  backgroundSteps?(): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  // live switches; take effect from the next model call
  setModel(model?: string): Promise<void>;
  setEffort(effort?: string): Promise<void>;
  setPermissionMode(mode: string): Promise<void>;
  // Retitles the session in this process (Claude Code's own rename; a Pal, pals-prd §13).
  rename?(title: string, sessionId?: string): Promise<void>;
  // Puts the files the session changed back as they were right before the
  // owner's message `uuid` (file checkpointing must have been on then).
  rewindFiles?(uuid: string, dryRun?: boolean): Promise<FilesRewound>;
  // The plan's limits and the login, asked of this process (no turn); absent on a harness without them.
  planReport?(): Promise<PlanReport>;
  // Resolves once Claude Code is up (it answered the SDK's first request);
  // rejects with its reason when it refused to start.
  ready(): Promise<void>;
  close(): void;
  readonly closed: boolean;
  // When the process last said anything on its SDK stream (any message, ms):
  // the stall watchdog's sign of life.
  readonly lastActivity?: number;
}

/** What Claude Code says about putting files back (its RewindFilesResult). */
export interface FilesRewound {
  canRewind: boolean;
  error?: string;
  filesChanged?: string[];
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

/** The Pal's tool for answering the assistant (docs/pals-prd.md §16), as Claude Code names it. */
export const PALO_SEND_TOOL = "mcp__paloally__palo_send";

/** What a session's process may call without asking the owner: palo_send and the tools that reach the owner. */
export const SESSION_ALLOWED_TOOLS = [PALO_SEND_TOOL, ...["Artifact", "SendUserFile", "notify_user", "copy_to_clipboard", "pals_list", "add_pending", "resolve_pending", ...BACKLOG_TOOLS].map((n) => `mcp__paloally__${n}`)];

/**
 * Claude Code's own SendUserFile delivers nowhere PaloAlly can see; the
 * session uses ours. (SendMessage stays.) Claude Code's Artifact stays on
 * too (10-30): it is claude.ai's (a page published there with a link, data
 * it keeps, comments; claude.ai/artifact links read), not a copy of ours,
 * which keeps a result in the owner's 成果 (library). Each tool's description says
 * which to use.
 */
export const SESSION_DISALLOWED = ["SendUserFile"];

// ---------------- the harness adapter (docs/harness-adapter-design.md §2) ----------------
//
// Everything one coding harness keeps for itself, behind one interface: its
// processes (the driver above), its conversations on disk, going back in one,
// its own list of sessions, its settings, where its memory lives, its login and
// what its tool names mean. Claude Code's is harness/claude/ (ClaudeHarness);
// nothing above harness/ reads a transcript or calls the SDK.

/** One conversation the harness keeps: its id and the folder it runs in. */
export interface SessionRef {
  sessionId: string;
  cwd: string;
}

/** How an agent's conversation is shown (an agent's id, the assistant's names, what the owner sent with attachments). */
export interface HistoryMapOptions {
  pal: string;
  assistantName: string;
  paloName: string;
  duty?: string;
  recall?: (uuid: string) => { text: string; attachments: import("../types.ts").Attachment[]; kind?: "clipboard"; label?: string } | undefined;
}

/** A conversation's entries as the harness wrote them (opaque above harness/: only its own functions read them). */
export type HarnessEntry = Record<string, any>;

export interface HistoryStore {
  /** The session's conversation has been written (it has run a turn). */
  exists(ref: SessionRef): boolean;
  /** A page of its conversation as the app shows it: `pick` chooses the page from all it read (from the end when it's long). */
  page(ref: SessionRef, o: { map: HistoryMapOptions; pick: (all: import("../types.ts").ChatMessage[]) => import("../types.ts").ChatMessage[]; before?: string | number; limit: number }): Promise<import("../types.ts").ChatMessage[]>;
  /** Entries as the app shows them. */
  toMessages(entries: HarnessEntry[], map: HistoryMapOptions): import("../types.ts").ChatMessage[];
  /** The last entries (about `bytes` of them) and the first. */
  tail(ref: SessionRef, bytes?: number): HarnessEntry[];
  head(ref: SessionRef, bytes?: number): HarnessEntry[];
  /** The model it last ran on and its last words, from some of its entries. */
  model(entries: HarnessEntry[]): string | null;
  lastLine(entries: HarnessEntry[]): string | undefined;
  /** Follows what is written to it from now on (lines that reach it without passing through the host). */
  follow(ref: SessionRef, onEntry: (e: HarnessEntry) => void): { start(): void; poke(): void; stop(): void };
  /** One followed entry as the app shows it (null: nothing to show). */
  entryMessage(e: HarnessEntry, map: HistoryMapOptions): import("../types.ts").ChatMessage | null;
  /** The stall watchdog: did the session take the message sent under `uuid`; a signature of how far it has written. */
  took(ref: SessionRef, uuid: string): boolean;
  growth(ref: SessionRef): string;
  /** How big it is where it is kept (null: not there). */
  size(ref: SessionRef): number | null;
  /** What the session spent on `day` (YYYY-MM-DD in `tz`), its subagents' too. */
  spentOn(ref: SessionRef, day: string, tz: string): number;
  /** Where it is kept: for logs and diagnostics only, never parsed above harness/. */
  locate(ref: SessionRef): string;
}

/** Where a rewound session goes on from (kept until the fork has been written). */
export interface PendingRewindPoint {
  from: string;
  at: string | null;
  cut: string;
}

/** A conversation as it stands, as rewind reads it. */
export interface RewindChain {
  sessionId: string;
  entries: HarnessEntry[];
  chain: HarnessEntry[];
  startedAt?: number; // when its first entry was written
}

/** One of the owner's messages in it, to go back to just before. */
export interface RewindPoint {
  uuid: string; // the entry's id
  index: number; // where it is in the chain
  at: string | null; // the last entry kept (null: nothing is)
  text: string | null; // the owner's words in it (null: not the owner's)
}

export interface Rewinder {
  /** The conversation as it stands: the session's own, or (gone back and not spoken to since) the old one up to where it was cut. */
  chain(ref: SessionRef, pending?: PendingRewindPoint): RewindChain;
  /** Only the owner's entries of a session (a long one: just those lines), to match older messages by their words. */
  ownerChain(ref: SessionRef): RewindChain;
  /** Its entry for a message: by the id it was sent under (`exact`: only that entry), else by its words near `ts`. */
  find(chain: RewindChain, by: { uuid?: string; exact?: boolean; words?: string; ts?: number; used?: Set<string> }): RewindPoint | null;
  /** The ids of every entry kept up to `at` in the session (a fork's inherited entries). */
  keptIds(ref: SessionRef, at: string | null): Set<string>;
  /** Going back to this point can't be a fork (it's before the last compaction): it is copied now. */
  needsCopy(chain: RewindChain, point: RewindPoint): boolean;
  /** Copies the session up to `at` as a new one; its id. */
  copy(ref: SessionRef, at: string, title: string): Promise<string>;
  /** In a copy: each copied entry's new id, by the id it had. */
  renamed(ref: SessionRef): Map<string, string>;
  /** Files were kept as they were right before this message. */
  canRestoreFiles(chain: RewindChain, uuid: string): boolean;
  /** The words of an owner's entry (null: not the owner's). */
  ownerWords(e: HarnessEntry): string | null;
  /** The messages (by app id) that leave the conversation going back to `point`. */
  dropped(chain: RewindChain, point: RewindPoint, map: HistoryMapOptions): string[];
}

/** A session process of the harness' alive on this computer (Claude Code's registry). */
export interface LiveSession {
  pid: number;
  sessionId: string;
  name: string;
  cwd: string;
  kind: string;
  entrypoint?: string;
  status: string;
  waitingFor?: string;
  statusAt?: number;
  jobId?: string;
  socketPath?: string;
  startedAt?: number;
  nameSource?: string;
}

/** One of its conversations as its own list has it (Claude Code: the SDK's SDKSessionInfo). */
export interface SessionInfo {
  sessionId: string;
  summary: string;
  lastModified: number;
  fileSize?: number;
  customTitle?: string;
  firstPrompt?: string;
  gitBranch?: string;
  cwd?: string;
  tag?: string;
  createdAt?: number;
}

/** Where the sessions come from (the SDK; tests give their own). */
export interface RecentSource {
  list(o: { limit: number; includeProgrammatic: boolean }): Promise<SessionInfo[]>;
  info(sessionId: string, dir?: string): Promise<SessionInfo | undefined>;
}

/** The model and thinking depth a session goes on with when it's opened elsewhere. */
export interface OpenAs {
  model?: string;
  effort?: string;
}

export interface SessionDirectory {
  /** The harness' own live sessions on this computer. */
  live(): LiveSession[];
  /** Its ended conversations (listing, one's info) and retitling one without a process. */
  recent: RecentSource;
  rename(sessionId: string, title: string, cwd: string): Promise<void>;
  /** The line that resumes a session in a terminal (no session: a fresh one in the folder; nothing `written` yet: one under that id). */
  resumeCommand(cwd: string, sessionId: string | null, written?: boolean, as?: OpenAs): string;
  /**
   * What a terminal runs, in the session's folder, to open it (在终端打开): the
   * session resumed, or (nothing `written` yet) a fresh one under that id.
   * Throws on an id that isn't one of its own.
   */
  terminalRun(sessionId: string, written: boolean, as?: OpenAs): import("../terminal.ts").TerminalRun;
}

export interface HarnessSettings {
  /** The effort a session starts at when none is chosen (the harness' own settings). */
  defaultEffort(model: string | undefined, cwd: string): string | undefined;
  /** The permission mode the owner's sessions start in by default. */
  defaultPermissionMode(): string;
  /** The permission modes the owner can switch a session to. */
  readonly permissionModes: readonly string[];
  /** Effort ids, lowest first. */
  readonly efforts: readonly string[];
  /** The context window to measure a context against. */
  contextWindow(model: string | undefined, tokens?: number, reported?: number): number;
  /** Why a session didn't start, in a line the owner reads. */
  startError(raw: string): string;
  /** Another session's words, as the harness shows a message from it. */
  peerWrap(name: string, text: string): string;
}

export interface MemoryLocator {
  /** The harness' own memory for a folder (Claude Code's auto memory). */
  autoMemoryDir(cwd: string, configDir?: string): string;
  /** An agent's memory folder for its working folder. */
  agentMemoryDir(cwd: string): string;
  /** The instruction files of a folder it reads (CLAUDE.md…), relative. */
  readonly projectFiles: readonly string[];
}

/** The login process as AuthWatch drives it: lines out, a code in, an exit code. */
export interface LoginProcess {
  onLine(f: (line: string) => void): void;
  onExit(f: (code: number) => void): void;
  write(line: string): void;
  kill(): void;
}

export interface HarnessAuth {
  /** What a failed turn or probe said means the login ran out. */
  isFailure(text?: string, category?: string): boolean;
  /** An errored turn's words say a limit of the plan is used up (only asked when its process said nothing of limits); null: they don't. */
  isLimit(text?: string): LimitHit | null;
  /** Whether it says it is logged in now. */
  loggedIn(): Promise<boolean>;
  /** When its stored login last changed (never the secret), or null. */
  stamp(): Promise<string | null>;
  /** Its own sign-in, driven for the phone (a link out, a code back); `dir` is where it may write what it needs. */
  spawnLogin(dir: string): LoginProcess;
}

/**
 * What a tool is, whatever the harness calls it: a file read, a search, a
 * listing, a new file, an edit (a notebook's, several at once), a shell command (and the steps around one), the web, a subagent (and
 * its bookkeeping), a message to another session, a delivery to the owner,
 * plumbing (asking the owner, finding tools), quiet bookkeeping, an MCP
 * server's tool, or something else.
 */
export type ToolFamily =
  | "read" | "search" | "list" | "write" | "edit" | "notebook-edit" | "multi-edit" | "run" | "run-more" | "web-search" | "web-fetch"
  | "agent" | "agent-more" | "message" | "deliver" | "plumbing" | "quiet" | "mcp" | "other";

export interface ToolClass {
  family: ToolFamily;
  name: string; // the harness' own name for it
  command?: string; // run: the command line
  path?: unknown; // read / write: the file; search: where it looks (as given)
  filter?: unknown; // search: what it filters by (as given)
  filterIsPath?: boolean; // search: the filter is a path pattern (not a file glob)
  url?: string; // web-fetch
  server?: string; // mcp: its server
  tool?: string; // mcp: its tool on that server
}

export interface ToolVocabulary {
  ask: string; // asking the owner a question
  subagent: ReadonlySet<string>; // starting a subagent
  handback: string; // a subagent handing its report back
  handbackNote: RegExp; // the harness' note that a subagent's report went to the main agent
  selfReporting: ReadonlySet<string>; // tools whose progress shows by itself (a subagent writes its own transcript)
  peerSend: string; // a message to another session
  shell: string; // a shell command
  /** A tool of one of the host's MCP servers, as the harness names it. */
  qualified(server: string, tool: string): string;
  classify(name: string, input?: Record<string, unknown>): ToolClass;
  /** An always-allow rule as the app's scope words ("cmd:", "domain:", "path:", "tool:"). */
  ruleScope(toolName: string, content: string): string;
}

/**
 * What a harness can do, for the app (docs/harness-adapter-design.md §3): its
 * name, how its login works, its models, thinking depths and permission modes,
 * which features it has, the terminal commands copy names, and its project
 * instruction file. hello carries one per harness (`harnesses`), and
 * `harness.updated` a new one when its models change. An app that doesn't
 * get it (an older host) uses the same lists built in.
 */
export interface HarnessCapabilities {
  id: string;
  name: string; // shown where the app says which tool runs an agent
  commandPrefix: string | null; // slash commands; null: none
  login: { kind: "oauth-code" | "api-key" | "none"; account: string; fromPhone: boolean };
  models: ModelOption[]; // as model.get lists them; the first is the default
  efforts: string[]; // thinking depths, lowest first
  permissionModes: string[]; // the ones the owner can switch an agent to
  labels: Record<string, string>; // words for ids the app may not know (in the host's language)
  features: {
    rewind: boolean;
    restoreFiles: boolean;
    compact: boolean;
    autoCompact: boolean;
    takeOverTerminal: boolean;
    handBackToTerminal: boolean;
    rename: boolean;
    subagents: boolean;
    backgroundTasks: boolean;
    images: boolean;
    files: boolean;
    questions: { multiSelect: boolean; maxOptions: number };
    liveModelSwitch: boolean;
    liveModeSwitch: boolean;
    projectMemory: boolean;
    globalHooks: boolean;
  };
  terminal: { exitCommand: string; resumeCommand: string; newCommand: string }; // {sessionId} is filled in
  memory: { projectFile: string };
}

export interface Harness {
  readonly id: string;
  /** What it can do (the models as last listed by its processes). */
  capabilities(models: ModelOption[]): HarnessCapabilities;
  readonly tools: ToolVocabulary;
  readonly auth: HarnessAuth;
  /** Starts its processes and runs one-shot probes. */
  readonly driver: HarnessDriver;
  readonly history: HistoryStore;
  readonly rewind: Rewinder;
  readonly sessions: SessionDirectory;
  readonly settings: HarnessSettings;
  readonly memory: MemoryLocator;
}
