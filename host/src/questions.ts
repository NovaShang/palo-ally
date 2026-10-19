import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { AskOptions } from "./approvals.ts";
import type { Question, QuestionItem } from "./types.ts";
import { newId, readJson, writeJson } from "./util.ts";
import { t } from "./i18n/index.ts";

// Claude Code's AskUserQuestion reaches us through canUseTool like a
// permission prompt, but it is a question: the harness expects the owner's
// choices back in the tool input (`answers`: question text → label, labels
// comma-separated for multi-select, or the owner's own words). This module
// carries it to wherever the owner is and hands the answers back; first
// answer wins.

export const ASK_TOOL = "AskUserQuestion";

interface Pending {
  question: Question;
  input: Record<string, unknown>;
  resolve: (d: PermissionDecision) => void;
  timer: ReturnType<typeof setTimeout>;
}

export interface QuestionHooks {
  taskForToolUse(toolUseId?: string): string | undefined;
  onCreated(q: Question): void; // hub: chat card, push, WeChat text
  timeoutMinutes(): number;
}

export class QuestionManager {
  private questions: Question[];
  private pending = new Map<string, Pending>();

  constructor(
    private path: string,
    private bus: Bus,
    private audit: Audit,
    private hooks: QuestionHooks,
  ) {
    this.questions = readJson<Question[]>(path, []);
    // A previous process' questions can't be answered any more.
    for (const q of this.questions)
      if (q.status === "pending") {
        q.status = "expired";
        if (q.source?.kind === "session") q.note = t("approval.atComputer");
      }
    this.persist();
  }

  list(): Question[] {
    return [...this.questions].sort((a, b) => b.createdAt - a.createdAt).slice(0, 50);
  }

  listPending(): Question[] {
    return this.questions.filter((q) => q.status === "pending");
  }

  get(id: string): Question | undefined {
    return this.questions.find((q) => q.id === id);
  }

  // request is canUseTool for AskUserQuestion.
  request(req: PermissionRequest): Promise<PermissionDecision> {
    const asked = this.ask(req);
    if (!asked) return Promise.resolve({ behavior: "deny", message: t("question.badFormat") });
    return asked.result;
  }

  // ask puts the question in front of the owner; null when it's malformed.
  ask(req: PermissionRequest, o: AskOptions = {}): { question: Question; result: Promise<PermissionDecision> } | null {
    const items = parseItems(req.input);
    if (!items.length) return null;
    const question: Question = {
      id: newId("q_"),
      items,
      taskId: this.hooks.taskForToolUse(req.toolUseId),
      status: "pending",
      createdAt: Date.now(),
      ...(o.source ? { source: o.source } : {}),
    };
    this.questions.push(question);
    this.persist();
    this.audit.log("question.asked", { id: question.id, count: items.length, ...(o.source ? { session: o.source.id, sessionName: o.source.name } : {}) });

    const result = new Promise<PermissionDecision>((resolve) => {
      const ms = o.timeoutMs ?? this.hooks.timeoutMinutes() * 60_000;
      const timer = setTimeout(() => this.expire(question.id, "timeout", o.timeoutNote), ms);
      this.pending.set(question.id, { question, input: req.input, resolve, timer });
      const onAbort = () => this.expire(question.id, o.abortBy ?? "aborted", o.abortNote);
      if (req.signal.aborted) queueMicrotask(onAbort);
      else req.signal.addEventListener("abort", onAbort);
      this.bus.emit("question.updated", question);
      if (o.notify !== false) this.hooks.onCreated(question);
    });
    return { question, result };
  }

  // answer: `answers` maps each question's text to the chosen label(s) or the
  // owner's own words. A question left out was skipped: the harness hears so
  // in words, never something that reads like a choice. `device`: the paired
  // device that answered, for the audit trail.
  answer(id: string, answers: Record<string, string>, by: string, device?: string): Question {
    const p = this.pending.get(id);
    const q = p?.question ?? this.get(id);
    if (!q) throw new Error(t("question.none"));
    if (!p) return q; // already answered / expired: first answer wins
    const clean: Record<string, string> = {};
    const skipped: string[] = [];
    const told: Record<string, string> = {};
    for (const item of q.items) {
      const a = String(answers[item.question] ?? "").trim().slice(0, 1000);
      if (!a) {
        skipped.push(item.question);
        told[item.question] = t("question.skipped");
        continue;
      }
      clean[item.question] = a;
      told[item.question] = onlyNumbers(item, a) ? t("question.onlyNumbers", { a }) : a;
    }
    this.pending.delete(id);
    clearTimeout(p.timer);
    q.status = "answered";
    q.answers = clean;
    if (skipped.length) q.skipped = skipped;
    q.answeredAt = Date.now();
    q.answeredBy = by;
    this.persist();
    this.audit.log("question.answered", { id, by, ...(skipped.length ? { skipped: skipped.length } : {}), ...(device ? { device } : {}), ...(q.source ? { session: q.source.id, sessionName: q.source.name } : {}) });
    this.bus.emit("question.updated", q);
    p.resolve({ behavior: "allow", updatedInput: { ...p.input, answers: told } });
    return q;
  }

