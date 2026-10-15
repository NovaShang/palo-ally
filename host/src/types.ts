// Wire models shared by every channel. Mirrors docs/design.md §5.3 — keep in sync.

export type Channel = "app" | "cli" | "wechat" | "probe" | "schedule" | "system";

export interface ChatMessage {
  seq: number;
  id: string;
  role: "user" | "assistant" | "system";
  kind: "text" | "task" | "approval" | "question" | "notice" | "clipboard" | "ally" | "helper" | "pal_adopt";
  text: string;
  channel: Channel;
  ts: number;
  proactive?: boolean;
  taskId?: string;
  approvalId?: string;
  questionId?: string; // kind "question": the choice card it shows
  clientMsgId?: string; // echoed for app-sent messages so clients can merge their optimistic copy
  attachments?: Attachment[]; // images the owner sent with the message
  label?: string; // kind "clipboard": what the copied text is ("地址", "验证码")
  replyTo?: ReplyTo; // the owner quoted part of an earlier message
  card?: MessageCard; // a schedule goal's output (e.g. 晨报): shown as a card titled by the goal
  // kind "ally": words to or from an Ally (docs/allies-prd.md §7.6, §11). "in"
  // is their message as it arrived (role "system"); "out" is the assistant's
  // (role "assistant": a draft card, or sent at once to a 能对话 Ally) or the
  // owner's own words (role "user", from ally.say). The entry (ally.entry /
  // ally.log) has the latest text and status.
  allyId?: string;
  allyName?: string; // the other owner's name; shown as 「<allyName>的助理」
  dir?: "in" | "out";
  entryId?: string;
  author?: AllyAuthor; // kind "ally": who wrote it (§11.2)
  // kind "helper": the assistant proposes a Pal (docs/pals-prd.md §6, the
  // card of docs/sessions-prd.md §6.6); the owner answers with helper.decide.
  // kind "pal_adopt": the assistant proposes taking over a conversation that
  // ended on the computer (docs/pals-prd.md §10); the same helper.decide.
  // The message is sent again (same id and seq) when the proposal's status changes.
  proposal?: HelperProposal | PalAdoptProposal;
  // A Pal's conversation (docs/pals-prd.md §8): the Pal's id. Absent = the
  // assistant's own. A Pal's messages aren't kept in the assistant's
  // conversation: `seq` is their time in ms, and pals.history reads them back.
  pal?: string;
  // In a Pal's conversation, who said a user line that isn't the owner's:
  // the assistant's name for its words, or another session's name.
  from?: string;
}

export interface ReplyTo {
  messageId: string;
  excerpt: string; // ≤ 300 chars of the quoted text
}

export interface MessageCard {
  title: string;
  goalId?: string;
}

// Something sent along with a message. "image"/"file" live in the media
// store (owner uploads, and assistant sends marked temporary); "artifact"
// points into the library, where it can be found again.
export interface Attachment {
  id: string;
  kind: "image" | "file" | "artifact";
  mediaType: string;
  name?: string;
  size?: number;
  display?: "render" | "attach"; // SendUserFile's hint: show it, or just a file card
}

export type TaskStatus = "running" | "done" | "failed" | "needs_input" | "stopped";

export interface Task {
  id: string;
  title: string;
  summary: string;
  status: TaskStatus;
  source: "auto" | "report";
  createdAt: number;
  updatedAt: number;
  activityCount: number;
  // internal linkage (not needed by clients but harmless)
  toolUseId?: string;
  sdkTaskId?: string;
  peer?: string; // handed to another Claude Code session (its name); the host follows it
}

export interface TaskActivity {
  ts: number;
  kind: "tool_use" | "tool_result" | "text";
  tool?: string;
  label?: string; // plain words for the step ("跑命令"), from copy.ts
  text: string;
}

export type ApprovalStatus = "pending" | "allowed" | "denied" | "expired";

// A card one of the computer's Claude Code sessions asked for, not the
// assistant itself: "session", one the host doesn't run, through PaloAlly's
// hooks while the owner is away (docs/sessions-prd.md §7); "pal", a Pal
// (docs/pals-prd.md §7.4), always.
export interface CardSource {
  kind: "session" | "pal";
  id: string; // the session's id (CCSession.id), or the Pal's (Pal.id)
  name: string;
}

