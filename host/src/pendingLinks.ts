import type { Bus } from "./bus.ts";
import type { ChatLog } from "./chat.ts";
import { type MsgKey, t, tIn } from "./i18n/index.ts";
import type { NewPending, PendingStore } from "./pending.ts";
import type { AllyEntry, ChatMessage, HelperProposal, PalAdoptProposal, PendingLink, PendingSource, Task } from "./types.ts";
import { truncate } from "./util.ts";

// The cards that wait on the owner besides questions and permission prompts,
// each kept on 等你的事 while it waits (so the list is all that waits, and
// the apps' badges count only the list):
//  - the assistant's proposal cards: 开一个会话 (helper, 开吧 / 不用) and
//    接管 (pal_adopt, 接管 / 不用);
//  - an Ally draft (发送 / 不发);
//  - a task that needs the owner (needs_input), unless what it waits on is
//    already an item (a Pal's or a session's question or prompt).
// The item closes when its card is settled, wherever that happened; an
// option picked on the list does what the card's button does (Hub.answerPending).

export interface PendingLinksDeps {
  bus: Bus;
  chat: ChatLog;
  pending: PendingStore;
  paloName: () => string;
  allyName: (allyId: string) => string;
  openDrafts: () => { entry: AllyEntry; name: string }[];
  tasks: () => Task[];
  /** A Pal's id by its name or id (a task handed to it names it). */
  palId: (key: string) => string | undefined;
}

type Proposal = HelperProposal | PalAdoptProposal;

export class PendingLinks {
  constructor(private d: PendingLinksDeps) {
    d.bus.on((event, data) => {
      if (event === "chat.message") this.onMessage(data as ChatMessage);
      else if (event === "ally.entry") this.onDraft((data as { entry: AllyEntry }).entry);
      else if (event === "task.updated") this.onTask(data as Task);
    });
  }

  /** At start: an item for each card waiting now, and the items of cards settled while the host was away closed. */
  reconcile(): void {
    const cards = this.d.chat.filter((m) => (m.kind === "helper" || m.kind === "pal_adopt") && !m.pal && !m.rewound && !!m.proposal);
    const live = new Set<string>();
    for (const m of cards) if (this.onMessage(m)) live.add(m.proposal!.id);
    this.closeAllBut("proposal", live);

    const drafts = new Set<string>();
    for (const { entry, name } of this.d.openDrafts()) {
      this.follow(this.draftItem(entry, name));
      drafts.add(entry.id);
    }
    this.closeAllBut("allyDraft", drafts);

    const tasks = new Set<string>();
    for (const task of this.d.tasks()) if (this.onTask(task)) tasks.add(task.id);
    this.closeAllBut("task", tasks);
  }

  // ---- proposal cards (they are messages, sent again when settled) ----

  /** True while the card waits. */
  private onMessage(m: ChatMessage): boolean {
    if (m.pal) return false;
    if (m.kind === "ally" && m.entryId && m.dir === "out") {
      this.d.pending.linkMessage({ kind: "allyDraft", id: m.entryId }, m.id);
      return false;
    }
    if ((m.kind !== "helper" && m.kind !== "pal_adopt") || !m.proposal) return false;
    const p = m.proposal;
    const link: PendingLink = { kind: "proposal", id: p.id };
    if (p.status === "pending" && !m.rewound) {
      const adopt = m.kind === "pal_adopt";
      const duty = !adopt ? (p as HelperProposal).duty : undefined;
      this.follow({
        source: this.palo(),
        title: m.text,
        ...(duty ? { context: truncate(duty, 300) } : {}),
        options: [t(adopt ? "pending.opt.adopt" : "pending.opt.create"), t("pending.opt.no")],
        messageId: m.id,
        link,
      });
      return true;
    }
    this.d.pending.settle(link, proposalOutcome(p));
    return false;
  }

  // ---- Ally drafts ----

  private onDraft(e: AllyEntry): void {
    if (e.dir !== "out") return;
    const link: PendingLink = { kind: "allyDraft", id: e.id };
    if (e.status === "draft") {
      // Only a draft the owner hasn't seen go out yet (a direct one is queued at once).
      this.follow(this.draftItem(e, this.d.allyName(e.allyId)));
      return;
    }
    this.d.pending.settle(link, t(e.status === "rejected" ? "pending.link.notSent" : "pending.link.sent"));
  }

  private draftItem(e: AllyEntry, name: string): NewPending & { link: PendingLink } {
    const message = this.d.chat.filter((m) => m.kind === "ally" && m.entryId === e.id && !m.pal).at(-1);
    return {
      source: { kind: "ally", id: e.allyId, name },
      title: t("pending.link.draft", { name }),
      context: truncate(e.text, 300),
      options: [t("pending.opt.send"), t("pending.opt.dontSend")],
      ...(message ? { messageId: message.id } : {}),
      link: { kind: "allyDraft", id: e.id },
    };
  }

  // ---- tasks that need the owner ----

  /** True while the task waits on the owner through its item. */
  private onTask(task: Task): boolean {
    const link: PendingLink = { kind: "task", id: task.id };
    if (task.status !== "needs_input") {
      this.d.pending.settle(link, t(task.status === "running" ? "pending.link.taskOn" : "pending.link.taskEnded"));
      return false;
    }
    if (!this.d.pending.linked(link) && this.covered(task)) return false;
    this.follow({ source: this.palo(), title: t("pending.link.task", { title: task.title }), ...(task.summary ? { context: task.summary } : {}), link });
    return true;
  }

  // A task handed to a Pal or a session that is stopped on its own question
  // or prompt: that's on the list already (the owner answers it there).
  private covered(task: Task): boolean {
    if (!task.peer) return false;
    const pal = this.d.palId(task.peer);
    return this.d.pending
      .open()
      .some((i) => i.blocking && (i.source.kind === "pal" || i.source.kind === "session") && (i.source.name === task.peer || (!!pal && i.source.id === pal)));
  }

  // ---- shared ----

  private follow(n: NewPending & { link: PendingLink }): void {
    this.d.pending.follow(n);
  }

  private closeAllBut(kind: PendingLink["kind"], live: Set<string>): void {
    for (const id of this.d.pending.linkedIds(kind)) if (!live.has(id)) this.d.pending.settle({ kind, id }, t("pending.link.gone"));
  }

  private palo(): PendingSource {
    return { kind: "palo", name: this.d.paloName() };
  }
}

function proposalOutcome(p: Proposal): string {
  switch (p.status) {
    case "created":
      return t("pending.link.created");
    case "adopted":
      return t("pending.link.adopted");
    case "discarded":
      return t("pending.link.discarded");
    case "expired":
      return t("pending.link.expired");
    default:
      // a 接管 that didn't go through: why, as the card says it
      return p.note || t("pending.link.gone");
  }
}

/** What an option picked on the list does on the card: the card's action, or null (the owner's own words). */
export function linkAction(link: PendingLink, answer: string): "create" | "discard" | "send" | null {
  const is = (key: MsgKey) => answer === t(key) || answer === tIn("zh", key) || answer === tIn("en", key);
  if (link.kind === "proposal") {
    if (is("pending.opt.create") || is("pending.opt.adopt")) return "create";
    if (is("pending.opt.no")) return "discard";
  } else if (link.kind === "allyDraft") {
    if (is("pending.opt.send")) return "send";
    if (is("pending.opt.dontSend")) return "discard";
  }
  return null;
}
