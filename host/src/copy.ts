import type { ProbeTrigger } from "./probe.ts";
import type { DeliveryResult } from "./router.ts";
import type { Approval, Question, Task, Watch } from "./types.ts";
import { formatDuration, truncate, zonedParts } from "./util.ts";

// Every sentence the owner (or the model, for synthetic turns) reads from the
// shell lives here, so the voice stays consistent and is easy to change.

// friendlyError turns harness/API errors into something the owner can act on.
// The SDK's own error kind decides; the text match is only a fallback.
export function friendlyError(error: string, category?: string): string {
  switch (category) {
    case "rate_limit":
    case "overloaded":
    case "server_error":
      return "模型那边太忙了，这一步没做完。稍后再跟我说一次就好。";
    case "authentication_failed":
    case "oauth_org_not_allowed":
    case "verification_required":
    case "cloud_credential_error":
      return "我连不上模型了（登录失效）。请在电脑上运行 claude 重新登录，或者检查 API 密钥。";
    case "billing_error":
    case "account_on_hold":
      return "模型额度用完了或账号受限，等额度恢复或者换个模型再试。";
    case "model_not_found":
      return "现在选的模型用不了，去「模型与思考」里换一个。";
    case "max_output_tokens":
      return "这次回答太长被截断了，可以让我分几次说。";
  }
  const e = error.toLowerCase();
  if (/rate.?limit|429|overloaded|529/.test(e)) return "模型那边太忙了，这一步没做完。稍后再跟我说一次就好。";
  if (/not logged in|unauthorized|401|invalid api key|authentication/.test(e)) return "我连不上模型了（登录失效）。请在电脑上运行 claude 重新登录，或者检查 API 密钥。";
  if (/credit|billing|quota|usage limit/.test(e)) return "模型额度用完了，等额度恢复或者换个模型再试。";
  if (/network|econn|timed? ?out|socket|fetch failed/.test(e)) return "网络出了问题，这一步没做完。网络恢复后再跟我说一次。";
  if (/exited with code|process/.test(e)) return "我这边刚才意外中断了，已经重新准备好。刚才那件事可以再说一次。";
  return `出了点问题，这一步没做完。（${truncate(error, 120)}）`;
}

// Plain words for what the assistant is doing right now (shown while busy).
// The owner-facing status line while a tool runs: plain Chinese, never the
// tool's name, its input (paths, commands, URLs, queries) or our internal
// terms. The app appends the "…". null = keep the current line (the tool
// shows itself, like a question card, or is housekeeping).
export const ACTIVITY = {
  mail: "在查邮件",
  calendar: "在看日历",
  files: "在翻文件",
  writing: "在整理文件",
  web: "在网上查",
  computer: "在电脑上操作",
  background: "在后台办",
  handOff: "在交给后台办",
  docs: "在看文档",
  forYou: "在准备给你的东西",
  noting: "在记下来",
  generic: "在处理",
  reply: "在写回复",
  thinking: "在想",
} as const;

const KEEP_LINE = new Set(["AskUserQuestion", "ToolSearch", "TodoWrite", "ListAgents", "ExitPlanMode", "EnterPlanMode"]);

export function describeActivity(tool: string): string | null {
  if (KEEP_LINE.has(tool)) return null;
  switch (tool) {
    case "Read": case "Grep": case "Glob": case "LS": case "NotebookRead":
      return ACTIVITY.files;
    case "Write": case "Edit": case "MultiEdit": case "NotebookEdit":
      return ACTIVITY.writing;
    case "Bash": case "BashOutput": case "KillShell": case "KillBash": case "Monitor":
      return ACTIVITY.computer;
    case "WebSearch": case "WebFetch":
      return ACTIVITY.web;
    case "Agent": case "Task": case "TaskOutput": case "TaskStop": case "TaskCreate": case "TaskUpdate":
      return ACTIVITY.background;
    case "SendMessage":
      return ACTIVITY.handOff;
    case "SendUserFile": case "Artifact":
      return ACTIVITY.forYou;
  }
  const m = /^mcp__(.+?)__(.+)$/.exec(tool);
  if (!m) return ACTIVITY.generic;
  const server = m[1]!.toLowerCase();
  const name = m[2]!.toLowerCase();
  if (server === "paloally") {
    if (/sendus|artifact|clipboard|notify/.test(name)) return ACTIVITY.forYou;
    if (/watch|goal|report_task/.test(name)) return ACTIVITY.noting;
    return ACTIVITY.generic;
  }
  if (/gmail|outlook/.test(server) || /mail|inbox|draft|thread/.test(name)) return ACTIVITY.mail;
  if (/calendar/.test(server) || /calendar|event|meeting|schedule/.test(name)) return ACTIVITY.calendar;
  if (/chrome|browser|playwright|fetch|search|web/.test(server)) return ACTIVITY.web;
  if (/notion|drive|docs|confluence|sharepoint|onedrive|dropbox|box/.test(server)) return ACTIVITY.docs;
  return ACTIVITY.generic;
}

