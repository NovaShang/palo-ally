import { createSdkMcpServer, query, tool, type Options, type PermissionMode, type PreToolUseHookInput, type Query, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { assistantToolSpecs, sessionToolSpecs } from "../../tools/paloally.ts";
import { VERSION } from "../../config.ts";
import type {
  FilesRewound,
  HarnessDriver,
  HarnessEvent,
  ImageInput,
  MainSession,
  MainSessionOptions,
  ProbeRequest,
  ProbeResult,
  SessionOptions,
  ToolHandlers,
} from "../types.ts";
import { PALO_SEND_TOOL, SESSION_ALLOWED_TOOLS, SESSION_DISALLOWED, type DeliveryToolHandlers, type ToolSpec } from "../types.ts";

// AsyncQueue is the streaming-input prompt: messages pushed here become user
// turns in the long-lived CLI process.
class AsyncQueue<T> implements AsyncIterable<T> {
  private items: T[] = [];
  private waiters: ((r: IteratorResult<T>) => void)[] = [];
  private done = false;

  push(item: T): void {
    const w = this.waiters.shift();
    if (w) w({ value: item, done: false });
    else this.items.push(item);
  }

  end(): void {
    this.done = true;
    for (const w of this.waiters.splice(0)) w({ value: undefined as never, done: true });
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        const item = this.items.shift();
        if (item !== undefined) return Promise.resolve({ value: item, done: false });
        if (this.done) return Promise.resolve({ value: undefined as never, done: true });
        return new Promise((resolve) => this.waiters.push(resolve));
      },
    };
  }
}

const text = (s: string) => ({ content: [{ type: "text" as const, text: s }] });

// Every Claude Code session the host starts itself (the main one, probes,
// Pals) carries this, so PaloAlly's global hooks skip them: their prompts
// already reach the owner through the host's own approvals.
export const OWN_SESSION_ENV = { PALOALLY_SESSION: "1" } as const;

// Claude Code leaves its own Artifact tool (claude.ai's: a page there with a
// link, data it keeps, comments; claude.ai/artifact links read) off in
// sessions started through the SDK, as the host starts its own; this turns it
// on for the assistant. Not for a Pal: its tools add 10-12 thousand tokens to
// the prompt, on every call (measured on 2.1.322). It only lifts that
// default: the account's plan, the organization's policy, enableArtifact:
// false and CLAUDE_CODE_DISABLE_ARTIFACT still turn it off. On some accounts
// Claude Code swaps the tool, a few seconds in, for an MCP server of its own,
// claude-artifacts (the same pages, data and comments). The variable isn't in
// Claude Code's docs (read from 2.1.322), so a new version can drop it: check
// the init event's tools after an SDK update. A published page's link is in
// the conversation, so no browser is opened on the host. The owner's own
// environment wins over both.
export const CLAUDE_ARTIFACT_ENV = { CLAUDE_CODE_ARTIFACT: "1", CLAUDE_CODE_ARTIFACT_AUTO_OPEN: "0" } as const;

// PaloAlly's tools (host/src/tools/, harness-neutral) as Claude Code takes
// them: one in-process MCP server named paloally.
function mcpServer(specs: ToolSpec[]) {
  return createSdkMcpServer({
    name: "paloally",
    version: VERSION,
    alwaysLoad: true,
    tools: specs.map((s) => tool(s.name, s.description, s.schema, async (a: Record<string, unknown>) => text(await s.run(a)))),
  });
}

/** A session's whole MCP server: palo_send and the tools that reach the owner (tools/paloally.ts). */
export function paloSendMcpServer(send: (text: string) => Promise<string>, delivery?: DeliveryToolHandlers) {
  return mcpServer(sessionToolSpecs(send, delivery));
}

/** The assistant's MCP server (tools/paloally.ts). */
export function paloallyMcpServer(h: ToolHandlers) {
  return mcpServer(assistantToolSpecs(h));
}

