import { closeSync, existsSync, fstatSync, openSync, readSync, watch, type FSWatcher } from "node:fs";
import { type RawSessionMessage, firstLine, peerBody } from "./ccSessions.ts";
import type { Attachment, ChatMessage } from "./types.ts";

// A Pal's conversation as the app shows it (docs/pals-prd.md §4, §8): the
// same ChatMessage shape as the assistant's own, read from the session's
// transcript (what Claude Code keeps), so it's the whole conversation from
// before PaloAlly hosted it too. Ids are the transcript's own: a message's
// uuid for what went in, the API message id for a reply, which is also what
// the live stream uses (chat.delta / chat.message), so the two never
// disagree. `seq` is the time in ms: Pal messages don't take numbers from
// the assistant's conversation.

export interface PalMapOptions {
  pal: string; // the Pal's id
  assistantName: string; // how the assistant (Palo) is called; its words show as 「<name>」
  paloName: string; // the session name the assistant sends from (its SendMessage name)
  duty?: string; // a Pal the assistant opened: its first message is the assistant's handover
  // What the owner sent with images or files, by its uuid (MediaStore.recall):
  // the transcript has only the image bytes and the files' paths.
  recall?: (uuid: string) => { text: string; attachments: Attachment[] } | undefined;
}

function hasImage(content: unknown): boolean {
  return Array.isArray(content) && content.some((b: any) => b?.type === "image");
}

function userText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  if (content.some((b: any) => b?.type === "tool_result")) return null;
  const t = content
    .filter((b: any) => b?.type === "text" && typeof b.text === "string")
    .map((b: any) => b.text)
    .join("\n");
  return t || null;
}

/** Who sent a peer message, by name: the assistant's own session shows as the assistant. */
export function peerName(origin: any, content: string, o: PalMapOptions): string {
  const name = typeof origin?.name === "string" && origin.name ? origin.name : /from-name="([^"]*)"/.exec(content)?.[1] ?? "";
  return name === o.paloName ? o.assistantName : name || "另一个会话";
}

/** One user entry as the app shows it, or null (tool results, Claude Code's own notices). */
export function userEntryMessage(m: RawSessionMessage, o: PalMapOptions): ChatMessage | null {
  // (Claude Code's own lines it marks meta, as the transcript has them, aren't anyone's words.)
  if (m.type !== "user" || m.parent_tool_use_id || (m as any).isMeta) return null;
  const content = m.message?.content;
  // An image sent on its own has no words.
  const text = userText(content) ?? (hasImage(content) ? "" : null);
  if (text === null) return null;
  const ts = Date.parse(m.timestamp ?? "") || 0;
  const base = { seq: ts, id: m.uuid, role: "user" as const, kind: "text" as const, ts, pal: o.pal };
  // Claude Code compacted the conversation: its summary isn't anyone's words.
  if ((m as any).isCompactSummary) return { ...base, role: "system", kind: "notice", text: "前面的对话压缩过了", channel: "system" };
  const origin = m.origin;
  if (origin?.kind === "peer") return { ...base, text: peerBody(origin, text), channel: "system", from: peerName(origin, text, o) };
  // Only what the owner typed (or the host typed for them); Claude Code's own
  // notices, reminders and task notifications aren't.
  if (origin && origin.kind !== "human") return null;
  const cmd = /^<command-name>(.*?)<\/command-name>/s.exec(text.trim());
  if (cmd) {
    const args = /<command-args>([\s\S]*?)<\/command-args>/.exec(text)?.[1]?.trim();
    return { ...base, text: `${cmd[1]!.trim()}${args ? ` ${args}` : ""}`, channel: "app" };
  }
  const t = text.trim();
  // The assistant's pal_send: put in by the host the way a SendMessage reads.
  if (/^<cross-session-message[^>]*from-name="/.test(t)) return { ...base, text: peerBody(null, t), channel: "system", from: peerName(null, t, o) };
  // Sent from the app with images or files: as it was sent.
  const sent = o.recall?.(m.uuid);
  if (sent) return { ...base, text: sent.text, channel: "app", ...(sent.attachments.length ? { attachments: sent.attachments } : {}) };
  if (!t && hasImage(content)) return { ...base, text: "（图片）", channel: "app" };
  if (!t || /^(<local-command-|<system-reminder>|<command-message>|Caveat: |<cross-session-message)/.test(t)) return null;
  return { ...base, text: t, channel: "app" };
}

/** The whole conversation, oldest first. A reply written as several entries (one per block) is one message. */
export function toPalMessages(raw: RawSessionMessage[], o: PalMapOptions): ChatMessage[] {
  const out: ChatMessage[] = [];
  const replies = new Map<string, ChatMessage>();
  let first = true;
  for (const m of raw) {
    if (m.parent_tool_use_id) continue; // a subagent's
    if (m.type === "assistant") {
      const msg = m.message;
      const content = msg?.content;
      if (!Array.isArray(content) || msg?.model === "<synthetic>") continue;
      const text = content
        .filter((b: any) => b?.type === "text" && typeof b.text === "string")
        .map((b: any) => b.text)
        .join("\n\n")
        .trim();
      if (!text) continue;
      const id = typeof msg?.id === "string" && msg.id ? msg.id : m.uuid;
      const have = replies.get(id);
      if (have) {
        have.text = `${have.text}\n\n${text}`;
        continue;
      }
      const ts = Date.parse(m.timestamp ?? "") || 0;
      const reply: ChatMessage = { seq: ts, id, role: "assistant", kind: "text", text, channel: "app", ts, pal: o.pal };
      replies.set(id, reply);
      out.push(reply);
      continue;
    }
    const u = userEntryMessage(m, o);
    if (!u) continue;
    // The assistant's handover, typed in for a Pal it opened, is the assistant's.
    if (first && o.duty && !u.from && u.text === o.duty.trim()) Object.assign(u, { from: o.assistantName, channel: "system" });
    first = false;
    out.push(u);
  }
  return out;
}

/** A page: the `limit` before message `before` (its id, or a time in ms), or the newest; oldest first. */
export function pagePalMessages(all: ChatMessage[], before: string | number | undefined, limit: number): ChatMessage[] {
  let end = all.length;
  if (typeof before === "string" && before) {
    const i = all.findIndex((m) => m.id === before);
    if (i >= 0) end = i;
  } else if (typeof before === "number" && Number.isFinite(before)) {
    end = all.findIndex((m) => m.ts >= before);
    if (end < 0) end = all.length;
  }
  return all.slice(Math.max(0, end - limit), end);
}

/**
 * The model a session last ran on, from its transcript entries (null: none
 * recorded). Replies record the API's model id; the model Claude Code chose
 * (with its context size, like claude-opus-5-5[1m]) is in its own model
 * entries, and wins when it's the same model.
 */
export function transcriptModel(entries: any[]): string | null {
  let replied: string | null = null;
  let chosen: string | null = null;
  for (let i = entries.length - 1; i >= 0 && (!replied || !chosen); i--) {
    const e = entries[i];
    if (!replied && e?.type === "assistant" && !e.isSidechain) {
      const model = e.message?.model;
      if (typeof model === "string" && model && model !== "<synthetic>") replied = model;
    }
    if (!chosen && e?.type === "attachment" && e.attachment?.type === "model" && typeof e.attachment.identity?.modelId === "string") chosen = e.attachment.identity.modelId;
  }
  if (chosen && (!replied || chosen.replace(/\[.*\]$/, "") === replied)) return chosen;
  return replied ?? chosen;
}

/** The last thing said in it (a reply's first line), from transcript entries. */
export function transcriptLastLine(entries: any[]): string | undefined {
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e?.type !== "assistant" || e.isSidechain || e.message?.model === "<synthetic>") continue;
    const blocks = Array.isArray(e.message?.content) ? e.message.content : [];
    for (let j = blocks.length - 1; j >= 0; j--) {
      const b = blocks[j];
      if (b?.type === "text" && typeof b.text === "string" && b.text.trim()) return firstLine(b.text);
    }
  }
  return undefined;
}

