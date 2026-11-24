import type { zhBacklog } from "../zh/backlog.ts";

export const enBacklog: Record<keyof typeof zhBacklog, string> = {
  "backlog.prompt":
    "When the owner says to put something in the backlog (or to remember it for later), record it with mcp__paloally__backlog_add (text: one line saying what to do; details in note), then tell the owner which place it took; don't start on it now. The backlog belongs to this folder and is shared by the agents working in it; backlog_list shows it; when the owner has you do one of its items, mark it as yours first with backlog_start; backlog_edit changes an item's words; and when you finish one of its items mark it with backlog_done.",
  "backlog.file.title": "Backlog · {name}",
  "backlog.file.hint": "Palo's backlog: one line per item, top first; [>] being done, [x] done. Edit freely; keep the comment at each line's end.",
  "backlog.err.none": "No such item in the backlog",
  "backlog.err.empty": "Write something",
  "backlog.err.pal": "No such agent",
  "backlog.err.blocking": "An agent is stopped on this one: it needs an answer now",
  "backlog.line.doing": "being done {who}",
  "backlog.line.done": "done",
  "backlog.tool.added": "Added to the backlog as number {n} (id: {id}; the backlog of {folder}). Tell the owner it's noted; don't start on it now.",
  "backlog.tool.none": "The backlog of {folder} is empty.",
  "backlog.tool.list": "The backlog of {folder} (being done first, then the queue in order, done ones last):\n{lines}",
  "backlog.tool.started": "Marked as being done by you: \"{text}\". When it's done, mark it with backlog_done.",
  "backlog.tool.taken": "\"{text}\" is already being done by {who}; nothing changed.",
  "backlog.tool.edited": "Changed: \"{text}\".",
  "backlog.assistant": "the assistant",
  "backlog.tool.done": "Marked done: \"{text}\". {n} still queued.",
  "backlog.tool.undone": "Back in the queue: \"{text}\".",
  "backlog.quote.note": "(The owner is quoting {id} \"{text}\" from the backlog. When it's done, mark it with backlog_done.)",
  "backlog.later": "Moved to the backlog",
};