function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b: any) => (b?.type === "text" ? b.text : b?.type ? `[${b.type}]` : ""))
      .join("\n");
  }
  return content == null ? "" : JSON.stringify(content);
}

function toCommands(list: any[] | undefined) {
  return (list ?? []).map((c) => ({ name: String(c.name), description: String(c.description ?? ""), argumentHint: c.argumentHint || undefined }));
}

// mapMessage turns one SDK message into zero or more harness events.
/**
 * The main model's context window from a result's per-model usage: the model
 * that read the most input (subagents and titles run on others, smaller).
 */
export function mainContextWindow(modelUsage: unknown): number | undefined {
  if (!modelUsage || typeof modelUsage !== "object") return undefined;
  let best: { read: number; window: number } | undefined;
  for (const u of Object.values(modelUsage as Record<string, any>)) {
    const window = Number(u?.contextWindow);
    if (!(window > 0)) continue;
    const read = (Number(u.inputTokens) || 0) + (Number(u.cacheReadInputTokens) || 0) + (Number(u.cacheCreationInputTokens) || 0);
    if (!best || read > best.read) best = { read, window };
  }
  return best?.window;
}

export function mapMessage(msg: SDKMessage, state: { lastCost: number; contextTokens: number; lastError?: string; messageId?: string }): HarnessEvent[] {
  // total_cost_usd is cumulative for the session (including what a resume replays)
  const out: HarnessEvent[] = [];
  const m = msg as any;
  switch (m.type) {
    case "command_lifecycle": {
      const state = m.state === "queued" ? "queued" : m.state === "started" ? "read" : "done";
      if (typeof m.command_uuid === "string") out.push({ type: "words", uuid: m.command_uuid, state });
      break;
    }
    case "system":
      if (m.subtype === "init")
        out.push({
          type: "init",
          sessionId: m.session_id,
          model: m.model,
          tools: m.tools ?? [],
          terminalCommands: m.terminal_slash_commands,
          ...(typeof m.permissionMode === "string" ? { permissionMode: m.permissionMode } : {}),
          // the effort it actually runs at (a chosen one, or the model's default from Claude Code's settings)
          ...(typeof m.effort === "string" ? { effort: m.effort } : {}),
        });
      else if (m.subtype === "status" && typeof m.permissionMode === "string") out.push({ type: "mode", mode: m.permissionMode });
      else if (m.subtype === "commands_changed") out.push({ type: "commands", commands: toCommands(m.commands) });
      else if (m.subtype === "local_command_output" && m.content)
        out.push({ type: "assistant_text", text: String(m.content), parentToolUseId: null });
      else if (m.subtype === "task_started")
        out.push({ type: "task_started", taskId: m.task_id, toolUseId: m.tool_use_id, description: m.description ?? "", background: m.is_backgrounded, taskType: m.task_type });
      else if (m.subtype === "background_tasks_changed")
        out.push({ type: "background_tasks", taskIds: (m.tasks ?? []).map((t: any) => String(t.task_id)) });
      else if (m.subtype === "task_progress")
        out.push({ type: "task_progress", taskId: m.task_id, toolUseId: m.tool_use_id, summary: m.summary });
      else if (m.subtype === "task_updated" && m.patch?.is_backgrounded === true)
        out.push({ type: "task_backgrounded", taskId: m.task_id });
      else if (m.subtype === "task_notification")
        out.push({ type: "task_notification", taskId: m.task_id, toolUseId: m.tool_use_id, status: m.status, summary: m.summary ?? "" });
      else if (m.subtype === "compact_boundary")
        out.push({ type: "compact", trigger: m.compact_metadata?.trigger, preTokens: m.compact_metadata?.pre_tokens ?? 0, postTokens: m.compact_metadata?.post_tokens });
      break;
    case "stream_event": {
      const ev = m.event;
      // stamped on a turn's first stream event: which owner messages it answers
      if (m.parent_tool_use_id == null && m.user_message_uuid) out.push({ type: "answering", uuids: [m.user_message_uuid] });
      if (m.parent_tool_use_id == null && ev?.type === "message_start" && typeof ev.message?.id === "string") state.messageId = ev.message.id;
      if (m.parent_tool_use_id == null && ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
        out.push({ type: "text_delta", text: ev.delta.text, ...(state.messageId ? { messageId: state.messageId } : {}) });
      } else if (ev?.type === "content_block_start" && ev.content_block?.type === "tool_use") {
        out.push({ type: "tool_start", name: ev.content_block.name, parentToolUseId: m.parent_tool_use_id ?? null });
      }
      break;
    }
    case "assistant": {
      const parent = m.parent_tool_use_id ?? null;
      if (!parent && m.error) state.lastError = String(m.error);
      if (!parent && Array.isArray(m.user_message_uuids) && m.user_message_uuids.length) out.push({ type: "answering", uuids: m.user_message_uuids });
      const usage = m.message?.usage;
      if (!parent && usage) {
        state.contextTokens =
          (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0);
      }
      const messageId = typeof m.message?.id === "string" ? m.message.id : undefined;
      for (const b of m.message?.content ?? []) {
        if (b.type === "text" && b.text) out.push({ type: "assistant_text", text: b.text, parentToolUseId: parent, ...(messageId && !parent ? { messageId } : {}) });
        else if (b.type === "tool_use") out.push({ type: "tool_use", id: b.id, name: b.name, input: b.input ?? {}, parentToolUseId: parent });
      }
      break;
    }
    case "user": {
      const content = m.message?.content;
      if (Array.isArray(content)) {
        for (const b of content) {
          if (b?.type === "tool_result") {
            out.push({
              type: "tool_result",
              toolUseId: b.tool_use_id,
              content: toolResultText(b.content),
              isError: !!b.is_error,
              parentToolUseId: m.parent_tool_use_id ?? null,
            });
          }
        }
      }
      break;
    }
    case "result": {
      const total = m.total_cost_usd ?? 0;
      const errorCategory = m.is_error ? state.lastError : undefined;
      state.lastError = undefined; // each turn reports its own
      const cost = Math.max(0, total - state.lastCost);
      state.lastCost = total;
      const contextWindow = mainContextWindow(m.modelUsage);
      out.push({
        type: "result",
        isError: !!m.is_error,
        text: m.subtype === "success" ? (m.result ?? "") : (m.errors?.join("; ") ?? m.subtype),
        costUsd: cost,
        totalCostUsd: total,
        contextTokens: state.contextTokens,
        ...(contextWindow ? { contextWindow } : {}),
        sessionId: m.session_id,
        errorCategory,
        consumedUuids: Array.isArray(m.user_message_uuids) ? m.user_message_uuids : undefined,
        ...(m.startup_failure_reason ? { startupFailure: String(m.startup_failure_reason) } : {}),
      });
      break;
    }
  }
  return out;
}

