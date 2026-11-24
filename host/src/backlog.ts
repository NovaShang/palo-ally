import { createHash } from "node:crypto";
import { readFileSync, realpathSync, renameSync, statSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { basename, join, resolve } from "node:path";
import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { Backlog, BacklogItem } from "./types.ts";
import { ensureDir, expandHome, newId, truncate } from "./util.ts";
import { t } from "./i18n/index.ts";

// 待办 (docs/workbench-design/backlog.html; the owner's decision of 11-22):
// what the owner wants done and hasn't got to yet, one list per FOLDER,
// shared by every agent working in it, the assistant's being its own
// folder's. Kept by the host, never in the folder itself: one Markdown file
// per folder under state/backlog/, named after the folder (its name and a
// hash of its path) with the path written inside. One line per item, top
// first; the ones being done marked [>] with who does them, the done ones
// [x] at the end. The file is the truth and may be edited by hand: it's read
// again whenever it changed, lines without an id get one from their words
// (the same every time, so nothing is rewritten just for reading), and
// unknown marks read as queued. `backlog.updated` carries each change.

/** Done items kept in a list (the oldest go first). */
const KEEP_DONE = 50;
const TEXT_MAX = 300;
const NOTE_MAX = 1000;

export interface BacklogDeps {
  /** state/backlog */
  dir: string;
  bus: Bus;
  audit?: Audit;
  /** The assistant's own folder: its list is the assistant's. */
  assistantFolder: () => string;
  /** An agent's name now (a rename shows on its items). */
  palName?: (id: string) => string | undefined;
  now?: () => number;
}

interface Cached {
  mtimeMs: number;
  size: number;
  items: BacklogItem[];
}

/** A folder as the lists are keyed: absolute, ~ expanded, as the disk names it (/tmp → /private/tmp), no trailing slash. */
export function backlogFolder(p: string): string {
  let f = resolve(expandHome(p.trim()));
  try {
    f = realpathSync(f);
  } catch {
    /* gone or not there yet: as given */
  }
  return f.length > 1 ? f.replace(/\/+$/, "") : f;
}

export class BacklogStore {
  private cache = new Map<string, Cached>();
  /** What this process last wrote to each file, to tell a hand edit from our own write. */
  private written = new Map<string, string>();
  private watcher: FSWatcher | null = null;
  private timers = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(private d: BacklogDeps) {}

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  /** The file a folder's list lives in. */
  fileOf(folder: string): string {
    const slug = (basename(folder) || "root").replace(/[^\p{L}\p{N}._-]+/gu, "-").slice(0, 40) || "folder";
    const hash = createHash("sha256").update(folder).digest("hex").slice(0, 12);
    return join(this.d.dir, `${slug}-${hash}.md`);
  }

  list(folder: string): Backlog {
    return this.wire(folder, this.read(folder));
  }

  /** A new item, at the end of the queue (or its top). `n`: its place in the queue, from 1. */
  add(folder: string, n: { text: string; note?: string; top?: boolean }, by: string): { item: BacklogItem; n: number; backlog: Backlog } {
    const text = cleanText(n.text);
    if (!text) throw new Error(t("backlog.err.empty"));
    const items = this.read(folder);
    const note = cleanNote(n.note);
    const item: BacklogItem = { id: newId("b_"), text, ...(note ? { note } : {}), state: "queued", addedAt: this.now() };
    const queued = items.filter((i) => i.state === "queued");
    const at = n.top ? 0 : queued.length;
    items.splice(this.queueIndex(items, at), 0, item);
    this.write(folder, items);
    this.d.audit?.log("backlog.added", { id: item.id, by });
    return { item: { ...item }, n: at + 1, backlog: this.changed(folder, items) };
  }

  /** To a place in the queue (0 = top); a done or started one goes back in line there. */
  move(folder: string, id: string, to: number, by: string): Backlog {
    const items = this.read(folder);
    const item = take(items, id);
    if (item.state !== "queued") {
      if (item.state === "doing") delete item.pal, delete item.palName;
      item.state = "queued";
      delete item.doneAt;
    }
    const queued = items.filter((i) => i.state === "queued").length;
    const at = Math.max(0, Math.min(Number.isFinite(to) ? Math.floor(to) : queued, queued));
    items.splice(this.queueIndex(items, at), 0, item);
    this.write(folder, items);
    this.d.audit?.log("backlog.moved", { id, to: at, by });
    return this.changed(folder, items);
  }

  /** Meant for one agent of the folder (its 下一件 offers it first, the others skip it); null: anyone's. */
  assign(folder: string, id: string, pal: string | null, by: string): Backlog {
    const items = this.read(folder);
    const item = find(items, id);
    if (pal) {
      item.pal = pal;
      const name = this.d.palName?.(pal);
      if (name) item.palName = name;
      else delete item.palName;
    } else {
      delete item.pal;
      delete item.palName;
    }
    this.write(folder, items);
    this.d.audit?.log("backlog.assigned", { id, pal: pal ?? null, by });
    return this.changed(folder, items);
  }

  /** Its words or note changed (an empty note: none); what isn't given stays. */
  update(folder: string, id: string, patch: { text?: string; note?: string }, by: string): { item: BacklogItem; backlog: Backlog } {
    const items = this.read(folder);
    const item = find(items, id);
    if (patch.text !== undefined) {
      const text = cleanText(patch.text);
      if (!text) throw new Error(t("backlog.err.empty"));
      item.text = text;
    }
    if (patch.note !== undefined) {
      const note = cleanNote(patch.note);
      if (note) item.note = note;
      else delete item.note;
    }
    this.write(folder, items);
    this.d.audit?.log("backlog.updated", { id, by });
    return { item: { ...item }, backlog: this.changed(folder, items) };
  }

  /** A removed item back as it was (its id, its agent, its state), at place `to` among the ones in its state. */
  restore(folder: string, raw: unknown, to: number, by: string): Backlog {
    const items = this.read(folder);
    const item = cleanItem(raw);
    if (items.some((i) => i.id === item.id)) return this.wire(folder, items);
    const before = items.filter((i) => i.state === item.state);
    const at = Math.max(0, Math.min(Number.isFinite(to) ? Math.floor(to) : before.length, before.length));
    const next = before[at];
    if (next) items.splice(items.indexOf(next), 0, item);
    else items.push(item); // the list is put in order as it's written
    this.write(folder, items);
    this.d.audit?.log("backlog.restored", { id: item.id, to: at, by });
    return this.changed(folder, items);
  }

  /** Being done now, by an agent (or the owner, no agent; null: the assistant, no longer anyone's): it leads the list. */
  start(folder: string, id: string, pal: string | null | undefined, by: string): Backlog {
    const items = this.read(folder);
    const item = take(items, id);
    item.state = "doing";
    delete item.doneAt;
    if (pal) {
      item.pal = pal;
      const name = this.d.palName?.(pal);
      if (name) item.palName = name;
      else delete item.palName;
    } else if (pal === null) {
      delete item.pal;
      delete item.palName;
    }
    const doing = items.filter((i) => i.state === "doing").length;
    items.splice(doing, 0, item);
    this.write(folder, items);
    this.d.audit?.log("backlog.started", { id, ...(pal ? { pal } : {}), by });
    return this.changed(folder, items);
  }

  /** Done (to the end of the list), or not after all (back on top of the queue). */
  done(folder: string, id: string, isDone: boolean, by: string): { item: BacklogItem; backlog: Backlog } {
    const items = this.read(folder);
    const item = take(items, id);
    if (isDone) {
      item.state = "done";
      item.doneAt = this.now();
      items.push(item);
    } else {
      item.state = "queued";
      delete item.doneAt;
      delete item.pal;
      delete item.palName;
      items.splice(this.queueIndex(items, 0), 0, item);
    }
    this.write(folder, items);
    this.d.audit?.log(isDone ? "backlog.done" : "backlog.undone", { id, by });
    return { item: { ...item }, backlog: this.changed(folder, items) };
  }

  remove(folder: string, id: string, by: string): Backlog {
    const items = this.read(folder);
    take(items, id);
    this.write(folder, items);
    this.d.audit?.log("backlog.removed", { id, by });
    return this.changed(folder, items);
  }

  /** The item with this id in the folder's list. */
  get(folder: string, id: string): BacklogItem | undefined {
    const i = this.read(folder).find((x) => x.id === id);
    return i ? { ...i } : undefined;
  }

  // ---- hand edits ----

  /** Follows the files: a list edited by hand (or by an agent with its own tools) is sent to the apps. */
  watch(): void {
    if (this.watcher) return;
    ensureDir(this.d.dir);
    try {
      this.watcher = watch(this.d.dir, (_e, name) => {
        if (!name || !String(name).endsWith(".md")) return;
        const file = join(this.d.dir, String(name));
        clearTimeout(this.timers.get(file));
        this.timers.set(
          file,
          setTimeout(() => {
            this.timers.delete(file);
            this.noticeEdit(file);
          }, 150),
        );
      });
    } catch {
      this.watcher = null;
    }
  }

  close(): void {
    this.watcher?.close();
    this.watcher = null;
    for (const t of this.timers.values()) clearTimeout(t);
    this.timers.clear();
  }

  /** A file changed on disk: unless it's what we wrote, its folder's list is sent again. */
  noticeEdit(file: string): void {
    let text: string;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      text = "";
    }
    if (this.written.get(file) === text) return;
    const folder = headerFolder(text) ?? [...this.cache.keys()].find((f) => this.fileOf(f) === file);
    if (!folder) return;
    this.cache.delete(folder);
    this.written.delete(file);
    this.d.bus.emit("backlog.updated", this.list(folder));
  }

  // ---- the file ----

  private read(folder: string): BacklogItem[] {
    const file = this.fileOf(folder);
    let st: { mtimeMs: number; size: number } | null = null;
    try {
      st = statSync(file);
    } catch {
      st = null;
    }
    if (!st) {
      this.cache.delete(folder);
      return [];
    }
    const c = this.cache.get(folder);
    if (c && c.mtimeMs === st.mtimeMs && c.size === st.size) return c.items.map((i) => ({ ...i }));
    let items: BacklogItem[];
    try {
      items = parseBacklog(readFileSync(file, "utf8"), folder);
    } catch {
      items = [];
    }
    this.cache.set(folder, { mtimeMs: st.mtimeMs, size: st.size, items: items.map((i) => ({ ...i })) });
    return items;
  }

  private write(folder: string, items: BacklogItem[]): void {
    const ordered = order(items);
    const done = ordered.filter((i) => i.state === "done");
    const kept = done.length > KEEP_DONE ? ordered.filter((i) => i.state !== "done" || done.indexOf(i) >= done.length - KEEP_DONE) : ordered;
    const file = this.fileOf(folder);
    const text = formatBacklog(folder, kept);
    ensureDir(this.d.dir);
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, text, { mode: 0o600 });
    renameSync(tmp, file);
    this.written.set(file, text);
    items.splice(0, items.length, ...kept);
    try {
      const st = statSync(file);
      this.cache.set(folder, { mtimeMs: st.mtimeMs, size: st.size, items: kept.map((i) => ({ ...i })) });
    } catch {
      this.cache.delete(folder);
    }
  }

  private changed(folder: string, items: BacklogItem[]): Backlog {
    const b = this.wire(folder, items);
    this.d.bus.emit("backlog.updated", b);
    return b;
  }

  /** Where the queue's `at`th place is in the whole list (after the ones being done). */
  private queueIndex(items: BacklogItem[], at: number): number {
    let seen = 0;
    for (let i = 0; i < items.length; i++) {
      const s = items[i]!.state;
      if (s === "done") return i;
      if (s === "queued") {
        if (seen === at) return i;
        seen++;
      }
    }
    return items.length;
  }

  private wire(folder: string, items: BacklogItem[]): Backlog {
    const assistant = folder === backlogFolder(this.d.assistantFolder());
    return {
      folder,
      name: basename(folder) || folder,
      ...(assistant ? { assistant: true } : {}),
      editable: true,
      items: order(items).map((i) => {
        const name = i.pal ? this.d.palName?.(i.pal) : undefined;
        return { ...i, ...(name ? { palName: name } : {}) };
      }),
    };
  }
}

