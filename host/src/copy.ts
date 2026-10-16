import type { ProbeTrigger } from "./probe.ts";
import type { DeliveryResult } from "./router.ts";
import type { Approval, Question, Task, Watch } from "./types.ts";
import { t } from "./i18n/index.ts";
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
      return t("err.busy");
    case "authentication_failed":
    case "oauth_org_not_allowed":
    case "verification_required":
    case "cloud_credential_error":
      return t("err.auth");
    case "billing_error":
    case "account_on_hold":
      return t("err.billing");
    case "model_not_found":
      return t("err.model");
    case "max_output_tokens":
      return t("err.maxTokens");
  }
  const e = error.toLowerCase();
  if (/rate.?limit|429|overloaded|529/.test(e)) return t("err.busy");
  if (/not logged in|unauthorized|401|invalid api key|authentication/.test(e)) return t("err.auth");
  if (/credit|billing|quota|usage limit/.test(e)) return t("err.billingText");
  if (/network|econn|timed? ?out|socket|fetch failed/.test(e)) return t("err.network");
  if (/exited with code|process/.test(e)) return t("err.crashed");
  return t("err.generic", { detail: truncate(error, 120) });
}

// Plain words for what the assistant is doing right now (shown while busy).
// The owner-facing status line while a tool runs: plain words, never the
// tool's name, its input (paths, commands, URLs, queries) or our internal
// terms. The app appends the "…". null = keep the current line (the tool
// shows itself, like a question card, or is housekeeping).
export const ACTIVITY = {
  get mail() { return t("activity.mail"); },
  get calendar() { return t("activity.calendar"); },
  get files() { return t("activity.files"); },
  get writing() { return t("activity.writing"); },
  get web() { return t("activity.web"); },
  get computer() { return t("activity.computer"); },
  get background() { return t("activity.background"); },
  get handOff() { return t("activity.handOff"); },
  get docs() { return t("activity.docs"); },
  get forYou() { return t("activity.forYou"); },
  get noting() { return t("activity.noting"); },
  get generic() { return t("activity.generic"); },
  get reply() { return t("activity.reply"); },
  get ally() { return t("activity.ally"); },
  get thinking() { return t("activity.thinking"); },
};

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
    if (name === "ally_send") return ACTIVITY.ally;
    return ACTIVITY.generic;
  }
  if (/gmail|outlook/.test(server) || /mail|inbox|draft|thread/.test(name)) return ACTIVITY.mail;
  if (/calendar/.test(server) || /calendar|event|meeting|schedule/.test(name)) return ACTIVITY.calendar;
  if (/chrome|browser|playwright|fetch|search|web/.test(server)) return ACTIVITY.web;
  if (/notion|drive|docs|confluence|sharepoint|onedrive|dropbox|box/.test(server)) return ACTIVITY.docs;
  return ACTIVITY.generic;
}

export const activityThinking = () => ACTIVITY.thinking;
export const activityBackground = () => ACTIVITY.background;

export function statusWord(s: string): string {
  return t(s === "done" ? "status.done" : s === "failed" ? "status.failed" : s === "needs_input" ? "status.needs_input" : "status.stopped");
}

// ---- chat lines ----

export const taskReceiptText = (task: Task) => t("chat.taskReceipt", { what: task.summary || task.title });

export function taskResultText(task: Task): string {
  const icon = task.status === "done" ? "✅" : task.status === "failed" ? "⚠️" : "⏹";
  return t("chat.taskResult", { icon, title: task.title, what: task.summary || statusWord(task.status) });
}

export const approvalCardText = (a: Approval) => t("chat.approvalCard", { title: a.title, careful: a.careful ? t("chat.carefulSuffix") : "" });
// The chat text of a question card (the card itself shows the options).
export const questionCardText = (q: Question) =>
  t("chat.questionCard", { question: q.items[0]!.question, more: q.items.length > 1 ? t("chat.questionMore", { n: q.items.length }) : "" });
export const questionLineHelp = () => t("chat.questionLineHelp");

export const stopReply = () => t("chat.stopReply");
export const approvalAnswerReply = (allow: boolean) => t(allow ? "chat.approved" : "chat.denied");
export const statusReply = (busy: boolean, running: number, pending: number) =>
  t("chat.statusReply", { state: t(busy ? "chat.statusBusy" : "chat.statusIdle"), running, pending });

export const runawayNotice = () => t("chat.runaway");

export const budgetNotice = (label?: string) => t("chat.budget", { label: label ?? t("chat.budgetDefaultLabel") });

