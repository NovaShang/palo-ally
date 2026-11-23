// 立刻处理: words that come while a step holds the turn show as waiting; when
// every such step can go on in the background, the owner has that done and
// they are read now. The assistant and an agent alike.
import { afterAll, describe, expect, test } from "bun:test";
import { both, cleanupBoth, result } from "./bothRuntimes.ts";
import type { FakeMainSession, FakeScript } from "./fakeDriver.ts";
import { mapMessage } from "../src/harness/claude/driver.ts";
import { waitFor } from "./relayClient.ts";

afterAll(cleanupBoth);

/** A turn held by tool calls it names (a "*" has its task started), until stopped. */
const script: FakeScript = async (text, ctx) => {
  const m = /^卡住 (.+)$/.exec(text);
  if (!m) return void ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: `msg_${text}` });
  for (const n of m[1]!.split(" ")) {
    const name = n.replace("*", "");
    ctx.emit({ type: "tool_use", id: `t_${name}`, name, input: {}, parentToolUseId: null });
    if (n.endsWith("*")) ctx.emit({ type: "task_started", taskId: `k_${name}`, toolUseId: `t_${name}`, description: name });
  }
  await ctx.interrupted;
};
type T = ReturnType<typeof both>;

for (const kind of ["assistant", "agent"] as const) {
  describe(`words waiting for ${kind === "assistant" ? "the assistant" : "an agent"}`, () => {
    async function held(steps: string) {
      const t: T = both({ script, palScript: script });
      const pal = kind === "agent" ? await t.agent() : null;
      const say = async (text: string) => void (pal ? await t.call("pals.send", { id: pal.id, text }) : t.hub.userMessage(text, "app"));
      const proc = () => (pal ? t.driver.pals.at(-1)! : t.driver.last!) as FakeMainSession & { backgroundSteps?: () => Promise<void> };
      const wire = () => (pal ? t.hub.pals.list().find((p) => p.id === pal.id)! : t.hub.status()) as any;
      const now = () => t.call(pal ? "pals.handleNow" : "chat.handleNow", pal ? { id: pal.id } : {});
      await say(`卡住 ${steps}`);
      await waitFor(() => (pal ? wire().status === "busy" : wire().busy) && proc().sent.length === 1);
      const emit = (e: any) => proc().opts.onEvent(e);
      let moved = 0;
      proc().backgroundSteps = async () => {
        moved++;
        for (const n of steps.split(" ").filter((s) => s.endsWith("*")).map((s) => s.replace("*", ""))) {
          emit({ type: "task_backgrounded", taskId: `k_${n}` });
          emit({ type: "tool_result", toolUseId: `t_${n}`, content: "in the background", isError: false, parentToolUseId: null });
        }
      };
      const queue = async (text: string) => {
        await say(text);
        await waitFor(() => proc().sent.includes(text));
        const uuid = proc().sentUuids[proc().sent.indexOf(text)]!;
        emit({ type: "words", uuid, state: "queued" });
        return uuid;
      };
      return { t, pal, proc, wire, now, emit, queue, moved: () => moved, end: () => t.hub.pals.stopAndWait() };
    }

    test("nothing waits while it just works; a message put in meanwhile does, and stops when it's read", async () => {
      const h = await held("Bash*");
      expect(h.wire().waiting).toBeUndefined();
      const a = await h.queue("一");
      expect(h.wire().waiting).toEqual({ count: 1, canHandleNow: true });
      const b = await h.queue("二");
      expect(h.wire().waiting).toEqual({ count: 2, canHandleNow: true });
      // (an agent's line goes out a moment later)
      await waitFor(() => JSON.stringify(h.t.events.filter((e) => e.event === (h.pal ? "pals.updated" : "status")).at(-1) ?? "").includes('"count":2'));
      h.emit({ type: "words", uuid: a, state: "read" });
      h.emit({ type: "words", uuid: b, state: "read" });
      expect(h.wire().waiting).toBeUndefined();
      await h.end();
    });

    test("立刻处理 moves what holds it to the background, once, and the words are read", async () => {
      const h = await held("Bash* Agent*");
      const u = await h.queue("先改首页");
      await h.now();
      expect(h.moved()).toBe(1);
      h.emit({ type: "words", uuid: u, state: "read" });
      expect(h.wire().waiting).toBeUndefined();
      expect(await h.now()).toEqual({ ok: true }); // read meanwhile: nothing to do
      expect(h.moved()).toBe(1);
      expect(h.proc().closed).toBe(false);
      expect(h.t.hub.audit.tail(10).some((e) => e.type === (h.pal ? "pal.handle_now" : "chat.handle_now"))).toBe(true);
      await h.end();
    });

    test("a step that can't go to the background (an MCP tool, alone or beside a command; a command not yet started): no 立刻处理, and nothing is touched", async () => {
      for (const steps of ["mcp__slow__wait", "Bash* mcp__slow__wait", "Bash"]) {
        const h = await held(steps);
        await h.queue("先改首页");
        expect(h.wire().waiting).toEqual({ count: 1, canHandleNow: false });
        await expect(h.now()).rejects.toThrow("转不了后台");
        expect(h.moved()).toBe(0);
        await h.end();
      }
    });

    test("only thinking or writing: the words wait, with no 立刻处理", async () => {
      const h = await held("Bash*");
      await h.queue("先改首页");
      h.emit({ type: "tool_result", toolUseId: "t_Bash", content: "done", isError: false, parentToolUseId: null });
      expect(h.wire().waiting).toEqual({ count: 1, canHandleNow: false });
      await h.end();
    });

    test("the harness says it moved and nothing did: it says so", async () => {
      const h = await held("Bash*");
      await h.queue("先改首页");
      h.proc().backgroundSteps = async () => {};
      await expect(h.now()).rejects.toThrow("转不了后台");
      await h.end();
    }, 10_000);

    test("停止, the turn's end and a crash leave nothing waiting", async () => {
      for (const how of ["stop", "result", "crash"]) {
        const h = await held("Bash*");
        const u = await h.queue("先改首页");
        if (how === "stop") await (h.pal ? h.t.call("pals.stop", { id: h.pal.id }) : h.t.hub.stopAll("app"));
        else if (how === "crash") h.proc().crash();
        else h.emit(result(h.proc().sessionId, [h.proc().sentUuids[0]!, u]));
        await waitFor(() => h.wire().waiting === undefined);
        await h.end();
      }
    });
  });
}

test("Claude Code's command_lifecycle, as the host reads it", () => {
  const read = (state: string) => mapMessage({ type: "command_lifecycle", command_uuid: "u1", state, uuid: "x", session_id: "s" } as any, { lastCost: 0, contextTokens: 0 });
  expect(read("queued")).toEqual([{ type: "words", uuid: "u1", state: "queued" }]);
  expect(read("started")).toEqual([{ type: "words", uuid: "u1", state: "read" }]);
  for (const s of ["completed", "cancelled", "discarded"]) expect(read(s)).toEqual([{ type: "words", uuid: "u1", state: "done" }]);
});
