// 停止 at its edges, the assistant's and an agent's, pinned before the two
// become one (docs/harness-adapter-design.md step 14): mid-reply, with an open
// card, with words queued behind it, stopped twice, a late result of the
// stopped turn, nothing to stop. The assistant's stop ends its turn at once
// and closes its process; an agent's is interrupted and, if Claude Code is
// slow to end it, ended by the host within a moment, its process kept.
import { afterAll, describe, expect, test } from "bun:test";
import { both, cleanupBoth, result } from "./bothRuntimes.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

afterAll(cleanupBoth);

/** 「长篇」 streams half a reply and hangs until it's stopped; 「卡住」 asks first; anything else is answered. */
const script: FakeScript = async (text, ctx) => {
  if (text === "长篇") {
    ctx.emit({ type: "text_delta", text: "写到一半", messageId: "msg_cut" });
    await ctx.interrupted;
    return;
  }
  if (text === "卡住") {
    await ctx.useTool("Bash", { command: "sleep 999" }, { ask: true });
    await ctx.interrupted;
    return;
  }
  if (text === "问") {
    await ctx.useTool("AskUserQuestion", { questions: [{ question: "选哪个？", header: "选", options: [{ label: "A" }, { label: "B" }], multiSelect: false }] }, { ask: true });
    await ctx.interrupted;
    return;
  }
  ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: `msg_${text}` });
};
const never: FakeScript = async () => new Promise<void>(() => {});

/** Counts the interrupts each process is asked for. */
function interrupts(proc: { interrupt(): Promise<void> }): () => number {
  let n = 0;
  const orig = proc.interrupt.bind(proc);
  proc.interrupt = () => (n++, orig());
  return () => n;
}

