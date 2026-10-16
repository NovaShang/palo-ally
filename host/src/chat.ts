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
    // A message written again (update) replaces the earlier copy in place.
    const byId = new Map<string, number>();
    const all: ChatMessage[] = [];
    for (const m of readJsonl<ChatMessage>(path)) {
      const i = byId.get(m.id);
      if (i === undefined) {
        byId.set(m.id, all.length);
        all.push(m);
      } else all[i] = m;
    }
    this.messages = all;
    // A rewind takes a seq of its own (rewoundSeq), with no message under it.
    this.seq = this.messages.reduce((m, x) => Math.max(m, x.seq, x.rewoundSeq ?? 0), 0);
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

  // update changes a message the owner acts on (a helper proposal's status):
  // the same id and seq, sent again as chat.message for clients to replace.
  update(id: string, patch: Partial<Omit<ChatMessage, "id" | "seq" | "ts">>): ChatMessage | undefined {
    const i = this.messages.findIndex((m) => m.id === id);
    if (i < 0) return undefined;
    const next = { ...this.messages[i]!, ...patch } as ChatMessage;
    this.messages[i] = next;
    appendJsonl(this.path, next);
    this.bus.emit("chat.message", next);
    return next;
  }

  /**
   * The uuids the harness has these messages under now (a session copied
   * with new uuids): kept, not sent again (nothing a client shows changes).
   */
  setUuids(byId: Map<string, string>): void {
    for (let i = 0; i < this.messages.length; i++) {
      const m = this.messages[i]!;
      const uuid = byId.get(m.id);
      if (!uuid || uuid === m.uuid) continue;
      this.messages[i] = { ...m, uuid };
      appendJsonl(this.path, this.messages[i]);
    }
  }

  get(id: string): ChatMessage | undefined {
    for (let i = this.messages.length - 1; i >= 0; i--) if (this.messages[i]!.id === id) return this.messages[i];
    return undefined;
  }

  // delta streams partial assistant text; the final add() with the same id
  // closes it.
  delta(id: string, text: string): void {
    this.bus.emit("chat.delta", { id, text });
  }

  // What clients see: everything but what was gone back before (回到这里重来).
  private get shown(): ChatMessage[] {
    return this.messages.filter((m) => !m.rewound);
  }

  since(seq: number, limit = 500): ChatMessage[] {
    return this.messages.filter((m) => m.seq > seq && !m.rewound).slice(0, limit);
  }

  recent(limit: number): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (let i = this.messages.length - 1; i >= 0 && out.length < limit; i--) if (!this.messages[i]!.rewound) out.push(this.messages[i]!);
    return out.reverse();
  }

  before(seq: number, limit: number): ChatMessage[] {
    const older = this.messages.filter((m) => m.seq < seq && !m.rewound);
    return older.slice(-limit);
  }

  /**
   * 回到这里重来 (docs/rewind-prd.md §4.3): the message at `fromSeq` and
   * everything after it are marked rewound, kept in the log for the record
   * and no longer shown. The rewind takes a seq of its own, so a client that
   * missed it learns from `rewoundSince` on its next sync. Returns their ids.
   */
  rewind(fromSeq: number): string[] {
    const at = ++this.seq;
    const ids: string[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      const m = this.messages[i]!;
      if (m.seq < fromSeq || m.rewound) continue;
      const next = { ...m, rewound: true, rewoundSeq: at };
      this.messages[i] = next;
      appendJsonl(this.path, next);
      ids.push(m.id);
    }
    return ids;
  }

  /** The ids rewound after `seq` (a client syncing from there still has them). */
  rewoundSince(seq: number, limit = 1000): string[] {
    return this.messages.filter((m) => m.rewound && (m.rewoundSeq ?? 0) > seq).slice(-limit).map((m) => m.id);
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
      if (m.seq >= beforeSeq || m.rewound) continue;
      const text = m.label ? `${m.label} ${m.text}` : m.text;
      const at = text.toLowerCase().indexOf(q);
      if (at < 0) continue;
      hits.push({ seq: m.seq, id: m.id, role: m.role, ts: m.ts, channel: m.channel, snippet: snippetAround(text, at, q.length) });
    }
    return hits;
  }

  /** A window of messages around `seq` (for jumping to a search hit). */
  around(seq: number, before = 25, after = 25): ChatMessage[] {
    const shown = this.shown;
    let i = shown.findIndex((m) => m.seq >= seq);
    if (i < 0) i = shown.length;
    return shown.slice(Math.max(0, i - before), i + after + 1);
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
