// Workspaces and the right pane's tab state (docs/workbench-rpc.md §3).
// A workspace is a set of sessions the owner tiles together. The host keeps
// who is in it and the layout tree as the app wrote it; it checks that the
// layout's leaves are members (or Palo's leaf, PALO_LEAF) and never looks at the geometry. Nothing here
// ends a session: leaving or deleting a workspace only turns a session back
// into an ordinary one. An empty workspace stays until workspaces.delete.
import type { Bus } from "./bus.ts";
import type { Paths } from "./config.ts";
import { t } from "./i18n/index.ts";
import type { LayoutNode, PaneTab, TabsState, Workspace } from "./types.ts";
import { newId, readJson, writeJson } from "./util.ts";

interface WorkbenchFile {
  /** In the owner's order (the sidebar), top first. */
  workspaces: Workspace[];
  /** The owner's order of the sessions in no workspace, top first. */
  sessionOrder: string[];
  tabs: Record<string, TabsState>;
}

export interface WorkbenchDeps {
  paths: Paths;
  bus: Bus;
  /** A session's id (given an id, a name or a session id); undefined when there is none. */
  resolvePal: (id: string) => string | undefined;
  /** Every session now, with the workspace its own record says. */
  palList: () => { id: string; workspaceId?: string }[];
  /** Writes (or clears) the workspace on a session's record. */
  setPalWorkspace: (palId: string, workspaceId: string | undefined) => void;
  /** Sessions changed (their workspaceId): tell the apps. */
  palsChanged: () => void;
  now?: () => number;
  log?: (s: string) => void;
}

const NAME_MAX = 40;

/** The leaf that shows Palo in a workspace: a view of the assistant, not a member (any workspace may have it, at most once). */
export const PALO_LEAF = "palo";

/** `current` re-ordered by `ids`: the ones named (and in `current`) first in that order, the rest after in their own order; unknown ids are ignored. */
function ordered(current: string[], ids: unknown[]): string[] {
  const have = new Set(current);
  const first = [...new Set(ids)].filter((id): id is string => typeof id === "string" && have.has(id));
  return [...first, ...current.filter((id) => !first.includes(id))];
}

function orderedBy<T extends { id: string }>(items: T[], ids: unknown[]): T[] {
  const order = ordered(items.map((x) => x.id), ids);
  return order.map((id) => items.find((x) => x.id === id)!);
}

/** `current` without `id`, then with it at `index` (clamped). */
function placed(current: string[], id: string, index: number): string[] {
  const rest = current.filter((x) => x !== id);
  rest.splice(Math.max(0, Math.min(Math.floor(index), rest.length)), 0, id);
  return rest;
}

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const obj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

/** Parses a layout tree; only the known fields are kept. */
function parseNode(v: unknown, leaves: string[], depth = 0): LayoutNode {
  const bad = () => new Error(t("wb.badLayout"));
  if (!obj(v) || depth > 32) throw bad();
  const { w, h, x, y } = v;
  if (!isNum(w) || !isNum(h) || !isNum(x) || !isNum(y)) throw bad();
  if (v.type === "leaf") {
    if (typeof v.session !== "string" || !v.session) throw bad();
    leaves.push(v.session);
    return { type: "leaf", session: v.session, w, h, x, y };
  }
  if ((v.type !== "hsplit" && v.type !== "vsplit") || !Array.isArray(v.children) || !v.children.length) throw bad();
  return { type: v.type, w, h, x, y, children: v.children.map((c) => parseNode(c, leaves, depth + 1)) };
}

export function leavesOf(node: LayoutNode | null): string[] {
  if (!node) return [];
  return node.type === "leaf" ? [node.session] : node.children.flatMap(leavesOf);
}

/** The tree without a session's leaf: a split left with one child is that child, and none is gone. */
function without(node: LayoutNode, session: string): LayoutNode | null {
  if (node.type === "leaf") return node.session === session ? null : node;
  const kids = node.children.map((c) => without(c, session)).filter((c): c is LayoutNode => !!c);
  if (!kids.length) return null;
  return kids.length === 1 ? kids[0]! : { ...node, children: kids };
}

