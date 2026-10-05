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

  /** When the conversation started (the first message), if it has. */
  get startedAt(): number | undefined {
    return this.messages[0]?.ts;
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

  /**
   * Case-insensitive substring search, newest first (the 成果 search box).
   * Each hit carries a snippet of about ±40 characters around the first match.
   */
  search(query: string, limit = 50, beforeSeq = Infinity): ChatSearchHit[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const hits: ChatSearchHit[] = [];
    for (let i = this.messages.length - 1; i >= 0 && hits.length < limit; i--) {
      const m = this.messages[i]!;
      if (m.seq >= beforeSeq) continue;
      const text = m.label ? `${m.label} ${m.text}` : m.text;
      const at = text.toLowerCase().indexOf(q);
      if (at < 0) continue;
      hits.push({ seq: m.seq, id: m.id, role: m.role, ts: m.ts, channel: m.channel, snippet: snippetAround(text, at, q.length) });
    }
    return hits;
  }

  /** A window of messages around `seq` (for jumping to a search hit). */
  around(seq: number, before = 25, after = 25): ChatMessage[] {
    let i = this.messages.findIndex((m) => m.seq >= seq);
    if (i < 0) i = this.messages.length;
    return this.messages.slice(Math.max(0, i - before), i + after + 1);
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

export interface ChatSearchHit {
  seq: number;
  id: string;
  role: ChatMessage["role"];
  ts: number;
  channel: ChatMessage["channel"];
  snippet: string;
}

// ±40 characters around the match, on one line, with … where it was cut.
function snippetAround(text: string, at: number, len: number): string {
  const start = Math.max(0, at - 40);
  const end = Math.min(text.length, at + len + 40);
  const body = text.slice(start, end).replace(/\s+/g, " ").trim();
  return `${start > 0 ? "…" : ""}${body}${end < text.length ? "…" : ""}`;
}
