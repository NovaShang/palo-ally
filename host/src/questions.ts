import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { Question, QuestionItem } from "./types.ts";
import { newId, readJson, writeJson } from "./util.ts";

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
    for (const q of this.questions) if (q.status === "pending") q.status = "expired";
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
    const items = parseItems(req.input);
    if (!items.length) return Promise.resolve({ behavior: "deny", message: "问题格式不对，没法问主人" });
    const question: Question = {
      id: newId("q_"),
      items,
      taskId: this.hooks.taskForToolUse(req.toolUseId),
      status: "pending",
      createdAt: Date.now(),
    };
    this.questions.push(question);
    this.persist();
    this.audit.log("question.asked", { id: question.id, count: items.length });

    return new Promise<PermissionDecision>((resolve) => {
      const timer = setTimeout(() => this.expire(question.id, "timeout"), this.hooks.timeoutMinutes() * 60_000);
      this.pending.set(question.id, { question, input: req.input, resolve, timer });
      req.signal.addEventListener("abort", () => this.expire(question.id, "aborted"));
      this.bus.emit("question.updated", question);
      this.hooks.onCreated(question);
    });
  }

  // answer: `answers` maps each question's text to the chosen label(s) or the
  // owner's own words. Every question needs an answer.
  answer(id: string, answers: Record<string, string>, by: string): Question {
    const p = this.pending.get(id);
    const q = p?.question ?? this.get(id);
    if (!q) throw new Error("没有这个问题");
    if (!p) return q; // already answered / expired: first answer wins
    const clean: Record<string, string> = {};
    for (const item of q.items) {
      const a = String(answers[item.question] ?? "").trim();
      if (!a) throw new Error("每个问题都要选一下");
      clean[item.question] = a.slice(0, 1000);
    }
    this.pending.delete(id);
    clearTimeout(p.timer);
    q.status = "answered";
    q.answers = clean;
    q.answeredAt = Date.now();
    q.answeredBy = by;
    this.persist();
    this.audit.log("question.answered", { id, by });
    this.bus.emit("question.updated", q);
    p.resolve({ behavior: "allow", updatedInput: { ...p.input, answers: clean } });
    return q;
  }

  // cancelAll closes every open question (the stop button).
  cancelAll(by: string): void {
    for (const id of [...this.pending.keys()]) this.expire(id, by);
  }

  private expire(id: string, by: string): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    clearTimeout(p.timer);
    p.question.status = "expired";
    p.question.answeredAt = Date.now();
    p.question.answeredBy = by;
    this.persist();
    this.audit.log("question.expired", { id, by });
    this.bus.emit("question.updated", p.question);
    p.resolve({
      behavior: "deny",
      message: by === "timeout" ? "主人一直没回答。先按你的判断继续，或者以后再问。" : "主人没回答就停下了。",
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

// ---------------- text channels (WeChat) ----------------

// questionText renders the questions as numbered options for a text channel.
export function questionText(q: Question): string {
  const many = q.items.length > 1;
  const parts = q.items.map((item, i) => {
    const head = `${many ? `${i + 1}. ` : ""}${item.question}${item.multiSelect ? "（可多选）" : ""}`;
    const opts = item.options.map((o, j) => `  ${j + 1}) ${o.label}${o.description ? `：${o.description}` : ""}`);
    return [head, ...opts].join("\n");
  });
  const how = many
    ? `每行回一个问题，按顺序，比如：\n1\n2,3\n回数字选，也可以直接写你的想法。`
    : q.items[0]!.multiSelect
      ? "回数字选（多个用逗号隔开，比如 1,3），也可以直接写你的想法。"
      : "回数字选，也可以直接写你的想法。";
  return `想问你一下：\n${parts.join("\n\n")}\n\n${how}`;
}

// parseTextAnswer turns a text reply ("2", "1,3", or words) into answers, or
// null when it can't be matched to the questions (several questions, wrong
// number of lines).
export function parseTextAnswer(q: Question, text: string): Record<string, string> | null {
  const t = text.trim();
  if (!t) return null;
  const parts = q.items.length === 1 ? [t] : t.split(/\n+|[;；]/).map((s) => s.trim()).filter(Boolean);
  if (parts.length !== q.items.length) return null;
  const out: Record<string, string> = {};
  q.items.forEach((item, i) => {
    out[item.question] = answerFor(item, parts[i]!);
  });
  return out;
}

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
