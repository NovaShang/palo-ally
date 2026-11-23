// A process that froze mid-work is ended and resumed (the stall watchdog's
// recover), the assistant's and an agent's, pinned before the two become one
// (docs/harness-adapter-design.md step 14): each kind of turn, the words it
// took and the words it never did, several restarts in a row, words arriving
// meanwhile. The assistant re-queues its turn as the same kind; an agent is
// told to go on.
import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { transcriptPath } from "../src/harness/claude/paths.ts";
import { t as tr } from "../src/i18n/index.ts";
import { both, cleanupBoth, result } from "./bothRuntimes.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

afterAll(cleanupBoth);

const CONTINUE = tr("stall.continue");
const CONTINUE_PROACTIVE = tr("stall.continueProactive");

/** Words beginning with 卡 freeze the process; anything else is answered. */
const script: FakeScript = async (text, ctx) => {
  if (/^(\[[^\]]+\] )?卡/.test(text)) return new Promise<void>(() => {});
  ctx.emit({ type: "assistant_text", text: `回：${text.slice(0, 6)}`, parentToolUseId: null, messageId: `msg_${ctx.session.sentUuids.length}_${Math.random().toString(36).slice(2, 6)}` });
};

/** The harness wrote these messages in the session's transcript: it took them. */
function took(t: ReturnType<typeof both>, cwd: string, sid: string, uuids: string[]): void {
  const p = transcriptPath(t.claude.dir, cwd, sid);
  mkdirSync(join(p, ".."), { recursive: true });
  appendFileSync(p, uuids.map((uuid) => JSON.stringify({ type: "user", uuid, parentUuid: null, message: { role: "user", content: "x" } }) + "\n").join(""));
}

/** The assistant, after one answered turn. */
async function main(o: Parameters<typeof both>[0] = {}) {
  const t = both({ script, ...o });
  t.hub.userMessage("你好", "app");
  await t.hub.idle();
  return { ...t, sid: t.hub.status().sessionId! };
}