describe("the assistant's stop", () => {
  test("mid-reply: ended before stop returns, its process closed; the next words start a process on the same session", async () => {
    const t = both({ script });
    t.hub.userMessage("先说", "app");
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    t.hub.userMessage("长篇", "app");
    await tick(5);
    const proc = t.driver.last!;
    const asked = interrupts(proc);
    const before = t.events.length;
    t.hub.stopAll("app");
    expect(t.hub.status().busy).toBe(false);
    expect(t.hub.conversation.quiet).toBe(true);
    expect(asked()).toBe(1);
    expect(proc.closed).toBe(true);
    expect(t.replies().at(-1)).toMatchObject({ text: "写到一半", channel: "app" });
    // what went out: the half reply closed, then the status (idle) twice (the turn's end, the stop's)
    const out = t.events.slice(before).map((e) => e.event);
    expect(out.filter((e) => e === "chat.message")).toHaveLength(1);
    expect(t.events.slice(before).filter((e) => e.event === "status").map((e) => e.data.busy)).toEqual([false, false]);
    expect(t.hub.audit.tail(10).find((e) => e.type === "stop")).toMatchObject({ by: "app" });
    t.hub.userMessage("在吗", "app");
    await t.hub.idle();
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.opts.resumeSessionId).toBe(sid);
    expect(t.driver.last!.sent).toEqual(["在吗"]);
    expect(t.replies().at(-1)!.text).toBe("回：在吗");
  });

  test("with an open card: it's answered no, saying who stopped it", async () => {
    const t = both({ script });
    t.hub.userMessage("卡住", "app");
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    const card = t.hub.approvals.listPending()[0]!;
    t.hub.userMessage("/stop", "cli");
    expect(t.hub.approvals.listPending()).toEqual([]);
    expect(t.hub.approvals.get(card.id)).toMatchObject({ status: "denied", decidedBy: "stop:cli" });
    await tick(5);
    expect(t.driver.decisions[0]!.decision.behavior).toBe("deny");
    expect(t.hub.status().busy).toBe(false);
  });

  test("with a question open (a WeChat turn's): it's closed", async () => {
    const wechat = { status: () => "connected", reply: async () => {}, typing: async () => {}, setTyping: async () => {}, stop: async () => {} } as any;
    const t = both({ script: async (text, ctx) => script(text.replace("[来自微信] ", ""), ctx), wechat });
    t.hub.userMessage("问", "wechat", { userId: "u", contextToken: "c" } as any);
    await waitFor(() => t.hub.questions.listPending().length === 1);
    const q = t.hub.questions.listPending()[0]!;
    t.hub.stopAll("app");
    expect(t.hub.questions.listPending()).toEqual([]);
    expect(t.hub.questions.get(q.id)).toMatchObject({ status: "expired", answeredBy: "stop:app" });
    expect(t.hub.conversation.quiet).toBe(true);
  });

  test("with words queued: the owner's in flight, what waited in its queue and an Ally's message with the owner's words held for it are all dropped; its background tasks are stopped", async () => {
    const t = both({ script });
    t.hub.userMessage("长篇", "app");
    await tick(5);
    const proc = t.driver.last!;
    t.hub.userMessage("后面一句", "app");
    t.hub.conversation.enqueue({ text: "[定时] 看看", origin: "schedule", proactive: true });
    proc.opts.onEvent({ type: "tool_use", id: "tu_agent", name: "Agent", input: { description: "查资料", prompt: "x" }, parentToolUseId: null });
    proc.opts.onEvent({ type: "task_started", taskId: "sdk_1", toolUseId: "tu_agent", description: "查资料", background: true } as any);
    const task = t.hub.tasks.running()[0]!;
    expect(task.sdkTaskId).toBe("sdk_1");
    t.hub.stopAll("app");
    expect(t.driver.stoppedTasks).toEqual(["sdk_1"]);
    expect(t.hub.tasks.get(task.id)!.status).toBe("stopped");
    await t.hub.idle();
    await tick(10);
    expect(proc.sent).toEqual(["长篇", "后面一句"]);
    expect(t.driver.sessions).toHaveLength(1);
    expect(t.hub.conversation.quiet).toBe(true);

    t.driver.script = never;
    t.hub.conversation.enqueue({ text: "[好友] 在吗", origin: "system", proactive: true, allyId: "ally_s" });
    await tick(5);
    t.hub.userMessage("等它说完", "app");
    expect(t.hub.conversation.allyTurnAlly()).toBe("ally_s");
    t.hub.stopAll("app");
    expect(t.hub.conversation.allyTurnAlly()).toBeUndefined();
    expect(t.hub.conversation.quiet).toBe(true);
    await tick(10);
    expect(t.driver.last!.sent).toEqual(["[好友] 在吗"]);
    t.driver.script = script;
    t.hub.userMessage("新的", "app");
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["新的"]);
  });

  test("words in flight with no turn open (the last result left them): interrupted, not dropped, its process stays", async () => {
    const t = both({ script: never });
    const a = t.hub.userMessage("甲", "app")!;
    t.hub.userMessage("乙", "app");
    await tick(5);
    const proc = t.driver.last!;
    const asked = interrupts(proc);
    proc.opts.onEvent(result(proc.sessionId, [a.uuid!]));
    expect(t.hub.status().busy).toBe(false);
    t.hub.stopAll("app");
    expect(asked()).toBe(1);
    expect(proc.closed).toBe(false);
    expect(t.hub.conversation.quiet).toBe(false);
  });

  test("twice, and with nothing running: nothing more ends, the process of an idle one stays, it's asked to interrupt, and it goes on as usual", async () => {
    const t = both({ script });
    t.hub.stopAll("app"); // before it has a process
    expect(t.driver.sessions).toHaveLength(0);
    t.hub.userMessage("长篇", "app");
    await tick(5);
    const first = t.driver.last!;
    const asked = interrupts(first);
    t.hub.stopAll("app");
    const shown = t.hub.chat.lastSeq;
    t.hub.stopAll("app");
    expect(asked()).toBe(1);
    expect(t.hub.chat.lastSeq).toBe(shown);
    t.hub.userMessage("在吗", "app");
    await t.hub.idle();
    const idle = t.driver.last!;
    const again = interrupts(idle);
    t.hub.stopAll("app");
    expect(again()).toBe(1);
    expect(idle.closed).toBe(false);
    t.hub.userMessage("还在吗", "app");
    await t.hub.idle();
    expect(t.driver.last).toBe(idle);
    expect(t.replies().at(-1)!.text).toBe("回：还在吗");
  });

  test("a late result of the stopped turn: nothing shown, no error said, not busy; the next turn is its own", async () => {
    const t = both({ script });
    const m = t.hub.userMessage("长篇", "app")!;
    await tick(5);
    const proc = t.driver.last!;
    t.hub.stopAll("app");
    const shown = t.hub.chat.lastSeq;
    proc.opts.onEvent(result(proc.sessionId, [m.uuid!], { isError: true, text: "Request was aborted.", costUsd: 0.5, totalCostUsd: 0.5 }));
    expect(t.hub.chat.lastSeq).toBe(shown);
    expect(t.hub.status().busy).toBe(false);
    t.driver.script = never;
    const next = t.hub.userMessage("在吗", "app")!;
    await tick(5);
    // even after the next words went in, one that names the old message ends their turn (the host's: every result does), and they stay unanswered
    proc.opts.onEvent(result(proc.sessionId, [m.uuid!]));
    expect(t.hub.status().busy).toBe(false);
    expect(t.hub.conversation.quiet).toBe(false);
    const p = t.driver.last!;
    p.opts.onEvent({ type: "assistant_text", text: "在", parentToolUseId: null });
    p.opts.onEvent(result(p.sessionId, [next.uuid!]));
    expect(t.replies().at(-1)!).toMatchObject({ text: "在", channel: "app" });
    expect(t.replies().at(-1)!.proactive).toBeFalsy();
    expect(t.hub.conversation.quiet).toBe(true);
  });

  test("late output of the stopped turn's process opens a turn of the harness' own, as any output with nothing in flight does", async () => {
    const t = both({ script });
    t.hub.userMessage("长篇", "app");
    await tick(5);
    const proc = t.driver.last!;
    t.hub.stopAll("app");
    proc.opts.onEvent({ type: "assistant_text", text: "还有一句", parentToolUseId: null });
    expect(t.hub.status().busy).toBe(true);
    proc.opts.onEvent(result(proc.sessionId, []));
    expect(t.hub.chat.recent(1)[0]).toMatchObject({ text: "还有一句", proactive: true, channel: "system" });
  });
});