// ---- the Markdown ----

const HEADER = /^<!--\s*palo-backlog:\s*(.+?)\s*-->\s*$/;
const ITEM = /^[-*+]\s+(?:\[(.?)\]\s*)?(.*)$/;
const NUMBERED = /^\d+[.)]\s+(?:\[(.?)\]\s*)?(.*)$/;
const META = /\s*<!--(.*?)-->\s*$/;
const WHO = /\s*\(@([^()]*)\)\s*$/;

function headerFolder(text: string): string | undefined {
  for (const line of text.split("\n").slice(0, 5)) {
    const m = HEADER.exec(line.trim());
    if (m) return m[1];
  }
  return undefined;
}

/** The list a folder's file holds, however it was edited. */
export function parseBacklog(text: string, folder: string): BacklogItem[] {
  const items: BacklogItem[] = [];
  const seen = new Map<string, number>();
  const ids = new Set<string>();
  let last: BacklogItem | null = null;
  let inComment = false;
  for (const raw of text.replace(/\r\n?/g, "\n").split("\n")) {
    const trimmed = raw.trim();
    // A comment of several lines (the file's own header, or someone's) says nothing.
    if (inComment) {
      if (trimmed.includes("-->")) inComment = false;
      continue;
    }
    if (!trimmed) {
      last = null;
      continue;
    }
    if (trimmed.startsWith("<!--")) {
      if (!trimmed.includes("-->")) inComment = true;
      continue;
    }
    if (trimmed.startsWith("#")) {
      last = null;
      continue;
    }
    // An indented line under an item is its note.
    if (/^(\s{2,}|\t)/.test(raw) && last) {
      last.note = cleanNote(last.note ? `${last.note}\n${trimmed}` : trimmed);
      continue;
    }
    const m = ITEM.exec(trimmed) ?? NUMBERED.exec(trimmed);
    const mark = m ? (m[1] ?? "") : "";
    let body = m ? m[2]! : trimmed;
    const meta: Record<string, string> = {};
    const mm = META.exec(body);
    if (mm) {
      body = body.slice(0, mm.index);
      for (const tok of mm[1]!.trim().split(/\s+/)) {
        const c = tok.indexOf(":");
        if (c > 0) meta[tok.slice(0, c)] = tok.slice(c + 1);
        else if (/^b_\w+$/.test(tok)) meta.id = tok;
      }
    }
    const state: BacklogItem["state"] = /^[xX✓]$/.test(mark) ? "done" : /^[>~*]$/.test(mark) ? "doing" : "queued";
    let palName: string | undefined;
    const w = WHO.exec(body);
    if (w) {
      palName = w[1]!.trim() || undefined;
      body = body.slice(0, w.index);
    }
    const text = cleanText(body);
    if (!text) continue;
    // No id (written by hand): one from its words, the same on every read.
    let id = meta.id && /^b_[\w-]+$/.test(meta.id) && !ids.has(meta.id) ? meta.id : "";
    if (!id) {
      const k = `${state}\u0000${text}`;
      const n = seen.get(k) ?? 0;
      seen.set(k, n + 1);
      id = "b_" + createHash("sha1").update(`${folder}\u0000${text}\u0000${n}`).digest("hex").slice(0, 12);
      while (ids.has(id)) id = "b_" + createHash("sha1").update(id).digest("hex").slice(0, 12);
    }
    ids.add(id);
    const item: BacklogItem = { id, text, state };
    const pal = meta.pal || meta.for;
    if (pal) item.pal = pal;
    if (palName) item.palName = palName;
    const at = Number(meta.at);
    if (at > 0) item.addedAt = at;
    const done = Number(meta.done);
    if (state === "done" && done > 0) item.doneAt = done;
    items.push(item);
    last = item;
  }
  return order(items);
}