export interface Approval {
  id: string;
  tool: string;
  title: string;
  detail: string;
  taskId?: string;
  careful: boolean; // the harness marked this prompt as needing care (defaultToNo)
  status: ApprovalStatus;
  createdAt: number;
  decidedAt?: number;
  decidedBy?: string;
  suggestedScope?: string;
  reason?: string; // the harness' own words for why it asked
  source?: CardSource; // asked by a session on the computer
  // A short line on how it ended when that isn't the owner's answer:
  // 「在电脑上等你」 (the session asks in its terminal now), 「已在电脑上处理」.
  note?: string;
}

// The harness asking the owner to choose (Claude Code's AskUserQuestion).
// Not a permission: the answers go back to the model as the tool's input.
export interface QuestionOption {
  label: string;
  description?: string;
}

export interface QuestionItem {
  question: string;
  header?: string;
  options: QuestionOption[];
  multiSelect: boolean;
}

export type QuestionStatus = "pending" | "answered" | "expired";

export interface Question {
  id: string;
  items: QuestionItem[];
  taskId?: string;
  status: QuestionStatus;
  createdAt: number;
  // question text → the chosen label(s) (multi-select: "A, B") or the owner's own words
  answers?: Record<string, string>;
  answeredAt?: number;
  answeredBy?: string;
  source?: CardSource; // asked by a session on the computer
  note?: string; // see Approval.note
}

export interface Watch {
  id: string;
  title: string;
  kind: "check" | "schedule";
  instruction: string;
  intervalMinutes?: number;
  at?: string[];
  // schedule with `at`: only on this day of the month (1–31, -1 = the last
  // day); 29–31 fall on a shorter month's last day
  dayOfMonth?: number;
  enabled: boolean;
  createdBy: "agent" | "user";
  createdAt?: number;
  lastCheckedAt?: number;
  lastTriggeredAt?: number;
  skipIfActiveMinutes?: number;
  // dedupe cursor: opaque state the probe hands back each check
  cursor?: string;
  // keys of recent triggers, to suppress repeats
  recentKeys?: string[];
  // schedule bookkeeping: "YYYY-MM-DD HH:MM" slots already fired
  firedSlots?: string[];
  // check watches: how the last probe attempt went (also set when the probe
  // was skipped, e.g. the day's budget is used up), so nothing fails silently
  lastResult?: { at: number; ok: boolean; reason?: string };
  // What the owner sees: a watch is shown as a 「目标」 with a live progress
  // line and a state. The mechanism above stays as it is.
  state?: GoalState; // defaults: tracking (enabled) / paused (disabled)
  progress?: string; // one short latest-status line, in Chinese
  progressAt?: number;
  ratio?: number; // 0…1, only when the assistant can actually measure it
  outcome?: string; // a short line once done
  history?: GoalProgress[]; // the last few progress lines, newest last
}

export type GoalState = "tracking" | "waiting" | "done" | "paused";

export interface GoalProgress {
  at: number;
  text: string;
}

export interface Artifact {
  id: string;
  title: string;
  type: string;
  mainFile: string;
  pinned: boolean;
  updatedAt: number;
  files: { path: string; size: number }[];
}

export interface Status {
  online: boolean;
  busy: boolean;
  activity?: string; // what it is doing right now, in plain words (only while busy)
  model: string; // the model actually running (reported by the harness)
  effort?: string; // chosen effort level; absent = the model's default
  sessionId?: string;
  wechat: "off" | "connected" | "expired";
  version: string;
  metAt?: number; // when the owner first talked to it (first chat message), for 「认识你 N 天」
}

// ---- Allies (docs/allies-prd.md §6–7) ----

export type AllyKind = "family" | "mine"; // 家人朋友 / 我的

export type AllyStatus = "draft" | "queued" | "sent" | "delivered" | "seen" | "rejected";

// How the owner's assistant answers an Ally (§11.1): "converse" (能对话) it
// replies on its own, every word kept; "review" (每句要你看) every reply is a
// draft card the owner sends.
export type AllyTrust = "converse" | "review";

// Who wrote an exchange (§11.2): that side's owner in their own words, or
// their assistant.
export type AllyAuthor = "owner" | "assistant";

export interface AllySlot {
  start: string; // ISO 8601 with a time zone
  end: string;
}

