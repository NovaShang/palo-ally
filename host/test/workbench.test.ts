import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import type { PalsDeps, PalsTiming } from "../src/pals.ts";
import { leavesOf } from "../src/workbench.ts";
import { handleRpc } from "../src/rpc.ts";
import type { LayoutNode } from "../src/types.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli } from "./fakeClaude.ts";
import { makeHub, testConfig, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
});

const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
const echo: FakeScript = async (text, ctx) => {
  ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null, messageId: `m_${Math.random()}` });
};

function setup(o: { maxAwake?: number; paths?: ReturnType<typeof tmpPaths>; claude?: FakeClaudeDir; pals?: Partial<PalsDeps> } = {}) {
  const claude = o.claude ?? new FakeClaudeDir();
  if (!o.claude) dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const paths = o.paths ?? tmpPaths();
  const config = testConfig((c) => {
    if (o.maxAwake !== undefined) c.settings.maxAwake = o.maxAwake;
  });
  const ctx = makeHub({
    paths,
    config,
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false), readMessages: async () => [] },
    pals: { readMessages: async () => [], timing: { ...FAST, sleepCheckMs: 30 }, ...o.pals },
  });
  ctx.driver.spawnPals = false;
  ctx.driver.palScript = echo;
  ctx.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-wb-")));
  const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(ctx.hub, { method, params }, app)) ?? null));
  const mk = async (name: string, extra: Record<string, unknown> = {}) => (await call("pals.create", { cwd: project, name, ...extra })).pal as { id: string; sessionId: string; workspaceId?: string };
  const pal = (id: string) => ctx.hub.pals.list().find((p) => p.id === id)!;
  const last = (event: string) => ctx.events.filter((e) => e.event === event).at(-1)?.data;
  return { ...ctx, claude, project, call, mk, pal, last };
}
type T = ReturnType<typeof setup>;

const leaf = (session: string, x: number, w: number): LayoutNode => ({ type: "leaf", session, w, h: 1, x, y: 0 });
const row = (...ids: string[]): LayoutNode => ({ type: "hsplit", w: 1, h: 1, x: 0, y: 0, children: ids.map((id, i) => leaf(id, i / ids.length, 1 / ids.length)) });