describe("the assistant, stalled", () => {
  test("what the watchdog sees of it: busy with a turn or words unanswered, waiting on its own cards, its open tools, its transcript's growth, its pid from the registry", async () => {
    const t = await main();
    const s = t.stall("main");
    expect(s.name).toBe("Palo");
    expect([s.busy(), s.waiting(), s.openTools(), s.pid()]).toEqual([false, false, [], undefined]);
    const a = t.hub.userMessage("卡", "app")!;
    expect(s.busy()).toBe(true);
    const proc = t.driver.last!;
    const then = s.lastActivity();
    await tick(3);
    proc.opts.onEvent({ type: "tool_use", id: "tu1", name: "Bash", input: {}, parentToolUseId: null });
    proc.opts.onEvent({ type: "tool_use", id: "tu2", name: "Grep", input: {}, parentToolUseId: "sub" });
    expect(s.openTools()).toEqual(["Bash", "Grep"]);
    expect(s.lastActivity()).toBeGreaterThan(then);
    const before = s.progress();
    took(t, t.paths.home, t.sid, [a.uuid!]);
    expect(s.progress()).not.toBe(before);
    t.claude.register({ sessionId: t.sid, name: "palo", cwd: t.paths.home, pid: process.pid });
    expect(s.pid()).toBe(process.pid);
    // between turns, with words still unanswered
    proc.opts.onEvent(result(proc.sessionId, []));
    expect(s.busy()).toBe(true);
    t.hub.stopAll("app");
    t.hub.conversation.close();
    expect(s.busy()).toBe(false);
  });

  test("the owner's turn, its words taken: asked to go on as a turn of the same channel on the same session; the reply is the owner's", async () => {
    const t = await main();
    const a = t.hub.userMessage("卡住的活", "cli")!;
    await tick(5);
    const frozen = t.driver.last!;
    frozen.opts.onEvent({ type: "text_delta", text: "写了一半" });
    took(t, t.paths.home, t.sid, [a.uuid!]);
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    expect(frozen.closed).toBe(true);
    const now = t.driver.last!;
    expect(now).not.toBe(frozen);
    expect(now.opts.resumeSessionId).toBe(t.sid);
    expect(now.sent).toEqual([CONTINUE]);
    expect(now.sentUuids[0]).not.toBe(a.uuid!);
    await t.hub.idle();
    const r = t.replies().slice(-2);
    expect(r.map((m) => `${m.channel}:${m.text}`)).toEqual(["cli:写了一半", `cli:回：${CONTINUE.slice(0, 6)}`]);
    expect(r.every((m) => !m.proactive)).toBe(true);
    expect(t.hub.conversation.quiet).toBe(true);
  });

  test("the owner's words it never took go in again under the same ids with their images, as one turn; nothing is asked to go on", async () => {
    const t = await main();
    const { id } = t.hub.media.save("image/png", "iVBORw0KGgo=");
    const a = t.hub.userMessage("卡，看图", "app", undefined, undefined, [{ kind: "image", id, name: "a.png", mediaType: "image/png", size: 8 } as any])!;
    const b = t.hub.userMessage("还有一句", "cli")!;
    await tick(5);
    const frozen = t.driver.last!;
    const images = [...frozen.sentImages];
    t.driver.script = async () => new Promise<void>(() => {});
    expect(await t.stall("main").recover()).toEqual({ resent: 2, continued: false });
    const now = t.driver.last!;
    expect(now).not.toBe(frozen);
    expect(now.sent).toEqual(["卡，看图", "还有一句"]);
    expect(now.sentUuids).toEqual([a.uuid!, b.uuid!]);
    expect(now.sentImages).toEqual(images);
    expect(t.hub.status().busy).toBe(true);
    // one turn answers both, on the first one's channel (an older CLI that doesn't say which)
    now.opts.onEvent({ type: "assistant_text", text: "都看了", parentToolUseId: null });
    now.opts.onEvent(result(now.sessionId));
    expect(t.replies().at(-1)).toMatchObject({ text: "都看了", channel: "app" });
    expect(t.hub.conversation.quiet).toBe(true);
    // shown once each
    expect(t.hub.chat.since(0).filter((m) => m.role === "user").map((m) => m.text)).toEqual(["你好", "卡，看图", "还有一句"]);
  });

  test("some taken, some not: only the ones not taken go in again", async () => {
    const t = await main();
    const a = t.hub.userMessage("卡一", "app")!;
    const b = t.hub.userMessage("二", "app")!;
    await tick(5);
    took(t, t.paths.home, t.sid, [a.uuid!]);
    expect(await t.stall("main").recover()).toEqual({ resent: 1, continued: false });
    expect(t.driver.last!.sentUuids).toEqual([b.uuid!]);
    await t.hub.idle();
    expect(t.replies().at(-1)!.text).toBe("回：二");
  });

  test("words it took with no turn open yet: asked to go on on their channel", async () => {
    const t = await main();
    const a = t.hub.userMessage("卡一", "app")!;
    const b = t.hub.userMessage("卡二", "cli")!;
    await tick(5);
    const frozen = t.driver.last!;
    frozen.opts.onEvent(result(frozen.sessionId, [a.uuid!]));
    expect(t.hub.status().busy).toBe(false);
    took(t, t.paths.home, t.sid, [a.uuid!, b.uuid!]);
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    expect(t.driver.last!.sent).toEqual([CONTINUE]);
    await t.hub.idle();
    expect(t.replies().at(-1)).toMatchObject({ channel: "cli" });
    expect(t.replies().at(-1)!.proactive).toBeFalsy();
  });

  test("a goal's run: asked to go on as that run (proactive; its words are the goal's line and a card); what waited behind it goes after", async () => {
    const t = await main();
    const goal = t.hub.watches.add({ title: "房租", instruction: "看看房租", at: ["08:30"] }, "user");
    t.hub.conversation.enqueue({ text: "[定时] 卡", origin: "schedule", proactive: true, label: "房租", watchId: goal.id });
    await tick(5);
    t.hub.conversation.enqueue({ text: "[定时] 另一件", origin: "schedule", proactive: true, label: "另一件" });
    expect(t.driver.last!.sent).toEqual(["你好", "[定时] 卡"]);
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    expect(t.driver.last!.sent[0]).toBe(CONTINUE_PROACTIVE);
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual([CONTINUE_PROACTIVE, "[定时] 另一件"]);
    expect(t.hub.watches.get(goal.id)!.progress).toBe(`回：${CONTINUE_PROACTIVE.slice(0, 6)}`);
    expect(t.replies().at(-2)).toMatchObject({ proactive: true, channel: "schedule", card: { title: "resume", goalId: goal.id } });
  });

  test("the host's own /compact: not asked to go on; the owner's later words work", async () => {
    const t = await main();
    t.driver.script = async () => new Promise<void>(() => {});
    t.hub.conversation.enqueue({ text: "/compact", origin: "system", proactive: true, maintenance: true, label: "compact" });
    await tick(5);
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: false });
    expect(t.driver.sessions).toHaveLength(1);
    expect(t.hub.conversation.quiet).toBe(true);
    t.driver.script = script;
    t.hub.userMessage("在吗", "app");
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["在吗"]);
    expect(t.driver.last!.opts.resumeSessionId).toBe(t.sid);
  });

  test("an Ally's turn: its message isn't sent again nor asked to go on; its gate lifts; the owner's words held for it go in", async () => {
    const t = await main();
    t.hub.conversation.enqueue({ text: "[好友] 卡", origin: "system", proactive: true, allyId: "ally_x" });
    await tick(5);
    const m = t.hub.userMessage("等它说完", "cli")!;
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: false });
    expect(t.hub.conversation.allyTurnAlly()).toBeUndefined();
    expect(t.hub.audit.tail(10).find((e) => e.type === "ally.turn.end")).toMatchObject({ allyId: "ally_x", why: "stalled", held: 1 });
    expect(t.driver.last!.sent).toEqual(["等它说完"]);
    expect(t.driver.last!.sentUuids).toEqual([m.uuid!]);
    await t.hub.idle();
    expect(t.replies().at(-1)).toMatchObject({ text: "回：等它说完", channel: "cli" });
  });

  test("a WeChat turn: goes on as one, answered there", async () => {
    const sent: string[] = [];
    const wechat = { status: () => "connected", reply: async (_t: unknown, s: string) => void sent.push(s), typing: async () => {}, setTyping: async () => {}, stop: async () => {} } as any;
    const t = await main({ wechat });
    const target = { userId: "u", contextToken: "c" } as any;
    const m = t.hub.userMessage("卡", "wechat", target)!;
    await tick(5);
    took(t, t.paths.home, t.sid, [m.uuid!]);
    t.driver.script = async () => new Promise<void>(() => {});
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    expect(t.hub.conversation.wechatTarget()).toEqual(target);
    const now = t.driver.last!;
    now.opts.onEvent({ type: "assistant_text", text: "办好了", parentToolUseId: null });
    now.opts.onEvent(result(now.sessionId, [now.sentUuids[0]!]));
    await tick(5);
    expect(sent).toEqual(["办好了"]);
    expect(t.replies().at(-1)).toMatchObject({ channel: "wechat", text: "办好了" });
    // words never taken: their turn is a WeChat turn too
    t.hub.userMessage("卡卡", "wechat", target);
    await tick(5);
    expect(await t.stall("main").recover()).toEqual({ resent: 1, continued: false });
    expect(t.hub.conversation.wechatTarget()).toEqual(target);
  });

  test("several restarts in a row: the words go in each time under the same id until it takes them, then it's asked to go on; the session stays the same", async () => {
    const t = await main();
    const a = t.hub.userMessage("卡", "app")!;
    await tick(5);
    for (let i = 0; i < 3; i++) {
      expect(await t.stall("main").recover()).toEqual({ resent: 1, continued: false });
      await tick(5);
      expect(t.driver.last!.sentUuids).toEqual([a.uuid!]);
      expect(t.hub.status().busy).toBe(true);
    }
    took(t, t.paths.home, t.sid, [a.uuid!]);
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    expect(t.driver.sessions).toHaveLength(5);
    expect(t.driver.sessions.slice(1).every((s) => s.opts.resumeSessionId === t.sid)).toBe(true);
    await t.hub.idle();
    expect(t.hub.conversation.quiet).toBe(true);
    // a turn going on that froze again goes on again
    t.hub.userMessage("卡", "app");
    await tick(5);
    const b = t.driver.last!.sentUuids.at(-1)!;
    took(t, t.paths.home, t.sid, [b]);
    t.driver.script = async () => new Promise<void>(() => {});
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    await tick(5);
    expect(await t.stall("main").recover()).toEqual({ resent: 0, continued: true });
    expect(t.driver.last!.sent).toEqual([CONTINUE]);
  });

  test("words arriving while the frozen process is being killed: they start the new one at once and are counted with the ones never taken (they go in under the same id again)", async () => {
    const t = await main();
    const p = spawn("/bin/sleep", ["60"]);
    t.claude.register({ sessionId: t.sid, name: "palo", cwd: t.paths.home, pid: p.pid });
    const a = t.hub.userMessage("卡", "app")!;
    await tick(5);
    const recovering = t.stall("main").recover();
    await tick(10);
    t.driver.script = async () => new Promise<void>(() => {});
    const b = t.hub.userMessage("新来的", "app")!;
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.sent).toEqual(["新来的"]);
    expect(await recovering).toEqual({ resent: 2, continued: false });
    expect(p.killed || p.signalCode !== null || p.exitCode !== null).toBe(true);
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.sentUuids).toEqual([b.uuid!, a.uuid!, b.uuid!]);
    expect(t.hub.status().busy).toBe(true);
    const now = t.driver.last!;
    now.opts.onEvent({ type: "assistant_text", text: "都答了", parentToolUseId: null });
    now.opts.onEvent(result(now.sessionId, [a.uuid!, b.uuid!]));
    expect(t.hub.conversation.quiet).toBe(true);
    expect(t.replies().at(-1)).toMatchObject({ text: "都答了", channel: "app" });
  });
});