export function offlineNotice(gapMs: number, last: number, now: number, tz: string): string {
  const f = (ms: number) => {
    const p = zonedParts(ms, tz);
    return `${p.month}/${p.day} ${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
  };
  return t("chat.offline", { gap: formatDuration(gapMs), from: f(last), to: f(now) });
}

// ---- push titles ----

// What notify_user tells the assistant actually happened. Never 「已推送」
// unless a push or a WeChat message really went out.
export function notifyResultText(r: DeliveryResult | null): string {
  if (!r) return t("notify.noReceipt");
  if (r.suppressed === "quiet") return t("notify.quiet", { until: r.quietEnds ? t("notify.quietUntil", { end: r.quietEnds }) : "" });
  if (r.suppressed) return t("notify.suppressed");
  const pushed = r.devices ? t("notify.pushedDevices", { n: r.devices }) : t("notify.pushed");
  if (r.pushed && r.wechat) return t("notify.pushedWechat", { pushed });
  if (r.pushed) return t("notify.pushedOnly", { pushed });
  if (r.wechat) return t("notify.wechatFallback", { error: r.pushError ?? t("notify.unknownReason") });
  return t("notify.failed", { error: r.pushError ?? t("notify.unknownReason"), wechat: r.wechatNote ?? t("notify.wechatUnused") });
}

export const pushTitleApproval = () => t("push.approval");
export const pushTitleQuestion = () => t("push.question");
export const pushTitleBack = () => t("push.back");

// ---- synthetic turns the shell sends the model ----

export const scheduleTurnText = (w: Watch) => t("turn.schedule", { title: w.title, instruction: w.instruction, id: w.id });

const quoted = (x: string) => t("ally.msg.quote", { text: x });

export function probeTurnText(triggers: ProbeTrigger[]): string {
  const lines = triggers.map((x) => t("turn.probeLine", { title: quoted(x.watch.title), id: x.watch.id, summary: x.summary })).join("\n");
  return t("turn.probe", { lines });
}

export function restartTurnText(orphanedTitles: string[], unansweredOwnerText?: string): string | null {
  const lines: string[] = [];
  if (orphanedTitles.length) lines.push(t("turn.restart.orphaned", { titles: orphanedTitles.map(quoted).join(t("turn.listSep")) }));
  if (unansweredOwnerText) lines.push(t("turn.restart.unanswered", { text: truncate(unansweredOwnerText, 500) }));
  if (!lines.length) return null;
  return t("turn.restart", { lines: lines.join("") });
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
  if (tool === "Bash") return t("tool.bash");
  if (tool === "Write") return t("tool.write");
  if (tool === "Edit") return t("tool.edit");
  if (tool === "Read") return t("tool.read");
  if (tool === "WebFetch") return t("tool.webfetch", { domain: domainOf(input.url) ?? "" }).trim();
  if (tool.startsWith("mcp__")) {
    const leaf = tool.split("__").slice(2).join(" ");
    if (/browser_navigate|claude-in-chrome__navigate/.test(tool)) return t("tool.browserOpen", { domain: domainOf(input.url) ?? "" }).trim();
    if (/browser_click/.test(tool)) return t("tool.browserClick", { element: truncate(String(input.element ?? ""), 30) });
    if (/browser_type|fill_form|form_input/.test(tool)) return t("tool.browserType");
    if (/claude-in-chrome__computer/.test(tool)) return t("tool.chromeComputer");
    if (/javascript_tool|browser_evaluate/.test(tool)) return t("tool.chromeScript");
    if (/file_upload|upload_image/.test(tool)) return t("tool.upload");
    const tk = nameTokens(leaf);
    if (tk.includes("send") || tk.includes("reply") || tk.includes("forward")) return t("tool.send");
    if (tk.includes("delete") || tk.includes("trash") || tk.includes("remove")) return t("tool.delete");
    if (tk.includes("create") || tk.includes("add")) return t("tool.create");
    return t("tool.mcp");
  }
  return t("tool.other");
}

export function describeInput(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return truncate(String(input.command ?? ""), 4000);
  if (tool === "Write" || tool === "Edit" || tool === "Read") return String(input.file_path ?? "");
  if (input.url) return String(input.url);
  return truncate(JSON.stringify(input), 1000);
}

// Short label for one step in a task's activity list (shown in the app).
export function activityLabel(tool: string): string {
  if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") return t("label.write");
  if (tool === "Read") return t("label.read");
  if (tool === "Grep" || tool === "Glob") return t("label.find");
  if (tool === "Bash") return t("label.bash");
  if (tool === "WebSearch") return t("label.search");
  if (tool === "WebFetch") return t("label.fetch");
  if (tool === "Agent" || tool === "Task") return t("label.agent");
  if (/browser_|claude-in-chrome/.test(tool)) return t("label.browser");
  if (tool.startsWith("mcp__paloally__")) return t("label.paloally");
  if (tool.startsWith("mcp__")) return t("label.mcp");
  return t("label.other");
}

// ---- Allies (docs/allies-prd.md) ----

export const allyKindWord = (k: string) => t(k === "mine" ? "ally.kind.mine" : "ally.kind.family");
export const allyTrustWord = (x: string) => t(x === "converse" ? "ally.trust.converse" : "ally.trust.review");
// Who an Ally's words are from: their owner themselves, or their assistant.
export const allyFrom = (ownerName: string, author?: string) => (author === "owner" ? ownerName : t("ally.assistantOf", { name: ownerName }));
export const allyPushTitle = (ownerName: string, author?: string) => allyFrom(ownerName, author);
export const allyDraftedText = (ownerName: string, id: string) => t("ally.drafted", { name: ownerName, id });
export const allySentText = (ownerName: string, id: string) => t("ally.sent", { name: ownerName, id });
export const allyByeNotice = (ownerName: string) => t("ally.bye", { name: ownerName });
export const allyNotSeenText = (ownerName: string, hours: number, excerpt: string) => t("ally.notSeen", { name: ownerName, hours, excerpt });
export const allyUndeliveredText = (ownerName: string, excerpt: string) => t("ally.undelivered", { name: ownerName, excerpt });

// What the assistant hears when the host denies a tool in an Ally's turn.
export const allyToolDenied = (tool: string) => t("ally.toolDenied", { tool });

// The turn the assistant gets when an Ally's message arrives. The words go
// inside a fenced block named as an outside message, never as instructions;
// the fence carries a random tag and any <<< >>> inside the words is
// defused, so the message can't close the block early. `ownerSaid`: what the
// owner told this Ally themselves since its last message (the assistant
// didn't see those go out).
export function allyTurnHeader(
  ally: { id: string; ownerName: string; assistantName: string; trust?: string },
  ownerSaid: string[] = [],
): string {
  const n = ally.ownerName;
  const who = t("ally.turn.who", { name: n, assistant: ally.assistantName ? ` ${ally.assistantName}` : "" });
  const send = `mcp__paloally__ally_send(to="${ally.id}", replyTo=${t("ally.turn.replyToId")})`;
  const lines = [t("ally.turn.l1", { who }), t("ally.turn.l2"), t("ally.turn.l3")];
  // Who the reply is for differs by level: converse answers the Ally itself, review drafts for the owner.
  if (ally.trust === "converse") {
    lines.push(t("ally.turn.converse1", { name: n, send }), t("ally.turn.converse2"), t("ally.turn.converse3"), t("ally.turn.converse4"));
  } else {
    lines.push(t("ally.turn.review1", { name: n, send }), t("ally.turn.review2"), t("ally.turn.review3"), t("ally.turn.review4"));
  }
  if (ownerSaid.length) lines.push(t("ally.turn.ownerSaid", { name: n, said: ownerSaid.map(quoted).join(t("turn.listSep")) }));
  return lines.join("\n");
}

export function allyTurnMessage(
  e: { id: string; text: string; urgent: boolean; slots?: { start: string; end: string }[]; replyTo?: string; author?: string },
  tag: string,
  ownerName = t("ally.msg.defaultName"),
): string {
  const words = e.text.replace(/<<</g, "‹‹‹").replace(/>>>/g, "›››");
  const from = t(e.author === "owner" ? "ally.msg.fromOwner" : "ally.msg.fromAssistant", { name: ownerName });
  const head = t("ally.msg.head", {
    id: e.id,
    from,
    urgent: e.urgent ? t("ally.msg.urgent") : "",
    replyTo: e.replyTo ? t("ally.msg.replyTo", { id: e.replyTo }) : "",
  });
  const slots = e.slots?.length ? t("ally.msg.slots", { list: e.slots.map((x) => t("ally.msg.slot", x)).join("\n") }) : "";
  return `${head}\n${t("ally.msg.open", { tag })}\n${words}\n${t("ally.msg.close", { tag })}${slots}`;
}