describe("workspaces", () => {
  test("create, list, rename, delete: ids, members in order, no layout yet, newest write first", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const { workspace } = await t.call("workspaces.create", { name: "官网", memberIds: [a.id, b.id, a.id] });
    expect(workspace).toMatchObject({ name: "官网", memberIds: [a.id, b.id], layout: null });
    expect(workspace.id).toMatch(/^ws_[0-9a-f]{12}$/);
    expect(t.pal(a.id).workspaceId).toBe(workspace.id);
    expect(t.last("workspaces.updated").workspaces).toEqual([workspace]);
    expect(t.last("pals.updated").pals.find((p: any) => p.id === b.id).workspaceId).toBe(workspace.id);
    const c = await t.mk("丙");
    const second = (await t.call("workspaces.create", { memberIds: [c.id] })).workspace;
    expect(second.name).toBe("");
    expect((await t.call("workspaces.list")).workspaces.map((w: any) => w.id)).toEqual([second.id, workspace.id]);
    const renamed = (await t.call("workspaces.update", { id: workspace.id, name: "官网改版" })).workspace;
    expect(renamed).toMatchObject({ name: "官网改版", memberIds: [a.id, b.id] });
    expect(renamed.updatedAt).toBeGreaterThan(workspace.updatedAt);
    expect((await t.call("workspaces.list")).workspaces[0].id).toBe(workspace.id);
    // every write is echoed to every device, the sender too
    expect(t.last("workspaces.updated").workspaces[0]).toEqual(renamed);
    // an empty workspace is allowed (and so is leaving memberIds out): created to be filled later, kept until deleted
    const empty = (await t.call("workspaces.create", { name: "空的", memberIds: [] })).workspace;
    expect(empty).toMatchObject({ name: "空的", memberIds: [], layout: null });
    expect((await t.call("workspaces.create", {})).workspace.memberIds).toEqual([]);
    expect((await t.call("workspaces.move", { palId: c.id, workspaceId: empty.id })).workspaces.find((w: any) => w.id === empty.id).memberIds).toEqual([c.id]);
    await expect(t.call("workspaces.create", { memberIds: ["pal_nope"] })).rejects.toThrow("找不到这个会话");
    await expect(t.call("workspaces.create", { name: "长".repeat(41), memberIds: [a.id] })).rejects.toThrow("40");
    await expect(t.call("workspaces.update", { id: "ws_nope", name: "x" })).rejects.toThrow("找不到这个工作区");
    await expect(t.call("workspaces.delete", { id: "ws_nope" })).rejects.toThrow("找不到这个工作区");
    await t.hub.pals.stopAndWait();
  });

  test("a session is in at most one workspace: create and move take it out of the old one, which stays even when empty", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const one = (await t.call("workspaces.create", { name: "一", memberIds: [a.id, b.id] })).workspace;
    const two = (await t.call("workspaces.create", { name: "二", memberIds: [a.id] })).workspace;
    let list = (await t.call("workspaces.list")).workspaces;
    expect(list.find((w: any) => w.id === one.id).memberIds).toEqual([b.id]);
    expect(t.pal(a.id).workspaceId).toBe(two.id);
    // move b into two: one is now empty and is kept
    const moved = (await t.call("workspaces.move", { palId: b.id, workspaceId: two.id })).workspaces;
    expect(moved.map((w: any) => w.id).sort()).toEqual([one.id, two.id].sort());
    list = (await t.call("workspaces.list")).workspaces;
    expect(list.find((w: any) => w.id === one.id)).toMatchObject({ memberIds: [], name: "一" });
    expect(list.find((w: any) => w.id === two.id).memberIds).toEqual([a.id, b.id]);
    // out of any workspace
    const out = (await t.call("workspaces.move", { palId: a.id })).workspaces;
    expect(out.map((w: any) => w.id)).toEqual([two.id]);
    expect(t.pal(a.id).workspaceId).toBeUndefined();
    expect(t.pal(b.id).workspaceId).toBe(two.id);
    await expect(t.call("workspaces.move", { palId: "pal_nope", workspaceId: two.id })).rejects.toThrow("找不到这个会话");
    await expect(t.call("workspaces.move", { palId: a.id, workspaceId: "ws_nope" })).rejects.toThrow("找不到这个工作区");
    // the last one leaving does not delete the workspace
    await t.call("workspaces.move", { palId: b.id });
    expect((await t.call("workspaces.list")).workspaces).toHaveLength(2);
    expect((await t.call("workspaces.list")).workspaces.every((w: any) => w.memberIds.length === 0)).toBe(true);
    await t.hub.pals.stopAndWait();
  });

  test("layout: leaves must be members and appear once; geometry is stored as written; null clears it", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const c = await t.mk("丙");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id, b.id] })).workspace;
    const layout = row(a.id, b.id);
    const set = (await t.call("workspaces.update", { id: ws.id, layout })).workspace;
    expect(set.layout).toEqual(layout);
    // a layout lagging behind the members is fine (a member not yet tiled)
    expect((await t.call("workspaces.update", { id: ws.id, layout: leaf(a.id, 0, 1) })).workspace.layout).toEqual(leaf(a.id, 0, 1));
    await expect(t.call("workspaces.update", { id: ws.id, layout: row(a.id, c.id) })).rejects.toThrow("不属于");
    await expect(t.call("workspaces.update", { id: ws.id, layout: row(a.id, a.id) })).rejects.toThrow("不止一次");
    await expect(t.call("workspaces.update", { id: ws.id, layout: { type: "blob" } })).rejects.toThrow("布局");
    await expect(t.call("workspaces.update", { id: ws.id, layout: { type: "leaf", session: a.id, w: "1", h: 1, x: 0, y: 0 } })).rejects.toThrow("布局");
    expect((await t.call("workspaces.list")).workspaces[0].layout).toEqual(leaf(a.id, 0, 1));
    expect((await t.call("workspaces.update", { id: ws.id, layout: null })).workspace.layout).toBeNull();
    // name only: the layout is left alone
    await t.call("workspaces.update", { id: ws.id, layout });
    expect((await t.call("workspaces.update", { id: ws.id, name: "新名" })).workspace.layout).toEqual(layout);
    await t.hub.pals.stopAndWait();
  });

  test("delete turns the members back into ordinary sessions without ending them, and drops the workspace's tabs", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id, b.id] })).workspace;
    await t.call("workbench.tabs.set", { key: `ws:${ws.id}`, tabs: [{ kind: "files" }], open: true });
    expect(await t.call("workspaces.delete", { id: ws.id })).toEqual({ ok: true });
    expect((await t.call("workspaces.list")).workspaces).toEqual([]);
    expect(t.last("workspaces.updated")).toEqual({ workspaces: [] });
    expect(t.hub.pals.list().map((p) => [p.name, p.workspaceId])).toEqual(expect.arrayContaining([["甲", undefined], ["乙", undefined]]));
    expect(t.hub.pals.list()).toHaveLength(2);
    expect(t.last("workbench.updated")).toEqual({ key: `ws:${ws.id}`, state: null });
    expect((await t.call("workbench.tabs.get")).states).toEqual({});
    expect(t.pal(a.id).status).not.toBe("stopped");
    await t.hub.pals.stopAndWait();
  });

  test("restart restores workspaces, layouts, tabs and each session's workspace; dead members are dropped", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const ws = (await t.call("workspaces.create", { name: "官网", memberIds: [a.id, b.id] })).workspace;
    await t.call("workspaces.update", { id: ws.id, layout: row(a.id, b.id) });
    await t.call("workbench.tabs.set", { key: "palo", tabs: [{ kind: "library" }], active: 0, open: true });
    await t.call("workbench.tabs.set", { key: `ws:${ws.id}`, tabs: [{ kind: "web", url: "https://example.com" }], open: false });
    const before = (await t.call("workspaces.list")).workspaces;
    const tabs = (await t.call("workbench.tabs.get")).states;
    await t.hub.pals.stopAndWait();
    const again = setup({ paths: t.paths, claude: t.claude });
    expect((await again.call("workspaces.list")).workspaces).toEqual(before);
    expect((await again.call("workbench.tabs.get")).states).toEqual(tabs);
    expect(again.pal(a.id).workspaceId).toBe(ws.id);
    expect((await again.call("sync", {})).workspaces).toEqual(before);
    expect((await again.call("sync", {})).workbenchTabs).toEqual(tabs);
    await again.hub.pals.stopAndWait();
    // a session that is gone from pals.json is dropped from the workspace and its layout on the next start
    const raw = JSON.parse(readFileSync(t.paths.pals, "utf8"));
    raw.pals = raw.pals.filter((p: any) => p.id !== b.id);
    await Bun.write(t.paths.pals, JSON.stringify(raw));
    const third = setup({ paths: t.paths, claude: t.claude });
    const w = (await third.call("workspaces.list")).workspaces[0];
    expect(w.memberIds).toEqual([a.id]);
    expect(w.layout).toEqual(leaf(a.id, 0, 0.5));
    await third.hub.pals.stopAndWait();
  });
});

