import { createSdkMcpServer, query, tool, type Options, type PreToolUseHookInput, type Query, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { VERSION } from "../config.ts";
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

// Every Claude Code session the host starts itself (the main one, probes,
// Pals) carries this, so PaloAlly's global hooks skip them: their prompts
// already reach the owner through the host's own approvals.
export const OWN_SESSION_ENV = { PALOALLY_SESSION: "1" } as const;

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
          peer: z
            .string()
            .optional()
            .describe("这件事交给了本机另一个 Claude Code 会话时，填它的名字（SendMessage 的 to）：外壳会自己定期去看它的进展、它在等主人时推送提醒。用 SendMessage 交代任务时外壳通常会自动跟进，这里只在要改标题或手动关联时用"),
        },
        async (a) => text(await h.report_task(a)),
      ),
      tool(
        "register_watch",
        "登记一个帮主人盯住或推进的「目标」（主人在 App 里看到的就是目标列表）。title 写成目标本身（如「邮箱清零」「十一月回国机票」）。kind=check：外壳定期用轻量探针按 instruction 去查，有新情况再叫你（探针只读：只能读文件、搜网页、用连接器，不能跑命令、不能写文件；要记的状态它自己存在 cursor 里）；kind=schedule：到点（at 或每 interval_minutes）让你执行 instruction，每月几号用 day_of_month（-1 是月底）。带 id 是改已有目标的时间或说明（进度保留）。",
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
        "ally_list",
        "列出主人的 Ally（别人的助理，或主人自己另一台电脑上的助理）：id、对方主人的称呼、助理名、标签（家人朋友 / 我的）、现在是否在线，以及主人给的档位：「能对话」（你的回话直接发出）或「每句要你看」（你的回话先成草稿卡片）。",
        {},
        async () => text(await h.ally_list()),
      ),
      tool(
        "ally_send",
        "给一个 Ally 传话。主人给它的档位是「能对话」时直接发出（不用主人点头，每句都留记录）；是「每句要你看」时只生成草稿卡片，主人点「发送」才会发出，主人也可以改或不发。处理某个 Ally 来话的那一轮里，只有回给这个 Ally 的话可能直接发出，给别的 Ally 的一律是草稿。发给 Ally 的每句话都必须用它。立即返回：按返回的说法告诉主人，草稿别说成已经发出去了。",
        {
          to: z.string().describe("Ally 的 id，或对方主人的称呼"),
          text: z.string().describe("要传的原话，像主人自己会说的那样；不超过 4 KB"),
          urgent: z.boolean().optional().describe("真的急才标：对方会立刻收到推送"),
          slots: z
            .array(z.object({ start: z.string(), end: z.string() }))
            .optional()
            .describe("约时间时的候选时段，ISO 8601 带时区，如 2026-10-17T14:00:00+08:00；最多 5 个"),
          replyTo: z.string().optional().describe("回复对方哪一条（那条消息的 id）"),
        },
        async (a) => text(await h.ally_send(a)),
      ),
      tool(
        "pals_list",
        "列出主人的 Pal（这台电脑上由 PaloAlly 托管的 Claude Code 会话：id、现在的名字、目录、状态、最后一句；status 为 asleep 的是睡着了，进程关着；名字会变，以这里为准），以及电脑上其他还开着的 Claude Code 会话。要给某个 Pal 派活或问它进展，用 pal_send 发给它的 id 或名字。",

        {},
        async () => text(await h.pals_list()),
      ),
      tool(
        "pal_send",
        "给一个 Pal 发话（派活、问进展、转告主人的话）。给 Pal 发话只用它，不用 SendMessage。醒着的和睡着的都行：睡着的主机先叫醒它（几秒），再把话送进去，它看到的是你发来的消息。它回你的话会作为消息回到你这里。",
        {
          name: z.string().describe("Pal 的 id 或名字（pals_list 里的 id / name；它以前的名字也认）"),
          text: z.string().describe("要对它说的话，写完整：它看不到主对话"),
        },
        async (a) => text(await h.pal_send(a)),
      ),
      tool(
        "pal_propose",
        "提议开一个 Pal：一个专门负责某个长期项目的 Claude Code 会话，由 PaloAlly 托管，闲着时会睡下、有事时叫醒。只生成一张卡片，主人点「开吧」才会开；立即返回，别说已经开了。",

        {
          name: z.string().describe("Pal 的名字，主人一看就懂，如「网站」；也是你以后 SendMessage 给它用的名字"),
          dir: z.string().describe("项目目录（绝对路径或 ~/ 开头）"),
          duty: z.string().describe("交接说明：Pal 的第一条消息。写完整——它看不到主对话：项目是什么、要做什么、做到什么程度、注意什么；需要你时用 SendMessage 发给你"),
          dailyUsd: z.number().positive().describe("每天花费上限（美元）；超过了主机会让它停到第二天并告诉主人"),
        },
        async (a) => text(await h.pal_propose(a)),
      ),
      tool(
        "pals_recent",
        "列出这台电脑上最近 30 天里已经退出了的 Claude Code 对话（最新的在前）：sessionId、目录、标题、最后活动时间。正开着的会话和已经是 Pal 的不在这里（看 pals_list）。主人要把以前的某个对话接回来时用它查。",
        { folder: z.string().optional().describe("只看某个目录里的：绝对路径、~/ 开头的路径，或目录名（如 site）") },
        async (a) => text(await h.pals_recent(a)),
      ),
      tool(
        "pal_adopt",
        "提议把一个已经退出的 Claude Code 对话接回来当 Pal（接着原来的上下文跑，由 PaloAlly 托管）。只生成一张卡片「接管『标题』（目录）」，主人点「接管」才会接；立即返回，别说已经接了。",
        { sessionId: z.string().describe("pals_recent 给的 sessionId") },
        async (a) => text(await h.pal_adopt(a)),
      ),
      tool(
        "pair_link",
        "给主人的一台新设备（另一台 Mac、iPad 或手机）拿一个配对链接：打开这台电脑的配对窗口（5 分钟内有效，只能连一台），返回 paloally://pair 链接。主人在新设备上点开它，PaloAlly App 会自己打开并连上这台电脑。只在主人要连新设备时用。",
        {},
        async () => text(await h.pair_link()),
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
export function mapMessage(msg: SDKMessage, state: { lastCost: number; contextTokens: number; lastError?: string; messageId?: string }): HarnessEvent[] {
  // total_cost_usd is cumulative for the session (including what a resume replays)
  const out: HarnessEvent[] = [];
  const m = msg as any;
  switch (m.type) {
    case "system":
      if (m.subtype === "init")
        out.push({
          type: "init",
          sessionId: m.session_id,
          model: m.model,
          tools: m.tools ?? [],
          terminalCommands: m.terminal_slash_commands,
          ...(typeof m.permissionMode === "string" ? { permissionMode: m.permissionMode } : {}),
        });
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

type AnySessionOptions = SessionOptions & Partial<Pick<MainSessionOptions, "tools" | "sharedChrome">>;

// sessionOptions is what a long-lived session asks the SDK for (exported so
// tests can check it without starting Claude Code).
export function sessionOptions(opts: AnySessionOptions): Options {
  const { paloally: _ignored, ...extra } = (opts.mcpServers ?? {}) as Record<string, any>;
  const main = !!opts.tools; // the assistant's own session (a Pal has none of PaloAlly's tools)
  const extraArgs: Record<string, string | null> = {};
  if (opts.sharedChrome) extraArgs.chrome = null;
  if (opts.name) extraArgs.name = opts.name;
  const gate = opts.toolGate;
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
    includePartialMessages: true,
    forwardSubagentText: true,
    agentProgressSummaries: true, // live one-line progress for subagent tasks
    mcpServers: main ? { ...extra, paloally: paloallyMcpServer(opts.tools!) } : extra,
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
    // The host's gate runs as a PreToolUse hook: Claude Code consults it for
    // every call before its own permission decision, so it also covers what
    // auto mode or an allow rule would approve without asking canUseTool
    // (a hook's deny wins over both; SDK callback hooks run even when the
    // owner's settings turn hooks off).
    ...(gate
      ? {
          hooks: {
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
          },
        }
      : {}),
    env: {
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

  async stopTask(taskId: string): Promise<void> {
    await this.q.stopTask(taskId);
  }

  async setModel(model?: string): Promise<void> {
    await this.q.setModel(model);
  }

  async setEffort(effort?: string): Promise<void> {
    await this.q.applyFlagSettings({ effortLevel: (effort ?? null) as any });
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
          if (m.subtype === "success") output = m.structured_output ?? m.result;
          else error = m.errors?.join("; ") || m.subtype;
        }
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
    return { output, costUsd: cost, error, usage, ...(denied.length ? { denied } : {}) };
  }
}
