import type { Bus } from "./bus.ts";
import type { ChatMessage } from "./types.ts";
import { appendJsonl, newId, readJsonl } from "./util.ts";

// ChatLog is the main conversation's History (PRD §2.1): the full archive the
// client shows, independent of what the model's context currently holds.
// Every message gets a monotonically increasing seq so reconnecting clients
// can ask for exactly what they missed.
export class ChatLog {
  private messages: ChatMessage[];
  private seq: number;

  constructor(private path: string, private bus: Bus) {
    this.messages = readJsonl<ChatMessage>(path);
    this.seq = this.messages.reduce((m, x) => Math.max(m, x.seq), 0);
  }

  get lastSeq(): number {
    return this.seq;
  }

  add(msg: Omit<ChatMessage, "seq" | "id" | "ts"> & { id?: string; ts?: number }): ChatMessage {
    const full: ChatMessage = {
      ...msg,
      id: msg.id ?? newId("m_"),
      ts: msg.ts ?? Date.now(),
      seq: ++this.seq,
    };
    this.messages.push(full);
    appendJsonl(this.path, full);
    this.bus.emit("chat.message", full);
    return full;
  }

  // delta streams partial assistant text; the final add() with the same id
  // closes it.
  delta(id: string, text: string): void {
    this.bus.emit("chat.delta", { id, text });
  }

  since(seq: number, limit = 500): ChatMessage[] {
    return this.messages.filter((m) => m.seq > seq).slice(0, limit);
  }

  recent(limit: number): ChatMessage[] {
    return this.messages.slice(-limit);
  }

  before(seq: number, limit: number): ChatMessage[] {
    const older = this.messages.filter((m) => m.seq < seq);
    return older.slice(-limit);
  }

  findByClientMsgId(cid: string): ChatMessage | undefined {
    for (let i = this.messages.length - 1, n = 0; i >= 0 && n < 1000; i--, n++) {
      if (this.messages[i]!.clientMsgId === cid) return this.messages[i];
    }
    return undefined;
  }

  lastUserActivity(): number {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const m = this.messages[i]!;
      if (m.role === "user" && (m.channel === "app" || m.channel === "cli" || m.channel === "wechat")) return m.ts;
    }
    return 0;
  }
}
