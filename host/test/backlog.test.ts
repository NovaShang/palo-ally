import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { Audit } from "../src/audit.ts";
import { BacklogStore, backlogFolder, parseBacklog } from "../src/backlog.ts";
import { Bus } from "../src/bus.ts";
import { behaviorText } from "../src/home.ts";
import { tIn } from "../src/i18n/index.ts";
import { PAL_PROMPT } from "../src/pals.ts";
import { handleRpc } from "../src/rpc.ts";
import { makeDeliveryTools } from "../src/shellTools.ts";
import type { Backlog } from "../src/types.ts";
import { cleanup, makeHub, tick, tmpPaths } from "./helpers.ts";

// 待办 (docs/workbench-design/backlog.html): one list per folder, kept by the host as Markdown.

function store(now = { t: 1_800_000_000_000 }) {
  const paths = tmpPaths();
  const bus = new Bus();
  const events: Backlog[] = [];
  bus.on((e, d) => e === "backlog.updated" && events.push(d as Backlog));
  const names: Record<string, string> = { pal_a: "网站帮手", pal_b: "博客改版" };
  const s = new BacklogStore({ dir: paths.backlog, bus, audit: new Audit(paths.audit), assistantFolder: () => paths.home, palName: (id) => names[id], now: () => now.t });
  const folder = mkdtempSync(join(tmpdir(), "backlog-folder-"));
  return { s, bus, paths, events, names, now, folder: backlogFolder(folder), done: () => (cleanup(paths), rmSync(folder, { recursive: true, force: true })) };
}

const texts = (b: Backlog) => b.items.map((i) => `${i.state === "doing" ? ">" : i.state === "done" ? "x" : " "} ${i.text}`);

