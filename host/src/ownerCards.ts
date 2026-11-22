import { type ApprovalManager, type AskOptions, sessionPermission } from "./approvals.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import { t } from "./i18n/index.ts";
import { ASK_TOOL, type QuestionManager } from "./questions.ts";
import type { Approval, Question } from "./types.ts";

// The one place a session's stop for the owner becomes a card: a Pal's
// (through the harness' canUseTool) and a computer session's (through the
// hooks) alike. AskUserQuestion is a question card, anything else a
// permission card with its words (sessionPermission: the command whole).
// Each card is an item on 等你的事 (pending.ts follows both managers), so
// the apps show and count it from the list; `line` is what the 「在等你」
// push says, `ids` what it opens.

export type OwnerCard =
  | { kind: "question"; question: Question; line: string; ids: { questionId: string }; result: Promise<PermissionDecision> }
  | { kind: "approval"; approval: Approval; line: string; ids: { approvalId: string }; result: Promise<PermissionDecision> };

export interface CardManagers {
  approvals: ApprovalManager;
  questions: QuestionManager;
}

/** Puts the card in front of the owner; null for a malformed question (nothing was asked). */
export function askOwner(cards: CardManagers, req: PermissionRequest, o: AskOptions = {}): OwnerCard | null {
  if (req.toolName === ASK_TOOL) {
    const asked = cards.questions.ask(req, o);
    if (!asked) return null;
    const first = asked.question.items[0]!.question;
    return { kind: "question", question: asked.question, line: t("sessions.askYou", { q: first }), ids: { questionId: asked.question.id }, result: asked.result };
  }
  const words = sessionPermission(req.toolName, req.input);
  const asked = cards.approvals.ask(req, { ...o, title: words.title, detail: words.detail });
  return { kind: "approval", approval: asked.approval, line: words.line, ids: { approvalId: asked.approval.id }, result: asked.result };
}