describe("an agent, stalled", () => {
  test("what the watchdog sees of it", async () => {
    const t = both({ script, palScript: script, spawn: true });
    const pal = await t.agent();
    const s = t.stall(pal.id);
    expect([s.name, s.busy(), s.waiting(), s.openTools()]).toEqual([pal.name, false, false, []]);
    expect(s.pid()).toBe(t.driver.pals.at(-1)!.proc!.pid);
    await t.call("pals.send", { id: pal.id, text: "卡" });
    expect(s.busy()).toBe(true);
    const proc = t.driver.pals.at(-1)!;
    proc.opts.onEvent({ type: "tool_use", id: "tu1", name: "Bash", input: {}, parentToolUseId: null });
    expect(s.openTools()).toEqual(["Bash"]);
    const before = s.progress();
    took(t, t.project, pal.sessionId, [proc.sentUuids[0]!]);
    expect(s.progress()).not.toBe(before);
    void proc.opts.canUseTool({ toolName: "Bash", input: { command: "ls" }, toolUseId: "tu1", signal: new AbortController().signal });
    await tick(5);
    expect(s.waiting()).toBe(true);
    await t.hub.pals.stopAndWait();
  });

  test("words it never took go in again under the same ids with their images; a notice says it was restarted, not that it was interrupted; shown once", async () => {
    const t = both({ palScript: script, spawn: true });
    const pal = await t.agent();
    const { id } = t.hub.media.save("image/png", "iVBORw0KGgo=");
    await t.call("pals.send", { id: pal.id, text: "卡，看图", attachments: [id] });
    await t.call("pals.send", { id: pal.id, text: "还有" });
    const frozen = t.driver.pals.at(-1)!;
    await waitFor(() => frozen.sent.length === 2);
    const pid = frozen.proc!.pid!;
    t.driver.palScript = async () => new Promise<void>(() => {});
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 2, continued: false });
    expect(frozen.closed).toBe(true);
    const now = t.driver.pals.at(-1)!;
    expect(now).not.toBe(frozen);
    expect(now.proc!.pid).not.toBe(pid);
    expect(now.opts.resumeSessionId ?? now.opts.sessionId).toBe(pal.sessionId);
    expect(now.sent).toEqual(frozen.sent);
    expect(now.sentUuids).toEqual(frozen.sentUuids);
    expect(now.sentImages).toEqual(frozen.sentImages);
    expect(t.said(pal.id)).toEqual(["user:卡，看图", "user:还有", `notice:${tr("pals.stuckRestarted")}`]);
    expect(t.statusOf(pal.id)).toBe("busy");
    now.opts.onEvent({ type: "assistant_text", text: "看了", parentToolUseId: null, messageId: "msg_see" });
    now.opts.onEvent(result(now.sessionId, now.sentUuids));
    expect(t.statusOf(pal.id)).toBe("idle");
    await t.hub.pals.stopAndWait();
  });

  test("words it took, mid-reply: what was streamed is kept; it's told to go on, as the assistant's words", async () => {
    const t = both({ palScript: script, spawn: true });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "卡住的活" });
    const frozen = t.driver.pals.at(-1)!;
    await waitFor(() => t.statusOf(pal.id) === "busy");
    frozen.opts.onEvent({ type: "text_delta", text: "写了一半", messageId: "msg_half" });
    took(t, t.project, pal.sessionId, frozen.sentUuids);
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 0, continued: true });
    const now = t.driver.pals.at(-1)!;
    expect(now.opts.resumeSessionId).toBe(pal.sessionId);
    expect(now.sent).toEqual([CONTINUE]);
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.said(pal.id)).toEqual(["user:卡住的活", "assistant:写了一半", `notice:${tr("pals.stuckRestarted")}`, `user:${CONTINUE}`, `assistant:回：${CONTINUE.slice(0, 6)}`]);
    const told = t.palEvents("chat.message", pal.id).find((m) => m.text === CONTINUE)!;
    expect(told).toMatchObject({ role: "user", from: "Palo", channel: "system" });
    await t.hub.pals.stopAndWait();
  });

  test("a turn of the harness' own (no words of the owner): told to go on; with nothing on: restarted, told nothing", async () => {
    const t = both({ palScript: script, spawn: true });
    const pal = await t.agent();
    const p = t.driver.pals.at(-1)!;
    p.opts.onEvent({ type: "init", sessionId: p.sessionId, model: "fake-model", tools: [] });
    expect(t.statusOf(pal.id)).toBe("busy");
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 0, continued: true });
    expect(t.driver.pals.at(-1)!.sent).toEqual([CONTINUE]);
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 0, continued: false });
    expect(t.driver.pals.at(-1)!.sent).toEqual([]);
    expect(t.statusOf(pal.id)).toBe("idle");
    await t.hub.pals.stopAndWait();
  });

  test("an open card: closed with its process; the turn is told to go on", async () => {
    const t = both({ palScript: async (text, ctx) => (text === "要问" ? void (await ctx.useTool("Bash", { command: "ls" }, { ask: true })) : script(text, ctx)), spawn: true });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "要问" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    took(t, t.project, pal.sessionId, t.driver.pals.at(-1)!.sentUuids);
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 0, continued: true });
    expect(t.hub.approvals.listPending()).toEqual([]);
    await t.hub.pals.stopAndWait();
  });

  test("several restarts in a row: the words go in each time under the same id until it takes them, then it's told to go on", async () => {
    const t = both({ palScript: script, spawn: true });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "卡" });
    const uuid = t.driver.pals.at(-1)!.sentUuids[0]!;
    for (let i = 0; i < 2; i++) {
      expect(await t.stall(pal.id).recover()).toEqual({ resent: 1, continued: false });
      await tick(5);
      expect(t.driver.pals.at(-1)!.sentUuids).toEqual([uuid]);
      expect(t.statusOf(pal.id)).toBe("busy");
    }
    took(t, t.project, pal.sessionId, [uuid]);
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 0, continued: true });
    expect(t.driver.pals).toHaveLength(4);
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.said(pal.id).filter((m) => m === "user:卡")).toHaveLength(1);
    await t.hub.pals.stopAndWait();
  });

  test("words arriving while it's being restarted: the ones it never took still go in, once; the new ones are shown once", async () => {
    const t = both({ palScript: script, spawn: true });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "卡" });
    const uuid = t.driver.pals.at(-1)!.sentUuids[0]!;
    t.driver.palScript = async () => new Promise<void>(() => {});
    const recovering = t.stall(pal.id).recover();
    const sending = t.call("pals.send", { id: pal.id, text: "新来的" });
    expect((await recovering).resent).toBe(1);
    await sending;
    // (the ones it never took are in the process it ended up with, once; the new ones may have
    // gone into one the restart's own clean-up ended: not pinned)
    const now = t.driver.pals.at(-1)!;
    expect(now.sentUuids.filter((u) => u === uuid)).toHaveLength(1);
    expect(t.said(pal.id).filter((m) => m === "user:新来的")).toHaveLength(1);
    await t.hub.pals.stopAndWait();
  });

  test("it can't be started again: the recovery fails saying why, and the owner's next words start it", async () => {
    const t = both({ palScript: script, spawn: true });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "卡" });
    t.driver.failPalStart = () => "Claude Code process exited with code 1. stderr: Error: not logged in";
    await expect(t.stall(pal.id).recover()).rejects.toThrow("Claude Code 没登录");
    expect(t.said(pal.id)).toEqual(["user:卡"]);
    t.driver.failPalStart = undefined;
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    expect(t.driver.pals.at(-1)!.sent).toEqual(["在吗"]);
    await t.hub.pals.stopAndWait();
  });

  test("gone back (回到这里重来) and not written yet: what it was told goes in again on the fork", async () => {
    const t = both({ palScript: script, spawn: true });
    const sid = "eeee5555-0000-4000-8000-000000000001";
    t.cli.bg({ sessionId: sid, name: "网站", cwd: t.project });
    const p = transcriptPath(t.claude.dir, t.project, sid);
    mkdirSync(join(p, ".."), { recursive: true });
    const e = (uuid: string, parentUuid: string | null, type: string, content: unknown) => JSON.stringify({ type, uuid, parentUuid, timestamp: "2026-11-01T08:00:00Z", message: { role: type, content, ...(type === "assistant" ? { id: `msg_${uuid}` } : {}) }, ...(type === "user" ? { origin: { kind: "human" } } : {}) });
    writeFileSync(p, [e("p1", null, "user", "一"), e("r1", "p1", "assistant", [{ type: "text", text: "好" }]), e("p2", "r1", "user", "二"), e("r2", "p2", "assistant", [{ type: "text", text: "好" }])].join("\n") + "\n");
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    await t.call("pals.rewind", { id: pal.id, messageId: "p2" });
    await t.call("pals.send", { id: pal.id, text: "卡" });
    const uuid = t.driver.pals.at(-1)!.sentUuids[0]!;
    expect(await t.stall(pal.id).recover()).toEqual({ resent: 1, continued: false });
    expect(t.driver.pals.at(-1)!.opts.fork).toEqual({ fromSessionId: sid, at: "r1" });
    expect(t.driver.pals.at(-1)!.sentUuids).toEqual([uuid]);
    await t.hub.pals.stopAndWait();
  });
});