describe("BacklogStore", () => {
  test("add, move, assign, start, done, undone, remove: in the file, in order, read back the same", () => {
    const { s, events, folder, done, now } = store();
    const a = s.add(folder, { text: "  首页图片懒加载 ", note: "首屏 3.2 MB\n大部分是图" }, "app");
    expect(a.n).toBe(1);
    expect(a.item).toMatchObject({ text: "首页图片懒加载", note: "首屏 3.2 MB\n大部分是图", state: "queued", addedAt: now.t });
    const b = s.add(folder, { text: "文章页加目录" }, "app").item;
    const c = s.add(folder, { text: "404 页面重做" }, "app").item;
    expect(s.add(folder, { text: "最要紧的", top: true }, "app").n).toBe(1);
    expect(() => s.add(folder, { text: "   " }, "app")).toThrow("要写点内容");
    let list = s.move(folder, c.id, 1, "app");
    expect(texts(list)).toEqual(["  最要紧的", "  404 页面重做", "  首页图片懒加载", "  文章页加目录"]);
    list = s.assign(folder, b.id, "pal_b", "app");
    expect(list.items.find((i) => i.id === b.id)).toMatchObject({ pal: "pal_b", palName: "博客改版", state: "queued" });
    list = s.start(folder, a.item.id, "pal_a", "app");
    expect(list.items[0]).toMatchObject({ id: a.item.id, state: "doing", pal: "pal_a", palName: "网站帮手" });
    now.t += 60_000;
    const d = s.done(folder, a.item.id, true, "pal:pal_a");
    expect(d.item).toMatchObject({ state: "done", doneAt: now.t });
    expect(texts(d.backlog)).toEqual(["  最要紧的", "  404 页面重做", "  文章页加目录", "x 首页图片懒加载"]);
    // put back: on top of the queue, no longer anyone's
    const back = s.done(folder, a.item.id, false, "app").backlog;
    expect(back.items[0]).toMatchObject({ id: a.item.id, state: "queued" });
    expect(back.items[0]!.pal).toBeUndefined();
    s.done(folder, a.item.id, true, "app");
    // a done one dragged back into the queue is queued again
    expect(texts(s.move(folder, a.item.id, 0, "app"))[0]).toBe("  首页图片懒加载");
    list = s.remove(folder, c.id, "app");
    expect(list.items.map((i) => i.id)).not.toContain(c.id);
    expect(() => s.remove(folder, c.id, "app")).toThrow("待办里没有这件");
    // one event per change, each the whole list
    expect(events.length).toBe(12);
    expect(events.at(-1)!.items).toEqual(list.items);
    // the file is the truth: a new store reads the same list
    const file = s.fileOf(folder);
    const md = readFileSync(file, "utf8");
    expect(md).toContain(`<!-- palo-backlog: ${folder} -->`);
    expect(md).toContain("- [ ] 文章页加目录 (@博客改版) <!-- ");
    expect(md).toContain("  首屏 3.2 MB\n  大部分是图\n");
    const again = new BacklogStore({ dir: s.fileOf(folder).replace(/\/[^/]+$/, ""), bus: new Bus(), assistantFolder: () => "/nowhere" });
    expect(again.list(folder).items).toEqual(list.items);
    done();
  });

  test("lists are per folder (shared by the agents in it), the assistant's marked; ~ and trailing slashes are the same folder", () => {
    const { s, paths, folder, done } = store();
    s.add(folder, { text: "网站的事" }, "app");
    s.add(backlogFolder(paths.home), { text: "助理的杂事" }, "app");
    expect(texts(s.list(folder + "/"))).toEqual([]); // the raw string isn't normalized by the store…
    expect(texts(s.list(backlogFolder(folder + "/")))).toEqual(["  网站的事"]); // …backlogFolder is
    expect(s.list(backlogFolder(paths.home))).toMatchObject({ assistant: true, items: [{ text: "助理的杂事" }] });
    expect(s.list(folder).assistant).toBeUndefined();
    expect(s.fileOf(folder)).not.toBe(s.fileOf(backlogFolder(paths.home)));
    expect(backlogFolder("~/no-such-folder-here/")).toBe(join(homedir(), "no-such-folder-here"));
    expect(backlogFolder(folder.replace(realpathSync(tmpdir()), tmpdir()))).toBe(folder);
    done();
  });

  test("hand edits: no ids, other marks, notes, done ones in the middle, a duplicate id; ids stay put until written", () => {
    const { s, folder, done, events } = store();
    const file = s.fileOf(folder);
    mkdirSync(file.replace(/\/[^/]+$/, ""), { recursive: true });
    writeFileSync(
      file,
      [
        "# 我自己的标题",
        "",
        "- [x] 列表页按日期排序",
        "- 首页图片懒加载",
        "    首屏太大",
        "* [>] 博客评论区样式 (@博客改版) <!-- b_keep pal:pal_b -->",
        "1. 编号的一件",
        "- [ ] 重复的 id <!-- b_keep -->",
        "随手写的一行",
        "<!-- 一段",
        "注释 -->",
        "- [?] 看不懂的记号",
        "",
      ].join("\n"),
    );
    const first = s.list(folder);
    expect(texts(first)).toEqual(["> 博客评论区样式", "  首页图片懒加载", "  编号的一件", "  重复的 id", "  随手写的一行", "  看不懂的记号", "x 列表页按日期排序"]);
    expect(first.items[0]).toMatchObject({ id: "b_keep", pal: "pal_b", palName: "博客改版" });
    expect(first.items[1]).toMatchObject({ note: "首屏太大" });
    const ids = first.items.map((i) => i.id);
    expect(new Set(ids).size).toBe(ids.length);
    // read again (a fresh store, nothing cached): the same ids, the file untouched
    const fresh = new BacklogStore({ dir: file.replace(/\/[^/]+$/, ""), bus: new Bus(), assistantFolder: () => "/nowhere" });
    expect(fresh.list(folder).items.map((i) => i.id)).toEqual(ids);
    expect(readFileSync(file, "utf8")).toContain("随手写的一行");
    // an id from a hand-written line works, and the write keeps every id
    s.done(folder, ids[1]!, true, "app");
    expect(s.list(folder).items.map((i) => i.id).sort()).toEqual([...ids].sort());
    expect(readFileSync(file, "utf8")).toContain(`- [x] 首页图片懒加载 <!-- ${ids[1]} `);
    // edited by hand again later: read again (not the cached list)
    events.length = 0;
    writeFileSync(file, readFileSync(file, "utf8") + "- 新加的一行\n");
    expect(texts(s.list(folder))).toContain("  新加的一行");
    // gone: empty
    rmSync(file);
    expect(s.list(folder).items).toEqual([]);
    done();
  });

  test("parse: an empty or odd file is an empty list, never an error", () => {
    expect(parseBacklog("", "/f")).toEqual([]);
    expect(parseBacklog("# 待办\n\n<!-- -->\n", "/f")).toEqual([]);
    expect(parseBacklog("- [ ] <!-- b_1 -->\n", "/f")).toEqual([]);
  });

  test("an edit by hand on disk is sent to the apps; our own writes aren't sent twice", async () => {
    const { s, folder, events, done } = store();
    s.add(folder, { text: "第一件" }, "app");
    s.watch();
    await tick(50);
    events.length = 0;
    s.add(folder, { text: "第二件" }, "app");
    await tick(400);
    expect(events.length).toBe(1); // the add's own, not an echo from the watcher
    const file = s.fileOf(folder);
    writeFileSync(file, readFileSync(file, "utf8").replace("第二件", "第二件（改过）"));
    await tick(600);
    s.close();
    expect(events.length).toBe(2);
    expect(texts(events.at(-1)!)).toEqual(["  第一件", "  第二件（改过）"]);
    done();
  });

  test("done ones beyond 50 are dropped, the oldest first", () => {
    const { s, folder, done, now } = store();
    for (let i = 0; i < 55; i++) {
      const it = s.add(folder, { text: `件 ${i}` }, "app").item;
      now.t += 1;
      s.done(folder, it.id, true, "app");
    }
    const list = s.list(folder);
    expect(list.items.length).toBe(50);
    expect(list.items[0]!.text).toBe("件 5");
    done();
  });
});

