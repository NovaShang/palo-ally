import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { Approval, ChatMessage, PendingItem, PendingLink, PendingSource, Question } from "./types.ts";
import { newId, readJson, truncate, writeJson } from "./util.ts";
import { t } from "./i18n/index.ts";

// 等你的事 (docs/workbench-design/decisions-queue.html): everything the owner
// has to decide, recorded by the host, never left to the model's memory.
// Items come from the assistant's and the Pals' add_pending tool, from the
// assistant's own AskUserQuestion (turned into an item: the main
// conversation never stops on a question), and from every question or
// permission prompt a session is actually stopped on (blocking; answering
// the item answers it). The other cards that wait on the owner (a proposal
// to open or take over a session, an Ally draft, a task that needs them) are
// items too, linked to their card (`link`; pendingLinks.ts keeps them in
// step): the list is everything that waits, and the apps' badges count it.
// One store, kept on disk; `pending.updated` carries each change to the apps.

/** Open this long: a brief mentions it once. */
export const STALE_MS = 3 * 24 * 3600_000;
/** Mentioned and still open this much later: put away (已收起), still listed. */
export const SNOOZE_AFTER_REMINDER_MS = 4 * 24 * 3600_000;
/** Done or ignored items are kept this long, then dropped. */
const KEEP_CLOSED_MS = 30 * 24 * 3600_000;
/** What the apps get of the closed ones (今天处理过 is the app's cut of these). */
const LIST_CLOSED_MS = 3 * 24 * 3600_000;

// What the store keeps beyond the wire item.
interface PendingRecord extends PendingItem {
  watchId?: string; // added during a brief's run: linked to the brief's card once it's posted
  question?: string; // the assistant's own question it came from (its words go back with the answer)
  ended?: boolean; // linked: its card was settled (it can't come back)
}

export interface NewPending {
  source: PendingSource;
  title: string;
  context?: string;
  options?: string[];
  blocking?: boolean;
  messageId?: string;
  pal?: string;
  questionId?: string;
  approvalId?: string;
  watchId?: string;
  question?: string;
  link?: PendingLink;
}

export class PendingStore {
  private items: PendingRecord[];

  constructor(
    private path: string,
    private bus: Bus,
    private audit: Audit,
    private paloName: () => string = () => "Palo",
    private now: () => number = Date.now,
  ) {
    this.items = readJson<PendingRecord[]>(path, []);
    this.prune();
    bus.on((event, data) => {
      if (event === "question.updated") this.onQuestion(data as Question);
      else if (event === "approval.updated") this.onApproval(data as Approval);
      else if (event === "chat.message") this.onMessage(data as ChatMessage);
    });
  }

  /** What the apps show: every open and put-away item, and the ones closed lately. */
  list(): PendingItem[] {
    this.sweep();
    const since = this.now() - LIST_CLOSED_MS;
    // Newest first; added in the same millisecond, the one added later first.
    return this.items
      .filter((i) => i.status === "open" || i.status === "snoozed" || (i.resolvedAt ?? 0) >= since)
      .reverse()
      .sort((a, b) => b.createdAt - a.createdAt)
      .map(wire);
  }

  open(): PendingItem[] {
    return this.items.filter((i) => i.status === "open").map(wire);
  }

  get(id: string): PendingItem | undefined {
    const i = this.items.find((x) => x.id === id);
    return i ? wire(i) : undefined;
  }

  /** The assistant's question the item came from, when it was one. */
  questionOf(id: string): string | undefined {
    return this.items.find((x) => x.id === id)?.question;
  }

  // add puts a new item in. The same title from the same source while it's
  // still open is the same item (the model asking twice): that one comes back.
  add(n: NewPending): PendingItem {
    const title = truncate(n.title.trim().replace(/\s+/g, " "), 200);
    // A card's item is one per card, whatever the owner did with it.
    const linked = n.link ? this.linked(n.link) : undefined;
    if (linked) return wire(linked);
    const dup = !n.link && this.items.find((i) => i.status === "open" && !i.link && sameSource(i.source, n.source) && i.title === title);
    if (dup) return wire(dup);
    const options = (n.options ?? []).map((o) => String(o).trim()).filter(Boolean).slice(0, 6);
    const item: PendingRecord = {
      id: newId("p_"),
      source: n.source,
      title,
      ...(n.context?.trim() ? { context: truncate(n.context.trim(), 600) } : {}),
      ...(options.length ? { options } : {}),
      createdAt: this.now(),
      blocking: !!n.blocking,
      status: "open",
      ...(n.messageId ? { messageId: n.messageId } : {}),
      ...(n.pal ? { pal: n.pal } : {}),
      ...(n.questionId ? { questionId: n.questionId } : {}),
      ...(n.approvalId ? { approvalId: n.approvalId } : {}),
      ...(n.watchId ? { watchId: n.watchId } : {}),
      ...(n.question ? { question: n.question } : {}),
      ...(n.link ? { link: { kind: n.link.kind, id: n.link.id } } : {}),
    };
    this.items.push(item);
    this.audit.log("pending.added", { id: item.id, source: item.source.kind, ...(item.source.id ? { sourceId: item.source.id } : {}), blocking: item.blocking });
    this.changed(item);
    return wire(item);
  }