// Scheduling is the host's (durable watches); the harness' own timers live
// only in one process and would silently die with it.
const MAIN_DISALLOWED = ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup"];

type AnySessionOptions = SessionOptions & Partial<Pick<MainSessionOptions, "tools" | "sharedChrome" | "compactWindowTokens">>;

// sessionOptions is what a long-lived session asks the SDK for (exported so
// tests can check it without starting Claude Code).
export function sessionOptions(opts: AnySessionOptions): Options {
  const { paloally: _ignored, ...extra } = (opts.mcpServers ?? {}) as Record<string, any>;
  const main = !!opts.tools; // the assistant's own session (a Pal has none of PaloAlly's tools)
  const extraArgs: Record<string, string | null> = {};
  if (opts.sharedChrome) extraArgs.chrome = null;
  if (opts.name) extraArgs.name = opts.name;
  const gate = opts.toolGate;
  // A hook's input says the effort the turn runs at (after any downgrade for
  // the model): the main thread's is reported, nothing is decided.
  const effortHook = async (input: unknown) => {
    const i = input as { agent_id?: string; effort?: { level?: unknown }; permission_mode?: unknown };
    const level = i.effort?.level;
    if (!i.agent_id && typeof level === "string" && level) opts.onEvent({ type: "effort", level });
    // and the permission mode it ran in (plan mode ends when its plan is approved)
    if (!i.agent_id && typeof i.permission_mode === "string" && i.permission_mode) opts.onEvent({ type: "mode", mode: i.permission_mode });
    return {};
  };
  return {
    cwd: opts.cwd,
    model: opts.model,
    ...(opts.effort ? { effort: opts.effort as any } : {}),
    // Rewound: a new session (its id given) forked from the old one, which
    // keeps everything; the new one goes on from the entry `at`.
    ...(opts.fork
      ? { resume: opts.fork.fromSessionId, forkSession: true, resumeSessionAt: opts.fork.at, ...(opts.sessionId ? { sessionId: opts.sessionId } : {}) }
      : { resume: opts.resumeSessionId, ...(opts.sessionId && !opts.resumeSessionId ? { sessionId: opts.sessionId } : {}) }),
    ...(opts.fileCheckpointing ? { enableFileCheckpointing: true } : {}),
    permissionMode: opts.permissionMode as any,
    ...(opts.permissionMode === "bypassPermissions" ? { allowDangerouslySkipPermissions: true } : {}),
    systemPrompt: { type: "preset", preset: "claude_code", ...(opts.appendSystemPrompt ? { append: opts.appendSystemPrompt } : {}) },
    settingSources: ["user", "project", "local"],
    // Flag settings: they win over the owner's settings files for this session
    // only and are never written to them. Claude Code then compacts natively near
    // the window; the assistant's session only (a Pal keeps Claude Code's defaults).
    ...(main && (opts.compactWindowTokens ?? 0) > 0
      ? { settings: { autoCompactWindow: opts.compactWindowTokens, precomputeCompactionEnabled: true } }
      : {}),
    includePartialMessages: true,
    forwardSubagentText: true,
    agentProgressSummaries: true, // live one-line progress for subagent tasks
    mcpServers: main ? { ...extra, paloally: paloallyMcpServer(opts.tools!) } : opts.paloSend ? { ...extra, paloally: paloSendMcpServer(opts.paloSend, opts.sessionTools) } : extra,
    // Its own tools never ask the owner; Claude Code's built-in SendUserFile
    // is off, so the model uses ours, which lands in PaloAlly.
    ...(!main && opts.paloSend
      ? { allowedTools: opts.sessionTools ? SESSION_ALLOWED_TOOLS : [PALO_SEND_TOOL], ...(opts.sessionTools ? { disallowedTools: SESSION_DISALLOWED } : {}) }
      : {}),
    canUseTool: async (toolName, input, o) =>
      opts.canUseTool({
        toolName,
        input,
        toolUseId: o.toolUseID,
        title: o.title,
        reason: o.decisionReason,
        agentId: o.agentID,
        signal: o.signal,
        suggestions: o.suggestions,
        defaultToNo: o.defaultToNo,
        suppressAlwaysAllowRule: o.suppressAlwaysAllowRule,
      }) as any,
    hooks: {
      // The host's gate runs as a PreToolUse hook: Claude Code consults it for
      // every call before its own permission decision, so it also covers what
      // auto mode or an allow rule would approve without asking canUseTool
      // (a hook's deny wins over both; SDK callback hooks run even when the
      // owner's settings turn hooks off).
      ...(gate
        ? {
            PreToolUse: [
              {
                hooks: [
                  async (input) => {
                    const i = input as PreToolUseHookInput;
                    const deny = gate({ toolName: i.tool_name, input: (i.tool_input ?? {}) as Record<string, unknown>, agentId: i.agent_id, via: "hook" });
                    return deny ? { hookSpecificOutput: { hookEventName: "PreToolUse" as const, permissionDecision: "deny" as const, permissionDecisionReason: deny } } : {};
                  },
                ],
              },
            ],
          }
        : {}),
      // Each turn's end says the effort it ran at.
      Stop: [{ hooks: [effortHook] }],
    },
    env: {
      ...(main ? CLAUDE_ARTIFACT_ENV : {}),
      ...(opts.baseEnv ?? process.env),
      ...opts.env,
      ...OWN_SESSION_ENV,
      CLAUDE_AGENT_SDK_CLIENT_APP: `${main ? "paloally" : "paloally-pal"}/${VERSION}`,
    },
    ...(main ? { disallowedTools: MAIN_DISALLOWED } : {}),
    extraArgs,
    stderr: opts.stderr,
    ...(opts.spawn ? { spawnClaudeCodeProcess: (o) => opts.spawn!(o) } : {}),
  };
}

