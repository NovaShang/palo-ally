import { isAuthFailure } from "./auth.ts";
import type { HarnessDriver } from "./harness/types.ts";
import { t } from "./i18n/index.ts";
import type { ChatMessage } from "./types.ts";
import { truncate } from "./util.ts";

// 「TL;DR」 (chat.tldr): the recent stretch of a conversation, the
// assistant's or a session's, in a few points, with the owner's own words
// apart from what assistants said or passed on: words get relayed from one
// assistant to another, and the owner wants to see which ones are really
// hers. One cheap probe-model call, no tools. Nothing is posted into the
// conversation and nothing is stored: the last answer per conversation is
// kept in memory, good while that conversation's last message is the same.

export type TldrScope = "palo" | "pal";

/** One of the owner's own sentences, verbatim, and the message it is in. */
export interface TldrQuote {
  text: string;
  messageId: string;
  ts: number;
}

/** What an assistant, a session or someone's assistant said or passed on. */
export interface TldrRelayed {
  who: string;
  gist: string;
}

export interface TldrResult {
  points: string[];
  ownWords: TldrQuote[];
  relayed: TldrRelayed[];
  covered: number; // messages summarized
  since: number; // the first one's time (ms)
  until: number; // the last one's time (ms)
  lastMessageId: string;
  cached: boolean; // the same answer as last time: nothing new since
}

/** Who is who in the conversation, as the model is told. */
export interface TldrNames {
  assistant: string; // the assistant's name (Palo's conversation) or the session's
}

/** A message as the model reads it: numbered, its speaker labelled. */
export interface TldrLine {
  n: number;
  kind: "owner" | "assistant" | "relayed";
  who: string;
  text: string;
  ts: number;
  messageId: string;
}

export interface TldrDeps {
  driver: HarnessDriver;
  probeModel(): string;
  cwd(): string;
  env?(): Record<string, string> | undefined;
  spend(usd: number): void;
  log(s: string): void;
  /** The conversation's latest messages (oldest first) and its names. */
  messages(scope: TldrScope, id: string): Promise<{ messages: ChatMessage[]; names: TldrNames }>;
}

export const TLDR_MAX = 40;
export const TLDR_MIN = 10;
const PER_MESSAGE = 1500; // characters of one message the model reads
const PER_OWNER_MESSAGE = 3000;
const TOTAL = 40_000; // characters in all

// A quote block an assistant puts others' words in (home.ts: 「> 转述自 XX」).
const RELAY_HEAD = /^>\s*(?:转述自|Relayed from|Quoting)\s*[:：]?\s*(.+?)\s*$/i;

/**
 * The messages as numbered lines, each labelled by who said it: the owner's
 * typed words; an assistant's or a session's replies; words that came from
 * elsewhere (another session or assistant, an Ally, a 「> 转述自 XX」 block
 * in a reply). Cards, notices and empty messages are left out.
 */
export function tldrLines(messages: ChatMessage[], names: TldrNames): TldrLine[] {
  const out: TldrLine[] = [];
  const push = (m: ChatMessage, kind: TldrLine["kind"], who: string, text: string) => {
    const s = text.trim();
    if (!s) return;
    out.push({ n: out.length + 1, kind, who, text: s, ts: m.ts, messageId: m.id });
  };
  for (const m of messages) {
    if (m.rewound) continue;
    if (m.kind === "ally") {
      // An Ally's words in; the owner's own words out (ally.say); the assistant's to them.
      if (m.dir === "in") push(m, "relayed", m.author === "owner" ? m.allyName ?? "?" : t("tldr.allyAssistant", { name: m.allyName ?? "?" }), m.text);
      else if (m.role === "user") push(m, "owner", "", m.text);
      else push(m, "assistant", names.assistant, m.text);
      continue;
    }
    if (m.kind !== "text" && m.kind !== "task") continue;
    if (m.role === "user") {
      if (m.from) push(m, "relayed", m.from, m.text);
      else push(m, "owner", "", m.text);
    } else if (m.role === "assistant") {
      for (const part of splitRelayed(m.text)) push(m, part.who ? "relayed" : "assistant", part.who ?? names.assistant, part.text);
    }
  }
  return out;
}