describe("an agent's stop", () => {
  test("mid-reply: Claude Code ends it at once, its process kept; nothing says it finished; the next words go to the same process", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "长篇" });
    await waitFor(() => t.palEvents("chat.delta", pal.id).length === 1);
    const proc = t.driver.pals.at(-1)!;
    const asked = interrupts(proc);
    const t0 = Date.now();
    await t.call("pals.stop", { id: pal.id });
    expect(Date.now() - t0).toBeLessThan(150); // (not the whole settle)
    expect(asked()).toBe(1);
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.attentionOf(pal.id)).toBe("idle");
    expect(proc.closed).toBe(false);
    expect(t.said(pal.id)).toEqual(["user:长篇", "assistant:写到一半"]);
    expect(t.hub.audit.tail(10).find((e) => e.type === "pal.stop")).toMatchObject({ pal: pal.id, by: "app" });
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await waitFor(() => t.said(pal.id).at(-1) === "assistant:回：在吗" && t.statusOf(pal.id) === "idle");
    expect(t.driver.pals.at(-1)).toBe(proc);
    await t.hub.pals.stopAndWait();
  });

  test("with an open card or question: closed saying who stopped it; another agent's and the assistant's stay", async () => {
    const t = both({ script, palScript: script });
    const a = await t.agent();
    const b = await t.agent();
    t.hub.userMessage("卡住", "app");
    await t.call("pals.send", { id: a.id, text: "卡住" });
    await t.call("pals.send", { id: b.id, text: "问" });
    await waitFor(() => t.hub.approvals.listPending().length === 2 && t.hub.questions.listPending().length === 1);
    const mine = t.hub.approvals.listPending().find((x) => x.source?.id === a.id)!;
    expect(t.statusOf(a.id)).toBe("waiting");
    await t.call("pals.stop", { id: a.id });
    expect(t.hub.approvals.get(mine.id)).toMatchObject({ status: "denied", decidedBy: "stop:app" });
    expect(t.hub.approvals.listPending()).toHaveLength(1);
    expect(t.hub.approvals.listPending()[0]!.source).toBeUndefined();
    expect(t.hub.questions.listPending()).toHaveLength(1);
    expect(t.statusOf(a.id)).toBe("idle");
    const q = t.hub.questions.listPending()[0]!;
    await t.call("pals.stop", { id: b.id });
    expect(t.hub.questions.get(q.id)).toMatchObject({ status: "expired", answeredBy: "stop:app" });
    expect(t.statusOf(b.id)).toBe("idle");
    await t.hub.pals.stopAndWait();
  });

  test("with words queued behind it: they're dropped with the turn, whether Claude Code ended it or the host did", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    const proc = t.driver.pals.at(-1)!;
    await t.call("pals.send", { id: pal.id, text: "长篇" });
    await t.call("pals.send", { id: pal.id, text: "后面一句" });
    await waitFor(() => t.palEvents("chat.delta", pal.id).length === 1);
    const t0 = Date.now();
    await t.call("pals.stop", { id: pal.id }); // its result leaves 「后面一句」 unanswered: the host drops it after the settle
    expect(Date.now() - t0).toBeGreaterThanOrEqual(200);
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(proc.sent).toEqual(["长篇", "后面一句"]);
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await waitFor(() => t.said(pal.id).at(-1) === "assistant:回：在吗");
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.said(pal.id)).not.toContain("assistant:回：后面一句");

    // Claude Code never ends it
    t.driver.palScript = async (text, ctx) => {
      if (text !== "不理") return script(text, ctx);
      ctx.emit({ type: "tool_use", id: "tu_hang", name: "Bash", input: {}, parentToolUseId: null });
      await new Promise<void>(() => {});
    };
    await t.call("pals.send", { id: pal.id, text: "不理" });
    await t.call("pals.send", { id: pal.id, text: "又一句" });
    await waitFor(() => t.statusOf(pal.id) === "busy");
    await t.call("pals.stop", { id: pal.id });
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.driver.pals.at(-1)).toBe(proc);
    expect(proc.closed).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("words sent while it settles: they go in, what's left of the stopped turn doesn't take them with it once answered", async () => {
    let end!: () => void;
    const t = both({
      palScript: async (text, ctx) => {
        if (text !== "慢") return script(text, ctx);
        ctx.emit({ type: "text_delta", text: "半", messageId: "msg_half" });
        await new Promise<void>((r) => (end = r));
      },
    });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "慢" });
    await waitFor(() => t.palEvents("chat.delta", pal.id).length === 1);
    const stopping = t.call("pals.stop", { id: pal.id });
    await tick(20);
    const proc = t.driver.pals.at(-1)!;
    await t.call("pals.send", { id: pal.id, text: "改说这个" });
    await stopping;
    expect(t.statusOf(pal.id)).toBe("idle"); // ended by the host, the new words with it
    end();
    await waitFor(() => t.said(pal.id).includes("assistant:回：改说这个"));
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(proc.sent).toEqual(["慢", "改说这个"]);
    expect(t.said(pal.id)).toEqual(["user:慢", "user:改说这个", "assistant:半", "assistant:回：改说这个"]);
    await t.hub.pals.stopAndWait();
  });

  test("twice at once: one end; the second after it's idle does nothing", async () => {
    const t = both({
      palScript: async (text, ctx) => {
        if (text !== "不理") return script(text, ctx);
        ctx.emit({ type: "text_delta", text: "半", messageId: "msg_half" });
        await new Promise<void>(() => {});
      },
    });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "不理" });
    await waitFor(() => t.palEvents("chat.delta", pal.id).length === 1);
    const asked = interrupts(t.driver.pals.at(-1)!);
    await Promise.all([t.call("pals.stop", { id: pal.id }), t.call("pals.stop", { id: pal.id })]);
    expect(asked()).toBe(2);
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.said(pal.id)).toEqual(["user:不理", "assistant:半"]);
    await t.call("pals.stop", { id: pal.id });
    expect(asked()).toBe(2); // idle: nothing to interrupt
    expect(t.said(pal.id)).toEqual(["user:不理", "assistant:半"]);
    await t.hub.pals.stopAndWait();
  });

  test("idle or asleep: nothing is interrupted or started", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    const asked = interrupts(t.driver.pals.at(-1)!);
    await t.call("pals.stop", { id: pal.id });
    expect(asked()).toBe(0);
    await t.pal(pal.id).sleep();
    const n = t.driver.pals.length;
    await t.call("pals.stop", { id: pal.id });
    expect(t.statusOf(pal.id)).toBe("asleep");
    expect(t.driver.pals).toHaveLength(n);
  });

  test("a late error result of the stopped turn: no notice, not finished, not busy; its next turn's error is said again", async () => {
    const t = both({ palScript: never });
    const pal = await t.agent();
    const proc = t.driver.pals.at(-1)!;
    await t.call("pals.send", { id: pal.id, text: "甲" });
    await waitFor(() => t.statusOf(pal.id) === "busy");
    await t.call("pals.stop", { id: pal.id });
    expect(t.statusOf(pal.id)).toBe("idle");
    proc.opts.onEvent({ type: "assistant_text", text: "晚到的", parentToolUseId: null, messageId: "msg_late" });
    expect(t.statusOf(pal.id)).toBe("idle"); // said, but it opens no turn
    proc.opts.onEvent(result(proc.sessionId, [proc.sentUuids[0]!], { isError: true, text: "Request was aborted." }));
    expect(t.statusOf(pal.id)).toBe("idle");
    expect(t.attentionOf(pal.id)).toBe("idle");
    expect(t.said(pal.id)).toEqual(["user:甲", "assistant:晚到的"]);
    proc.opts.onEvent({ type: "init", sessionId: proc.sessionId, model: "fake-model", tools: [] });
    proc.opts.onEvent(result(proc.sessionId, [], { isError: true, text: "API Error: 500 boom" }));
    expect(t.said(pal.id).at(-1)).toStartWith("notice:");
    await t.hub.pals.stopAndWait();
  });

  test("its process dies while it settles: the agent comes back as usual", async () => {
    const t = both({ palScript: never });
    const pal = await t.agent();
    const proc = t.driver.pals.at(-1)!;
    await t.call("pals.send", { id: pal.id, text: "甲" });
    await waitFor(() => t.statusOf(pal.id) === "busy");
    const stopping = t.call("pals.stop", { id: pal.id });
    await tick(10);
    proc.crash();
    await stopping;
    await waitFor(() => t.driver.pals.length === 2 && t.statusOf(pal.id) === "idle", 3_000);
    await t.hub.pals.stopAndWait();
  });
});
