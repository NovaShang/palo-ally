import { describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import { ChatLog } from "../src/chat.ts";
import { PendingStore } from "../src/pending.ts";
import { linkAction, PendingLinks } from "../src/pendingLinks.ts";
import { PROPOSAL_TTL_MS, type PalsTiming } from "../src/pals.ts";
import { handleRpc } from "../src/rpc.ts";
import type { AllyEntry, Task } from "../src/types.ts";
import { AllyNet, befriend } from "./allyNet.ts";
import { cleanup, makeHub, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

// 等你的事 holds every card that waits on the owner: besides questions and
// permission prompts, the assistant's proposal cards, Ally drafts and tasks
// that need the owner (pendingLinks.ts). The apps' badges count only the list.

const app = { clientId: "app_1", deviceId: "dev-x", channel: "app" as const, local: false };
const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };

function setup(now?: () => number) {
  const ctx = makeHub({ pals: { timing: FAST, ...(now ? { now } : {}) } });
  ctx.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-pal-")));
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(ctx.hub, { method, params }, app)) ?? null));
  return { ...ctx, project, call };
}

describe("proposal cards", () => {
  test("a waiting card is an item with the card's options; 开吧 / 不用 on the list do what the card does; tapped on the card or expired, its item closes", async () => {
    let clock = Date.now();
    const t = setup(() => clock);
    const tools = t.hub.toolHandlers();
    await tools.pal_propose({ name: "网站", dir: t.project, duty: "做网站" });
    const card = t.hub.chat.recent(1)[0]!;
    const item = t.hub.pending.open().find((i) => i.link?.id === card.proposal!.id)!;
    expect(item).toMatchObject({
      source: { kind: "palo", name: "Palo" },
      title: card.text,
      context: "做网站",
      options: ["开吧", "不用"],
      blocking: false,
      messageId: card.id,
      link: { kind: "proposal", id: card.proposal!.id },
    });
    // 开吧 from the list: the Pal starts, the card says so, the item is done
    const done = await t.call("pending.answer", { id: item.id, answer: "开吧" });
    expect(done.item).toMatchObject({ status: "done", conclusion: "开了" });
    expect(t.hub.chat.get(card.id)!.proposal!.status).toBe("created");
    expect(t.hub.pals.list().map((p) => p.name)).toEqual(["网站"]);
    // 不用 from the list
    await tools.pal_propose({ name: "文档", dir: t.project, duty: "写文档" });
    const second = t.hub.chat.recent(1)[0]!;
    const two = t.hub.pending.linked({ kind: "proposal", id: second.proposal!.id })!;
    await t.call("pending.answer", { id: two.id, answer: "不用" });
    expect(t.hub.chat.get(second.id)!.proposal!.status).toBe("discarded");
    expect(t.hub.pending.get(two.id)).toMatchObject({ status: "done", conclusion: "不用了" });
    // tapped on the card: the item follows
    await tools.pal_propose({ name: "日记", dir: t.project, duty: "记日记" });
    const third = t.hub.chat.recent(1)[0]!;
    const three = t.hub.pending.linked({ kind: "proposal", id: third.proposal!.id })!;
    await t.call("helper.decide", { proposalId: third.proposal!.id, action: "discard" });
    expect(t.hub.pending.get(three.id)).toMatchObject({ status: "done", conclusion: "不用了" });
    // left a day: the card expires, so does the item; it can't be put back
    await tools.pal_propose({ name: "照片", dir: t.project, duty: "理照片" });
    const four = t.hub.pending.linked({ kind: "proposal", id: t.hub.chat.recent(1)[0]!.proposal!.id })!;
    clock += PROPOSAL_TTL_MS + 1000;
    t.hub.pals.expireProposals();
    expect(t.hub.pending.get(four.id)).toMatchObject({ status: "done", conclusion: "过期了" });
    await expect(t.call("pending.update", { id: four.id, action: "reopen" })).rejects.toThrow("放不回去");
    expect(t.hub.pending.open()).toEqual([]);
    await t.hub.pals.stopAndWait();
    cleanup(t.paths);
  });

  test("the owner's own words on a proposal's item go to the assistant; the card and its item still wait", async () => {
    const t = setup();
    await t.hub.toolHandlers().pal_propose({ name: "网站", dir: t.project, duty: "做网站" });
    const card = t.hub.chat.recent(1)[0]!;
    const item = t.hub.pending.linked({ kind: "proposal", id: card.proposal!.id })!;
    const r = await t.call("pending.answer", { id: item.id, answer: "先等等，下周再说" });
    expect(r.item.status).toBe("open");
    expect(t.hub.chat.get(card.id)!.proposal!.status).toBe("pending");
    await t.hub.idle();
    const mine = t.hub.chat.since(0).filter((m) => m.role === "user").at(-1)!;
    expect(mine).toMatchObject({ text: "先等等，下周再说", pendingId: item.id, replyTo: { messageId: card.id } });
    expect(t.driver.last!.sent.at(-1)).toContain("那张卡还在等他点");
    await t.hub.pals.stopAndWait();
    cleanup(t.paths);
  });

  test("a 接管 card: 接管 / 不用; it closes as the card settles", () => {
    const paths = tmpPaths();
    const bus = new Bus();
    const chat = new ChatLog(join(paths.state, "chat.jsonl"), bus);
    const pending = new PendingStore(join(paths.state, "pending.json"), bus, new Audit(paths.audit), () => "Palo");
    new PendingLinks({ bus, chat, pending, paloName: () => "Palo", allyName: () => "", openDrafts: () => [], tasks: () => [], palId: () => undefined }).reconcile();
    const proposal = { id: "pa_1", sessionId: "s1", cwd: "/w", title: "首页改版", status: "pending" as const };
    const m = chat.add({ role: "assistant", kind: "pal_adopt", text: "接管「首页改版」（/w）？", channel: "system", proposal });
    const item = pending.linked({ kind: "proposal", id: "pa_1" })!;
    expect(item).toMatchObject({ title: "接管「首页改版」（/w）？", options: ["接手", "不用"], messageId: m.id });
    // 接管, the option's old word, still takes it (an item listed before the rename).
    expect(linkAction({ kind: "proposal", id: "pa_1" }, "接管")).toBe("create");
    expect(linkAction({ kind: "proposal", id: "pa_1" }, "接手")).toBe("create");
    chat.update(m.id, { proposal: { ...proposal, status: "failed", note: "Claude Code 没登录" } }, { resync: true });
    expect(pending.get(item.id)).toMatchObject({ status: "done", conclusion: "Claude Code 没登录" });
    cleanup(paths);
  });
});