// The probe's web lookups, approved up front. A probe runs unattended in auto
// mode, but Claude Code runs auto mode only on models that have it: on the
// cheap probe model (Haiku 4.5) it starts in "default" instead, where these
// ask first, and with nobody to answer they'd be refused every time. They
// only read; the rest (Read/Glob/Grep inside the probe's folder) runs anyway,
// and anything else, connectors included, is still the mode's call.
const PROBE_PREAPPROVED = new Set(["WebFetch", "WebSearch"]);

// probeOptions is what a probe run asks the SDK for (exported so tests can
// check it without starting Claude Code).
export function probeOptions(req: ProbeRequest): Options {
  return {
    cwd: req.cwd,
    model: req.model,
    systemPrompt: req.systemPrompt, // short custom prompt, not the full Claude Code one
    settingSources: [], // no CLAUDE.md / user settings: keep the context short
    tools: req.tools,
    allowedTools: req.tools.filter((t) => PROBE_PREAPPROVED.has(t)),
    mcpServers: req.mcpServers as any,
    ...(req.strictMcp ? { strictMcpConfig: true, skills: [] } : {}),
    persistSession: false,
    maxTurns: req.maxTurns,
    // A probe looks things up and answers in a fixed schema; extended
    // thinking was most of its output tokens (and of its cost).
    thinking: { type: "disabled" },
    // Unattended: the harness' classifier decides each call (where the model
    // has auto mode), and anything it would ask a human about is denied at
    // once (nobody is there to answer).
    permissionMode: "auto",
    permissionPrompts: "none",
    outputFormat: { type: "json_schema", schema: req.outputSchema },
    env: { ...process.env, ...req.env, ...OWN_SESSION_ENV, CLAUDE_AGENT_SDK_CLIENT_APP: `paloally-probe/${VERSION}` },
  };
}