/** Squeezes a tree into the left `f` of its width. */
function squeezeX(node: LayoutNode, f: number): LayoutNode {
  const n = { ...node, x: node.x * f, w: node.w * f };
  return n.type === "leaf" ? n : { ...n, children: n.children.map((c) => squeezeX(c, f)) } as LayoutNode;
}

/** The tree with a new leaf beside the rest: the old tree gives up a share of the width (the app evens it out). */
function withLeaf(node: LayoutNode, session: string): LayoutNode {
  const k = Math.max(1, leavesOf(node).length);
  const f = k / (k + 1);
  return {
    type: "hsplit",
    w: node.w,
    h: node.h,
    x: node.x,
    y: node.y,
    children: [squeezeX(node, f), { type: "leaf", session, w: node.w / (k + 1), h: node.h, x: node.x + node.w * f, y: node.y }],
  };
}

function parseTab(v: unknown): PaneTab {
  const bad = () => new Error(t("wb.badTabs"));
  if (!obj(v) || typeof v.kind !== "string" || !v.kind) throw bad();
  switch (v.kind) {
    case "files":
    case "library":
      return { kind: v.kind };
    case "preview":
      if (typeof v.path !== "string" || !v.path.trim()) throw bad();
      // The file's absolute path (older tabs: relative to the pane's files).
      // A `scope` an older app wrote is dropped.
      return { kind: "preview", path: v.path };
    case "artifact":
      // One item of 成果, by its id.
      if (typeof v.path !== "string" || !v.path.trim()) throw bad();
      return { kind: "artifact", path: v.path };
    case "web": {
      let ok = false;
      try {
        const u = new URL(String(v.url));
        ok = u.protocol === "http:" || u.protocol === "https:";
      } catch {
        ok = false;
      }
      if (!ok) throw bad();
      return { kind: "web", url: String(v.url) };
    }
    default:
      return { ...v, kind: v.kind }; // a newer app's kind: kept as written
  }
}

const tabId = (tab: PaneTab): string => (tab.kind === "preview" || tab.kind === "artifact" ? `${tab.kind}:${tab.path}` : tab.kind === "web" ? `web:${tab.url}` : tab.kind === "files" || tab.kind === "library" ? tab.kind : JSON.stringify(tab));

