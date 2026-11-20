import type { zhPending } from "../zh/pending.ts";

export const enPending: Record<keyof typeof zhPending, string> = {
  "pending.decided": "Decided",
  "pending.closed": "Ended before it was answered",
  "pending.skipped": "Skipped",
  "pending.questions": "{q} ({n} questions)",
  "pending.allow": "Allow",
  "pending.deny": "Deny",
  "pending.allowed": "Allowed",
  "pending.denied": "Denied",
  "pending.err.none": "No such item",
  "pending.err.gone": "That question has ended and can't go back on the list",
  "pending.err.action": "Unknown action",
  "pending.err.empty": "Give an answer",
  "pending.line.blocking": " (a session is stopped waiting)",
  "pending.tool.added": "Put on the owner's pending list (id: {id}); {n} in all now. The owner decides in the app when convenient, and the decision comes back to you as a message. Carry on with other things; don't wait.",
  "pending.tool.dup": "That one is already on the list (id: {id}); not added twice.",
  "pending.tool.badTitle": "title can't be empty: one sentence saying what the owner must decide.",
  "pending.tool.resolved": "Marked decided: {conclusion}. {rest}",
  "pending.tool.rest": "{n} left:\n{lines}",
  "pending.tool.none": "Nothing else is on the list.",
  "pending.ask.deferred":
    "Handed to the owner: the question is on the owner's pending list ({ids}); they'll answer when convenient, and the answer comes back to you as a message. Carry on: do what you can now, don't decide for the owner on the parts that depend on it, and don't ask again.",
  "pending.answer.note": "(The owner answered {id} \"{title}\" on the pending list; it's marked decided. Use resolve_pending to word the conclusion better. {rest})",
  "pending.answer.question": "(This answers what you asked the owner: \"{q}\")",
  "pending.answer.pal": "About \"{title}\": {answer}",
  "pending.surface.turn":
    "[Pending] The owner tapped \"Talk about this\" and wants to decide it now:\nid: {id}\nFrom: {source}\nTo decide: {title}\nBackground: {context}\nOptions: {options}\nIts card is already at the bottom of the conversation (background, what to decide, the options). Add a sentence or two with your view or what the owner still needs to know, without repeating the card's words, then wait for the answer.",
  "pending.surface.none": "(none)",
  "pending.brief.stale": "\n\nThese items have waited for the owner's decision for over three days; mention them once in this run (one line is enough), not again after:\n{lines}",
};
