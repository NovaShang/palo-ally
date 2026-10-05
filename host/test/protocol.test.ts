// Contract between host and app: drive every RPC method and event through a
// real Hub, check the method list matches the implementation, and write the
// samples to the Swift test fixtures (decoded strictly on the client side).
import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { RPC_EVENTS, RPC_METHODS, handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { checkFixture, cleanup, makeHub, shape, tick } from "./helpers.ts";

const script: FakeScript = async (t, ctx) => {
  if (t === "派个任务") {
    ctx.emit({ type: "tool_use", id: "ag1", name: "Agent", input: { description: "查资料" }, parentToolUseId: null });
    await ctx.opts.tools.report_task({ id: "r1", summary: "在查", status: "running", title: "查资料" });
    ctx.emit({ type: "tool_use", id: "s1", name: "WebSearch", input: { query: "q" }, parentToolUseId: "ag1" });
    return;
  }
  if (t === "要确认") {
    await ctx.useTool("Bash", { command: "npm test" }, {
      ask: true,
      reason: "要运行命令",
      suggestions: [{ type: "addRules", behavior: "allow", destination: "localSettings", rules: [{ toolName: "Bash", ruleContent: "npm test:*" }] }],
    });
    return;
  }
  ctx.emit({ type: "text_delta", text: "你好" });
  ctx.emit({ type: "assistant_text", text: "你好，我在。", parentToolUseId: null });
};

describe("host ↔ app protocol", () => {
  test("every method answers, every event fires; samples written for the Swift client", async () => {
    const { hub, paths, events, driver } = makeHub({ script });
    hub.onUnpairDevice = () => {};
    const ctx = { clientId: "app_1_dev-x", deviceId: "dev-x", channel: "app" as const, local: false };
    const call = async (method: string, params: unknown = {}) => {
      const r = await handleRpc(hub, { method, params }, ctx);
      return JSON.parse(JSON.stringify(r ?? null));
    };
    const methods: Record<string, { params: unknown; result: unknown }> = {};
    const run = async (method: string, params: unknown = {}) => (methods[method] = { params, result: await call(method, params) }).result as any;

    await run("hello", { client: "ios", version: "test" });
    const img = await run("media.upload", { mediaType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==" });
    const doc = await run("media.uploadChunk", { name: "说明.txt", mediaType: "text/plain", offset: 0, data: Buffer.from("hi").toString("base64"), done: true });
    await run("chat.send", {
      text: "你好",
      clientMsgId: "c-1",
      attachments: [img.id, doc.id],
      replyTo: { messageId: "m_earlier", excerpt: "两封邮件需要你回" },
    });
    await run("media.get", { id: img.id });
    writeFileSync(`${paths.home}/note.txt`, "hello");
    await hub.toolHandlers().SendUserFile({ files: ["note.txt"], status: "normal", temporary: true });
    await run("media.read", { id: hub.chat.since(0).at(-1)!.attachments![0]!.id, offset: 0 });
    await hub.toolHandlers().copy_to_clipboard({ text: "123456", label: "验证码" });
    await hub.idle();
    // a schedule goal's output arrives as a card (晨报)
    (hub as any).onSchedule(hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["07:30"] }, "user"));
    await hub.idle();
    await run("sync", {});
    await run("chat.history", { beforeSeq: 99, limit: 10 });
    const found = await run("chat.search", { query: "你好", limit: 5 });
    expect(found.messages.length).toBeGreaterThan(0);
    await run("chat.around", { seq: found.messages[0].seq, before: 2, after: 2 });
    await run("commands.list");
    const models = await run("model.get");
    await run("model.set", { model: models.models[0].value, effort: "medium" });
    hub.userMessage("派个任务", "app");
    await hub.idle();
    const task = hub.tasks.list()[0]!;
    await run("task.get", { id: task.id });
    await run("task.stop", { id: task.id });
    hub.userMessage("要确认", "app");
    await tick(10);
    await run("approval.answer", { id: hub.approvals.listPending()[0]!.id, allow: true, remember: true });
    await hub.idle();
    const w = (await run("watch.add", { title: "晨报", instruction: "整理日程", at: ["08:30"] })).watch;
    hub.watches.progress(w.id, "已整理 3 条日程", { ratio: 0.5, outcome: "示例" });
    await run("watch.update", { id: w.id, patch: { enabled: false } });
    await run("watch.remove", { id: w.id });
    mkdirSync(join(paths.artifacts, "brief"), { recursive: true });
    writeFileSync(join(paths.artifacts, "brief", "brief.md"), "# 晨报\n- 一件事");
    hub.artifacts.publish("brief", "晨报", "brief.md", "markdown");
    await run("artifact.list");
    await run("artifact.read", { id: "brief" });
    await run("artifact.pin", { id: "brief", pinned: true });
    await run("memory.list");
    const mem = await run("memory.read", { path: "user.md" });
    await run("memory.write", { path: "user.md", content: "# 关于主人\n", baseUpdatedAt: mem.updatedAt });
    await run("settings.update", { patch: { probeIntervalMinutes: 15, assistantName: "帕帕", color: "teal" } });
    await run("push.register", { token: "a".repeat(64), env: "sandbox" });
    await run("push.unregister", { token: "a".repeat(64) });
    driver.probeResponder = () => ({
      output: { suggestions: [{ chip: "找出没在用的订阅", prompt: "帮我把信用卡账单里的订阅都找出来，标出最近三个月没用过的", category: "省钱" }, { chip: "每周日给我做周报", prompt: "以后每周日晚上把我这一周做的事整理成周报" }] },
      costUsd: 0.0002,
    });
    await hub.suggestions.refresh("test");
    await run("suggestions.list");
    await run("suggestions.dismiss", { id: hub.suggestions.list()[0]!.id });
    await run("audit.tail", { limit: 3 });
    await run("stop");
    await run("device.unpair");
    await tick(150);

    // the documented list is exactly what's implemented
    expect(Object.keys(methods).sort()).toEqual([...RPC_METHODS].sort());
    await expect(call("no.such.method")).rejects.toThrow("unknown method");

    const sampleEvents: Record<string, unknown> = {};
    for (const e of events) if (!(e.event in sampleEvents)) sampleEvents[e.event] = JSON.parse(JSON.stringify(e.data));
    // commands.updated fires when the harness reports its list
    expect(Object.keys(sampleEvents).sort()).toEqual([...RPC_EVENTS].sort());

    const fixture = { methods, events: sampleEvents };
    checkFixture(resolve(import.meta.dir, "../../ios/PaloAllyKit/Tests/PaloAllyKitTests/Fixtures/protocol.json"), fixture, shape);
    cleanup(paths);
  });
});