export const ACTIVITY_THINKING = ACTIVITY.thinking;
export const ACTIVITY_BACKGROUND = ACTIVITY.background;

export function statusWord(s: string): string {
  return s === "done" ? "办好了" : s === "failed" ? "没办成" : s === "needs_input" ? "需要你" : "已停下";
}

// ---- chat lines ----

export const taskReceiptText = (t: Task) => `收到，开始办：${t.summary || t.title}`;

export function taskResultText(t: Task): string {
  const icon = t.status === "done" ? "✅" : t.status === "failed" ? "⚠️" : "⏹";
  return `${icon} ${t.title}：${t.summary || statusWord(t.status)}`;
}

export const approvalCardText = (a: Approval) => `这一步要你点头：${a.title}${a.careful ? "（请仔细看一下）" : ""}`;
// The chat text of a question card (the card itself shows the options).
export const questionCardText = (q: Question) => `想问你：${q.items[0]!.question}${q.items.length > 1 ? `（共 ${q.items.length} 个问题）` : ""}`;
export const questionLineHelp = "有几个问题就回几行，按顺序，每行一个数字或你的想法。";

export const stopReply = "好，手上的事都停下了。";
export const approvalAnswerReply = (allow: boolean) => (allow ? "好，已同意。" : "好，已拒绝。");
export const statusReply = (busy: boolean, running: number, pending: number) =>
  `${busy ? "忙着" : "空闲"}；进行中的任务 ${running} 个，待确认 ${pending} 个。`;

export const runawayNotice = "目标的提醒这阵子触发得异常频繁，我先把后面的通知压住了，只放在对话里，你有空看看。";

export const budgetNotice = (label?: string) =>
  `今天的花费到了你设的上限，目标的定期检查先停下了（比如「${label ?? "定时任务"}」）。明天会恢复。`;

