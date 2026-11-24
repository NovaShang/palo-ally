import { z } from "zod";
import type { DeliveryToolHandlers, ToolHandlers, ToolSpec } from "../harness/types.ts";

// PaloAlly's own tools, harness-neutral (docs/harness-adapter-design.md step 8):
// each one's name, the words the model reads, its parameters and what it does.
// The harness adapter offers them its own way (Claude Code: an in-process MCP
// server named paloally, harness/claude/driver.ts).

function spec<S extends z.ZodRawShape>(name: string, description: string, schema: S, run: (a: z.infer<z.ZodObject<S>>) => Promise<string>): ToolSpec {
  return { name, description, schema, run: run as ToolSpec["run"] };
}

// A session's whole MCP server: palo_send, and the tools that reach the owner
// (the same definitions the assistant has, handlers scoped to the session).
// None of the assistant's manager tools. Its words to the assistant go through
// the host, never through Claude Code's peer registry, which a restart makes stale.
export function sessionToolSpecs(send: (text: string) => Promise<string>, delivery?: DeliveryToolHandlers): ToolSpec[] {
  const shared = delivery ? deliveryTools(delivery, true) : null;
  return [
      spec(
        "palo_send",
        "Send a message to the owner's assistant (the session that manages the Pals). Use this to reply to the assistant, report back, or ask it for something; it is delivered by Palo directly and works even after the assistant restarts. Write it complete: the assistant can't see this conversation.",
        { text: z.string().describe("What to tell the assistant") },
        async (a) => send(a.text),
      ),
      ...(shared ? [shared.Artifact, shared.SendUserFile, shared.notify_user, shared.copy_to_clipboard, shared.pals_list, shared.add_pending, shared.resolve_pending, shared.backlog_add, shared.backlog_list, shared.backlog_done] : []),
  ];
}