/** A reply cut into its own words and the 「> 转述自 XX」 blocks in it. */
export function splitRelayed(text: string): { who?: string; text: string }[] {
  const parts: { who?: string; text: string }[] = [];
  let own: string[] = [];
  let quote: { who: string; lines: string[] } | null = null;
  const flushOwn = () => {
    if (own.join("\n").trim()) parts.push({ text: own.join("\n") });
    own = [];
  };
  for (const line of text.split("\n")) {
    const head = line.match(RELAY_HEAD);
    if (head) {
      if (quote) parts.push({ who: quote.who, text: quote.lines.join("\n") });
      flushOwn();
      quote = { who: head[1]!, lines: [] };
      continue;
    }
    if (quote && /^\s*>/.test(line)) {
      quote.lines.push(line.replace(/^\s*>\s?/, ""));
      continue;
    }
    if (quote) {
      parts.push({ who: quote.who, text: quote.lines.join("\n") });
      quote = null;
    }
    own.push(line);
  }
  if (quote) parts.push({ who: quote.who, text: quote.lines.join("\n") });
  flushOwn();
  return parts;
}

/** How many of the latest lines to take: since the last TL;DR, between 10 and 40. */
export function tldrWindow(lines: TldrLine[], lastSeenId?: string): TldrLine[] {
  let n = TLDR_MAX;
  if (lastSeenId) {
    const at = lines.findLastIndex((l) => l.messageId === lastSeenId);
    if (at >= 0) n = Math.min(TLDR_MAX, Math.max(TLDR_MIN, lines.length - 1 - at));
  }
  const picked = lines.slice(-n);
  return picked.map((l, i) => ({ ...l, n: i + 1 }));
}

/** The lines as the model reads them; the latest ones kept when they're too long all together. */
export function tldrPrompt(lines: TldrLine[]): string {
  const blocks: string[] = [];
  let total = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i]!;
    const label = l.kind === "owner" ? "[OWNER]" : l.kind === "assistant" ? `[ASSISTANT: ${l.who}]` : `[RELAYED from ${l.who}]`;
    const block = `#${l.n} ${label} ${new Date(l.ts).toISOString()}\n${truncate(l.text, l.kind === "owner" ? PER_OWNER_MESSAGE : PER_MESSAGE)}`;
    if (total + block.length > TOTAL && blocks.length) break;
    total += block.length;
    blocks.unshift(block);
  }
  return blocks.join("\n\n");
}

export const tldrSchema = () => ({
  type: "object",
  properties: {
    points: { type: "array", items: { type: "string" }, description: t("tldr.pointsDesc") },
    ownWords: {
      type: "array",
      description: t("tldr.ownWordsDesc"),
      items: {
        type: "object",
        properties: { msg: { type: "integer", description: "the #number of the [OWNER] message it is from" }, text: { type: "string" } },
        required: ["msg", "text"],
      },
    },
    relayed: {
      type: "array",
      description: t("tldr.relayedDesc"),
      items: { type: "object", properties: { who: { type: "string" }, gist: { type: "string" } }, required: ["who", "gist"] },
    },
  },
  required: ["points", "ownWords", "relayed"],
});