describe("Hub: 待办", () => {
  test("the RPCs: the assistant's list, an agent's by its folder, a folder's; errors in words", async () => {
    const { hub, paths } = makeHub();
    const site = backlogFolder(mkdtempSync(join(tmpdir(), "site-")));
    (hub.pals as any).list = () => [
      { id: "pal_a", name: "网站帮手", cwd: site },
      { id: "pal_b", name: "博客改版", cwd: site },
    ];
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    const call = (method: string, params: any = {}) => handleRpc(hub, { method, params }, ctx) as Promise<any>;
    const mine = await call("backlog.add", { text: "助理的杂事" });
    expect(mine.backlog).toMatchObject({ folder: backlogFolder(paths.home), assistant: true });
    const a = (await call("backlog.add", { pal: "pal_a", text: "首页图片懒加载" })).item;
    const b = (await call("backlog.add", { folder: site, text: "文章页加目录" })).item;
    // agents in the same folder share it
    expect((await call("backlog.list", { pal: "pal_b" })).backlog.items.map((i: any) => i.id)).toEqual([a.id, b.id]);
    expect((await call("backlog.move", { pal: "pal_b", id: b.id, to: 0 })).backlog.items.map((i: any) => i.id)).toEqual([b.id, a.id]);
    expect((await call("backlog.assign", { pal: "pal_a", id: a.id, agent: "pal_b" })).backlog.items[1]).toMatchObject({ pal: "pal_b", palName: "博客改版" });
    expect((await call("backlog.assign", { pal: "pal_a", id: a.id, agent: null })).backlog.items[1].pal).toBeUndefined();
    expect((await call("backlog.start", { pal: "pal_a", id: a.id, agent: "pal_a" })).backlog.items[0]).toMatchObject({ id: a.id, state: "doing", palName: "网站帮手" });
    expect((await call("backlog.done", { pal: "pal_a", id: a.id })).backlog.items.at(-1)).toMatchObject({ id: a.id, state: "done" });
    expect((await call("backlog.done", { pal: "pal_a", id: a.id, done: false })).backlog.items[0]).toMatchObject({ id: a.id, state: "queued" });
    expect((await call("backlog.remove", { pal: "pal_a", id: b.id })).backlog.items.map((i: any) => i.id)).toEqual([a.id]);
    await expect(call("backlog.list", { pal: "nobody" })).rejects.toThrow("没有这个 agent");
    await expect(call("backlog.done", { pal: "pal_a", id: "b_none" })).rejects.toThrow("待办里没有这件");
    // the assistant's untouched by all that
    expect((await call("backlog.list")).backlog.items.map((i: any) => i.text)).toEqual(["助理的杂事"]);
    cleanup(paths);
  });

  test("the tools: the assistant adds to its own folder's list, a session to its folder's; list and done; the prompt line", async () => {
    const { hub, paths } = makeHub();
    const tools = hub.toolHandlers();
    const added = await tools.backlog_add({ text: "整理报销单", note: "十月的" });
    expect(added).toContain("排第 1 件");
    const id = hub.backlog.list(backlogFolder(paths.home)).items[0]!.id;
    expect(await tools.backlog_list({})).toContain(`${id} [1] 整理报销单 (十月的)`);
    expect(await tools.backlog_done({ id })).toContain("已标完成：「整理报销单」");
    expect(await tools.backlog_done({ id: "b_none" })).toBe("待办里没有这件");
    expect(await tools.backlog_add({ text: "" })).toBe("要写点内容");
    // a session's: its folder's list
    const site = mkdtempSync(join(tmpdir(), "site-"));
    const session = makeDeliveryTools({
      artifacts: hub.artifacts, chat: hub.chat, router: hub.router, audit: hub.audit, media: hub.media, ownerChannel: () => "app", cwd: site, backlog: hub.backlog,
      session: { id: "pal_a", name: () => "网站帮手", card: (m) => hub.chat.add(m), notice: (text) => hub.chat.add({ role: "assistant", kind: "notice", text, channel: "system" }) },
    });
    expect(await session.backlog_add({ text: "首页图片懒加载" })).toContain(backlogFolder(site));
    expect(hub.backlog.list(backlogFolder(site)).items.map((i) => i.text)).toEqual(["首页图片懒加载"]);
    expect(await session.backlog_list({})).toContain("首页图片懒加载");
    expect(await session.backlog_list({ folder: paths.home })).toContain("整理报销单");
    // the line both are told
    for (const lang of ["zh", "en"] as const) expect(behaviorText(lang)).toContain(tIn(lang, "backlog.prompt"));
    expect(PAL_PROMPT("Palo")).toContain("backlog_add");
    rmSync(site, { recursive: true, force: true });
    cleanup(paths);
  });

  test("以后再说: an item goes on the 待办 of the folder it came from, and leaves 等你的事; a blocking one can't", async () => {
    const { hub, paths } = makeHub();
    const site = backlogFolder(mkdtempSync(join(tmpdir(), "site-")));
    (hub.pals as any).list = () => [{ id: "pal_a", name: "网站帮手", cwd: site }];
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    const call = (method: string, params: any = {}) => handleRpc(hub, { method, params }, ctx) as Promise<any>;
    const mine = hub.pending.add({ source: { kind: "palo", name: "Palo" }, title: "官网要不要加暗色模式", context: "不急" });
    const r = await call("pending.update", { id: mine.id, action: "later" });
    expect(r.item).toMatchObject({ status: "done", conclusion: "放进待办了" });
    expect(hub.backlog.list(backlogFolder(paths.home)).items[0]).toMatchObject({ text: "官网要不要加暗色模式", note: "不急", state: "queued" });
    const pals = hub.pending.add({ source: { kind: "pal", id: "pal_a", name: "网站帮手" }, title: "首页用哪张图", pal: "pal_a" });
    await call("pending.update", { id: pals.id, action: "later" });
    expect(hub.backlog.list(site).items.map((i) => i.text)).toEqual(["首页用哪张图"]);
    const asked = hub.questions.ask(
      { toolName: "AskUserQuestion", input: { questions: [{ question: "合并吗？", options: [{ label: "合并" }, { label: "先别" }] }] }, signal: new AbortController().signal } as any,
      { source: { kind: "session", id: "s1", name: "修登录" }, notify: false },
    )!;
    await tick(0);
    const blocking = hub.pending.open().find((i) => i.questionId === asked.question.id)!;
    await expect(call("pending.update", { id: blocking.id, action: "later" })).rejects.toThrow("卡着");
    expect(hub.pending.get(blocking.id)!.status).toBe("open");
    // the owner quoting an item of the assistant's 待办: the assistant is told which
    const item = hub.backlog.list(backlogFolder(paths.home)).items[0]!;
    expect(hub.pendingQuoteNote({ messageId: `backlog:${item.id}`, excerpt: item.text }).note).toContain(item.id);
    expect(hub.pendingQuoteNote({ messageId: "backlog:b_none", excerpt: "x" }).note).toBeUndefined();
    hub.questions.answer(asked.question.id, { "合并吗？": "合并" }, "app");
    rmSync(site, { recursive: true, force: true });
    cleanup(paths);
  });
});