/** The file for a folder's list. */
export function formatBacklog(folder: string, items: BacklogItem[]): string {
  const lines = [`<!-- palo-backlog: ${folder} -->`, `<!-- ${t("backlog.file.hint")} -->`, `# ${t("backlog.file.title", { name: basename(folder) || folder })}`, ""];
  for (const i of order(items)) {
    const mark = i.state === "done" ? "x" : i.state === "doing" ? ">" : " ";
    const who = i.palName ? ` (@${i.palName.replace(/[()]/g, "")})` : "";
    const meta = [i.id, i.pal ? `pal:${i.pal}` : "", i.addedAt ? `at:${i.addedAt}` : "", i.doneAt ? `done:${i.doneAt}` : ""].filter(Boolean).join(" ");
    lines.push(`- [${mark}] ${i.text}${who} <!-- ${meta} -->`);
    if (i.note) for (const n of i.note.split("\n")) lines.push(`  ${n}`);
  }
  return lines.join("\n") + "\n";
}

/** Being done first, then the queue, then the done ones, each in its order. */
function order(items: BacklogItem[]): BacklogItem[] {
  return [...items.filter((i) => i.state === "doing"), ...items.filter((i) => i.state === "queued"), ...items.filter((i) => i.state === "done")];
}

function cleanText(s: unknown): string {
  return truncate(
    String(s ?? "")
      .replace(/<!--|-->/g, "")
      .replace(/\s+/g, " ")
      .trim(),
    TEXT_MAX,
  );
}

