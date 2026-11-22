import { describe, expect, test } from "bun:test";
import { ApprovalManager } from "../src/approvals.ts";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import type { PermissionRequest } from "../src/harness/types.ts";
import { askOwner } from "../src/ownerCards.ts";
import { PendingStore } from "../src/pending.ts";
import { QuestionManager } from "../src/questions.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

// A session's stop for the owner becomes a card in one place (ownerCards.ts),
// and every card is an item on 等你的事.

function mk() {
  const paths = tmpPaths();
  const bus = new Bus();
  const audit = new Audit(paths.audit);
  const hooks = { taskForToolUse: () => undefined, onCreated: () => {}, timeoutMinutes: () => 30 };
  const approvals = new ApprovalManager(`${paths.state}/a.json`, bus, audit, hooks);
  const questions = new QuestionManager(`${paths.state}/q.json`, bus, audit, hooks);
  const pending = new PendingStore(`${paths.state}/pending.json`, bus, audit);
  return { approvals, questions, pending, paths };
}

const req = (toolName: string, input: Record<string, unknown>): PermissionRequest => ({ toolName, input, signal: new AbortController().signal });
const source = { kind: "pal" as const, id: "pal_1", name: "数据层迁移" };

describe("askOwner", () => {
  test("a command: a permission card with the whole command, its push line, and a blocking item from that agent", async () => {
    const { approvals, questions, pending, paths } = mk();
    const long = `npm run migrate -- ${"x".repeat(5000)}`;
    const card = askOwner({ approvals, questions }, req("Bash", { command: long }), { source, notify: false })!;
    expect(card.kind).toBe("approval");
    if (card.kind !== "approval") throw new Error("kind");
    expect(card.approval.detail).toBe(long);
    expect(card.line).toContain("npm run migrate");
    expect(card.ids).toEqual({ approvalId: card.approval.id });
    const item = pending.open().find((i) => i.approvalId === card.approval.id)!;
    expect(item).toMatchObject({ blocking: true, pal: "pal_1", source: { kind: "pal", id: "pal_1" }, title: card.approval.title });
    approvals.answer(card.approval.id, true, "app");
    expect((await card.result).behavior).toBe("allow");
    expect(pending.get(item.id)!.status).toBe("done");
    cleanup(paths);
  });

  test("AskUserQuestion: a question card and its item; a malformed one asks nothing", async () => {
    const { approvals, questions, pending, paths } = mk();
    const input = { questions: [{ question: "迁移前要不要备份？", header: "备份", multiSelect: false, options: [{ label: "备份" }, { label: "不用" }] }] };
    const card = askOwner({ approvals, questions }, req("AskUserQuestion", input), { source, notify: false })!;
    expect(card.kind).toBe("question");
    if (card.kind !== "question") throw new Error("kind");
    expect(card.line).toContain("迁移前要不要备份？");
    expect(card.ids).toEqual({ questionId: card.question.id });
    expect(pending.open().find((i) => i.questionId === card.question.id)).toMatchObject({ options: ["备份", "不用"], blocking: true });
    expect(askOwner({ approvals, questions }, req("AskUserQuestion", { questions: [] }), { source })).toBeNull();
    expect(pending.open()).toHaveLength(1);
    cleanup(paths);
  });

  test("the assistant's own prompt has the same words as a session's", () => {
    const { approvals, questions, paths } = mk();
    const long = `rm -rf build && ${"y".repeat(5000)}`;
    void approvals.request(req("Bash", { command: long }));
    const own = approvals.listPending()[0]!;
    const card = askOwner({ approvals, questions }, req("Bash", { command: long }), { source, notify: false })!;
    if (card.kind !== "approval") throw new Error("kind");
    expect([own.title, own.detail]).toEqual([card.approval.title, card.approval.detail]);
    cleanup(paths);
  });
});
