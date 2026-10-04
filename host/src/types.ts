// Wire models shared by every channel. Mirrors docs/design.md §5.3 — keep in sync.

export type Channel = "app" | "cli" | "wechat" | "probe" | "schedule" | "system";

export interface ChatMessage {
  seq: number;
  id: string;
  role: "user" | "assistant" | "system";
  kind: "text" | "task" | "approval" | "notice";
  text: string;
  channel: Channel;
  ts: number;
  proactive?: boolean;
  taskId?: string;
  approvalId?: string;
  clientMsgId?: string; // echoed for app-sent messages so clients can merge their optimistic copy
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
}

export interface TaskActivity {
  ts: number;
  kind: "tool_use" | "tool_result" | "text";
  tool?: string;
  text: string;
}

export type ApprovalStatus = "pending" | "allowed" | "denied" | "expired";

export interface Approval {
  id: string;
  tool: string;
  title: string;
  detail: string;
  taskId?: string;
  irreversible: boolean;
  status: ApprovalStatus;
  createdAt: number;
  decidedAt?: number;
  decidedBy?: string;
  suggestedScope?: string;
}

export interface Watch {
  id: string;
  title: string;
  kind: "check" | "schedule";
  instruction: string;
  intervalMinutes?: number;
  at?: string[];
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
  killed: boolean;
  busy: boolean;
  model: string;
  sessionId?: string;
  wechat: "off" | "connected" | "expired";
  version: string;
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
