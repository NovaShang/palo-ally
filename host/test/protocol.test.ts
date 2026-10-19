// Contract between host and app: drive every RPC method and event through a
// real Hub, check the method list matches the implementation, and write the
// samples to the Swift test fixtures (decoded strictly on the client side).
import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { RPC_EVENTS, RPC_METHODS, handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { AllyNet } from "./allyNet.ts";
import { checkFixture, cleanup, shape, tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { AwayDetector } from "../src/away.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import type { SDKSessionInfo } from "@anthropic-ai/claude-agent-sdk";

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
  if (t === "要问我") {
    await ctx.useTool("AskUserQuestion", {
      questions: [
        { question: "约哪天？", header: "日期", options: [{ label: "周六", description: "上午" }, { label: "周日", description: "下午" }], multiSelect: false },
        { question: "谁一起去？", header: "同行", options: [{ label: "太太", description: "" }, { label: "孩子", description: "" }], multiSelect: true },
      ],
    }, { ask: true });
    return;
  }
  ctx.emit({ type: "text_delta", text: "你好" });
  ctx.emit({ type: "assistant_text", text: "你好，我在。", parentToolUseId: null });
};

describe("host ↔ app protocol", () => {
  test("every method answers, every event fires; samples written for the Swift client", async () => {
    // On an in-memory Ally net, so the ally.* methods have a peer.
    const net = new AllyNet();
    // A made-up computer for the sessions: one terminal session, one
    // background session, Claude Code's CLI and the owner away from the screen.
    const claude = new FakeClaudeDir();
    const cli = new FakeCli(claude);
    const histories = new Map<string, any[]>();
    // The conversations that ended on the computer, as the SDK's listSessions gives them.
    const ended: SDKSessionInfo[] = [];
    const { hub, paths, events, driver, logins } = net.add("家人A", {
      script,
      sessions: {
        claudeDir: claude.dir,
        cli,
        away: new AwayDetector(() => null, Date.now, () => true),
        readMessages: async (sid) => histories.get(sid) ?? [],
      },
      pals: {
        models: async () => [{ value: "opus", displayName: "Opus", description: "", efforts: ["low", "high", "max"] }],
        reveal: async () => {}, // never opens a real window
        recentSource: { list: async () => ended, info: async (sid) => ended.find((i) => i.sessionId === sid) },
        // 交还终端 after going back copies the conversation as it stands (the SDK's forkSession).
        forkSession: async () => ({ sessionId: "9d4e2b60-0000-4000-8000-000000000004" }),
      },
    }).ctx;
    const peer = net.add("家人B");
    hub.onUnpairDevice = () => {};
    // The relay's pairing window, as `paloally pair` opens it.
    hub.openPairing = async (ttl) => ({ code: "123456", ttl, link: "paloally://pair?relay=https%3A%2F%2Frelay.example.com&daemon=d-home&code=123456&hostkey=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" });
    const ctx = { clientId: "app_1_dev-x", deviceId: "dev-x", channel: "app" as const, local: false };
    const call = async (method: string, params: unknown = {}) => {
      const r = await handleRpc(hub, { method, params }, ctx);
      return JSON.parse(JSON.stringify(r ?? null));
    };
    type Sample = { params: unknown; result: unknown };
    const methods: Record<string, Sample | Sample[]> = {};
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
    // 回到这里重来: back to just before one of the owner's messages, in its
    // transcript as Claude Code wrote it; a client that was away hears of it
    // on its next sync (a second sample).
    const seqBefore = hub.chat.lastSeq;
    const again = hub.userMessage("帮我订周六中午的餐厅", "app")!;
    await hub.idle();
    claude.transcript(paths.home, hub.status().sessionId!, [
      { type: "user", uuid: "e1", parentUuid: null, timestamp: "2026-10-16T08:00:00Z", message: { role: "user", content: "你好" } },
      { type: "assistant", uuid: "e2", parentUuid: "e1", timestamp: "2026-10-16T08:00:01Z", message: { id: "msg_e2", role: "assistant", content: [{ type: "text", text: "你好，我在。" }] } },
      { type: "user", uuid: again.uuid, parentUuid: "e2", timestamp: "2026-10-16T08:01:00Z", message: { role: "user", content: again.text } },
    ]);
    expect((await run("chat.rewind", { messageId: again.id })).text).toBe("帮我订周六中午的餐厅");
    methods["sync"] = [methods["sync"] as Sample, { params: { sinceSeq: seqBefore }, result: await call("sync", { sinceSeq: seqBefore }) }];
    expect(((methods["sync"] as Sample[])[1]!.result as any).rewound[0]).toBe(again.id);
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
    hub.userMessage("要问我", "app");
    await tick(10);
    await run("question.answer", { id: hub.questions.listPending()[0]!.id, answers: { "约哪天？": "周日", "谁一起去？": "太太, 孩子" } });
    await hub.idle();
    const w = (await run("watch.add", { title: "晨报", instruction: "整理日程", at: ["08:30"] })).watch;
    hub.watches.progress(w.id, "已整理 3 条日程", { ratio: 0.5, outcome: "示例" });
    await run("watch.update", { id: w.id, patch: { enabled: false, dayOfMonth: -1 } });
    await run("watch.remove", { id: w.id });
    mkdirSync(join(paths.artifacts, "brief"), { recursive: true });
    writeFileSync(join(paths.artifacts, "brief", "brief.md"), "# 晨报\n- 一件事");
    hub.artifacts.publish("brief", "晨报", "brief.md", "markdown", false, "日常", "palo");
    await run("artifact.list");
    await run("artifact.read", { id: "brief" });
    await run("artifact.pin", { id: "brief", pinned: true });
    await run("memory.list");
    const mem = await run("memory.read", { path: "user.md" });
    // keeps the 称呼 line: an Ally invite carries the owner's name
    await run("memory.write", { path: "user.md", content: "# 关于主人\n\n- 称呼：家人A\n", baseUpdatedAt: mem.updatedAt });
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
    await run("host.update", { check: true }); // a dev checkout: managed by hand
    // A link for one more of the owner's devices (5 minutes, one device).
    const invite = await run("pair.invite");
    expect(invite.link).toStartWith("paloally://pair?");
    expect(invite.expiresAt - Date.now()).toBeGreaterThan(290_000);
    // The owner's devices (docs/devices-prd.md): this one (said hello as an
    // iPhone), a Mac paired earlier; the Mac taken off from here.
    const paired = [
      { deviceId: "dev-x", label: "iPhone", pub: "", pairedAt: Date.parse("2026-10-01T09:00:00Z"), lastSeen: Date.now() },
      { deviceId: "dev-mac", label: "书房的 Mac", pub: "", pairedAt: Date.parse("2026-10-02T09:00:00Z"), lastSeen: Date.parse("2026-10-15T20:00:00Z") },
    ];
    hub.devices = { list: () => paired, remove: (id) => paired.splice(paired.findIndex((d) => d.deviceId === id), 1).length > 0 };
    const listed = await run("device.list");
    expect(listed.devices.map((d: any) => [d.deviceId, d.current, d.platform ?? null])).toEqual([["dev-x", true, "ios"], ["dev-mac", false, null]]);
    expect(await run("device.remove", { deviceId: "dev-mac" })).toEqual({ ok: true });
    // Allies: an invite, then this host scans the other's, a message in, a
    // draft out (with times), the level changed to 能对话, the owner's own
    // words both ways, and unpairing at the end.
    await run("ally.invite");
    const { link } = await peer.hub.allies.invite();
    const other = (await run("ally.accept", { link, kind: "family", trust: "review" })).ally;
    const toUs = peer.hub.allies.list()[0]!;
    await peer.hub.toolHandlers().ally_send({ to: toUs.id, text: "今晚我晚点回，大概九点", urgent: true });
    peer.hub.allies.decide(peer.hub.allies.log(toUs.id)[0]!.id, "send");
    await waitFor(() => hub.allies.log(other.id).length === 1);
    await hub.toolHandlers().ally_send({
      to: other.id,
      text: "周六下午带孩子去公园？",
      slots: [{ start: "2026-10-17T14:00:00+08:00", end: "2026-10-17T17:00:00+08:00" }],
      replyTo: hub.allies.log(other.id)[0]!.id,
    });
    await run("ally.draft.decide", { id: hub.allies.log(other.id).at(-1)!.id, action: "send", text: "周六下午两点带孩子去公园？" });
    await waitFor(() => hub.allies.log(other.id).at(-1)!.status === "delivered");
    await run("ally.trust", { id: other.id, trust: "converse" });
    await run("ally.say", { id: other.id, text: "我七点到" });
    await waitFor(() => hub.allies.log(other.id).at(-1)!.status === "delivered");
    peer.hub.allies.say(toUs.id, "好，门口见");
    await waitFor(() => hub.allies.log(other.id).at(-1)!.text === "好，门口见");
    await run("ally.list");
    await run("ally.log", { id: other.id, limit: 10 });
    await hub.idle();
    await run("ally.remove", { id: other.id });
    // Sessions: the computer's Claude Code sessions, a session's prompt and
    // question on the phone through the hooks.
    claude.register({ sessionId: "5d821f3c-0000-4000-8000-000000000001", name: "修登录跳转", cwd: "/Users/someone/code/app", status: "busy" });
    claude.transcript("/Users/someone/code/app", "5d821f3c-0000-4000-8000-000000000001", [assistantEntry("在跑登录相关的测试。")]);
    histories.set("5d821f3c-0000-4000-8000-000000000001", [
      { type: "user", uuid: "c1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "登录以后应该回到原来那一页" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "c2", timestamp: "2026-10-12T10:01:00Z", message: { role: "assistant", content: [{ type: "text", text: "找到了：跳转时把原来的地址丢了。" }] } },
      { type: "user", uuid: "c3", timestamp: "2026-10-12T10:02:00Z", message: { role: "user", content: "…" }, origin: { kind: "peer", name: "笔记整理", body: "设计稿在 notes/设计.md" } },
      { type: "user", uuid: "c4", timestamp: "2026-10-12T10:03:00Z", message: { role: "user", content: "…" }, origin: { kind: "peer", name: "Palo", body: "主人说先别管登录页" } },
    ]);
    const term = (await run("sessions.list")).sessions[0];
    const sig = () => ({ signal: new AbortController().signal, env: {} });
    const prompt = hub.sessions.onHook("PermissionRequest", { session_id: term.id, cwd: term.cwd, hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "npm run build" } }, sig());
    await tick(5);
    const sessionCard = JSON.parse(JSON.stringify(hub.approvals.listPending()[0]!));
    hub.approvals.answer(hub.approvals.listPending()[0]!.id, true, "app");
    await prompt;
    const asked = hub.sessions.onHook("PermissionRequest", {
      session_id: term.id,
      cwd: term.cwd,
      hook_event_name: "PermissionRequest",
      tool_name: "AskUserQuestion",
      tool_input: { questions: [{ question: "方案选哪个？", header: "方案", options: [{ label: "A", description: "快" }, { label: "B", description: "稳" }], multiSelect: false }] },
    }, sig());
    await tick(5);
    const sessionQuestion = JSON.parse(JSON.stringify(hub.questions.listPending()[0]!));
    hub.questions.answer(hub.questions.listPending()[0]!.id, { "方案选哪个？": "B" }, "app");
    await asked;
    // one the owner didn't get to: back in the terminal
    const late = hub.sessions.onHook("PermissionRequest", { session_id: term.id, cwd: term.cwd, hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "npm test" } }, sig());
    await tick(5);
    (hub.approvals as any).settle(hub.approvals.listPending()[0]!.id, "expired", "timeout", undefined, "在电脑上等你");
    await late;
    await run("sessions.history", { id: term.id, limit: 50 });
    await run("sessions.hooks", { enabled: true });
    await hub.sessions.setHooks(false, "test");
    // Pals: the terminal session waits to be quit there; a background one is
    // adopted (its words, its streamed reply, its card, its history); the
    // assistant opens one; one goes back to the terminal, one out of the list.
    driver.palScript = async (text, c) => {
      if (text === "起任务") c.emit({ type: "task_started", taskId: "t_9c1", description: "跑全部测试", background: true, taskType: "local_bash" });
      if (text === "要确认") {
        await c.useTool("Bash", { command: "npm run build" }, { ask: true });
        return;
      }
      const id = `msg_0${text.length}`;
      c.emit({ type: "text_delta", text: "好，", messageId: id });
      c.emit({ type: "assistant_text", text: "好，列表页这就做。", parentToolUseId: null, messageId: id });
    };
    expect((await call("pals.adopt", { sessionId: term.id })).waiting).toBe("exit-in-terminal");
    const site = "/Users/someone/code/site";
    const bgId = "7a3e9c10-0000-4000-8000-000000000002";
    cli.bg({ sessionId: bgId, name: "网站", cwd: site });
    claude.transcript(site, bgId, [assistantEntry("列表页的样式好了。", { model: "claude-sonnet-4-6" })]);
    await run("pals.list");
    const pal = (await run("pals.adopt", { sessionId: bgId })).pal;
    histories.set(bgId, [
      { type: "user", uuid: "p1", timestamp: "2026-10-12T11:00:00Z", message: { role: "user", content: "列表要能按日期排序" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "p2", timestamp: "2026-10-12T11:00:05Z", message: { id: "msg_01", role: "assistant", content: [{ type: "text", text: "加上了。" }] } },
      { type: "user", uuid: "p3", timestamp: "2026-10-12T11:01:00Z", message: { role: "user", content: "…" }, origin: { kind: "peer", name: "Palo", body: "主人说今晚不用部署" } },
    ]);
    await run("pals.send", { id: pal.id, text: "把列表页做完", clientMsgId: "c-pal-1" });
    await waitFor(() => events.some((e) => e.event === "chat.message" && e.data.pal && e.data.role === "assistant"));
    // With an image and a file, the media ids chat.send takes too.
    const plainSend = methods["pals.send"] as Sample;
    const shot = await call("media.upload", { mediaType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==" });
    const spec = await call("media.uploadChunk", { name: "列表.md", mediaType: "text/markdown", offset: 0, data: Buffer.from("按日期排序").toString("base64"), done: true });
    const withFiles = { id: pal.id, text: "照这张图和这份说明改", clientMsgId: "c-pal-2", attachments: [shot.id, spec.id] };
    methods["pals.send"] = [plainSend, { params: withFiles, result: await call("pals.send", withFiles) }];
    await waitFor(() => events.some((e) => e.event === "chat.message" && e.data.pal && e.data.clientMsgId === "c-pal-2"));
    await run("pals.history", { id: pal.id, limit: 50 });
    void hub.pals.send(pal.id, "要确认");
    await waitFor(() => hub.approvals.listPending().length === 1);
    const palCard = JSON.parse(JSON.stringify(hub.approvals.listPending()[0]!));
    hub.approvals.answer(palCard.id, true, "app");
    await waitFor(() => hub.pals.list().every((p) => p.status === "idle"));
    await run("pals.stop", { id: pal.id });
    // 回到这里重来 in the Pal: whether its files can go back, and going back with them
    claude.transcript(site, bgId, [
      { type: "user", uuid: "p1", parentUuid: null, timestamp: "2026-10-12T11:00:00Z", message: { role: "user", content: "列表要能按日期排序" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "p2", parentUuid: "p1", timestamp: "2026-10-12T11:00:05Z", message: { id: "msg_01", role: "assistant", content: [{ type: "text", text: "加上了。" }] } },
      { type: "file-history-snapshot", messageId: "p4", snapshot: { messageId: "p4", trackedFileBackups: {} } },
      { type: "user", uuid: "p4", parentUuid: "p2", timestamp: "2026-10-12T11:02:00Z", message: { role: "user", content: "再把表头固定住" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "p5", parentUuid: "p4", timestamp: "2026-10-12T11:02:09Z", message: { id: "msg_02", role: "assistant", content: [{ type: "text", text: "固定好了。" }] } },
    ]);
    const check = { params: { id: pal.id, messageId: "p4", check: true }, result: await call("pals.rewind", { id: pal.id, messageId: "p4", check: true }) };
    expect(check.result).toEqual({ canRestoreFiles: true });
    const rewound = { params: { id: pal.id, messageId: "p4", restoreFiles: true }, result: await call("pals.rewind", { id: pal.id, messageId: "p4", restoreFiles: true }) };
    expect(rewound.result).toEqual({ text: "再把表头固定住", filesRestored: true });
    methods["pals.rewind"] = [check, rewound];
    const project = realpathSync(mkdtempSync(`${tmpdir()}/site-`));
    await hub.toolHandlers().pal_propose({ name: "文档", dir: project, duty: "你负责主人的文档：先把安装说明写完。" });
    const proposal = hub.chat.recent(1)[0]!.proposal!;
    const opened = (await run("helper.decide", { proposalId: proposal.id, action: "create" })).pal;
    // 网站 goes to sleep (§12); words wake it (what waking cost is kept), and
    // pals.wake does too; asleep again, as the list's sample shows it.
    const putToSleep = () => (hub.pals as any).putToSleep(hub.pals.get(pal.id), "test") as Promise<void>;
    await putToSleep();
    await call("pals.send", { id: pal.id, text: "接着做" });
    await waitFor(() => hub.pals.list().find((p) => p.id === pal.id)?.lastWakeUsd !== undefined);
    await putToSleep();
    const woke = (await run("pals.wake", { id: pal.id })).pal;
    expect([woke.status, typeof woke.lastWakeUsd]).toEqual(["idle", "number"]);
    await putToSleep();
    await waitFor(() => events.some((e) => e.event === "pals.updated" && e.data.pals.some((p: any) => p.id === pal.id && p.status === "asleep" && p.lastWakeUsd)));
    // 最近的对话: one that ended in the same folder, listed; the assistant's
    // card for it, and the same card once the owner took it over.
    const endedId = "3c9d2e71-0000-4000-8000-000000000003";
    claude.transcript(project, endedId, [
      { type: "user", uuid: "r1", timestamp: "2026-10-12T09:00:00Z", message: { role: "user", content: "把首页改成两栏" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "r2", timestamp: "2026-10-12T09:01:00Z", message: { id: "msg_r2", model: "claude-sonnet-4-6", role: "assistant", content: [{ type: "text", text: "两栏的样式好了。" }] } },
    ]);
    ended.push({ sessionId: endedId, summary: "首页改成两栏", customTitle: "首页改成两栏", firstPrompt: "把首页改成两栏", lastModified: Date.parse("2026-10-12T09:01:00Z"), cwd: project });
    await run("pals.recent", {});
    expect(methods["pals.recent"]).toMatchObject({ result: { sessions: [{ sessionId: endedId, cwd: project, title: "首页改成两栏" }] } });
    await hub.toolHandlers().pal_adopt({ sessionId: endedId });
    const adoptCard = hub.chat.recent(1)[0]!;
    expect((await call("helper.decide", { proposalId: adoptCard.proposal!.id, action: "create" })).pal.sessionId).toBe(endedId);
    // The owner stops waiting for the terminal session to be quit: pals.adopt
    // has two samples, adopting and cancelling.
    const adopted = methods["pals.adopt"]!;
    const cancelled = { params: { sessionId: term.id, cancel: true }, result: await call("pals.adopt", { sessionId: term.id, cancel: true }) };
    expect(cancelled.result).toEqual({ cancelled: true });
    methods["pals.adopt"] = [adopted as Sample, cancelled];
    // The owner names it (§13): Claude Code's title for the session changes too.
    expect((await run("pals.rename", { id: pal.id, name: "网站改版" })).pal.name).toBe("网站改版");
    await run("pals.release", { id: pal.id });
    // Files on the computer (docs/files-prd.md), read-only: the opened Pal's
    // project folder, and the same folder opened from the preview pane.
    mkdirSync(join(project, "src"), { recursive: true });
    writeFileSync(join(project, "README.md"), "# 文档\n安装说明见 src/app.ts\n");
    writeFileSync(join(project, "src", "app.ts"), "export const app = 1;\n");
    writeFileSync(join(project, "video.mov"), Buffer.alloc(5 * 1024 * 1024 + 1));
    const scope = { kind: "pal", id: opened.id };
    await run("files.list", { scope, path: "" });
    const read = { params: { scope, path: "README.md" }, result: await call("files.read", { scope, path: "README.md" }) };
    const big = { params: { scope, path: "video.mov" }, result: await call("files.read", { scope, path: "video.mov" }) };
    expect(big.result.tooLarge).toBe(true);
    methods["files.read"] = [read, big];
    await run("files.search", { scope, query: "app", limit: 20 });
    expect((await run("files.resolve", { scope, paths: ["src/app.ts", "README.md:2", "src/nope.ts"] })).files).toHaveLength(2);
    await run("files.folders.browse", { path: project });
    const folder = (await run("files.folders.add", { path: project })).folder;
    await run("files.folders.list", {});
    await run("files.folders.remove", { id: folder.id });
    // The workbench (docs/workbench-rpc.md §2): the owner's own session in any folder,
    // its first turn done and then seen, ended, listed among the earlier ones and picked up again.
    const made = (await run("pals.create", { cwd: project, text: "把安装说明写完" })).pal;
    // (A clone: toMatchObject with a matcher would overwrite the sample's own field.)
    expect(typeof made.name).toBe("string");
    expect(structuredClone(made)).toMatchObject({ createdBy: "owner", name: expect.stringMatching(/^session-/), status: "starting", attention: "idle", folded: false });
    expect(made.name).toMatch(/^session-/);
    await waitFor(() => hub.pals.list().find((p) => p.id === made.id)?.attention === "done", 5_000);
    const unseen = hub.pals.list().find((p) => p.id === made.id)!;
    expect(unseen.finishedAt).toBeDefined();
    const seenPal = (await run("pals.seen", { id: made.id })).pal;
    expect([seenPal.attention, typeof seenPal.seenAt]).toEqual(["idle", "number"]);
    const folders = (await run("pals.folders", {})).folders;
    expect(folders[0]).toMatchObject({ path: project });
    // a conversation that ended on the computer, and a session unused for days (folded)
    const recentId = "8e4f1a22-0000-4000-8000-000000000005";
    claude.transcript(project, recentId, [{ type: "user", uuid: "q1", timestamp: "2026-10-12T08:00:00Z", message: { role: "user", content: "补一份更新日志" }, origin: { kind: "human" } }]);
    ended.push({ sessionId: recentId, summary: "补一份更新日志", customTitle: "更新日志", firstPrompt: "补一份更新日志", lastModified: Date.now() - 60_000, cwd: project });
    const old = hub.pals.list().find((p) => p.sessionId === endedId)!;
    (hub.pals.get(old.id) as any).rec.lastUsedAt = Date.now() - 5 * 86_400_000;
    // The details: after a turn, the model switched, compacted, and its folder handed to the opener.
    const det = await run("pals.detail", { id: made.id });
    expect(det).toMatchObject({ pal: { id: made.id }, contextWindow: 200_000, models: [{ id: "opus" }], tasks: [] });
    expect((await run("pals.setModel", { id: made.id, effort: "high" })).pal.effort).toBe("high");
    await run("pals.compact", { id: made.id });
    await waitFor(() => hub.pals.list().find((p) => p.id === made.id)?.status === "idle", 3_000);
    await call("pals.send", { id: made.id, text: "起任务" });
    await waitFor(() => (hub.pals.get(made.id) as any).detailInfo().tasks.length === 1, 3_000);
    await run("pals.stopTask", { id: made.id, taskId: "t_9c1" });
    await run("pals.reveal", { id: made.id, kind: "finder" });
    const endedPal = (await run("pals.end", { id: made.id })).earlier;
    expect(endedPal).toMatchObject({ kind: "ended", key: `ended:${made.sessionId}`, sessionId: made.sessionId, cwd: project });
    const earlier = (await run("pals.earlier", { limit: 20 })).items as { kind: string; key: string }[];
    expect(earlier.map((i) => i.kind).sort()).toEqual(["ended", "folded", "recent"]);
    const folded = earlier.find((i) => i.kind === "folded")!;
    const back = [
      { params: { key: `ended:${made.sessionId}` }, result: await call("pals.resume", { key: `ended:${made.sessionId}` }) },
      { params: { key: folded.key }, result: await call("pals.resume", { key: folded.key }) },
    ];
    expect(typeof back[0]!.result.pal.name).toBe("string");
    expect(typeof back[1]!.result.pal.name).toBe("string");
    expect(back[0]!.result.pal).toMatchObject({ name: made.name, cwd: project, sessionId: made.sessionId });
    expect(back[1]!.result.pal).toMatchObject({ folded: false });
    methods["pals.resume"] = back;
    // Workspaces and the right pane's tabs (docs/workbench-rpc.md §3).
    const [m1, m2] = [back[0]!.result.pal.id as string, back[1]!.result.pal.id as string];
    const empty = (await call("workspaces.create", { name: "空的", memberIds: [] })).workspace;
    expect(empty).toMatchObject({ name: "空的", memberIds: [], layout: null });
    await call("workspaces.delete", { id: empty.id });
    const ws = (await run("workspaces.create", { name: "官网", memberIds: [m1] })).workspace;
    expect(ws).toMatchObject({ name: "官网", memberIds: [m1], layout: null });
    const moved = (await run("workspaces.move", { palId: m2, workspaceId: ws.id })).workspaces[0];
    expect(moved.memberIds).toEqual([m1, m2]);
    const tiles = { type: "hsplit", w: 1, h: 1, x: 0, y: 0, children: [{ type: "leaf", session: m1, w: 0.5, h: 1, x: 0, y: 0 }, { type: "leaf", session: m2, w: 0.5, h: 1, x: 0.5, y: 0 }] };
    expect((await run("workspaces.update", { id: ws.id, name: "官网改版", layout: tiles })).workspace).toMatchObject({ name: "官网改版", layout: tiles });
    expect((await run("workspaces.list", {})).workspaces).toHaveLength(1);
    const tabs = [{ kind: "files" }, { kind: "library" }, { kind: "preview", path: `${project}/README.md` }, { kind: "web", url: "https://example.com" }];
    expect((await call("workbench.tabs.set", { key: `ws:${ws.id}`, tabs, active: 3, open: true })).state).toMatchObject({ tabs, active: 3, open: true });
    expect((await call("workbench.tabs.get", {})).states[`ws:${ws.id}`]).toBeDefined();
    await run("workbench.tabs.set", { key: "palo", tabs, active: 0, open: true });
    // (keyed by "palo" so the sample's shape doesn't depend on a generated id)
    expect((await run("workbench.tabs.get", { key: "palo" })).states.palo.tabs).toEqual(tabs);
    expect((await call("sync", {})).workspaces).toHaveLength(1);
    expect(Object.keys((await call("sync", {})).workbenchTabs)).toContain(`ws:${ws.id}`);
    await run("workspaces.delete", { id: ws.id });
    await run("pals.remove", { id: opened.id });
    // Claude Code's login ran out: signed in again from the phone.
    hub.auth.failed({ kind: "probe" });
    expect((await call("auth.login.start")).auth).toMatchObject({ state: "expired", login: { state: "starting" } });
    logins[0]!.say("URL https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code");
    methods["auth.login.start"] = { params: {}, result: await call("auth.login.start") };
    expect((methods["auth.login.start"] as Sample).result).toMatchObject({ auth: { login: { state: "waiting", url: expect.stringContaining("oauth/authorize") } } });
    expect((await run("auth.login.code", { code: "a1b2c3#d4e5" })).auth.login.state).toBe("checking");
    expect((await run("auth.login.cancel")).auth).toMatchObject({ state: "expired" });
    hub.pals.stop();
    await run("stop");
    await run("device.unpair");
    await tick(150);

    // the documented list is exactly what's implemented
    expect(Object.keys(methods).sort()).toEqual([...RPC_METHODS].sort());
    await expect(call("no.such.method")).rejects.toThrow("unknown method");

    const sampleEvents: Record<string, unknown> = {};
    for (const e of events) if (!(e.event in sampleEvents)) sampleEvents[e.event] = JSON.parse(JSON.stringify(e.data));
    // The list once it has someone in it (with a last entry), and chat
    // messages of each shape the client draws: the owner's, an Ally's words
    // in (from their assistant, from them), a draft card out, and the
    // owner's own words to an Ally.
    sampleEvents["ally.updated"] = events.filter((e) => e.event === "ally.updated" && e.data.allies[0]?.lastEntry).at(-1)!.data;
    const chat = events.filter((e) => e.event === "chat.message").map((e) => e.data);
    sampleEvents["chat.message"] = JSON.parse(
      JSON.stringify([
        chat[0],
        chat.find((m) => m.kind === "ally" && m.dir === "in"),
        chat.find((m) => m.kind === "ally" && m.dir === "out"),
        chat.find((m) => m.kind === "ally" && m.dir === "in" && m.author === "owner"),
        chat.find((m) => m.kind === "ally" && m.role === "user"),
        // a Pal proposal, and the same message once the Pal was opened
        chat.find((m) => m.kind === "helper"),
        chat.filter((m) => m.kind === "helper").at(-1),
        // a card proposing to take over an ended conversation, and the same once it was
        chat.find((m) => m.kind === "pal_adopt"),
        chat.filter((m) => m.kind === "pal_adopt").at(-1),
        // a Pal's conversation: the owner's words, its reply, the assistant's handover
        chat.find((m) => m.pal && m.role === "user" && !m.from),
        chat.find((m) => m.pal && m.role === "assistant"),
        chat.find((m) => m.pal && m.from),
      ]),
    );
    // the assistant's conversation gone back, and a Pal's
    sampleEvents["chat.rewound"] = [events.find((e) => e.event === "chat.rewound" && !e.data.pal)!.data, events.find((e) => e.event === "chat.rewound" && e.data.pal)!.data];
    sampleEvents["chat.delta"] = [events.find((e) => e.event === "chat.delta" && !e.data.pal)!.data, events.find((e) => e.event === "chat.delta" && e.data.pal)!.data];
    // Cards: the assistant's own, a session's (with its source), a
    // session's that went back to the computer (with a note), and a Pal's.
    const approvals = events.filter((e) => e.event === "approval.updated").map((e) => e.data);
    sampleEvents["approval.updated"] = JSON.parse(JSON.stringify([approvals[0], sessionCard, approvals.find((a) => a.source && a.note), palCard]));
    expect(palCard.source).toEqual({ kind: "pal", id: pal.id, name: "网站" });
    const questions = events.filter((e) => e.event === "question.updated").map((e) => e.data);
    sampleEvents["question.updated"] = JSON.parse(JSON.stringify([questions[0], sessionQuestion]));
    expect(sessionCard.source).toEqual({ kind: "session", id: term.id, name: "修登录跳转" });
    expect(sessionQuestion.source).toBeDefined();
    // the computer's sessions; the Pals (a list with both, a terminal session being adopted among the others)
    sampleEvents["sessions.updated"] = events.filter((e) => e.event === "sessions.updated" && e.data.sessions.length).at(-1)!.data;
    sampleEvents["pals.updated"] = events.filter((e) => e.event === "pals.updated" && e.data.pals.length === 2 && e.data.others.some((x: any) => x.adopting)).at(-1)!.data;
    // the workspaces' list with one workspace laid out, and a tab state written
    sampleEvents["workspaces.updated"] = events.filter((e) => e.event === "workspaces.updated" && e.data.workspaces[0]?.layout).at(-1)!.data;
    sampleEvents["workbench.updated"] = events.filter((e) => e.event === "workbench.updated" && e.data.state).at(-1)!.data;
    // commands.updated fires when the harness reports its list
    expect(Object.keys(sampleEvents).sort()).toEqual([...RPC_EVENTS].sort());

    // The made-up folder, not this machine's temp path.
    const fixture = JSON.parse(
      JSON.stringify({ methods, events: sampleEvents }).replaceAll(project, "/Users/someone/code/site").replaceAll(dirname(project), "/Users/someone/code"),
    );
    checkFixture(resolve(import.meta.dir, "../../ios/PaloAllyKit/Tests/PaloAllyKitTests/Fixtures/protocol.json"), fixture, shape);
    cleanup(paths);
    cleanup(peer.ctx.paths);
    claude.cleanup();
    cli.close();
  }, 20_000);
});