class ClaudeMainSession implements MainSession {
  private input = new AsyncQueue<SDKUserMessage>();
  private q: Query;
  private closing = false; // close() was called: an exit is ours, not a crash
  private readyPromise: Promise<void> | null = null;
  closed = false;
  lastActivity = 0;

  constructor(private opts: AnySessionOptions) {
    const main = !!opts.tools; // the assistant's own session (a Pal has none of PaloAlly's tools)
    const options = sessionOptions(opts);
    this.q = query({ prompt: this.input, options });
    void this.pump();
    if (!main) return;
    this.q
      .supportedModels()
      .then((ms) =>
        opts.onEvent({
          type: "models",
          models: ms.map((m) => ({
            value: m.value,
            displayName: m.displayName,
            description: m.description,
            efforts: m.supportsEffort ? (m.supportedEffortLevels ?? []) : [],
            ...(m.resolvedModel ? { resolved: m.resolvedModel } : {}),
          })),
        }),
      )
      .catch(() => {});
    this.q
      .supportedCommands()
      .then((cs) => opts.onEvent({ type: "commands", commands: toCommands(cs) }))
      .catch(() => {});
  }

  private async pump(): Promise<void> {
    const opts = this.opts;
    const state = { lastCost: opts.priorCostUsd ?? 0, contextTokens: 0 };
    let error: string | undefined;
    try {
      for await (const msg of this.q) {
        this.lastActivity = Date.now();
        for (const e of mapMessage(msg, state)) opts.onEvent(e);
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      opts.onEvent({ type: "error", message: error });
    } finally {
      this.closed = true;
      if (!this.closing) opts.onExit?.(error);
    }
  }

  ready(): Promise<void> {
    this.readyPromise ??= this.q.initializationResult().then(() => {});
    return this.readyPromise;
  }

  send(t: string, uuid: string, images: ImageInput[] = []): void {
    // Images go in as content blocks ahead of the text, as the API expects.
    const content = images.length
      ? [
          ...images.map((i) => ({ type: "image", source: { type: "base64", media_type: i.mediaType, data: i.data } })),
          ...(t ? [{ type: "text", text: t }] : []),
        ]
      : t;
    this.input.push({
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      uuid,
      ...(this.opts.ownerOrigin ? { origin: { kind: "human" } } : {}),
    } as SDKUserMessage);
  }

  async interrupt(): Promise<void> {
    await this.q.interrupt().catch(() => {});
  }

  async backgroundSteps(): Promise<void> {
    await this.q.backgroundTasks();
  }

  async stopTask(taskId: string): Promise<void> {
    await this.q.stopTask(taskId);
  }

  async setModel(model?: string): Promise<void> {
    await this.q.setModel(model);
  }

  async setEffort(effort?: string): Promise<void> {
    await this.q.applyFlagSettings({ effortLevel: (effort ?? null) as any });
  }

  async setPermissionMode(mode: string): Promise<void> {
    await this.q.setPermissionMode(mode as PermissionMode);
  }

  // Claude Code's rename_session control request, as the SDK's Query sends
  // it (source "host": the CLI counts it as the owner's own rename).
  async rename(title: string, sessionId?: string): Promise<void> {
    const q = this.q as unknown as { renameSession?: (title: string, sessionId?: string) => Promise<void> };
    if (typeof q.renameSession !== "function") throw new Error("这个版本的 Claude Code 改不了名字");
    await q.renameSession(title, sessionId);
  }

  async rewindFiles(uuid: string, dryRun = false): Promise<FilesRewound> {
    const r = await this.q.rewindFiles(uuid, { dryRun });
    return { canRewind: !!r.canRewind, ...(r.error ? { error: r.error } : {}), ...(r.filesChanged ? { filesChanged: r.filesChanged } : {}) };
  }

  close(): void {
    this.closing = true;
    this.input.end();
    this.q.close();
    this.closed = true;
  }
}

export class ClaudeCodeDriver implements HarnessDriver {
  readonly name = "claude-code";

  startMain(opts: MainSessionOptions): MainSession {
    return new ClaudeMainSession(opts);
  }

  startPal(opts: SessionOptions): MainSession {
    const { tools: _none, sharedChrome: _no, toolGate: _gate, ...rest } = opts as AnySessionOptions;
    return new ClaudeMainSession(rest);
  }

  async runProbe(req: ProbeRequest): Promise<ProbeResult> {
    let output: unknown = undefined;
    let cost = 0;
    let error: string | undefined;
    let usage: Record<string, unknown> | undefined;
    let denied: string[] = [];
    try {
      const q = query({ prompt: req.prompt, options: probeOptions(req) });
      for await (const msg of q) {
        const m = msg as any;
        if (m.type === "result") {
          cost = m.total_cost_usd ?? 0;
          usage = m.modelUsage;
          denied = (m.permission_denials ?? []).map((d: any) => String(d.tool_name));
          // A failed call (no login, say) can still end as "success", flagged is_error.
          if (m.subtype === "success" && !m.is_error) output = m.structured_output ?? m.result;
          else error = m.errors?.join("; ") || (typeof m.result === "string" && m.result) || m.subtype;
        }
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
    return { output, costUsd: cost, error, usage, ...(denied.length ? { denied } : {}) };
  }
}
