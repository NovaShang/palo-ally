// The turn model of the assistant (its host-made turns) and of an agent (the
// harness' turns), pinned before they become one AgentSession turn model with
// flags (docs/harness-adapter-design.md step 13): which owner messages a turn
// answers and in what order the replies come, a turn the harness starts on its
// own, a stop mid-turn, replies in several text blocks, reply ids, an Ally's
// gated turn, host-initiated turns and [skip]. Only public surfaces: RPCs, bus
// events, the chat log, the fake harness.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { handleRpc } from "../src/rpc.ts";
import type { HarnessEvent } from "../src/harness/types.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli } from "./fakeClaude.ts";
import { makeHub, tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
});

const FAST = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
const result = (sessionId: string, consumedUuids?: string[]): HarnessEvent => ({ type: "result", isError: false, text: "", costUsd: 0, totalCostUsd: 0, contextTokens: 10, sessionId, ...(consumedUuids ? { consumedUuids } : {}) });

function setup(o: { script?: FakeScript; palScript?: FakeScript } = {}) {
  const claude = new FakeClaudeDir();
  dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const t = makeHub({
    script: o.script,
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false) },
    pals: { timing: FAST },
  });
  if (o.palScript) t.driver.palScript = o.palScript;
  t.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-turns-")));
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(t.hub, { method, params }, app)) ?? null));
  const agent = async () => {
    const { pal } = await call("pals.create", { cwd: project });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === pal.id)?.status === "idle");
    return pal as { id: string; sessionId: string; name: string };
  };
  const statusOf = (id: string) => t.hub.pals.list().find((p) => p.id === id)?.status;
  const palEvents = (event: string, id: string) => t.events.filter((e) => e.event === event && e.data?.pal === id).map((e) => e.data);
  const mainEvents = (event: string) => t.events.filter((e) => e.event === event && !e.data?.pal).map((e) => e.data);
  const replies = () => t.hub.chat.since(0).filter((m) => m.role === "assistant");
  return { ...t, project, call, agent, statusOf, palEvents, mainEvents, replies };
}