export function assistantToolSpecs(h: ToolHandlers): ToolSpec[] {
  const shared = deliveryTools(h);
  return [
      spec(
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
            .describe("这件事交给了 Pal（pal_send）时，填它的名字：外壳会跟着它的状态更新这一行。用 pal_send 派活时外壳会自动开一行并跟进，这里只在要改标题或手动关联时用。交给不是 Pal 的 Claude Code 会话（SendMessage）也可以填它的名字，但外壳不跟进，它回话后你自己把这一行改成 done"),
        },
        async (a) => h.report_task(a),
      ),
      spec(
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
        async (a) => h.register_watch(a),
      ),
      spec("list_watches", "列出所有目标（含状态和最新进度）。", {}, async () => h.list_watches()),
      spec("remove_watch", "删除一个目标。", { id: z.string() }, async (a) => h.remove_watch(a)),
      spec(
        "update_goal",
        "Update the progress line the owner sees on one of their goals (registered with register_watch; ids from list_watches). Write `progress` as one short, concrete line in Chinese about where it stands now — e.g. 「每天比价，现在最低 ¥4,860」, 「本周 4/6 天做到」, 「等你连上 Gmail」. Set `state` when it changes: `waiting` when it needs the owner to do something, `done` when achieved (add a short `outcome`; checking stops), `paused` to stop checking, `tracking` to resume. Pass `ratio` (0–1) only when progress is genuinely measurable.",
        {
          id: z.string(),
          progress: z.string().describe("one short line in Chinese"),
          state: z.enum(["tracking", "waiting", "done", "paused"]).optional(),
          ratio: z.number().min(0).max(1).optional(),
          outcome: z.string().optional().describe("one short line when done"),
        },
        async (a) => h.update_goal(a),
      ),
      // The next two mirror Claude Code's own SendUserFile and Artifact
      // tools (names, wording, parameters), so the model uses them the way
      // it already knows how.
      shared.SendUserFile,
      shared.Artifact,
      shared.copy_to_clipboard,
      spec(
        "ally_list",
        "列出主人的好友（别人的助理；以前加的也可能是主人自己另一台主机上的助理）：id、对方主人的称呼、助理名、标签（家人朋友 / 我的）、现在是否在线，以及主人给的档位：「能对话」（你的回话直接发出）或「每句要你看」（你的回话先成草稿卡片）。",
        {},
        async () => h.ally_list(),
      ),
      spec(
        "ally_send",
        "给一个好友传话。主人给它的档位是「能对话」时直接发出（不用主人点头，每句都留记录）；是「每句要你看」时只生成草稿卡片，主人点「发送」才会发出，主人也可以改或不发。处理某个好友来话的那一轮里，只有回给这个好友的话可能直接发出，给别的好友的一律是草稿。发给好友的每句话都必须用它。立即返回：按返回的说法告诉主人，草稿别说成已经发出去了。",
        {
          to: z.string().describe("好友的 id，或对方主人的称呼"),
          text: z.string().describe("要传的原话，像主人自己会说的那样；不超过 4 KB"),
          urgent: z.boolean().optional().describe("真的急才标：对方会立刻收到推送"),
          slots: z
            .array(z.object({ start: z.string(), end: z.string() }))
            .optional()
            .describe("约时间时的候选时段，ISO 8601 带时区，如 2026-10-17T14:00:00+08:00；最多 5 个"),
          replyTo: z.string().optional().describe("回复对方哪一条（那条消息的 id）"),
        },
        async (a) => h.ally_send(a),
      ),
      shared.pals_list,
      spec(
        "pal_send",
        "给一个 Pal 发话（派活、问进展、转告主人的话）。给 Pal 发话只用它，不用 SendMessage。醒着的和睡着的都行：睡着的主机先叫醒它（几秒），再把话送进去，它看到的是你发来的消息。它回你的话会作为消息回到你这里。",
        {
          name: z.string().describe("Pal 的 id 或名字（pals_list 里的 id / name；它以前的名字也认）"),
          text: z.string().describe("要对它说的话，写完整：它看不到主对话"),
        },
        async (a) => h.pal_send(a),
      ),
      spec(
        "pal_propose",
        "提议开一个 Pal：一个专门负责某个长期项目的 Claude Code 会话，由 Palo 托管，闲着时会睡下、有事时叫醒。只生成一张卡片，主人点「开吧」才会开；立即返回，别说已经开了。",

        {
          name: z.string().describe("Pal 的名字，主人一看就懂，如「网站」；也是你以后 pal_send 给它用的名字"),
          dir: z.string().describe("项目目录（绝对路径或 ~/ 开头）"),
          duty: z.string().describe("交接说明：Pal 的第一条消息。写完整——它看不到主对话：项目是什么、要做什么、做到什么程度、注意什么；需要你时用 palo_send 工具发给你"),
        },
        async (a) => h.pal_propose(a),
      ),
      spec(
        "pals_recent",
        "列出这台主机上最近 30 天里已经退出了的 Claude Code 对话（最新的在前）：sessionId、目录、标题、最后活动时间。正开着的会话和已经是 Pal 的不在这里（看 pals_list）。主人要把以前的某个对话接回来时用它查。",
        { folder: z.string().optional().describe("只看某个目录里的：绝对路径、~/ 开头的路径，或目录名（如 site）") },
        async (a) => h.pals_recent(a),
      ),
      spec(
        "pal_adopt",
        "提议把一个已经退出的 Claude Code 对话接回来当 Pal（接着原来的上下文跑，由 Palo 托管）。只生成一张卡片「接手『标题』（目录）」，主人点「接手」才会接；立即返回，别说已经接了。",
        { sessionId: z.string().describe("pals_recent 给的 sessionId") },
        async (a) => h.pal_adopt(a),
      ),
      spec(
        "pal_archive",
        "把一个 Pal 归档，跟主人在 App 里点「归档」一样：它停下，移出列表，放进「已归档」，之后还能拿回来；文件和对话都不删。只在主人明确要关掉、移除、归档某个 Pal 时用，不要自己决定。它正在干活、等主人点头或后台有任务时不会归档，会告诉你它在做什么：先问主人，主人说照样归档再带 force 调一次。",
        {
          name: z.string().describe("Pal 的 id 或现在的名字（pals_list 里的 id / name）"),
          force: z.boolean().optional().describe("它正忙也归档，手上的事会断。只在主人知道它正忙、仍要归档时用"),
        },
        async (a) => h.pal_archive(a),
      ),
      spec(
        "pal_rename",
        "给一个 Pal 改名，跟主人在 App 里改名一样（Claude Code 里的会话标题也跟着改）。只在主人要改名时用。重名会自动加数字，最后叫什么以返回的为准。",
        {
          name: z.string().describe("Pal 的 id 或现在的名字（pals_list 里的 id / name）"),
          newName: z.string().describe("新名字，最多 40 个字"),
        },
        async (a) => h.pal_rename(a),
      ),
      spec(
        "pair_link",
        "给主人的一台新设备（另一台 Mac、iPad 或手机）拿一个配对链接：打开这台主机的配对窗口（5 分钟内有效，只能连一台），返回 paloally://pair 链接。主人在新设备上点开它，Palo App 会自己打开并连上这台主机。只在主人要连新设备时用。",
        {},
        async () => h.pair_link(),
      ),
      shared.notify_user,
      shared.add_pending,
      shared.resolve_pending,
      shared.backlog_add,
      shared.backlog_list,
      shared.backlog_done,
  ];
}

