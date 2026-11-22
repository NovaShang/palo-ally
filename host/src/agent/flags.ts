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

  // Its turns (agent/session.ts), one model:
  /**
   * Who opens a turn. "host": the host, when it sends words with none open
   * (the owner's, or a host-initiated turn from its queue) and when the
   * harness names the owner messages it's answering; output with none open
   * opens one (the owner's if any of theirs are unanswered, else one the
   * harness started on its own); every result ends it. "harness": the
   * harness, at its init or first output; a result ends it once no words
   * are left unanswered (busy until then).
   */
  turns: "host" | "harness";
  /** A reply's id: made by the host, or the API message's (as in its transcript). */
  replyIds: "host" | "api";
  /** A reply's text blocks: each a message of its own, or those of one API message joined into one, a blank line between. */
  textBlocks: "split" | "joined";
  /** A turn the harness started on its own is closed when it goes quiet without a result. */
  implicitQuiet: boolean;
  /** A subagent's output is the session's: it opens a turn, shows as background work, and its open tool calls end with the turn. */
  subagentTurns: boolean;
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
  turns: "host",
  replyIds: "host",
  textBlocks: "split",
  implicitQuiet: true,
  subagentTurns: true,
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
  turns: "harness",
  replyIds: "api",
  textBlocks: "joined",
  implicitQuiet: false,
  subagentTurns: false,
};
