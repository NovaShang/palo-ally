// Wire models shared by every channel. Mirrors docs/design.md §5.3 — keep in sync.

export type Channel = "app" | "cli" | "wechat" | "probe" | "schedule" | "system";

export interface ChatMessage {
  seq: number;
  id: string;
  role: "user" | "assistant" | "system";
  kind: "text" | "task" | "approval" | "question" | "notice" | "clipboard";
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