// The tools that reach the owner, defined once: the assistant's server and
// every session's carry these same definitions (a session's handlers are
// scoped to it). The two that mirror Claude Code's own SendUserFile and
// Artifact keep its names, wording and parameters, so the model uses them
// the way it already knows how.
export function deliveryTools(h: DeliveryToolHandlers, forSession = false) {
  return {
    SendUserFile: spec(
      "SendUserFile",
      "Send files to the user. Use this for any file the user would want to see — a generated diagram, a report, a screenshot, a built artifact — and you want it surfaced, not just mentioned. Send deliverables as they are produced, not batched at the end of the task. Do NOT send routine working files — scratch files, debug output, partial fragments, or every incremental save; each call renders a file card in the conversation. Re-send a file only when it has meaningfully changed. Paths can be absolute or relative to the current working directory.\n\nAdd a `caption` when a one-liner of context helps. Set `status` on every call: `proactive` when you're initiating (it reaches the user's phone), `normal` when replying. `display`: 'render' to show the content inline (images, charts, PDFs, HTML), 'attach' for a file card only; omit to decide by file type.\n\nEvery file sent is also kept in the user's library (成果) so it can be found again — the conversation is one endless timeline. Set `temporary: true` only when you're sure it never needs to be found again (an image you grabbed off the web to show in passing, a throwaway screenshot).",
      {
        files: z.array(z.string()).min(1).describe("File paths (absolute or relative to cwd). Always pass an array."),
        caption: z.string().optional().describe("Optional short caption for the file(s)."),
        status: z.enum(["normal", "proactive"]),
        display: z.enum(["render", "attach"]).optional(),
        temporary: z.boolean().optional().describe("true = show it now, don't keep it in the library"),
      },
      async (a) => h.SendUserFile(a),
      ),
    Artifact: spec(
      "Artifact",
      "Publish a page or document the user will keep and come back to — a report, a dashboard, a write-up (HTML, Markdown, PDF, or any file) — into the user's library (成果), with a card in the conversation. Publishing the same file_path again updates the same artifact (periodic ones like a morning brief: overwrite the file and publish again). A multi-file artifact passes its other files through `files`, mapping each published path (relative, as the main file references it) to a source file.\n\nThis is the default for keeping a result: it stays private on the user's host and shows in the Palo app. claude.ai's artifacts are another thing: Claude Code's own Artifact tool (no mcp__ prefix), or the mcp__claude-artifacts__ tools where Claude Code offers those instead. If you have either, use it when the user wants a claude.ai link (to share or open on the web), a page that stores data or takes comments, or when reading a claude.ai/artifact link.",
      {
        file_path: z.string().describe("The main file to publish (absolute or relative to cwd)."),
        title: z.string().optional().describe("A short name for it."),
        description: z.string().optional().describe("One sentence about it, shown with the card."),
        files: z.record(z.string(), z.string()).optional().describe("Supporting files: published path → source path."),
        folder: z.string().optional().describe("The group it is kept under in the library: a short name in the owner's language (理财, 旅行, 家务), reused for related things. Omit to leave it where it is."),
      },
      async (a) => h.Artifact(a),
      ),
    copy_to_clipboard: spec(
      "copy_to_clipboard",
      "Put text on the user's phone clipboard so they can paste it elsewhere — an address, a code, a reply draft, a command. Use it when the user will clearly want to paste this; don't use it for ordinary answers. The conversation also shows a card with a copy button.",
      {
        text: z.string().describe("Exactly the text to copy, nothing around it."),
        label: z.string().optional().describe("A few words saying what it is, e.g. 收货地址, 验证码."),
      },
      async (a) => h.copy_to_clipboard(a),
      ),
    pals_list: spec(
      "pals_list",
      "列出主人的 Pal（这台主机上由 Palo 托管的 Claude Code 会话：id、现在的名字、目录、状态、最后一句；status 为 asleep 的是睡着了，进程关着；名字会变，以这里为准），以及这台主机上其他还开着的 Claude Code 会话。要给某个 Pal 派活或问它进展，用 pal_send 发给它的 id 或名字。",
      {},
      async () => h.pals_list(),
      ),
    notify_user: spec(
      "notify_user",
      "主动推送一条消息给主人（手机通知；推不出去会改发微信）。只在真正要紧时用。返回的是实际送达情况：没送到就别对主人说已推送。",
      { text: z.string(), urgent: z.boolean().optional() },
      async (a) => h.notify_user(a),
      ),
    // 等你的事: the host keeps the list, not the model; never blocks.
    add_pending: spec(
      "add_pending",
      "Put something the owner must decide on their pending list (等你的事), instead of asking and waiting. The host keeps the list and shows it in the Palo app; it returns at once with the item's id, and the owner's decision comes back to you later as a message. Anything that waits for the owner's answer goes here, not only big decisions: a draft to look at and approve, which of several things to do first, whether to merge or publish, a proposal you made that needs their word. You may mention it in your reply, but a question only in the reply gets lost: if your reply ends by asking or waiting for the owner, put it here too. Small things you can settle yourself, settle. One item per decision, never the same one twice. `title`: one sentence saying what to decide, in the owner's language (「供应商合同第 7 条要不要保留」). `context`: one or two sentences of background. `options`: short answers to pick from, when there are clear ones.",
      {
        title: z.string().describe("One sentence: what the owner must decide"),
        context: z.string().optional().describe("One or two sentences of background"),
        options: z.array(z.string()).max(6).optional().describe("Short answers to pick from (2-4 is best)"),
      },
      async (a) => h.add_pending(a),
      ),
    resolve_pending: spec(
      "resolve_pending",
      "Mark one of the owner's pending items (等你的事) decided, with a one-line conclusion in the owner's language (「保留第 7 条」). Use it when the owner decides something on the list in conversation; an answer the owner picks in the app is marked already (calling it again only rewords the line). Returns what's left on the list.",
      {
        id: z.string().describe("The item's id (from add_pending, or as the host gave it)"),
        conclusion: z.string().describe("One line: what was decided"),
      },
      async (a) => h.resolve_pending(a),
      ),
    // 待办: the folder's list, kept by the host; the owner orders it and starts its items.
    backlog_add: spec(
      "backlog_add",
      "Put something on the backlog (待办) of the folder you work in: what the owner wants done later, not now. Use it when the owner says to put something in the backlog / 待办 or to remember it for later; don't start on it. The host keeps the list (shared by the agents in this folder) and the owner orders and starts its items in the Palo app. `text`: one line saying what to do, in the owner's language. `note`: a few lines of detail, optional. `folder`: another folder's backlog (absolute path), only when the owner names one.",
      {
        text: z.string().describe("One line: what to do"),
        note: z.string().optional().describe("A few lines of detail"),
        folder: z.string().optional().describe("Absolute path of another folder whose backlog this goes on (default: yours)"),
      },
      async (a) => h.backlog_add(a),
      ),
    backlog_list: spec(
      "backlog_list",
      "See the backlog (待办) of the folder you work in: the items being done (and by whom), the queue in the owner's order, the done ones; each with its id.",
      { folder: z.string().optional().describe("Absolute path of another folder (default: yours)") },
      async (a) => h.backlog_list(a),
      ),
    backlog_done: spec(
      "backlog_done",
      "Mark an item of the backlog (待办) done, once you have finished it (id from backlog_list). The owner can still put it back.",
      {
        id: z.string().describe("The item's id"),
        folder: z.string().optional().describe("Absolute path of another folder (default: yours)"),
      },
      async (a) => h.backlog_done(a),
      ),
  };
}
