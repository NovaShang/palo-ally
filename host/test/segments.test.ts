import { describe, expect, test } from "bun:test";
import { cleanup, makeHub, tick } from "./helpers.ts";

// A turn whose answer is split around tool calls (text → Bash → SendMessage to
// a peer → text) must keep every text segment: once the owner reported a
// reply where only the tail of the last segment showed up.
describe("assistant text around tool calls", () => {
  test("text → Bash → SendMessage(peer) → text keeps both segments", async () => {
    const first = "我查了一下：这两条回复在电脑这边存的是完整的。你是在 iPhone 上看到被截断的，还是 Mac 上？能截个图的话更好定位。";
    const second = "我已经报给维护那边了。顺带还报了一个：任务行混了一段英文原文，能定位得更快。";
    const { hub, paths } = makeHub({
      script: async (_t, ctx) => {
        for (const piece of first.match(/.{1,7}/gu)!) ctx.emit({ type: "text_delta", text: piece });
        ctx.emit({ type: "assistant_text", text: first, parentToolUseId: null });
        await ctx.useTool("Bash", { command: "grep x ~/.paloally/state/chat.jsonl" });
        await ctx.useTool("SendMessage", { to: "build-test-paloally-product", message: "Bug from 高尚: please fix the truncated replies." });
        for (const piece of second.match(/.{1,7}/gu)!) ctx.emit({ type: "text_delta", text: piece });
        ctx.emit({ type: "assistant_text", text: second, parentToolUseId: null });
      },
    });
    hub.userMessage("为什么回复被截断了？", "app");
    await hub.idle();
    await tick(30);
    const texts = hub.chat
      .since(0)
      .filter((m) => m.role === "assistant" && m.kind === "text")
      .map((m) => m.text)
      .join("\n");
    expect(texts).toContain(first);
    expect(texts).toContain(second);
    cleanup(paths);
  });
});

describe("finished handoff rows", () => {
  test("a peer row finishing posts no chat card (the assistant relays it)", async () => {
    const { hub, paths } = makeHub();
    const t = hub.tasks.openPeer("转交给 builder 的事", "交出去了，等对方开工", "builder");
    hub.tasks.settlePeer(t.id, "done", "办好了");
    await tick(10);
    expect(hub.chat.since(0).filter((m) => m.kind === "task")).toHaveLength(0);
    cleanup(paths);
  });
});
