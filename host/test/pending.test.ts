import { describe, expect, test } from "bun:test";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import { PendingStore, SNOOZE_AFTER_REMINDER_MS, STALE_MS } from "../src/pending.ts";
import { handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { cleanup, makeHub, tick, tmpPaths } from "./helpers.ts";

// 等你的事: the host keeps what the owner must decide (docs/workbench-design/decisions-queue.html).

function store(now = { t: 1_000_000_000_000 }) {
  const paths = tmpPaths();
  const bus = new Bus();
  const events: any[] = [];
  bus.on((e, d) => e === "pending.updated" && events.push(d));
  const s = new PendingStore(`${paths.state}/pending.json`, bus, new Audit(paths.audit), () => "Palo", () => now.t);
  return { s, bus, paths, events, now };
}

describe("PendingStore", () => {
  test("add, the same one twice is one item, resolve, ignore, reopen; kept across a restart", () => {
    const { s, paths, events, now } = store();
    const a = s.add({ source: { kind: "palo", name: "Palo" }, title: "  报销要不要开一个 Pal  专门管 ", options: ["开吧", "不用", ""] });
    expect(a).toMatchObject({ title: "报销要不要开一个 Pal 专门管", options: ["开吧", "不用"], status: "open", blocking: false });
    expect(s.add({ source: { kind: "palo", name: "Palo" }, title: "报销要不要开一个 Pal 专门管" }).id).toBe(a.id);
    // the same words from a Pal are its own item
    const b = s.add({ source: { kind: "pal", id: "pal_1", name: "网站" }, title: "报销要不要开一个 Pal 专门管", pal: "pal_1" });
    expect(b.id).not.toBe(a.id);
    expect(s.openFor("pal", "pal_1").map((i) => i.id)).toEqual([b.id]);
    expect(s.resolve(a.id, "开报销帮手", "app")).toMatchObject({ status: "done", conclusion: "开报销帮手" });
    expect(s.update(b.id, "ignore", "app").status).toBe("ignored");
    expect(s.update(b.id, "reopen", "app").status).toBe("open");
    expect(() => s.update(b.id, "explode", "app")).toThrow();
    expect(events.length).toBe(5);
    now.t += 1000;
    const again = new PendingStore(`${paths.state}/pending.json`, new Bus(), new Audit(paths.audit), () => "Palo", () => now.t);
    expect(again.list()).toHaveLength(2);
    expect(again.get(a.id)!.status).toBe("done");
    expect(again.get(b.id)!.status).toBe("open");
    cleanup(paths);
  });

  test("a brief mentions an item left open three days, once; days later it's put away (still listed)", () => {
    const { s, paths, now } = store();
    const old = s.add({ source: { kind: "palo", name: "Palo" }, title: "回国机票：现在买还是再等等" });
    expect(s.takeStale()).toHaveLength(0);
    now.t += STALE_MS + 1000;
    s.add({ source: { kind: "palo", name: "Palo" }, title: "新的一件" });
    expect(s.takeStale().map((i) => i.id)).toEqual([old.id]);
    expect(s.takeStale()).toHaveLength(0); // once
    now.t += SNOOZE_AFTER_REMINDER_MS + 1000;
    const listed = s.list().find((i) => i.id === old.id)!;
    expect(listed.status).toBe("snoozed");
    cleanup(paths);
  });

  test("a session's question and permission prompt are blocking items, closed when answered", () => {
    const { s, bus, paths } = store();
    const q = { id: "q_1", items: [{ question: "方案选哪个？", header: "方案", options: [{ label: "A" }, { label: "B" }], multiSelect: false }], status: "pending", createdAt: 1, source: { kind: "pal", id: "pal_1", name: "网站" } };
    bus.emit("question.updated", q);
    const item = s.open()[0]!;
    expect(item).toMatchObject({ title: "方案选哪个？", options: ["A", "B"], blocking: true, questionId: "q_1", pal: "pal_1", source: { kind: "pal", name: "网站" } });
    bus.emit("question.updated", { ...q, status: "answered", answers: { "方案选哪个？": "B" } });
    expect(s.get(item.id)).toMatchObject({ status: "done", conclusion: "B" });
    const a = { id: "a_1", tool: "Bash", title: "运行 npm test", detail: "npm test", careful: false, status: "pending", createdAt: 1 };
    bus.emit("approval.updated", a);
    const ap = s.open()[0]!;
    expect(ap).toMatchObject({ title: "运行 npm test", blocking: true, approvalId: "a_1", source: { kind: "palo", name: "Palo" } });
    expect(ap.options!.length).toBe(2);
    bus.emit("approval.updated", { ...a, status: "denied" });
    expect(s.get(ap.id)!.status).toBe("done");
    // a question that's gone can't be put back
    expect(() => s.update(item.id, "reopen", "app")).toThrow();
    cleanup(paths);
  });
});

describe("Hub: 等你的事", () => {
  test("add_pending / resolve_pending: the assistant's and a brief's items; the brief's card is their 看原文", async () => {
    const script: FakeScript = async (t, ctx) => {
      if (t.startsWith("[定时]") || t.includes("晨报")) {
        await ctx.opts.tools.add_pending({ title: "周四和王老师的会改不改时间", context: "他提议改到周五下午 3 点。", options: ["改到周五", "维持周四"] });
        ctx.emit({ type: "assistant_text", text: "- 周四的会要你定", parentToolUseId: null });
        return;
      }
      ctx.emit({ type: "assistant_text", text: "好", parentToolUseId: null });
    };
    const { hub, paths } = makeHub({ script });
    const tools = hub.toolHandlers();
    hub.userMessage("在吗", "app");
    await hub.idle();
    const r = await tools.add_pending({ title: "报销要不要开一个 Pal 专门管", options: ["开吧", "不用"] });
    const id = /id: (p_\w+)/.exec(r)![1]!;
    expect(await tools.add_pending({ title: "报销要不要开一个 Pal 专门管" })).toContain("没有重复放");
    const item = hub.pending.get(id)!;
    expect(item.source).toEqual({ kind: "palo", name: "Palo" });
    expect(item.messageId).toBe(hub.chat.since(0).filter((m) => m.role === "assistant").at(-1)!.id);
    // a brief's run
    (hub as any).onSchedule(hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["07:30"] }, "user"));
    await hub.idle();
    const brief = hub.pending.open().find((i) => i.source.kind === "brief")!;
    expect(brief.source.name).toBe("晨报");
    const card = hub.chat.since(0).find((m) => m.card)!;
    expect(brief.messageId).toBe(card.id);
    const res = await tools.resolve_pending({ id, conclusion: "开报销帮手" });
    expect(res).toContain("开报销帮手");
    expect(res).toContain("周四和王老师的会改不改时间"); // what's left
    expect(await tools.resolve_pending({ id: "p_nope", conclusion: "x" })).toContain("没有这件事");
    cleanup(paths);
  });

  test("聊这件: a card at the bottom and a turn the owner doesn't see; answering it goes to the assistant", async () => {
    const seen: string[] = [];
    const script: FakeScript = async (t, ctx) => {
      seen.push(t);
      ctx.emit({ type: "assistant_text", text: "我倾向保留。", parentToolUseId: null });
    };
    const { hub, paths, driver } = makeHub({ script });
    const ctx = { clientId: "c", deviceId: "d", channel: "app" as const, local: false };
    const item = hub.pending.add({ source: { kind: "palo", name: "Palo" }, title: "供应商合同第 7 条要不要保留", context: "违约金比行业高一倍。", options: ["保留", "删掉"] });
    const r: any = await handleRpc(hub, { method: "pending.surface", params: { id: item.id } }, ctx);
    await hub.idle();
    const card = hub.chat.get(r.id)!;
    expect(card).toMatchObject({ kind: "pending", pendingId: item.id, role: "assistant" });
    expect(seen.at(-1)).toContain(item.id);
    expect(seen.at(-1)).toContain("违约金比行业高一倍");
    // nothing of the owner's shows for it
    expect(hub.chat.since(0).filter((m) => m.role === "user")).toHaveLength(0);
    const ans: any = await handleRpc(hub, { method: "pending.answer", params: { id: item.id, answer: "保留" } }, ctx);
    expect(ans.item).toMatchObject({ status: "done", conclusion: "保留" });
    await hub.idle();
    const mine = hub.chat.since(0).filter((m) => m.role === "user").at(-1)!;
    expect(mine).toMatchObject({ text: "保留", pendingId: item.id, replyTo: { messageId: card.id, excerpt: item.title } });
    expect(driver.last!.sent.at(-1)).toContain("清单里没有别的了"); // what's left
    // list / update over RPC
    const listed: any = await handleRpc(hub, { method: "pending.list" }, ctx);
    expect(listed.items.find((i: any) => i.id === item.id).status).toBe("done");
    const back: any = await handleRpc(hub, { method: "pending.update", params: { id: item.id, action: "reopen" } }, ctx);
    expect(back.item.status).toBe("open");
    cleanup(paths);
  });

  test("a Pal's add_pending is its own; the owner's answer goes to that Pal; its blocking question is answered through the item", async () => {
    const { hub, paths } = makeHub();
    const item = hub.pending.add({ source: { kind: "pal", id: "pal_x", name: "网站" }, title: "首页用哪张图", options: ["A", "B"], pal: "pal_x" });
    const sent: [string, string][] = [];
    (hub.pals as any).send = async (id: string, text: string) => (sent.push([id, text]), { id: "m", seq: 1 });
    await hub.answerPending(item.id, "B", "app");
    expect(sent).toEqual([["pal_x", "关于「首页用哪张图」：B"]]);
    expect(hub.pending.get(item.id)!.status).toBe("done");
    // a question of a session's: answered as the question
    const asked = hub.questions.ask(
      { toolName: "AskUserQuestion", input: { questions: [{ question: "合并吗？", options: [{ label: "合并" }, { label: "先别" }] }] }, signal: new AbortController().signal } as any,
      { source: { kind: "session", id: "s1", name: "修登录" }, notify: false },
    )!;
    await tick(0);
    const blocking = hub.pending.open().find((i) => i.questionId === asked.question.id)!;
    expect(blocking.blocking).toBe(true);
    await hub.answerPending(blocking.id, "合并", "app");
    const d = await asked.result;
    expect(d.behavior === "allow" && (d.updatedInput as any).answers).toEqual({ "合并吗？": "合并" });
    expect(hub.pending.get(blocking.id)).toMatchObject({ status: "done", conclusion: "合并" });
    cleanup(paths);
  });
});