// One message to or from an Ally. Outgoing: draft → queued → sent →
// delivered → seen, or "rejected" (final; `note` says why in a few words).
// Incoming: delivered → seen. An incoming entry keeps the sender's id.
export interface AllyEntry {
  id: string;
  allyId: string;
  dir: "in" | "out";
  ts: number;
  text: string;
  urgent: boolean;
  slots?: AllySlot[];
  replyTo?: string; // the entry this answers
  status: AllyStatus;
  note?: string;
  // Who wrote it. Out: the owner (ally.say) or the assistant for them. In:
  // the other owner or their assistant (absent from a pre-§11 host: "assistant").
  author: AllyAuthor;
}

export interface AllyInfo {
  id: string;
  kind: AllyKind;
  ownerName: string;
  assistantName: string;
  online: boolean;
  lastSeen: number; // 0 = never reached
  lastEntry?: AllyEntry;
  trust: AllyTrust; // how our assistant answers them
  theirTrust?: AllyTrust; // how theirs answers us, when their host says
}

// ---- Sessions: the computer's Claude Code sessions (docs/sessions-prd.md §7) ----

export type CCSessionKind = "helper" | "terminal" | "background";
export type CCSessionStatus = "busy" | "idle" | "waiting" | "stopped";

export interface CCSession {
  id: string; // Claude Code's session id
  name: string;
  cwd: string;
  kind: CCSessionKind; // "helper" isn't used any more (Pals replaced helpers)
  status: CCSessionStatus;
  waitingFor?: string;
  lastLine?: string;
  contextTokens?: number;
  updatedAt: number;
  // pals.adopt is waiting for it to quit in its terminal (/exit), then it becomes a Pal
  adopting?: boolean;
}

// ---- Pals (docs/pals-prd.md §8) ----

// "asleep" (§12): idle a while, its process ended; the record stays and the
// next word for it (or pals.wake) resumes it.
export type PalStatus = "busy" | "idle" | "waiting" | "starting" | "stopped" | "asleep";

// A Claude Code session the host runs itself, by resuming its transcript.
export interface Pal {
  id: string;
  name: string; // fixed: the list's, and the name the assistant SendMessages it by
  cwd: string;
  sessionId: string; // Claude Code's (claude --resume <sessionId>)
  status: PalStatus;
  activity?: string; // busy: what it's doing, in plain words
  note?: string; // stopped: why (spending limit, couldn't start, open somewhere else)
  lastLine?: string;
  pending: number; // its cards waiting on the owner
  model?: string;
  lastWakeUsd?: number; // what the first turn after its last wake cost (USD)
  createdBy: "owner" | "palo";
  updatedAt: number;
}

// One line of a session's conversation. "palo": it came through PaloAlly —
// `from` is 「主人」 for the owner's words from the app, or the assistant's
// name for its own. "peer": another session; `from` is its name.
export interface CCMessage {
  id: string;
  ts: number;
  role: "owner" | "assistant" | "peer" | "palo";
  text: string;
  from?: string;
}

export type HelperProposalStatus = "pending" | "created" | "discarded" | "expired";

export interface HelperProposal {
  id: string; // helper.decide's proposalId
  name: string;
  cwd: string;
  duty: string; // what it's for; becomes the Pal's first message
  dailyUsd: number;
  status: HelperProposalStatus;
  sessionId?: string; // once created
  palId?: string; // once created: the Pal it became
  note?: string; // why it didn't start, when it didn't
}

// ---- 接管最近的对话 (docs/pals-prd.md §10) ----

// A Claude Code conversation on the computer that ended lately (pals.recent).
export interface RecentSession {
  sessionId: string;
  cwd: string;
  title: string; // its custom title, else Claude Code's summary, else its first words
  lastModified: number; // ms: when its transcript last changed
  size: number; // its transcript's bytes
}

export type PalAdoptStatus = "pending" | "adopted" | "discarded" | "failed";

// The assistant's card proposing to take one over (pal_adopt); the owner
// answers with helper.decide.
export interface PalAdoptProposal {
  id: string; // helper.decide's proposalId
  sessionId: string;
  cwd: string;
  title: string;
  status: PalAdoptStatus;
  palId?: string; // adopted: the Pal it became
  note?: string; // failed: why
}

export interface MemoryFile {
  path: string;
  scope: "core" | "auto";
  size: number;
  updatedAt: number;
}

export interface AuditEntry {
  ts: number;
  type: string;
  [k: string]: unknown;
}
