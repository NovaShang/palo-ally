import { createSdkMcpServer, query, tool, type Query, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { VERSION } from "../config.ts";
import type {
  HarnessDriver,
  HarnessEvent,
  ImageInput,
  MainSession,
  MainSessionOptions,
  ProbeRequest,
  ProbeResult,
  ToolHandlers,
} from "./types.ts";

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

export function paloallyMcpServer(h: ToolHandlers) {
  return createSdkMcpServer({
    name: "paloally",
    version: VERSION,
    alwaysLoad: true,
    tools: [
      tool(
        "report_task",
        "（可选）润色主人任务列表里某个后台任务那一行：给它一句话的说明和状态。任务本身由系统自动跟踪，不调用也会出现在列表里。",
        {
          id: z.string().describe("你给这个任务起的短 id，同一任务前后要一致"),
          summary: z.string().describe("一句话：在做什么 / 结果是什么"),
          status: z.enum(["running", "done", "failed", "needs_input", "stopped"]),
          title: z.string().optional().describe("任务标题（几个字），首次登记时给"),
        },
        async (a) => text(await h.report_task(a)),
      ),
      tool(
        "register_watch",
        "登记一个帮主人盯住或推进的「目标」（主人在 App 里看到的就是目标列表）。title 写成目标本身（如「邮箱清零」「十一月回国机票」）。kind=check：外壳定期用轻量探针按 instruction 去查，有新情况再叫你；kind=schedule：到点（at 或每 interval_minutes）让你执行 instruction，每月几号用 day_of_month（-1 是月底）。带 id 是改已有目标的时间或说明（进度保留）。",
        {
          id: z.string().optional().describe("改已有目标时给它的 id；新登记不填"),
          title: z.string().optional().describe("目标，几个字，主人一眼看懂（新登记必填）"),
          instruction: z.string().optional().describe("盯什么、用什么工具怎么查；或到点要做什么（新登记必填）"),
          kind: z.enum(["check", "schedule"]).optional(),
          interval_minutes: z.number().optional(),
          at: z.array(z.string()).optional().describe('本地时间 "HH:MM" 列表，如 ["08:30"]'),
          day_of_month: z.number().int().optional().describe("配合 at：每月几号（1–31，-1 是月底；29–31 遇到小月就在月底）；改目标时 0 表示取消"),
        },
        async (a) => text(await h.register_watch(a)),
      ),
      tool("list_watches", "列出所有目标（含状态和最新进度）。", {}, async () => text(await h.list_watches())),
      tool("remove_watch", "删除一个目标。", { id: z.string() }, async (a) => text(await h.remove_watch(a))),
      tool(
        "update_goal",
        "Update the progress line the owner sees on one of their goals (registered with register_watch; ids from list_watches). Write `progress` as one short, concrete line in Chinese about where it stands now — e.g. 「每天比价，现在最低 ¥4,860」, 「本周 4/6 天做到」, 「等你连上 Gmail」. Set `state` when it changes: `waiting` when it needs the owner to do something, `done` when achieved (add a short `outcome`; checking stops), `paused` to stop checking, `tracking` to resume. Pass `ratio` (0–1) only when progress is genuinely measurable.",
        {
          id: z.string(),
          progress: z.string().describe("one short line in Chinese"),
          state: z.enum(["tracking", "waiting", "done", "paused"]).optional(),
          ratio: z.number().min(0).max(1).optional(),
          outcome: z.string().optional().describe("one short line when done"),
        },
        async (a) => text(await h.update_goal(a)),
      ),
      // The next two mirror Claude Code's own SendUserFile and Artifact
      // tools (names, wording, parameters), so the model uses them the way
      // it already knows how.
      tool(
        "SendUserFile",
        "Send files to the user. Use this for any file the user would want to see — a generated diagram, a report, a screenshot, a built artifact — and you want it surfaced, not just mentioned. Send deliverables as they are produced, not batched at the end of the task. Do NOT send routine working files — scratch files, debug output, partial fragments, or every incremental save; each call renders a file card in the conversation. Re-send a file only when it has meaningfully changed. Paths can be absolute or relative to the current working directory.\n\nAdd a `caption` when a one-liner of context helps. Set `status` on every call: `proactive` when you're initiating (it reaches the user's phone), `normal` when replying. `display`: 'render' to show the content inline (images, charts, PDFs, HTML), 'attach' for a file card only; omit to decide by file type.\n\nEvery file sent is also kept in the user's library (产出物库) so it can be found again — the conversation is one endless timeline. Set `temporary: true` only when you're sure it never needs to be found again (an image you grabbed off the web to show in passing, a throwaway screenshot).",
        {
          files: z.array(z.string()).min(1).describe("File paths (absolute or relative to cwd). Always pass an array."),
          caption: z.string().optional().describe("Optional short caption for the file(s)."),
          status: z.enum(["normal", "proactive"]),
          display: z.enum(["render", "attach"]).optional(),
          temporary: z.boolean().optional().describe("true = show it now, don't keep it in the library"),
        },
        async (a) => text(await h.SendUserFile(a)),
      ),
      tool(
        "Artifact",
        "Publish a page or document the user will keep and come back to — a report, a dashboard, a write-up (HTML, Markdown, PDF, or any file) — into the user's library (产出物库), with a card in the conversation. Publishing the same file_path again updates the same artifact (periodic ones like a morning brief: overwrite the file and publish again). A multi-file artifact passes its other files through `files`, mapping each published path (relative, as the main file references it) to a source file.",
        {
          file_path: z.string().describe("The main file to publish (absolute or relative to cwd)."),
          title: z.string().optional().describe("A short name for it."),
          description: z.string().optional().describe("One sentence about it, shown with the card."),
          files: z.record(z.string(), z.string()).optional().describe("Supporting files: published path → source path."),
        },
        async (a) => text(await h.Artifact(a)),
      ),
      tool(
        "copy_to_clipboard",
        "Put text on the user's phone clipboard so they can paste it elsewhere — an address, a code, a reply draft, a command. Use it when the user will clearly want to paste this; don't use it for ordinary answers. The conversation also shows a card with a copy button.",
        {
          text: z.string().describe("Exactly the text to copy, nothing around it."),
          label: z.string().optional().describe("A few words saying what it is, e.g. 收货地址, 验证码."),
        },
        async (a) => text(await h.copy_to_clipboard(a)),
      ),
      tool(
        "notify_user",
        "主动推送一条消息给主人（手机通知；推不出去会改发微信）。只在真正要紧时用。返回的是实际送达情况：没送到就别对主人说已推送。",
        { text: z.string(), urgent: z.boolean().optional() },
        async (a) => text(await h.notify_user(a)),
      ),
    ],
  });
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
export function mapMessage(msg: SDKMessage, state: { lastCost: number; contextTokens: number; lastError?: string }): HarnessEvent[] {
  // total_cost_usd is cumulative for the session (including what a resume replays)
  const out: HarnessEvent[] = [];
  const m = msg as any;
  switch (m.type) {
    case "system":
      if (m.subtype === "init")
        out.push({ type: "init", sessionId: m.session_id, model: m.model, tools: m.tools ?? [], terminalCommands: m.terminal_slash_commands });
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
      if (m.parent_tool_use_id == null && ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
        out.push({ type: "text_delta", text: ev.delta.text });
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
      for (const b of m.message?.content ?? []) {
        if (b.type === "text" && b.text) out.push({ type: "assistant_text", text: b.text, parentToolUseId: parent });
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
      out.push({
        type: "result",
        isError: !!m.is_error,
        text: m.subtype === "success" ? (m.result ?? "") : (m.errors?.join("; ") ?? m.subtype),
        costUsd: cost,
        totalCostUsd: total,
        contextTokens: state.contextTokens,
        sessionId: m.session_id,
        errorCategory,
        consumedUuids: Array.isArray(m.user_message_uuids) ? m.user_message_uuids : undefined,
      });
      break;
    }
  }
  return out;
}

class ClaudeMainSession implements MainSession {
  private input = new AsyncQueue<SDKUserMessage>();
  private q: Query;
  closed = false;

  constructor(opts: MainSessionOptions) {
    const { paloally: _ignored, ...extra } = opts.mcpServers as Record<string, any>;
    this.q = query({
      prompt: this.input,
      options: {
        cwd: opts.cwd,
        model: opts.model,
        ...(opts.effort ? { effort: opts.effort as any } : {}),
        resume: opts.resumeSessionId,
        permissionMode: opts.permissionMode as any,
        systemPrompt: { type: "preset", preset: "claude_code", append: opts.appendSystemPrompt },
        settingSources: ["user", "project", "local"],
        includePartialMessages: true,
        forwardSubagentText: true,
        agentProgressSummaries: true, // live one-line progress for subagent tasks
        mcpServers: { ...extra, paloally: paloallyMcpServer(opts.tools) },
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
        env: { ...process.env, ...opts.env, CLAUDE_AGENT_SDK_CLIENT_APP: `paloally/${VERSION}` },
        // Scheduling is ours (durable watches); the harness' own timers live only
        // in one process and would silently die with it.
        disallowedTools: ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup"],
        extraArgs: opts.sharedChrome ? { chrome: null } : {},
        stderr: opts.stderr,
      },
    });
    void this.pump(opts);
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
          })),
        }),
      )
      .catch(() => {});
    this.q
      .supportedCommands()
      .then((cs) => opts.onEvent({ type: "commands", commands: toCommands(cs) }))
      .catch(() => {});
  }

  private async pump(opts: MainSessionOptions): Promise<void> {
    const state = { lastCost: opts.priorCostUsd ?? 0, contextTokens: 0 };
    try {
      for await (const msg of this.q) {
        for (const e of mapMessage(msg, state)) opts.onEvent(e);
      }
    } catch (e) {
      opts.onEvent({ type: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      this.closed = true;
    }
  }

  send(t: string, uuid: string, images: ImageInput[] = []): void {
    // Images go in as content blocks ahead of the text, as the API expects.
    const content = images.length
      ? [
          ...images.map((i) => ({ type: "image", source: { type: "base64", media_type: i.mediaType, data: i.data } })),
          ...(t ? [{ type: "text", text: t }] : []),
        ]
      : t;
    this.input.push({ type: "user", message: { role: "user", content }, parent_tool_use_id: null, uuid } as SDKUserMessage);
  }

  async interrupt(): Promise<void> {
    await this.q.interrupt().catch(() => {});
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

  close(): void {
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

  async runProbe(req: ProbeRequest): Promise<ProbeResult> {
    let output: unknown = undefined;
    let cost = 0;
    let error: string | undefined;
    let usage: Record<string, unknown> | undefined;
    try {
      const q = query({
        prompt: req.prompt,
        options: {
          cwd: req.cwd,
          model: req.model,
          systemPrompt: req.systemPrompt, // short custom prompt, not the full Claude Code one
          settingSources: [], // no CLAUDE.md / user settings: keep the context short
          tools: req.tools,
          mcpServers: req.mcpServers as any,
          ...(req.strictMcp ? { strictMcpConfig: true, skills: [] } : {}),
          persistSession: false,
          maxTurns: req.maxTurns,
          // Unattended: the harness' classifier decides each call, and anything it
          // would ask a human about is denied at once (nobody is there to answer).
          permissionMode: "auto",
          permissionPrompts: "none",
          outputFormat: { type: "json_schema", schema: req.outputSchema },
          env: { ...process.env, ...req.env, CLAUDE_AGENT_SDK_CLIENT_APP: `paloally-probe/${VERSION}` },
        },
      });
      for await (const msg of q) {
        const m = msg as any;
        if (m.type === "result") {
          cost = m.total_cost_usd ?? 0;
          usage = m.modelUsage;
          if (m.subtype === "success") output = m.structured_output ?? m.result;
          else error = m.errors?.join("; ") || m.subtype;
        }
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
    return { output, costUsd: cost, error, usage };
  }
}