export class Workbench {
  private data: WorkbenchFile;
  private emitTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private d: WorkbenchDeps) {
    const saved = readJson<Partial<WorkbenchFile>>(d.paths.workbench, {});
    const workspaces = Array.isArray(saved.workspaces) ? saved.workspaces : [];
    // Before there was a manual order the list was newest write first: that is where the order starts.
    if (!Array.isArray(saved.sessionOrder)) workspaces.sort((a, b) => b.updatedAt - a.updatedAt);
    this.data = {
      workspaces,
      sessionOrder: Array.isArray(saved.sessionOrder) ? saved.sessionOrder.filter((x): x is string => typeof x === "string") : [],
      tabs: obj(saved.tabs) ? (saved.tabs as Record<string, TabsState>) : {},
    };
    this.reconcile();
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  private save(): void {
    writeJson(this.d.paths.workbench, this.data);
  }

  /** The two records of who is in what (here and on each session) agree again, and the dead are dropped. */
  private reconcile(): void {
    let changed = false;
    const pals = new Map(this.d.palList().map((p) => [p.id, p]));
    const seen = new Set<string>();
    for (const ws of this.data.workspaces) {
      const members = ws.memberIds.filter((id) => pals.has(id) && !seen.has(id));
      if (members.length !== ws.memberIds.length) {
        for (const id of ws.memberIds) if (!members.includes(id)) this.prune(ws, id);
        ws.memberIds = members;
        changed = true;
      }
      for (const id of members) {
        seen.add(id);
        if (pals.get(id)?.workspaceId !== ws.id) this.d.setPalWorkspace(id, ws.id);
      }
    }
    for (const p of pals.values()) if (p.workspaceId && !seen.has(p.id)) this.d.setPalWorkspace(p.id, undefined);
    for (const key of Object.keys(this.data.tabs)) {
      if (!this.tabsOwnerExists(key)) {
        delete this.data.tabs[key];
        changed = true;
      }
    }
    this.sessionOrder(); // settles the order (and saves it the first time)
    if (changed) this.save();
  }

  private tabsOwnerExists(key: string): boolean {
    if (key === "palo") return true;
    if (key.startsWith("pal:")) return this.d.resolvePal(key.slice(4)) === key.slice(4);
    if (key.startsWith("ws:")) return this.exists(key.slice(3));
    return false;
  }

  // ---------------- read ----------------

  exists(id: string): boolean {
    return this.data.workspaces.some((w) => w.id === id);
  }

  /** In the owner's order, top first. */
  list(): Workspace[] {
    return this.data.workspaces.map((w) => structuredClone(w));
  }

  /**
   * The sessions in no workspace, in the owner's order. A session the order doesn't know yet
   * (new, or from before there was an order) goes on top, in the sessions' own order; the dead are dropped.
   */
  sessionOrder(): string[] {
    const ordinary = this.d.palList().map((p) => p.id).filter((id) => !this.workspaceOf(id));
    const known = new Set(ordinary);
    const seen = new Set<string>();
    const kept = this.data.sessionOrder.filter((id) => known.has(id) && !seen.has(id) && !!seen.add(id));
    const fresh = ordinary.filter((id) => !seen.has(id));
    const order = [...fresh, ...kept];
    if (order.length !== this.data.sessionOrder.length || order.some((id, i) => id !== this.data.sessionOrder[i])) {
      this.data.sessionOrder = order;
      this.save();
    }
    return [...order];
  }

  /** The ordinary sessions with `palId` at `index` (clamped; none = the top). */
  private place(palId: string, index?: number): void {
    const rest = this.sessionOrder().filter((id) => id !== palId);
    const at = isNum(index) ? Math.max(0, Math.min(Math.floor(index), rest.length)) : 0;
    rest.splice(at, 0, palId);
    this.data.sessionOrder = rest;
  }

  /** A new session: on top of the ordinary ones (unless it starts in a workspace). */
  added(palId: string): void {
    if (this.workspaceOf(palId)) return;
    this.place(palId);
    this.save();
    this.emitNow();
  }

  /** Sessions that are leaves of some layout: the ones on screen, never put to sleep to make room. */
  shownIds(): Set<string> {
    return new Set(this.data.workspaces.flatMap((w) => leavesOf(w.layout)).filter((id) => id !== PALO_LEAF));
  }

  workspaceOf(palId: string): Workspace | undefined {
    return this.data.workspaces.find((w) => w.memberIds.includes(palId));
  }

  private must(id: unknown): Workspace {
    const ws = this.data.workspaces.find((w) => w.id === id);
    if (!ws) throw new Error(t("pals.noWorkspace"));
    return ws;
  }

  private mustPal(id: unknown): string {
    const pal = this.d.resolvePal(String(id ?? ""));
    if (!pal) throw new Error(t("pals.noPal"));
    return pal;
  }

  // ---------------- events ----------------

  /** Written: never the same stamp twice for one workspace, so an echo can be told from an older one. */
  private touch(ws: Workspace): void {
    ws.updatedAt = Math.max(this.now(), ws.updatedAt + 1);
  }

  emitNow(): void {
    if (this.emitTimer) clearTimeout(this.emitTimer);
    this.emitTimer = null;
    this.d.bus.emit("workspaces.updated", { workspaces: this.list(), sessionOrder: this.sessionOrder() });
  }

  private emitSoon(): void {
    if (this.emitTimer) return;
    this.emitTimer = setTimeout(() => {
      this.emitTimer = null;
      this.emitNow();
    }, 30);
    (this.emitTimer as any).unref?.();
  }

  // ---------------- membership ----------------

  /** The layout without this session's leaf. */
  private prune(ws: Workspace, palId: string): void {
    if (ws.layout) ws.layout = without(ws.layout, palId);
  }

  /** Out of whichever workspace it is in; that one stays even if it is now empty. Returns it. */
  private detach(palId: string): Workspace | undefined {
    const ws = this.workspaceOf(palId);
    if (!ws) return undefined;
    ws.memberIds = ws.memberIds.filter((id) => id !== palId);
    this.prune(ws, palId);
    this.touch(ws);
    return ws;
  }

  private attach(ws: Workspace, palId: string, leaf: boolean): void {
    if (!ws.memberIds.includes(palId)) ws.memberIds.push(palId);
    // A new session of a laid-out workspace gets a tile of its own; without a layout the app arranges them all.
    if (leaf && ws.layout && !leavesOf(ws.layout).includes(palId)) ws.layout = withLeaf(ws.layout, palId);
    this.touch(ws);
    this.d.setPalWorkspace(palId, ws.id);
  }

  /** A new or resumed session joins a workspace (pals.create, pals.resume), with a tile. */
  join(workspaceId: string, palId: string): void {
    const ws = this.must(workspaceId);
    const old = this.workspaceOf(palId);
    if (old && old !== ws) this.detach(palId);
    this.attach(ws, palId, true);
    this.save();
    this.emitNow();
  }

  /** A session is gone (ended, removed, handed back): out of its workspace and layout, its tabs dropped. */
  gone(palId: string): void {
    const ws = this.detach(palId);
    this.data.sessionOrder = this.data.sessionOrder.filter((id) => id !== palId);
    const key = `pal:${palId}`;
    const had = key in this.data.tabs;
    delete this.data.tabs[key];
    this.save();
    if (ws) this.emitNow();
    if (had) this.d.bus.emit("workbench.updated", { key, state: null });
  }

  // ---------------- workspaces.* ----------------

  private cleanName(v: unknown): string {
    const name = String(v ?? "").replace(/\s+/g, " ").trim();
    if ([...name].length > NAME_MAX) throw new Error(t("wb.nameLong"));
    return name;
  }

  create(o: { name?: unknown; memberIds?: unknown }): { workspace: Workspace } {
    const name = this.cleanName(o?.name);
    const raw = Array.isArray(o?.memberIds) ? o.memberIds : []; // none is fine: an empty workspace to fill later
    const ids = [...new Set(raw.map((id) => this.mustPal(id)))];
    const now = this.now();
    const ws: Workspace = { id: newId("ws_"), name, memberIds: [], layout: null, createdAt: now, updatedAt: now };
    for (const id of ids) this.detach(id);
    this.data.workspaces.unshift(ws);
    for (const id of ids) this.attach(ws, id, false);
    ws.updatedAt = now;
    this.save();
    this.emitNow();
    this.d.palsChanged();
    return { workspace: structuredClone(ws) };
  }

  update(o: { id?: unknown; name?: unknown; layout?: unknown; memberIds?: unknown }): { workspace: Workspace } {
    const ws = this.must(o?.id);
    let name = ws.name;
    if (o.name !== undefined) name = this.cleanName(o.name);
    let layout = ws.layout;
    if (o.layout !== undefined) {
      if (o.layout === null) layout = null;
      else {
        const leaves: string[] = [];
        layout = parseNode(o.layout, leaves);
        if (new Set(leaves).size !== leaves.length) throw new Error(t("wb.layoutDupe"));
        if (leaves.some((id) => id !== PALO_LEAF && !ws.memberIds.includes(id))) throw new Error(t("wb.layoutNotMember"));
      }
    }
    ws.name = name;
    ws.layout = layout;
    if (o.memberIds !== undefined) {
      if (!Array.isArray(o.memberIds)) throw new Error(t("wb.badOrder"));
      ws.memberIds = ordered(ws.memberIds, o.memberIds);
    }
    this.touch(ws);
    this.save();
    this.emitNow();
    return { workspace: structuredClone(ws) };
  }

  /** Into a workspace, out of one, or from one to another. Returns the workspaces it changed. */
  move(o: { palId?: unknown; workspaceId?: unknown; index?: unknown }): { workspaces: Workspace[] } {
    const palId = this.mustPal(o?.palId);
    const target = o.workspaceId === undefined || o.workspaceId === null || o.workspaceId === "" ? undefined : this.must(o.workspaceId);
    const old = this.workspaceOf(palId);
    const changed = new Set<Workspace>();
    const index = isNum(o.index) ? o.index : undefined;
    if (old !== target) {
      if (old) {
        this.detach(palId);
        changed.add(old);
      }
      if (target) {
        this.attach(target, palId, false);
        if (index !== undefined) target.memberIds = placed(target.memberIds, palId, index);
        changed.add(target);
      } else {
        this.d.setPalWorkspace(palId, undefined);
        this.place(palId, index); // out of a workspace: the top, unless it says where
      }
      this.save();
      this.emitNow();
      this.d.palsChanged();
    } else if (index !== undefined) {
      // Already there: only its place moves.
      if (target) {
        target.memberIds = placed(target.memberIds, palId, index);
        this.touch(target);
      } else this.place(palId, index);
      this.save();
      this.emitNow();
      if (target) changed.add(target);
    } else if (target) changed.add(target);
    return { workspaces: [...changed].map((w) => structuredClone(w)) };
  }

  /** workbench.order.set: the owner's order of the ordinary sessions, or of the workspaces. */
  orderSet(o: { kind?: unknown; ids?: unknown }): { sessionOrder: string[]; workspaceOrder: string[] } {
    if ((o?.kind !== "sessions" && o?.kind !== "workspaces") || !Array.isArray(o.ids)) throw new Error(t("wb.badOrder"));
    if (o.kind === "sessions") this.data.sessionOrder = ordered(this.sessionOrder(), o.ids);
    else this.data.workspaces = orderedBy(this.data.workspaces, o.ids);
    this.save();
    this.emitNow();
    return { sessionOrder: this.sessionOrder(), workspaceOrder: this.data.workspaces.map((w) => w.id) };
  }

  delete(o: { id?: unknown }): { ok: true } {
    const ws = this.must(o?.id);
    this.data.workspaces = this.data.workspaces.filter((w) => w !== ws);
    for (const id of ws.memberIds) this.d.setPalWorkspace(id, undefined);
    this.data.sessionOrder = [...ws.memberIds, ...this.data.sessionOrder.filter((id) => !ws.memberIds.includes(id))];
    const key = `ws:${ws.id}`;
    const had = key in this.data.tabs;
    delete this.data.tabs[key];
    this.save();
    this.emitNow();
    this.d.palsChanged();
    if (had) this.d.bus.emit("workbench.updated", { key, state: null });
    return { ok: true };
  }

  // ---------------- workbench.tabs.* ----------------

  tabsGet(o: { key?: unknown } = {}): { states: Record<string, TabsState> } {
    if (typeof o?.key === "string" && o.key) {
      const s = this.data.tabs[o.key];
      return { states: s ? { [o.key]: structuredClone(s) } : {} };
    }
    return { states: this.allTabs() };
  }

  allTabs(): Record<string, TabsState> {
    return structuredClone(this.data.tabs);
  }

  tabsSet(o: { key?: unknown; tabs?: unknown; active?: unknown; open?: unknown }): { state: TabsState } {
    const key = typeof o?.key === "string" ? o.key : "";
    if (key !== "palo" && !/^(pal|ws):.+/.test(key)) throw new Error(t("wb.badTabsKey"));
    if (!this.tabsOwnerExists(key)) throw new Error(t("wb.noTabsOwner"));
    if (!Array.isArray(o.tabs) || typeof o.open !== "boolean") throw new Error(t("wb.badTabs"));
    const tabs: PaneTab[] = [];
    const seen = new Set<string>();
    for (const raw of o.tabs) {
      const tab = parseTab(raw);
      const id = tabId(tab);
      if (seen.has(id)) continue;
      seen.add(id);
      tabs.push(tab);
    }
    const asked = isNum(o.active) ? Math.floor(o.active) : 0;
    const active = Math.max(0, Math.min(asked, tabs.length - 1));
    const prev = this.data.tabs[key];
    const state: TabsState = { tabs, active, open: o.open, updatedAt: Math.max(this.now(), (prev?.updatedAt ?? 0) + 1) };
    this.data.tabs[key] = state;
    this.save();
    this.d.bus.emit("workbench.updated", { key, state: structuredClone(state) });
    return { state: structuredClone(state) };
  }
}