/** Whitespace and the quote marks around it don't count when matching a quote. */
const squash = (s: string) => s.replace(/\s+/g, "");
const unwrap = (s: string) => s.trim().replace(/^[「『“"'‘]+|[」』”"'’]+$/g, "").replace(/(?:\.\.\.|…)+$/, "").trim();

/**
 * The model's answer, checked: a quote of the owner's is kept only if it is
 * really in one of the owner's messages (whitespace aside), and is tied to
 * that message; anything it made up or paraphrased is dropped.
 */
export function checkTldr(output: unknown, lines: TldrLine[]): { points: string[]; ownWords: TldrQuote[]; relayed: TldrRelayed[] } {
  let o = output;
  if (typeof o === "string") {
    try {
      o = JSON.parse(o);
    } catch {
      o = {};
    }
  }
  const r = (o ?? {}) as { points?: unknown; ownWords?: unknown; relayed?: unknown };
  const strs = (v: unknown) => (Array.isArray(v) ? v : []);
  const points = strs(r.points).filter((p): p is string => typeof p === "string" && !!p.trim()).map((p) => truncate(p.trim(), 300)).slice(0, 8);
  const owner = lines.filter((l) => l.kind === "owner");
  const ownWords: TldrQuote[] = [];
  for (const q of strs(r.ownWords)) {
    const text = unwrap(String((q as any)?.text ?? ""));
    const key = squash(text);
    if (key.length < 2) continue;
    const said = owner.find((l) => l.n === Number((q as any)?.msg) && squash(l.text).includes(key)) ?? owner.find((l) => squash(l.text).includes(key));
    if (!said || ownWords.some((w) => squash(w.text) === key)) continue;
    ownWords.push({ text: truncate(text, 600), messageId: said.messageId, ts: said.ts });
  }
  ownWords.sort((a, b) => a.ts - b.ts);
  const relayed = strs(r.relayed)
    .map((x) => ({ who: String((x as any)?.who ?? "").trim(), gist: String((x as any)?.gist ?? "").trim() }))
    .filter((x) => x.who && x.gist)
    .map((x) => ({ who: truncate(x.who, 60), gist: truncate(x.gist, 300) }))
    .slice(0, 8);
  return { points, ownWords: ownWords.slice(0, 8), relayed };
}

export class Tldr {
  private cache = new Map<string, TldrResult>();
  private running = new Map<string, Promise<TldrResult>>();

  constructor(private d: TldrDeps) {}

  /** chat.tldr: the conversation's recent stretch, summarized (or the last answer, when nothing came since). */
  run(scope: TldrScope, id: string): Promise<TldrResult> {
    const key = `${scope}:${id}`;
    const busy = this.running.get(key);
    if (busy) return busy;
    const p = this.make(scope, id, key).finally(() => this.running.delete(key));
    this.running.set(key, p);
    return p;
  }

  private async make(scope: TldrScope, id: string, key: string): Promise<TldrResult> {
    const { messages, names } = await this.d.messages(scope, id);
    const all = tldrLines(messages, names);
    const last = all.at(-1);
    if (!last || !all.some((l) => l.kind === "owner")) throw new Error(t("tldr.err.empty"));
    const before = this.cache.get(key);
    if (before?.lastMessageId === last.messageId) return { ...before, cached: true };
    const lines = tldrWindow(all, before?.lastMessageId);
    const res = await this.d.driver.runProbe({
      model: this.d.probeModel(),
      cwd: this.d.cwd(),
      systemPrompt: t("tldr.system"),
      prompt: tldrPrompt(lines),
      mcpServers: {},
      tools: [],
      outputSchema: tldrSchema() as unknown as Record<string, unknown>,
      maxTurns: 2,
      strictMcp: true,
      env: this.d.env?.(),
    });
    this.d.spend(res.costUsd);
    this.d.log(`tldr ${key}: ${lines.length} messages, $${res.costUsd.toFixed(4)}${res.usage ? ` ${JSON.stringify(res.usage)}` : ""}${res.error ? ` error: ${truncate(res.error, 200)}` : ""}`);
    if (res.error) throw new Error(isAuthFailure(res.error) ? t("tldr.err.login") : t("tldr.err.failed", { why: truncate(res.error, 200) }));
    const checked = checkTldr(res.output, lines);
    if (!checked.points.length) throw new Error(t("tldr.err.failed", { why: "no points" }));
    const out: TldrResult = {
      ...checked,
      covered: lines.length,
      since: lines[0]!.ts,
      until: last.ts,
      lastMessageId: last.messageId,
      cached: false,
    };
    this.cache.set(key, out);
    return out;
  }
}