describe("Ally drafts", () => {
  test("a draft is the Ally's item (发送 / 不发); 发送 on the list sends it; 不发 on the card closes its item", async () => {
    const net = new AllyNet();
    const a = net.add("家人A");
    const b = net.add("家人B");
    await befriend(a, b);
    const toB = a.hub.allies.list()[0]!;
    await a.hub.toolHandlers().ally_send({ to: "家人B", text: "今晚我晚点回，大概九点" });
    const draft = a.hub.allies.log(toB.id).at(-1)!;
    const card = a.hub.chat.recent(5).find((m) => m.kind === "ally")!;
    const item = a.hub.pending.linked({ kind: "allyDraft", id: draft.id })!;
    expect(item).toMatchObject({
      source: { kind: "ally", id: toB.id, name: "家人B" },
      title: "要不要把这段话发给家人B",
      context: "今晚我晚点回，大概九点",
      options: ["发送", "不发"],
      messageId: card.id,
      status: "open",
    });
    const r = (await handleRpc(a.hub, { method: "pending.answer", params: { id: item.id, answer: "发送" } }, app)) as any;
    expect(r.item).toMatchObject({ status: "done", conclusion: "发了" });
    await waitFor(() => a.hub.allies.log(toB.id).at(-1)!.status === "delivered");
    // 不发 on the card
    await a.hub.toolHandlers().ally_send({ to: "家人B", text: "周末去公园？" });
    const second = a.hub.allies.log(toB.id).at(-1)!;
    const two = a.hub.pending.linked({ kind: "allyDraft", id: second.id })!;
    await handleRpc(a.hub, { method: "ally.draft.decide", params: { id: second.id, action: "discard" } }, app);
    expect(a.hub.pending.get(two.id)).toMatchObject({ status: "done", conclusion: "没发" });
    expect(a.hub.pending.open()).toEqual([]);
  });
});