describe("the assistant's turns", () => {
  test("owner words sent back to back while a turn runs go in at once, in order; each turn answers its own and the replies come in that order, none proactive", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const t = setup({
      script: async (text, ctx) => {
        if (text === "慢慢来") await gate;
        ctx.emit({ type: "text_delta", text: `回：${text}` });
        ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null });
      },
    });
    const a = t.hub.userMessage("慢慢来", "app")!;
    const b = t.hub.userMessage("一", "app")!;
    const c = t.hub.userMessage("二", "cli")!;
    expect(t.driver.last!.sent).toEqual(["慢慢来", "一", "二"]);
    expect(t.driver.last!.sentUuids).toEqual([a.uuid, b.uuid, c.uuid]);
    expect(t.hub.status().busy).toBe(true);
    release();
    await t.hub.idle();
    const r = t.replies();
    expect(r.map((m) => `${m.channel}:${m.text}`)).toEqual(["app:回：慢慢来", "app:回：一", "cli:回：二"]);
    expect(r.every((m) => !m.proactive)).toBe(true);
    expect(t.pusher.pushes).toEqual([]);
    expect(t.hub.status().busy).toBe(false);
  });

  test("one turn that answers two owner messages (the harness folded them): one reply, on the first one's channel", async () => {
    const t = setup({ script: async () => {} });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    const s = t.driver.last!;
    const before = t.hub.chat.lastSeq;
    t.driver.script = async () => new Promise<void>(() => {}); // the harness holds them; the test answers
    const a = t.hub.userMessage("甲", "cli")!;
    const b = t.hub.userMessage("乙", "app")!;
    await tick(5);
    s.opts.onEvent({ type: "answering", uuids: [a.uuid!, b.uuid!] });
    s.opts.onEvent({ type: "assistant_text", text: "甲乙都收到", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId, [a.uuid!, b.uuid!]));
    const shown = t.hub.chat.since(before).filter((m) => m.role === "assistant");
    expect(shown.map((m) => `${m.channel}:${m.text}:${!!m.proactive}`)).toEqual(["cli:甲乙都收到:false"]);
    expect(t.hub.status().busy).toBe(false);
    expect(t.hub.conversation.quiet).toBe(true);
  });

  test("a result that answers only some: the others stay unanswered, and the harness' next output opens their turn without a new message", async () => {
    const t = setup({ script: async () => {} });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    const s = t.driver.last!;
    t.driver.script = async () => new Promise<void>(() => {});
    const a = t.hub.userMessage("甲", "app")!;
    const b = t.hub.userMessage("乙", "wechat", { userId: "u", contextToken: "c" } as any)!;
    await tick(5);
    s.opts.onEvent({ type: "assistant_text", text: "先回甲", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId, [a.uuid!]));
    expect(t.hub.status().busy).toBe(false); // the turn is over; 乙 is still in flight
    expect(t.hub.conversation.quiet).toBe(false);
    s.opts.onEvent({ type: "tool_use", id: "tu_1", name: "Bash", input: {}, parentToolUseId: null });
    expect(t.hub.status().busy).toBe(true);
    expect(t.hub.conversation.wechatTarget()).toEqual({ userId: "u", contextToken: "c" } as any);
    s.opts.onEvent({ type: "tool_result", toolUseId: "tu_1", content: "ok", isError: false, parentToolUseId: null });
    s.opts.onEvent({ type: "assistant_text", text: "再回乙", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId, [b.uuid!]));
    expect(t.replies().slice(-2).map((m) => `${m.channel}:${m.text}`)).toEqual(["app:先回甲", "wechat:再回乙"]);
    expect(t.hub.conversation.quiet).toBe(true);
  });

  test("a reply in several text blocks: each block is its own message under its own host-made id, each streamed under that id", async () => {
    const t = setup({
      script: async (_text, ctx) => {
        ctx.emit({ type: "text_delta", text: "第一", messageId: "msg_api_1" });
        ctx.emit({ type: "text_delta", text: "块", messageId: "msg_api_1" });
        ctx.emit({ type: "assistant_text", text: "第一块", parentToolUseId: null, messageId: "msg_api_1" });
        await ctx.useTool("Read", { file_path: "/x" });
        ctx.emit({ type: "text_delta", text: "第二块", messageId: "msg_api_2" });
        ctx.emit({ type: "assistant_text", text: "第二块", parentToolUseId: null, messageId: "msg_api_2" });
        ctx.emit({ type: "assistant_text", text: "第三块", parentToolUseId: null, messageId: "msg_api_2" });
      },
    });
    t.hub.userMessage("说三段", "app");
    await t.hub.idle();
    const r = t.replies();
    expect(r.map((m) => m.text)).toEqual(["第一块", "第二块", "第三块"]);
    for (const m of r) expect(m.id).toMatch(/^m_/);
    expect(new Set(r.map((m) => m.id)).size).toBe(3);
    const deltas = t.mainEvents("chat.delta");
    expect(deltas.map((d) => [d.text, d.id === r[0]!.id ? 0 : d.id === r[1]!.id ? 1 : -1])).toEqual([
      ["第一", 0],
      ["块", 0],
      ["第二块", 1],
    ]);
    expect(t.hub.conversation.streamingReply()).toBeNull();
  });

  test("a turn the harness starts on its own: a subagent's output opens it too; shown as background work; it's proactive and closes at its result", async () => {
    const t = setup();
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    const s = t.driver.last!;
    s.opts.onEvent({ type: "tool_use", id: "sub_1", name: "Bash", input: {}, parentToolUseId: "agent_tool_1" });
    expect(t.hub.status().busy).toBe(true);
    expect(t.hub.status().activity).toBe(t.hub.conversation.activity);
    const bg = t.hub.conversation.activity;
    expect(bg).toBeTruthy();
    s.opts.onEvent({ type: "text_delta", text: "不流" });
    expect(t.mainEvents("chat.delta").some((d) => d.text === "不流")).toBe(false); // a proactive turn isn't streamed
    s.opts.onEvent({ type: "assistant_text", text: "后台办完了", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId));
    const m = t.hub.chat.recent(1)[0]!;
    expect(m).toMatchObject({ text: "后台办完了", proactive: true, channel: "system" });
    expect(t.hub.status().busy).toBe(false);
  });

  test("stop mid-reply: what was streamed is kept under its id, the turn ends at once, owner words still in flight are dropped", async () => {
    const t = setup({
      script: async (text, ctx) => {
        if (text !== "长篇") return void ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null });
        ctx.emit({ type: "text_delta", text: "写到一半" });
        await ctx.interrupted;
      },
    });
    t.hub.userMessage("长篇", "app");
    await tick(5);
    const id = t.mainEvents("chat.delta")[0]!.id;
    t.hub.userMessage("/stop", "app");
    expect(t.hub.status().busy).toBe(false);
    const cut = t.hub.chat.since(0).find((m) => m.id === id)!;
    expect(cut).toMatchObject({ role: "assistant", text: "写到一半", channel: "app" });
    expect(t.hub.conversation.quiet).toBe(true);
    t.hub.userMessage("在吗", "app");
    await t.hub.idle();
    expect(t.hub.chat.recent(1)[0]!.text).toBe("回：在吗");
  });

  test("host-initiated turns: [skip] paragraphs are dropped from what's shown; a goal's run gives the goal its line; the owner answered in one is a plain reply with no push", async () => {
    const t = setup({
      script: async (text, ctx) => {
        if (text === "[定时] 一") return void ctx.emit({ type: "assistant_text", text: "[skip]\n\n今天没事。\n\n[SKIP]", parentToolUseId: null });
        if (text === "[定时] 二") return void ctx.emit({ type: "assistant_text", text: "[skip]", parentToolUseId: null });
        ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null });
      },
    });
    t.hub.conversation.enqueue({ text: "[定时] 一", origin: "schedule", proactive: true, label: "看看" });
    await t.hub.idle();
    expect(t.hub.chat.recent(1)[0]).toMatchObject({ text: "今天没事。", proactive: true, channel: "schedule" });
    expect(t.pusher.pushes).toHaveLength(1);
    const before = t.hub.chat.lastSeq;
    t.hub.conversation.enqueue({ text: "[定时] 二", origin: "schedule", proactive: true });
    await t.hub.idle();
    expect(t.hub.chat.since(before)).toEqual([]);
    expect(t.pusher.pushes).toHaveLength(1);
    // a goal's run: its words are the goal's line, and a card titled by it
    const goal = t.hub.watches.add({ title: "房租", instruction: "看看房租", at: ["08:30"] }, "user");
    t.hub.conversation.enqueue({ text: "[定时] 一", origin: "schedule", proactive: true, label: "房租", watchId: goal.id });
    await t.hub.idle();
    expect(t.hub.watches.get(goal.id)!.progress).toBe("今天没事。");
    expect(t.hub.chat.recent(1)[0]!.card).toEqual({ title: "房租", goalId: goal.id });

    // the owner's words folded into a host-initiated turn
    const pushed = t.pusher.pushes.length;
    const s = t.driver.last!;
    t.driver.script = async () => new Promise<void>(() => {});
    t.hub.conversation.enqueue({ text: "[定时] 三", origin: "schedule", proactive: true });
    await tick(5);
    const owner = t.hub.userMessage("顺便问下", "cli")!;
    s.opts.onEvent({ type: "assistant_text", text: "一起答了", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId, [s.sentUuids.at(-2)!, owner.uuid!]));
    expect(t.hub.chat.recent(1)[0]).toMatchObject({ text: "一起答了", channel: "cli" });
    expect(t.hub.chat.recent(1)[0]!.proactive).toBeFalsy();
    expect(t.pusher.pushes).toHaveLength(pushed);
  });

  test("an Ally's turn the harness queued behind another: the gate stays until a result consumes its message; then the owner's held words go, as their own turn", async () => {
    const t = setup({ script: async () => {} });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    const s = t.driver.last!;
    t.driver.script = async () => new Promise<void>(() => {});
    t.hub.conversation.enqueue({ text: "[好友] 在吗", origin: "system", proactive: true, allyId: "ally_q" });
    await tick(5);
    const allyUuid = s.sentUuids.at(-1)!;
    expect(t.hub.conversation.allyTurnAlly()).toBe("ally_q");
    t.hub.userMessage("我来了", "app");
    expect(s.sent.at(-1)).toBe("[好友] 在吗");
    // a result for something else: the gate stays
    s.opts.onEvent(result(s.sessionId, ["other"]));
    expect(t.hub.conversation.allyTurnAlly()).toBe("ally_q");
    expect(s.sent.at(-1)).toBe("[好友] 在吗");
    // the Ally's message answered: the owner's words go in now
    s.opts.onEvent({ type: "assistant_text", text: "好友那边答了", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId, [allyUuid]));
    expect(t.hub.conversation.allyTurnAlly()).toBeUndefined();
    expect(s.sent.at(-1)).toBe("我来了");
    // they're in flight, their turn opens with the harness' first output
    expect(t.hub.status().busy).toBe(false);
    expect(t.hub.conversation.quiet).toBe(false);
    s.opts.onEvent({ type: "assistant_text", text: "回：我来了", parentToolUseId: null });
    s.opts.onEvent(result(s.sessionId, [s.sentUuids.at(-1)!]));
    expect(t.hub.chat.recent(1)[0]).toMatchObject({ text: "回：我来了", channel: "app" });
    expect(t.hub.chat.recent(1)[0]!.proactive).toBeFalsy();
  });
});