  // resolve marks it decided, with a one-line conclusion. Saying it again
  // (the assistant rewording what the owner chose) only changes the line.
  resolve(id: string, conclusion: string, by: string): PendingItem {
    const item = this.find(id);
    item.status = "done";
    item.conclusion = truncate(conclusion.trim().replace(/\s+/g, " "), 200) || item.conclusion || t("pending.decided");
    item.resolvedAt ??= this.now();
    this.audit.log("pending.resolved", { id, by });
    this.changed(item);
    return wire(item);
  }

  // update: the owner's hand on the list. ignore: off the list; reopen: back
  // on it (撤回 / 放回); snooze: put away.
  update(id: string, action: string, by: string): PendingItem {
    const item = this.find(id);
    if (action === "ignore") {
      item.status = "ignored";
      item.resolvedAt = this.now();
    } else if (action === "snooze") {
      item.status = "snoozed";
      item.resolvedAt = this.now();
    } else if (action === "reopen") {
      // A question or prompt that already ended can't come back.
      if (((item.questionId || item.approvalId) && item.status !== "open") || item.ended) throw new Error(t("pending.err.gone"));
      item.status = "open";
      delete item.resolvedAt;
      delete item.conclusion;
      delete item.remindedAt;
      item.createdAt = Math.max(item.createdAt, this.now() - STALE_MS + 3600_000);
    } else throw new Error(t("pending.err.action"));
    this.audit.log("pending.updated", { id, action, by });
    this.changed(item);
    return wire(item);
  }

  /** Open items of one source (a Pal's own, for its panel). */
  openFor(kind: PendingSource["kind"], id?: string): PendingItem[] {
    return this.items.filter((i) => i.status === "open" && i.source.kind === kind && (id === undefined || i.source.id === id)).map(wire);
  }

  /**
   * For a brief's run: the items open more than three days the owner hasn't
   * heard about yet, marked as mentioned now. A few days after that they're
   * put away by themselves (sweep).
   */
  takeStale(): PendingItem[] {
    const cutoff = this.now() - STALE_MS;
    const stale = this.items.filter((i) => i.status === "open" && !i.blocking && !i.remindedAt && i.createdAt < cutoff);
    for (const i of stale) i.remindedAt = this.now();
    if (stale.length) this.persist();
    return stale.map(wire);
  }

  /** Mentioned in a brief and still open days later: put away. */
  sweep(): void {
    const cutoff = this.now() - SNOOZE_AFTER_REMINDER_MS;
    for (const i of this.items) {
      if (i.status !== "open" || !i.remindedAt || i.remindedAt > cutoff) continue;
      i.status = "snoozed";
      i.resolvedAt = this.now();
      this.audit.log("pending.snoozed", { id: i.id, by: "auto" });
      this.changed(i);
    }
  }

  /**
   * After a restart: the questions and prompts of the last process can't be
   * answered any more (their managers closed them before we listened), so
   * their items close too.
   */
  reconcile(live: (i: PendingItem) => boolean): void {
    for (const i of this.items) {
      if (i.status !== "open" || !(i.questionId || i.approvalId) || live(i)) continue;
      i.status = "done";
      i.conclusion = t("pending.closed");
      i.resolvedAt = this.now();
      this.changed(i);
    }
  }

  // ---- linked ones: a card that waits on the owner (pendingLinks.ts) ----

  /** The item a card has (not one whose card was settled before). */
  linked(link: PendingLink): PendingItem | undefined {
    const i = this.items.find((x) => x.link && !x.ended && x.link.kind === link.kind && x.link.id === link.id);
    return i ? wire(i) : undefined;
  }

  /**
   * The card waits on the owner: its item is there (added once; its words
   * follow the card's while it's open). The owner's ignoring it stands.
   */
  follow(n: NewPending & { link: PendingLink }): PendingItem {
    const cur = this.items.find((x) => x.link && !x.ended && x.link.kind === n.link.kind && x.link.id === n.link.id);
    if (!cur) return this.add(n);
    if (cur.status !== "open") return wire(cur);
    const title = truncate(n.title.trim().replace(/\s+/g, " "), 200);
    const context = n.context?.trim() ? truncate(n.context.trim(), 600) : undefined;
    let changed = false;
    if (title && cur.title !== title) (cur.title = title), (changed = true);
    if (context !== cur.context) {
      if (context) cur.context = context;
      else delete cur.context;
      changed = true;
    }
    if (n.messageId && !cur.messageId) (cur.messageId = n.messageId), (changed = true);
    if (changed) this.changed(cur);
    return wire(cur);
  }

  /** The card was settled (answered on the card, expired, gone): its item closes with what became of it. */
  settle(link: PendingLink, conclusion: string): void {
    for (const i of this.items) {
      if (!i.link || i.ended || i.link.kind !== link.kind || i.link.id !== link.id) continue;
      i.ended = true;
      if (i.status === "open" || i.status === "snoozed") {
        i.status = "done";
        i.conclusion = truncate(conclusion, 200);
        i.resolvedAt = this.now();
        this.audit.log("pending.settled", { id: i.id, link: link.kind });
        this.changed(i);
      } else this.persist();
    }
  }