  // cancelAll closes every open question of the assistant's (the stop
  // button); sessions' questions are theirs.
  cancelAll(by: string): void {
    for (const [id, p] of [...this.pending]) if (!p.question.source) this.expire(id, by);
  }

  // cancelFor closes one session's or Pal's open questions.
  cancelFor(sourceId: string, by: string): void {
    for (const [id, p] of [...this.pending]) if (p.question.source?.id === sourceId) this.expire(id, by);
  }

  private expire(id: string, by: string, note?: string): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    clearTimeout(p.timer);
    p.question.status = "expired";
    p.question.answeredAt = Date.now();
    p.question.answeredBy = by;
    if (note) p.question.note = note;
    this.persist();
    this.audit.log("question.expired", { id, by, ...(note ? { note } : {}), ...(p.question.source ? { session: p.question.source.id } : {}) });
    this.bus.emit("question.updated", p.question);
    p.resolve({
      behavior: "deny",
      message: by === "timeout" ? t("question.timeout") : t("question.stopped"),
    });
  }

  private persist(): void {
    if (this.questions.length > 200) this.questions = this.questions.slice(-200);
    writeJson(this.path, this.questions);
  }
}

// parseItems reads AskUserQuestion's input defensively (1–4 questions, 2–4
// options each in the harness' schema; we accept what is well-formed).
export function parseItems(input: Record<string, unknown>): QuestionItem[] {
  const raw = Array.isArray(input.questions) ? input.questions : [];
  return raw.slice(0, 4).flatMap((r: any) => {
    const question = typeof r?.question === "string" ? r.question.trim() : "";
    const options = (Array.isArray(r?.options) ? r.options : [])
      .filter((o: any) => typeof o?.label === "string" && o.label.trim())
      .slice(0, 6)
      .map((o: any) => ({ label: o.label.trim(), ...(typeof o.description === "string" && o.description.trim() ? { description: o.description.trim() } : {}) }));
    if (!question || !options.length) return [];
    return [{ question, ...(typeof r.header === "string" && r.header.trim() ? { header: r.header.trim() } : {}), options, multiSelect: !!r.multiSelect }];
  });
}

// onlyNumbers: own words that are just digits ("1", "11") are not a pick of
// option 1; the asker is told so instead of guessing.
function onlyNumbers(item: QuestionItem, a: string): boolean {
  return /^[\d\s,，、.。]+$/.test(a) && !item.options.some((o) => o.label === a);
}

// ---------------- text channels (WeChat) ----------------

// questionText renders the questions as numbered options for a text channel.
export function questionText(q: Question): string {
  const many = q.items.length > 1;
  const parts = q.items.map((item, i) => {
    const head = `${many ? `${i + 1}. ` : ""}${item.question}${item.multiSelect ? t("question.multi") : ""}`;
    const opts = item.options.map((o, j) => `  ${j + 1}) ${o.label}${o.description ? t("question.optDesc", { d: o.description }) : ""}`);
    return [head, ...opts].join("\n");
  });
  const how = many
    ? t("question.howMany")
    : q.items[0]!.multiSelect
      ? t("question.howMulti")
      : t("question.howOne");
  return t("question.text", { body: parts.join("\n\n"), how });
}

// parseTextAnswer turns a text reply ("2", "1,3", or words) into answers, or
// null when it can't be matched to the questions (several questions, wrong
// number of lines). 「跳过」 skips them all, or one question on its own line.
export function parseTextAnswer(q: Question, text: string): Record<string, string> | null {
  const t = text.trim();
  if (!t) return null;
  if (SKIP.test(t)) return {};
  const parts = q.items.length === 1 ? [t] : t.split(/\n+|[;；]/).map((s) => s.trim()).filter(Boolean);
  if (parts.length !== q.items.length) return null;
  const out: Record<string, string> = {};
  q.items.forEach((item, i) => {
    if (!SKIP.test(parts[i]!)) out[item.question] = answerFor(item, parts[i]!);
  });
  return out;
}

const SKIP = /^(跳过|skip)$/i;

function answerFor(item: QuestionItem, part: string): string {
  // Only digits and separators: option numbers.
  if (/^[\d\s,，、和]+$/.test(part)) {
    const nums = [...new Set(part.match(/\d+/g)!.map(Number))].filter((n) => n >= 1 && n <= item.options.length);
    if (nums.length) {
      const picked = item.multiSelect ? nums : nums.slice(0, 1);
      return picked.map((n) => item.options[n - 1]!.label).join(", ");
    }
  }
  return part; // the owner's own words (the 「其他」 answer)
}
