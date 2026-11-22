// Where a session's words go as the harness streams them (docs/harness-adapter-design.md
// §1.1 row 8). The assistant's go into its chat log (chat.jsonl, seq numbers,
// what chat.history reads back); an agent's go out as events carrying its id,
// its history being its harness' transcript. Both runtimes write through one.
import type { ChatLog } from "../chat.ts";
import type { ChatMessage } from "../types.ts";

/** A message as a runtime writes it: the sink gives it its place (seq, time, whose). */
export type SinkMessage = Omit<ChatMessage, "seq" | "ts" | "id" | "channel" | "pal"> & { id?: string; channel?: ChatMessage["channel"] };

export interface OutputSink {
  /** More text of the reply being streamed under `id`. */
  delta(id: string, text: string): void;
  /** A whole message (a reply, a notice, a card). */
  message(m: SinkMessage): ChatMessage;
}

/** The assistant's: its chat log. */
export class ChatLogSink implements OutputSink {
  constructor(private chat: ChatLog) {}

  delta(id: string, text: string): void {
    this.chat.delta(id, text);
  }

  message(m: SinkMessage): ChatMessage {
    return this.chat.add({ ...m, channel: m.channel ?? "app" });
  }
}

/** An agent's: events carrying its id (its history is the harness' transcript). */
export class TranscriptSink implements OutputSink {
  constructor(
    private pal: string,
    private d: { emit: (event: "chat.message" | "chat.delta", data: unknown) => void; now: () => number },
  ) {}

  delta(id: string, text: string): void {
    this.d.emit("chat.delta", { id, text, pal: this.pal });
  }

  message(m: SinkMessage): ChatMessage {
    const ts = this.d.now();
    const msg = { seq: ts, ts, channel: "app", ...m, pal: this.pal } as ChatMessage;
    this.d.emit("chat.message", msg);
    return msg;
  }

  /** A message already made whole (the owner's words as sent, a delivery card, a line read from the transcript). */
  put(msg: ChatMessage): void {
    this.d.emit("chat.message", msg);
  }
}
