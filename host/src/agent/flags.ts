// What makes the assistant the assistant and an agent an agent: one
// AgentSession, these flags (docs/harness-adapter-design.md §1.2). Flags that
// only the assistant has today (its host-initiated turns, WeChat, an Ally's
// gated turn, idle compaction) choose pieces that plug in (turnQueue.ts,
// wechatRelay.ts, allyTurn.ts, idleCompact.ts), not branches through the class.
import type { ProcessFlags } from "./processHost.ts";

export interface AgentFlags extends ProcessFlags {
  /** Where its conversation is kept and read: the assistant's chat.jsonl (kept as is), or the harness' transcript. */
  history: "chatLog" | "transcript";
  /** Lines that reach the transcript without passing through the host (another session's SendMessage) are shown. */
  followTranscript: boolean;
  /** Host-initiated turns: a queue that waits for idle, [skip], proactive pushes, the daily budget, goal results. */
  proactiveTurns: boolean;
  /** WeChat turns: typing, paragraph by paragraph replies, questions as numbered text. */
  wechat: boolean;
  /** 只说话不动手 during an Ally's turn. */
  allyGate: boolean;
  /** AskUserQuestion: to 等你的事 at once ("defer"), or a blocking card ("block"). */
  questions: "defer" | "block";
  /** The host compacts at a clean break before the prompt cache expires (config.session). */
  autoCompact: boolean;
  /** Its files can go back to how they were before any of the owner's messages. */
  fileCheckpoints: boolean;
  /** Its subagents and background tasks: the host's task list, or its own record. */
  tasks: "tracker" | "record";
}

export const ASSISTANT_FLAGS: AgentFlags = {
  history: "chatLog",
  followTranscript: false,
  proactiveTurns: true,
  wechat: true,
  allyGate: true,
  questions: "defer",
  autoCompact: true,
  canSleep: false,
  restart: "on-demand",
  startMode: "lazy-sync",
  exclusive: false,
  fileCheckpoints: false,
  tasks: "tracker",
};

export const AGENT_FLAGS: AgentFlags = {
  history: "transcript",
  followTranscript: true,
  proactiveTurns: false,
  wechat: false,
  allyGate: false,
  questions: "block",
  autoCompact: false,
  canSleep: true,
  restart: "backoff",
  startMode: "awaited",
  exclusive: true,
  fileCheckpoints: true,
  tasks: "record",
};