describe("workspaces and sessions", () => {
  test("pals.create with a workspaceId joins it (a new leaf beside the others once laid out); an unknown one is refused", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id] })).workspace;
    const b = await t.mk("乙", { workspaceId: ws.id });
    expect(b.workspaceId).toBe(ws.id);
    let w = (await t.call("workspaces.list")).workspaces[0];
    expect(w.memberIds).toEqual([a.id, b.id]);
    expect(w.layout).toBeNull(); // not laid out: the app arranges them all
    await t.call("workspaces.update", { id: ws.id, layout: row(a.id, b.id) });
    const c = await t.mk("丙", { workspaceId: ws.id });
    w = (await t.call("workspaces.list")).workspaces[0];
    expect(w.memberIds).toEqual([a.id, b.id, c.id]);
    expect(leavesOf(w.layout).sort()).toEqual([a.id, b.id, c.id].sort());
    const sum = (n: LayoutNode): number => (n.type === "leaf" ? n.w : n.children.reduce((s, k) => s + sum(k), 0));
    expect(sum(w.layout)).toBeCloseTo(1);
    expect(t.last("workspaces.updated").workspaces[0].memberIds).toEqual([a.id, b.id, c.id]);
    await expect(t.call("pals.create", { cwd: t.project, workspaceId: "ws_nope" })).rejects.toThrow("找不到这个工作区");
    expect(t.hub.pals.list()).toHaveLength(3);
    await t.hub.pals.stopAndWait();
  });

  test("pals.end takes the session out of members and layout, drops its tabs, and the ended entry remembers the workspace; resume puts it back", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id, b.id] })).workspace;
    await t.call("workspaces.update", { id: ws.id, layout: row(a.id, b.id) });
    await t.call("workbench.tabs.set", { key: `pal:${b.id}`, tabs: [{ kind: "library" }], open: true });
    const ended = (await t.call("pals.end", { id: b.id })).earlier;
    expect(ended).toMatchObject({ kind: "ended", workspaceId: ws.id });
    let w = (await t.call("workspaces.list")).workspaces[0];
    expect(w.memberIds).toEqual([a.id]);
    expect(w.layout).toEqual(leaf(a.id, 0, 0.5)); // the sibling takes its place; the app renormalizes
    expect(t.last("workspaces.updated").workspaces[0].memberIds).toEqual([a.id]);
    expect(t.last("workbench.updated")).toEqual({ key: `pal:${b.id}`, state: null });
    expect((await t.call("workbench.tabs.get")).states).toEqual({});
    // resume: back in the workspace with a tile
    const back = (await t.call("pals.resume", { key: ended.key })).pal;
    expect(back.workspaceId).toBe(ws.id);
    w = (await t.call("workspaces.list")).workspaces[0];
    expect(w.memberIds).toEqual([a.id, back.id]);
    expect(leavesOf(w.layout).sort()).toEqual([a.id, back.id].sort());
    // the last member ending leaves an empty workspace, kept
    await t.call("pals.end", { id: a.id });
    await t.call("pals.end", { id: back.id });
    w = (await t.call("workspaces.list")).workspaces[0];
    expect(w).toMatchObject({ id: ws.id, memberIds: [], layout: null });
    await t.hub.pals.stopAndWait();
  });

  test("resume of an ended session whose workspace is gone is an ordinary session", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id] })).workspace;
    const ended = (await t.call("pals.end", { id: a.id })).earlier;
    await t.call("workspaces.delete", { id: ws.id });
    const back = (await t.call("pals.resume", { key: ended.key })).pal;
    expect(back.workspaceId).toBeUndefined();
    await t.hub.pals.stopAndWait();
  });

  test("pals.remove also takes the session out of its workspace", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id, b.id] })).workspace;
    await t.call("pals.remove", { id: a.id });
    expect((await t.call("workspaces.list")).workspaces[0]).toMatchObject({ id: ws.id, memberIds: [b.id] });
    await t.hub.pals.stopAndWait();
  });

  test("sessions in a workspace never fold; out of it they do", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const b = await t.mk("乙");
    await t.call("workspaces.create", { memberIds: [a.id] });
    for (const id of [a.id, b.id]) (t.hub.pals.get(id) as any).rec.lastUsedAt = Date.now() - 30 * 86_400_000;
    expect(t.pal(a.id).folded).toBe(false);
    expect(t.pal(b.id).folded).toBe(true);
    await t.call("workspaces.move", { palId: a.id });
    expect(t.pal(a.id).folded).toBe(true);
    await t.hub.pals.stopAndWait();
  });

  test("shownIds: a session that is a leaf of a layout stays awake past maxAwake; a member without a tile does not", async () => {
    const t = setup({ maxAwake: 2 });
    const ids: string[] = [];
    const up = async (name: string) => {
      const p = await t.mk(name);
      ids.push(p.id);
      await waitFor(() => t.pal(p.id).status === "idle");
      await tick(4);
    };
    await up("甲");
    await up("乙");
    // a member without a tile is not shown; tiled, 甲 is passed over when a third needs room
    const ws = (await t.call("workspaces.create", { memberIds: [ids[0]!] })).workspace;
    expect(t.hub.workbench.shownIds().size).toBe(0);
    await t.call("workspaces.update", { id: ws.id, layout: leaf(ids[0]!, 0, 1) });
    expect([...t.hub.workbench.shownIds()]).toEqual([ids[0]]);
    await up("丙");
    await waitFor(() => t.pal(ids[1]!).status === "asleep", 2_000);
    await tick(150);
    expect(t.pal(ids[0]!).status).toBe("idle");
    expect(t.pal(ids[2]!).status).toBe("idle");
    await t.hub.pals.stopAndWait();
  });
});