// TranscriptFollower reads what Claude Code appends to a transcript from the
// moment it starts following, and hands over each new entry. Words that reach
// a Pal from another session (SendMessage) only show up there, never in the
// SDK's stream.
export class TranscriptFollower {
  private offset = 0;
  private partial = "";
  private watcher: FSWatcher | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private debounce: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private path: string,
    private onEntry: (e: any) => void,
    private pollMs = 2_000,
  ) {}

  /** Starts at the file's current end (what's there already is history). */
  start(): void {
    this.offset = this.size();
    this.partial = "";
    this.watchFile();
    this.timer = setInterval(() => this.poke(), this.pollMs);
    (this.timer as any).unref?.();
  }

  private watchFile(): void {
    if (this.watcher || !existsSync(this.path)) return;
    try {
      this.watcher = watch(this.path, () => {
        if (this.debounce) clearTimeout(this.debounce);
        this.debounce = setTimeout(() => this.poke(), 100);
      });
    } catch {
      this.watcher = null; // the poll covers it
    }
  }

  stop(): void {
    this.watcher?.close();
    this.watcher = null;
    if (this.timer) clearInterval(this.timer);
    if (this.debounce) clearTimeout(this.debounce);
    this.timer = null;
    this.debounce = null;
  }

  private size(): number {
    try {
      const fd = openSync(this.path, "r");
      try {
        return fstatSync(fd).size;
      } finally {
        closeSync(fd);
      }
    } catch {
      return 0;
    }
  }

  /** Reads what was appended since the last look. */
  poke(): void {
    if (!this.watcher) this.watchFile(); // a new session's file appears with its first message
    let fd: number;
    try {
      fd = openSync(this.path, "r");
    } catch {
      return;
    }
    let chunk = "";
    try {
      const size = fstatSync(fd).size;
      if (size < this.offset) {
        this.offset = 0; // rewritten
        this.partial = "";
      }
      if (size === this.offset) return;
      const buf = Buffer.alloc(size - this.offset);
      readSync(fd, buf, 0, buf.length, this.offset);
      this.offset = size;
      chunk = buf.toString("utf8");
    } finally {
      closeSync(fd);
    }
    const lines = (this.partial + chunk).split("\n");
    this.partial = lines.pop() ?? "";
    for (const l of lines) {
      if (!l.trim()) continue;
      let e: any;
      try {
        e = JSON.parse(l);
      } catch {
        continue;
      }
      this.onEntry(e);
    }
  }
}