export function offlineNotice(gapMs: number, last: number, now: number, tz: string): string {
  const f = (ms: number) => {
    const p = zonedParts(ms, tz);
    return `${p.month}/${p.day} ${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
  };
  return `我掉线了 ${formatDuration(gapMs)}（${f(last)} – ${f(now)}），刚恢复。6 小时内错过的定时任务我会补上，更早的就跳过了；这段时间的微信消息可能没收到。`;
}

// ---- push titles ----

// What notify_user tells the assistant actually happened. Never 「已推送」
// unless a push or a WeChat message really went out.
export function notifyResultText(r: DeliveryResult | null): string {
  if (!r) return "消息已放进 App 对话；推送还没确认送达（推送服务回得慢）。别当作主人已经看到。";
  if (r.suppressed === "quiet")
    return `已记入 App 对话。现在是免打扰时段，没推送，之后也不会补推${r.quietEnds ? `（免打扰到 ${r.quietEnds}）` : ""}。真要紧就带 urgent=true 再发一次。`;
  if (r.suppressed) return "已记入 App 对话。短时间内推送太多（或刚推过同样的内容），这条没推送。";
  const pushed = r.devices ? `已推送到 ${r.devices} 台设备` : "已推送";
  if (r.pushed && r.wechat) return `${pushed}，也发了微信提醒。`;
  if (r.pushed) return `${pushed}。`;
  if (r.wechat) return `推送没发出去：${r.pushError ?? "原因不明"}。已改发微信提醒；消息也在 App 对话里。`;
  return `没能通知到主人：推送没发出去（${r.pushError ?? "原因不明"}），微信也发不了（${r.wechatNote ?? "微信没用上"}）。消息只在 App 对话里，主人打开 App 才看得到。别对主人说推过去了；要紧的话，等主人下次来消息时当面提。`;
}

export const PUSH_TITLE_APPROVAL = "需要你确认";
export const PUSH_TITLE_QUESTION = "等你回答";
export const PUSH_TITLE_BACK = "我回来了";

// ---- synthetic turns the shell sends the model ----

export const scheduleTurnText = (w: Watch) => `[定时·${w.title}] ${w.instruction}\n（目标 ${w.id}：你的回复第一句会记成它的进度；状态有变就用 update_goal。）`;

export function probeTurnText(triggers: ProbeTrigger[]): string {
  const lines = triggers.map((t) => `- 「${t.watch.title}」（${t.watch.id}）：${t.summary}`).join("\n");
  return `[探针] 以下目标有新情况：\n${lines}\n判断是否值得告诉主人；值得就直接写给主人看的话，不值得就只回复 [skip]。`;
}

export function restartTurnText(orphanedTitles: string[], unansweredOwnerText?: string): string | null {
  const lines: string[] = [];
  if (orphanedTitles.length) lines.push(`这些后台任务被打断了：${orphanedTitles.map((t) => `「${t}」`).join("、")}。`);
  if (unansweredOwnerText) lines.push(`主人在重启前发的这条消息还没回：「${truncate(unansweredOwnerText, 500)}」。`);
  if (!lines.length) return null;
  return `[系统] 助理刚刚重启了。${lines.join("")}需要的话接着办或者回答主人；都不需要就只回复 [skip]。`;
}

// ---- approval cards ----

function domainOf(url: unknown): string | null {
  if (typeof url !== "string") return null;
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

function nameTokens(name: string): string[] {
  return name
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

export function describeTool(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return "在电脑上运行一条命令";
  if (tool === "Write") return "写入文件";
  if (tool === "Edit") return "修改文件";
  if (tool === "Read") return "看一个文件";
  if (tool === "WebFetch") return `打开网页 ${domainOf(input.url) ?? ""}`.trim();
  if (tool.startsWith("mcp__")) {
    const leaf = tool.split("__").slice(2).join(" ");
    if (/browser_navigate|claude-in-chrome__navigate/.test(tool)) return `浏览器打开 ${domainOf(input.url) ?? ""}`.trim();
    if (/browser_click/.test(tool)) return `在网页上点击「${truncate(String(input.element ?? ""), 30)}」`;
    if (/browser_type|fill_form|form_input/.test(tool)) return "在网页上填写内容";
    if (/claude-in-chrome__computer/.test(tool)) return "在你的浏览器里操作";
    if (/javascript_tool|browser_evaluate/.test(tool)) return "在你的浏览器里运行一段脚本";
    if (/file_upload|upload_image/.test(tool)) return "往网页上传文件";
    const t = nameTokens(leaf);
    if (t.includes("send") || t.includes("reply") || t.includes("forward")) return "替你发出一条消息";
    if (t.includes("delete") || t.includes("trash") || t.includes("remove")) return "删除一些东西";
    if (t.includes("create") || t.includes("add")) return "替你新建一项内容";
    return "使用一个连接的服务";
  }
  return "做一步操作";
}

export function describeInput(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return truncate(String(input.command ?? ""), 4000);
  if (tool === "Write" || tool === "Edit" || tool === "Read") return String(input.file_path ?? "");
  if (input.url) return String(input.url);
  return truncate(JSON.stringify(input), 1000);
}

// Short label for one step in a task's activity list (shown in the app).
export function activityLabel(tool: string): string {
  if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") return "写文件";
  if (tool === "Read") return "看文件";
  if (tool === "Grep" || tool === "Glob") return "找文件";
  if (tool === "Bash") return "跑命令";
  if (tool === "WebSearch") return "搜索";
  if (tool === "WebFetch") return "看网页";
  if (tool === "Agent" || tool === "Task") return "安排帮手";
  if (/browser_|claude-in-chrome/.test(tool)) return "用浏览器";
  if (tool.startsWith("mcp__paloally__")) return "整理";
  if (tool.startsWith("mcp__")) return "用连接的服务";
  return "处理";
}