describe("tasks that need the owner", () => {
  test("needs_input is an item from the assistant until the task goes on or ends; one stopped on a Pal's own question isn't counted twice", async () => {
    const t = setup();
    const task = t.hub.tasks.report("poster", "海报用哪种配色要你定", "needs_input", "做海报");
    const item = t.hub.pending.linked({ kind: "task", id: task.id })!;
    expect(item).toMatchObject({ source: { kind: "palo", name: "Palo" }, title: "「做海报」需要你", context: "海报用哪种配色要你定", status: "open" });
    expect(item.options).toBeUndefined();
    // still waiting, new words: the same item, its words updated
    t.hub.tasks.report("poster", "配色：蓝还是橙", "needs_input");
    expect(t.hub.pending.open().filter((i) => i.link?.kind === "task")).toHaveLength(1);
    expect(t.hub.pending.get(item.id)!.context).toBe("配色：蓝还是橙");
    t.hub.tasks.report("poster", "按蓝色在做", "running");
    expect(t.hub.pending.get(item.id)).toMatchObject({ status: "done", conclusion: "接着做了" });
    // asks again later: a new item
    t.hub.tasks.report("poster", "字体要你定", "needs_input");
    const again = t.hub.pending.linked({ kind: "task", id: task.id })!;
    expect(again.id).not.toBe(item.id);
    t.hub.tasks.report("poster", "做好了", "done");
    expect(t.hub.pending.get(again.id)!.status).toBe("done");

    // handed to a Pal that is stopped on its own question: that question is the item
    t.hub.pending.add({ source: { kind: "pal", id: "pal_x", name: "网站" }, title: "首页用哪张图", blocking: true, questionId: "q_x", pal: "pal_x" });
    const handed = t.hub.tasks.openPeer("改首页", "", "网站");
    t.hub.tasks.updatePeer(handed.id, "needs_input", "等你回答：首页用哪张图");
    expect(t.hub.pending.linked({ kind: "task", id: handed.id })).toBeUndefined();
    expect(t.hub.pending.open()).toHaveLength(1);
    await t.hub.pals.stopAndWait();
    cleanup(t.paths);
  });
});

describe("after a restart", () => {
  test("an item for each card still waiting; the items of cards settled meanwhile close; the owner's ignoring stands", () => {
    const paths = tmpPaths();
    const bus = new Bus();
    const chat = new ChatLog(join(paths.state, "chat.jsonl"), bus);
    const store = () => new PendingStore(join(paths.state, "pending.json"), bus, new Audit(paths.audit), () => "Palo");
    let pending = store();
    // the last process' items: a draft since sent, a task since done, one ignored
    const sent = pending.add({ source: { kind: "ally", id: "al_1", name: "家人B" }, title: "要不要把这段话发给家人B", link: { kind: "allyDraft", id: "ae_sent" } });
    const task = pending.add({ source: { kind: "palo", name: "Palo" }, title: "「做海报」需要你", link: { kind: "task", id: "t_done" } });
    const ignored = pending.add({ source: { kind: "palo", name: "Palo" }, title: "开一个会话？", link: { kind: "proposal", id: "hp_1" } });
    pending.update(ignored.id, "ignore", "app");
    // waiting now: that proposal still, a draft and a task
    chat.add({ role: "assistant", kind: "helper", text: "开一个会话「网站」专门管 ~/w？", channel: "system", proposal: { id: "hp_1", name: "网站", cwd: "/w", duty: "做网站", status: "pending" } });
    const draft: AllyEntry = { id: "ae_new", allyId: "al_1", dir: "out", ts: 1, text: "明天见", urgent: false, status: "draft", author: "assistant" };
    const waiting: Task = { id: "t_wait", title: "订餐厅", summary: "几个人？", status: "needs_input", source: "report", createdAt: 1, updatedAt: 1, activityCount: 0 };
    const done: Task = { ...waiting, id: "t_done", status: "done" };
    pending = store();
    new PendingLinks({
      bus,
      chat,
      pending,
      paloName: () => "Palo",
      allyName: () => "家人B",
      openDrafts: () => [{ entry: draft, name: "家人B" }],
      tasks: () => [waiting, done],
      palId: () => undefined,
    }).reconcile();
    expect(pending.get(sent.id)).toMatchObject({ status: "done", conclusion: "已经不用定了" });
    expect(pending.get(task.id)).toMatchObject({ status: "done", conclusion: "这件已经结束" });
    expect(pending.get(ignored.id)!.status).toBe("ignored");
    expect(pending.open().map((i) => i.link)).toEqual(expect.arrayContaining([{ kind: "allyDraft", id: "ae_new" }, { kind: "task", id: "t_wait" }]));
    expect(pending.open()).toHaveLength(2);
    cleanup(paths);
  });
});