  /** Where a card is in the conversation, once it's there (看原文). */
  linkMessage(link: PendingLink, messageId: string): void {
    const i = this.items.find((x) => x.link && !x.ended && x.link.kind === link.kind && x.link.id === link.id);
    if (!i || i.messageId) return;
    i.messageId = messageId;
    this.changed(i);
  }

  /** The linked items of one kind whose card is still unsettled here (for a reconcile). */
  linkedIds(kind: PendingLink["kind"]): string[] {
    return this.items.filter((i) => i.link?.kind === kind && !i.ended).map((i) => i.link!.id);
  }

  // ---- blocking ones: a session's question or permission prompt ----

  private onQuestion(q: Question): void {
    const item = this.items.find((i) => i.questionId === q.id);
    if (q.status === "pending") {
      if (item) return;
      const first = q.items[0];
      if (!first) return;
      const one = q.items.length === 1 && !first.multiSelect;
      this.add({
        source: q.source ? { kind: q.source.kind, id: q.source.id, name: q.source.name } : { kind: "palo", name: this.paloName() },
        title: q.items.length > 1 ? t("pending.questions", { q: first.question, n: q.items.length }) : first.question,
        ...(first.header ? { context: first.header } : {}),
        ...(one ? { options: first.options.map((o) => o.label) } : {}),
        blocking: true,
        questionId: q.id,
        ...(q.source?.kind === "pal" ? { pal: q.source.id } : {}),
      });
      return;
    }
    if (!item || item.status !== "open") return;
    item.status = "done";
    item.resolvedAt = this.now();
    item.conclusion =
      q.status === "answered" && q.answers && Object.keys(q.answers).length
        ? truncate(Object.values(q.answers).join(t("turn.listSep")), 200)
        : (q.note ?? t(q.status === "answered" ? "pending.skipped" : "pending.closed"));
    this.changed(item);
  }

  private onApproval(a: Approval): void {
    const item = this.items.find((i) => i.approvalId === a.id);
    if (a.status === "pending") {
      if (item) return;
      this.add({
        source: a.source ? { kind: a.source.kind, id: a.source.id, name: a.source.name } : { kind: "palo", name: this.paloName() },
        title: a.title,
        ...(a.detail ? { context: truncate(a.detail, 300) } : {}),
        options: [t("pending.allow"), t("pending.deny")],
        blocking: true,
        approvalId: a.id,
        ...(a.source?.kind === "pal" ? { pal: a.source.id } : {}),
      });
      return;
    }
    if (!item || item.status !== "open") return;
    item.status = "done";
    item.resolvedAt = this.now();
    item.conclusion = a.note ?? t(a.status === "allowed" ? "pending.allowed" : a.status === "denied" ? "pending.denied" : "pending.closed");
    this.changed(item);
  }

  // A chat card for a question or approval: the item's 看原文; a brief's card: its items'.
  private onMessage(m: ChatMessage): void {
    if (m.pal) return;
    const link = (i: PendingRecord) => {
      if (i.messageId) return;
      i.messageId = m.id;
      this.changed(i);
    };
    if (m.questionId) this.items.filter((i) => i.questionId === m.questionId).forEach(link);
    else if (m.approvalId) this.items.filter((i) => i.approvalId === m.approvalId).forEach(link);
    else if (m.card?.goalId) this.items.filter((i) => i.watchId === m.card!.goalId).forEach(link);
  }

  private find(id: string): PendingRecord {
    const item = this.items.find((x) => x.id === id);
    if (!item) throw new Error(t("pending.err.none"));
    return item;
  }

  private changed(item: PendingRecord): void {
    this.persist();
    this.bus.emit("pending.updated", wire(item));
  }

  private prune(): void {
    const cutoff = this.now() - KEEP_CLOSED_MS;
    this.items = this.items.filter((i) => i.status === "open" || i.status === "snoozed" || (i.resolvedAt ?? i.createdAt) >= cutoff);
  }

  private persist(): void {
    if (this.items.length > 500) this.prune();
    writeJson(this.path, this.items);
  }
}

function sameSource(a: PendingSource, b: PendingSource): boolean {
  return a.kind === b.kind && (a.id ?? "") === (b.id ?? "");
}

// The item as the apps get it (no store-only fields).
function wire(i: PendingRecord): PendingItem {
  const { watchId: _w, question: _q, ended: _e, ...rest } = i;
  return { ...rest, source: { ...rest.source }, ...(rest.link ? { link: { ...rest.link } } : {}) };
}

/** The open items as lines for the model: id, who, title. */
export function pendingLines(items: PendingItem[]): string {
  return items.map((i) => `- ${i.id}${i.blocking ? t("pending.line.blocking") : ""}: ${i.title}${i.source.name ? ` (${i.source.name})` : ""}`).join("\n");
}