describe("an agent's turns", () => {
  test("words sent back to back go in one after another, in order; it's busy until the last is answered; each reply under its API id", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    let n = 0;
    const t = setup({
      palScript: async (text, ctx) => {
        if (text === "慢慢来") await gate;
        const id = `msg_t${++n}`;
        ctx.emit({ type: "text_delta", text: `回：${text}`, messageId: id });
        ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: id });
      },
    });
    const pal = await t.agent();
    const sends = ["慢慢来", "一", "二"].map((text) => t.call("pals.send", { id: pal.id, text }));
    await waitFor(() => t.driver.pals.at(-1)!.sent.length === 3);
    expect(t.driver.pals.at(-1)!.sent).toEqual(["慢慢来", "一", "二"]);
    expect(t.statusOf(pal.id)).toBe("busy");
    release();
    await Promise.all(sends);
    await waitFor(() => t.statusOf(pal.id) === "idle");
    const mine = t.palEvents("chat.message", pal.id);
    expect(mine.map((m) => `${m.role}:${m.text}`)).toEqual(["user:慢慢来", "user:一", "user:二", "assistant:回：慢慢来", "assistant:回：一", "assistant:回：二"]);
    expect(mine.filter((m) => m.role === "assistant").map((m) => m.id)).toEqual(["msg_t1", "msg_t2", "msg_t3"]);
    await t.hub.pals.stopAndWait();
  });

  test("a result that leaves words unanswered keeps it busy; the next result ends it", async () => {
    const t = setup({ palScript: async () => new Promise<void>(() => {}) });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "甲" });
    await t.call("pals.send", { id: pal.id, text: "乙" });
    const p = t.driver.pals.at(-1)!;
    const [ua, ub] = p.sentUuids;
    p.opts.onEvent({ type: "assistant_text", text: "回甲", parentToolUseId: null, messageId: "msg_a" });
    p.opts.onEvent(result(p.sessionId, [ua!]));
    expect(t.statusOf(pal.id)).toBe("busy");
    p.opts.onEvent({ type: "assistant_text", text: "回乙", parentToolUseId: null, messageId: "msg_b" });
    p.opts.onEvent(result(p.sessionId, [ub!]));
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.hub.pals.list().find((x) => x.id === pal.id)!.attention).toBe("done");
    await t.hub.pals.stopAndWait();
  });

  test("a reply in several text blocks of one API message is one message: the blocks joined by a blank line, streamed so too; another API message is another", async () => {
    const t = setup({
      palScript: async (_text, ctx) => {
        ctx.emit({ type: "text_delta", text: "第一块", messageId: "msg_j1" });
        ctx.emit({ type: "assistant_text", text: "第一块", parentToolUseId: null, messageId: "msg_j1" });
        ctx.emit({ type: "text_delta", text: "第二块", messageId: "msg_j1" });
        ctx.emit({ type: "assistant_text", text: "第二块", parentToolUseId: null, messageId: "msg_j1" });
        ctx.emit({ type: "text_delta", text: "另一条", messageId: "msg_j2" });
        ctx.emit({ type: "assistant_text", text: "另一条", parentToolUseId: null, messageId: "msg_j2" });
      },
    });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "说" });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    const out = t.palEvents("chat.message", pal.id).filter((m) => m.role === "assistant");
    expect(out.map((m) => [m.id, m.text])).toEqual([
      ["msg_j1", "第一块"],
      ["msg_j1", "第一块\n\n第二块"],
      ["msg_j2", "另一条"],
    ]);
    expect(t.palEvents("chat.delta", pal.id).map((d) => [d.id, d.text])).toEqual([
      ["msg_j1", "第一块"],
      ["msg_j1", "\n\n"],
      ["msg_j1", "第二块"],
      ["msg_j2", "另一条"],
    ]);
    await t.hub.pals.stopAndWait();
  });

  test("a reply without an API id gets one made by the host, streamed and final under it", async () => {
    const t = setup({
      palScript: async (_text, ctx) => {
        ctx.emit({ type: "text_delta", text: "无号" });
        ctx.emit({ type: "assistant_text", text: "无号", parentToolUseId: null });
      },
    });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "说" });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    const out = t.palEvents("chat.message", pal.id).filter((m) => m.role === "assistant");
    const d = t.palEvents("chat.delta", pal.id);
    expect(out).toHaveLength(1);
    expect(out[0]!.id).toMatch(/^m_/);
    expect(d.map((x) => x.id)).toEqual([out[0]!.id]);
    await t.hub.pals.stopAndWait();
  });

  test("a turn the harness starts on its own (another session's message): busy from its init, its reply shown, done at its result; a subagent's output alone doesn't make it busy", async () => {
    const t = setup();
    const pal = await t.agent();
    const p = t.driver.pals.at(-1)!;
    p.opts.onEvent({ type: "tool_use", id: "sub_x", name: "Bash", input: {}, parentToolUseId: "agent_tool_9" });
    expect(t.statusOf(pal.id)).toBe("idle");
    p.opts.onEvent({ type: "tool_result", toolUseId: "sub_x", content: "ok", isError: false, parentToolUseId: "agent_tool_9" });
    p.opts.onEvent({ type: "init", sessionId: p.sessionId, model: "fake-model", tools: [] });
    expect(t.statusOf(pal.id)).toBe("busy");
    p.opts.onEvent({ type: "assistant_text", text: "看到了", parentToolUseId: null, messageId: "msg_own" });
    p.opts.onEvent(result(p.sessionId, []));
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.palEvents("chat.message", pal.id).filter((m) => m.role === "assistant").map((m) => [m.id, m.text, m.proactive])).toEqual([["msg_own", "看到了", undefined]]);
    expect(t.hub.pals.list().find((x) => x.id === pal.id)!.attention).toBe("done");
    expect(t.pusher.pushes.every((x) => !x.body.includes("看到了"))).toBe(true);
    await t.hub.pals.stopAndWait();
  });

  test("stop mid-reply: what was streamed is kept under its id; the late result of the stopped turn says nothing and doesn't make it busy; the next words work", async () => {
    let lateResult!: () => void;
    const t = setup({
      palScript: async (text, ctx) => {
        if (text !== "长篇") {
          ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: `msg_${text}` });
          return;
        }
        ctx.emit({ type: "text_delta", text: "写到一半", messageId: "msg_cut" });
        await new Promise<void>((r) => (lateResult = r));
        ctx.emit({ type: "tool_use", id: "late_tool", name: "Bash", input: {}, parentToolUseId: null });
      },
    });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "长篇" });
    await waitFor(() => t.palEvents("chat.delta", pal.id).length === 1);
    expect(await t.call("pals.stop", { id: pal.id })).toEqual({ ok: true });
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.palEvents("chat.message", pal.id).find((m) => m.id === "msg_cut")).toMatchObject({ role: "assistant", text: "写到一半" });
    const notices = () => t.palEvents("chat.message", pal.id).filter((m) => m.kind === "notice").length;
    const n = notices();
    lateResult();
    await tick(20);
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(notices()).toBe(n);
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await waitFor(() => t.palEvents("chat.message", pal.id).some((m) => m.text === "回：在吗"));
    await waitFor(() => t.statusOf(pal.id) === "idle");
    await t.hub.pals.stopAndWait();
  });

  test("its own /compact is a silent turn: no words of the owner shown, and its result doesn't set the context size", async () => {
    const t = setup({
      palScript: async (text, ctx) => {
        if (text === "/compact") ctx.emit({ type: "compact", trigger: "manual", preTokens: 5000, postTokens: 321 });
        else ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: `msg_${text}` });
      },
    });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "先说" });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    const shown = t.palEvents("chat.message", pal.id).length;
    await t.call("pals.compact", { id: pal.id });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.palEvents("chat.message", pal.id).length).toBe(shown);
    const detail = await t.call("pals.detail", { id: pal.id });
    expect(detail.contextTokens).toBe(321);
    await t.hub.pals.stopAndWait();
  });
});