describe("right-pane tabs", () => {
  test("get and set per key (palo, pal:<id>, ws:<id>); set replaces the whole state and echoes to everyone", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const ws = (await t.call("workspaces.create", { memberIds: [a.id] })).workspace;
    expect((await t.call("workbench.tabs.get")).states).toEqual({});
    const tabs = [{ kind: "library" }, { kind: "web", url: "https://example.com" }, { kind: "preview", path: "/Users/someone/a.md" }];
    const r = (await t.call("workbench.tabs.set", { key: "palo", tabs, active: 1, open: true })).state;
    expect(r).toMatchObject({ tabs, active: 1, open: true });
    expect(t.last("workbench.updated")).toEqual({ key: "palo", state: r });
    await t.call("workbench.tabs.set", { key: `pal:${a.id}`, tabs: [{ kind: "files" }], open: false });
    await t.call("workbench.tabs.set", { key: `ws:${ws.id}`, tabs: [], open: true });
    const all = (await t.call("workbench.tabs.get")).states;
    expect(Object.keys(all).sort()).toEqual(["palo", `pal:${a.id}`, `ws:${ws.id}`].sort());
    expect((await t.call("workbench.tabs.get", { key: `pal:${a.id}` })).states).toEqual({ [`pal:${a.id}`]: all[`pal:${a.id}`] });
    expect((await t.call("workbench.tabs.get", { key: "pal:pal_other" })).states).toEqual({});
    // a whole replacement, and updatedAt moves on
    const again = (await t.call("workbench.tabs.set", { key: "palo", tabs: [{ kind: "files" }], open: false })).state;
    expect(again).toMatchObject({ tabs: [{ kind: "files" }], active: 0, open: false });
    expect(again.updatedAt).toBeGreaterThan(r.updatedAt);
    expect((await t.call("sync", {})).workbenchTabs.palo).toEqual(again);
    await t.hub.pals.stopAndWait();
  });

  test("duplicates collapse, active is clamped, bad tabs and keys are refused", async () => {
    const t = setup();
    const a = await t.mk("甲");
    const set = (params: Record<string, unknown>) => t.call("workbench.tabs.set", { key: "palo", open: true, ...params });
    const s = (await set({ tabs: [{ kind: "files" }, { kind: "files" }, { kind: "web", url: "http://a.test" }, { kind: "web", url: "http://a.test" }, { kind: "preview", path: "/x" }, { kind: "preview", path: "/x" }, { kind: "library" }, { kind: "library" }], active: 99 })).state;
    expect(s.tabs).toEqual([{ kind: "files" }, { kind: "web", url: "http://a.test" }, { kind: "preview", path: "/x" }, { kind: "library" }]);
    expect(s.active).toBe(3);
    expect((await set({ tabs: [], active: 4 })).state.active).toBe(0);
    expect((await set({ tabs: [{ kind: "files" }], active: -3 })).state.active).toBe(0);
    for (const bad of [[{ kind: "web", url: "ftp://x" }], [{ kind: "web", url: "nope" }], [{ kind: "preview", path: " " }], [{ kind: "" }], [{}], ["files"]]) await expect(set({ tabs: bad })).rejects.toThrow("标签");
    await expect(set({ tabs: "x" })).rejects.toThrow("标签");
    await expect(t.call("workbench.tabs.set", { key: "palo", tabs: [] })).rejects.toThrow("标签");
    await expect(set({ key: "other", tabs: [] })).rejects.toThrow("标签位置");
    await expect(set({ key: "pal:pal_nope", tabs: [] })).rejects.toThrow("不存在");
    await expect(set({ key: "ws:ws_nope", tabs: [] })).rejects.toThrow("不存在");
    await expect(set({ key: `pal:${a.id.slice(0, 6)}`, tabs: [] })).rejects.toThrow("不存在");
    await t.hub.pals.stopAndWait();
  });

  test("a tab kind the host doesn't know is kept as written, through a restart too, and doesn't collapse into another", async () => {
    const t = setup();
    const odd = [{ kind: "terminal", cwd: "/x", n: 2 }, { kind: "terminal", cwd: "/y" }, { kind: "files" }];
    const s = (await t.call("workbench.tabs.set", { key: "palo", tabs: odd, active: 2, open: true })).state;
    expect(s.tabs).toEqual(odd);
    await t.hub.pals.stopAndWait();
    const again = setup({ paths: t.paths, claude: t.claude });
    expect((await again.call("workbench.tabs.get", { key: "palo" })).states.palo).toEqual(s);
    await again.hub.pals.stopAndWait();
  });
});