function cleanNote(s: unknown): string {
  const lines = String(s ?? "")
    .replace(/<!--|-->/g, "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  return truncate(lines.join("\n"), NOTE_MAX);
}

/** An item as an app sends it back (backlog.restore). */
function cleanItem(raw: unknown): BacklogItem {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const text = cleanText(r.text);
  if (!text) throw new Error(t("backlog.err.empty"));
  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  const num = (v: unknown) => (typeof v === "number" && v > 0 ? v : undefined);
  const id = str(r.id);
  const note = cleanNote(r.note);
  const state: BacklogItem["state"] = r.state === "doing" || r.state === "done" ? r.state : "queued";
  const pal = str(r.pal);
  const palName = str(r.palName);
  const addedAt = num(r.addedAt);
  const doneAt = state === "done" ? num(r.doneAt) : undefined;
  return {
    id: /^b_[\w-]+$/.test(id) ? id : newId("b_"),
    text,
    ...(note ? { note } : {}),
    state,
    ...(/^[\w-]+$/.test(pal) ? { pal, ...(palName ? { palName } : {}) } : {}),
    ...(addedAt ? { addedAt } : {}),
    ...(doneAt ? { doneAt } : {}),
  };
}

function find(items: BacklogItem[], id: string): BacklogItem {
  const i = items.find((x) => x.id === id);
  if (!i) throw new Error(t("backlog.err.none"));
  return i;
}

function take(items: BacklogItem[], id: string): BacklogItem {
  const at = items.findIndex((x) => x.id === id);
  if (at < 0) throw new Error(t("backlog.err.none"));
  return items.splice(at, 1)[0]!;
}

/** The list as lines for the model: id, state, words. */
export function backlogLines(b: Backlog): string {
  let n = 0;
  return b.items
    .map((i) => {
      const where = i.state === "doing" ? t("backlog.line.doing", { who: i.palName ?? "" }) : i.state === "done" ? t("backlog.line.done") : `${++n}`;
      return `- ${i.id} [${where}] ${i.text}${i.note ? ` (${i.note.replace(/\n/g, " / ")})` : ""}`;
    })
    .join("\n");
}
