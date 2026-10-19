import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { allyTurnTool } from "../src/allyGate.ts";
import { sessionOptions } from "../src/harness/claude.ts";
import { PALO_SEND_TOOL, SESSION_ALLOWED_TOOLS, type MainSessionOptions } from "../src/harness/types.ts";
import { summarizeTail } from "../src/handoffs.ts";
import { toPalMessages } from "../src/palHistory.ts";
import type { PalsTiming } from "../src/pals.ts";
import { peerWrap } from "../src/palSession.ts";
import { BEHAVIORS } from "../src/home.ts";
import { t as tr, setLang } from "../src/i18n/index.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";
import { handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";

const dirs: FakeClaudeDir[] = [];
afterAll(() => dirs.forEach((d) => d.cleanup()));

const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
const SID = "cccc1111-0000-4000-8000-000000000001";

function setup(opts: { claude?: FakeClaudeDir; paths?: ReturnType<typeof tmpPaths>; script?: FakeScript } = {}) {
  const claude = opts.claude ?? new FakeClaudeDir();
  if (!opts.claude) dirs.push(claude);
  const cli = new FakeCli(claude);
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-pal-")));
  const ctx = makeHub({
    paths: opts.paths ?? tmpPaths(),
    script: opts.script,
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false), readMessages: async () => [] },
    pals: { readMessages: async () => [], timing: FAST },
  });
  ctx.hub.pals.start();
  const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(ctx.hub, { method, params }, app)) ?? null));
  return { ...ctx, claude, cli, project, call };
}

async function adopt(t: ReturnType<typeof setup>, name = "网站") {
  t.cli.bg({ sessionId: SID, name, cwd: t.project });
  t.claude.transcript(t.project, SID, [assistantEntry("列表页做好了。", { model: "claude-haiku-4-5-20251001" })]);
  return (await t.call("pals.adopt", { sessionId: SID })).pal;
}

const wrapped = (name: string, text: string) => `<cross-session-message from="${name}" from-name="${name}">\n${text}\n</cross-session-message>`;
const palOpts = (t: ReturnType<typeof setup>) => t.driver.pals.at(-1)!.opts;

describe("palo_send: a Pal answers the assistant through the host", () => {
  test("the Pal's process gets exactly palo_send and the owner-facing tools, pre-approved, and none of the manager tools", async () => {
    const t = setup();
    await adopt(t);
    const opts = palOpts(t);
    expect(typeof opts.paloSend).toBe("function");
    expect((opts as any).tools).toBeUndefined();
    const sdk = sessionOptions(opts as MainSessionOptions);
    expect(Object.keys(sdk.mcpServers!)).toEqual(["paloally"]);
    const server: any = (sdk.mcpServers as any).paloally.instance;
    expect(Object.keys(server._registeredTools)).toEqual(["palo_send", "Artifact", "SendUserFile", "notify_user", "copy_to_clipboard", "pals_list"]);
    expect(sdk.allowedTools).toEqual(SESSION_ALLOWED_TOOLS);
    // the assistant's own session has the full set and no such tool
    const main: any = sessionOptions({ ...(opts as any), tools: {} as any, paloSend: undefined });
    expect(Object.keys(main.mcpServers.paloally.instance._registeredTools)).not.toContain("palo_send");
    expect(main.allowedTools).toBeUndefined();
    // and in the Pal's own gate it never makes a card
    expect(await opts.canUseTool({ toolName: PALO_SEND_TOOL, input: { text: "x" }, toolUseId: "t1", signal: new AbortController().signal } as any)).toMatchObject({ behavior: "allow" });
    expect(allyTurnTool(PALO_SEND_TOOL, { text: "x" }, { home: "/h", memoryDir: "/m" }).ok).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("the words reach the assistant's session wrapped as from the Pal, and the Pal is told so", async () => {
    const t = setup();
    const pal = await adopt(t);
    const result = await palOpts(t).paloSend!("登录页的测试补完了，全部通过");
    expect(result).toBe("已经送到「Palo」。它的回话会作为消息回到你这里。");
    await waitFor(() => !!t.driver.last?.sent.length);
    expect(t.driver.last!.sent).toEqual([wrapped("网站", "登录页的测试补完了，全部通过")]);
    expect(t.driver.last!.sent[0]).toBe(peerWrap("网站", "登录页的测试补完了，全部通过"));
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.palo_send")).toMatchObject({ pal: pal.id, name: "网站" });
    expect(await palOpts(t).paloSend!("  ")).toBe("没送：话是空的");
    // a renamed Pal answers by its name now
    (t.hub.pals.get(pal.id)!.rec as any).name = "官网";
    await palOpts(t).paloSend!("好了");
    await waitFor(() => t.driver.last!.sent.length === 2);
    expect(t.driver.last!.sent[1]).toContain('from-name="官网"');
    await t.hub.pals.stopAndWait();
  });

  test("in the host's language", async () => {
    const t = setup();
    await adopt(t);
    setLang("en");
    try {
      expect(await palOpts(t).paloSend!("done")).toBe('Delivered to "Palo". Its reply will come back to you as a message.');
      expect(await palOpts(t).paloSend!("")).toBe("Not sent: the message is empty.");
    } finally {
      setLang("zh");
    }
    await t.hub.pals.stopAndWait();
  });

  test("mid-turn it queues behind the running turn, in order, and goes in once that turn ends", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const script: FakeScript = async (text, ctx) => {
      if (text === "忙着") await gate;
      ctx.emit({ type: "assistant_text", text: `ok ${text.slice(0, 5)}`, parentToolUseId: null });
    };
    const t = setup({ script });
    await adopt(t);
    await t.call("chat.send", { text: "忙着" });
    await waitFor(() => t.driver.last?.sent.length === 1);
    await palOpts(t).paloSend!("第一句");
    await palOpts(t).paloSend!("第二句");
    await new Promise((r) => setTimeout(r, 100));
    expect(t.driver.last!.sent).toEqual(["忙着"]); // not folded into the running turn
    release();
    await waitFor(() => t.driver.last!.sent.length === 3);
    expect(t.driver.last!.sent.slice(1)).toEqual([wrapped("网站", "第一句"), wrapped("网站", "第二句")]);
    await t.hub.pals.stopAndWait();
  });

  test("after the host restarts it still arrives, with no session registry involved", async () => {
    const t = setup();
    await adopt(t);
    await t.hub.pals.stopAndWait();
    // a new host process over the same state; the registry holds nothing of the assistant's
    const t2 = setup({ claude: t.claude, paths: t.paths });
    await waitFor(() => t2.driver.pals.length === 1, 5_000);
    const before = readdirSync(join(t.claude.dir, "sessions")).sort();
    expect(await palOpts(t2).paloSend!("重启之后也到")).toContain("已经送到");
    await waitFor(() => !!t2.driver.last?.sent.length);
    expect(t2.driver.last!.sent).toEqual([wrapped("网站", "重启之后也到")]);
    expect(readdirSync(join(t.claude.dir, "sessions")).sort()).toEqual(before);
    await t2.hub.pals.stopAndWait();
  });

  test("the Pal's own conversation shows what it sent, live and read back", async () => {
    const script: FakeScript = async (_text, ctx) => {
      await ctx.useTool(PALO_SEND_TOOL, { text: "做完了" }, { id: "toolu_p1" });
    };
    const t = setup();
    t.driver.palScript = script;
    const pal = await adopt(t);
    await t.call("pals.send", { id: pal.id, text: "汇报" });
    await waitFor(() => t.events.some((e) => e.event === "chat.message" && e.data.pal === pal.id && e.data.id === "toolu_p1"));
    expect(t.events.find((e) => e.data?.id === "toolu_p1")!.data).toMatchObject({ role: "assistant", kind: "text", text: "做完了", pal: pal.id });
    const entries = [
      { type: "assistant", uuid: "a1", timestamp: "2026-10-18T10:00:00Z", message: { id: "msg_1", model: "m", content: [{ type: "text", text: "好，我告诉它" }, { type: "tool_use", id: "toolu_p1", name: PALO_SEND_TOOL, input: { text: "做完了" } }] } },
    ];
    const msgs = toPalMessages(entries as any, { pal: pal.id, assistantName: "Palo", paloName: "Palo" });
    expect(msgs.map((m) => [m.id, m.role, m.text])).toEqual([["msg_1", "assistant", "好，我告诉它"], ["toolu_p1", "assistant", "做完了"]]);
    await t.hub.pals.stopAndWait();
  });

  test("handoff tracking reads it as a reply to the assistant", () => {
    const tail = summarizeTail([{ type: "assistant", timestamp: "2026-10-18T10:00:00Z", message: { content: [{ type: "tool_use", id: "x", name: PALO_SEND_TOOL, input: { text: "做完了" } }] } }]);
    expect(tail.replies).toHaveLength(1);
    expect(tail.replies[0]).toMatchObject({ text: "做完了" });
  });

  test("the prompts tell each side which tool to use", () => {
    expect(tr("pals.prompt", { paloName: "Palo" })).toContain("palo_send");
    expect(BEHAVIORS.zh).toMatch(/from-name.*pal_send/s);
    expect(BEHAVIORS.en).toMatch(/from-name.*pal_send/s);
  });
});

describe("a session's tools that reach the owner", () => {
  const MANAGER = ["pal_propose", "pal_adopt", "pals_recent", "pal_send", "register_watch", "list_watches", "remove_watch", "update_goal", "report_task", "ally_list", "ally_send", "pair_link"];

  test("exactly the intended tools, pre-approved; the built-in Artifact and SendUserFile are off, SendMessage stays; Palo's list is unchanged", async () => {
    const t = setup();
    await adopt(t);
    const sdk: any = sessionOptions(palOpts(t) as MainSessionOptions);
    const names = Object.keys(sdk.mcpServers.paloally.instance._registeredTools);
    expect(names.sort()).toEqual(["Artifact", "SendUserFile", "copy_to_clipboard", "notify_user", "palo_send", "pals_list"]);
    for (const m of MANAGER) expect(names).not.toContain(m);
    expect(sdk.allowedTools.sort()).toEqual(names.map((n) => `mcp__paloally__${n}`).sort());
    expect(sdk.disallowedTools).toEqual(["Artifact", "SendUserFile"]);
    expect(sdk.disallowedTools).not.toContain("SendMessage");
    expect(sdk.allowedTools).not.toContain("SendMessage");
    for (const n of names) {
      expect(await palOpts(t).canUseTool({ toolName: `mcp__paloally__${n}`, input: {}, toolUseId: "t1", signal: new AbortController().signal } as any)).toMatchObject({ behavior: "allow" });
    }
    const main: any = sessionOptions({ ...(palOpts(t) as any), tools: {} as any, paloSend: undefined, sessionTools: undefined });
    expect(Object.keys(main.mcpServers.paloally.instance._registeredTools)).toEqual([
      "report_task", "register_watch", "list_watches", "remove_watch", "update_goal", "SendUserFile", "Artifact", "copy_to_clipboard",
      "ally_list", "ally_send", "pals_list", "pal_send", "pal_propose", "pals_recent", "pal_adopt", "pair_link", "notify_user",
    ]);
    expect(main.disallowedTools).toEqual(["CronCreate", "CronDelete", "CronList", "ScheduleWakeup"]);
    await t.hub.pals.stopAndWait();
  });

  test("Artifact records the session as its source, reads paths from its folder, and shows it on the wire", async () => {
    const t = setup();
    const pal = await adopt(t);
    writeFileSync(join(t.project, "report.md"), "# 报告");
    const out = await palOpts(t).sessionTools!.Artifact({ file_path: "report.md", title: "报告", description: "做好了", folder: "测试" });
    expect(out).toContain("报告");
    const listed = (await t.call("artifact.list")).artifacts.find((a: any) => a.title === "报告");
    expect(listed).toMatchObject({ source: pal.id, folder: "测试", mainFile: "report.md" });
    // the assistant's own say "palo"
    writeFileSync(join(t.hub.paths.home, "mine.md"), "# 我的");
    await t.hub.toolHandlers().Artifact({ file_path: "mine.md" });
    expect(t.hub.artifacts.list().find((a) => a.mainFile === "mine.md")!.source).toBe("palo");
    // the card is in the session's conversation, not the assistant's
    const card = t.events.find((e) => e.event === "chat.message" && e.data.attachments?.[0]?.id === listed.id);
    expect(card!.data).toMatchObject({ pal: pal.id, role: "assistant", attachments: [{ kind: "artifact", display: "render" }] });
    expect(t.hub.chat.recent(20).some((m) => m.attachments?.some((a) => a.id === listed.id))).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("SendUserFile lands in the session's conversation, live and read back, never in the assistant's", async () => {
    const script: FakeScript = async (_text, ctx) => {
      await ctx.useTool("mcp__paloally__SendUserFile", { files: ["chart.txt"], status: "normal" }, { id: "toolu_f1" });
    };
    const t = setup();
    t.driver.palScript = script;
    const pal = await adopt(t);
    writeFileSync(join(t.project, "chart.txt"), "数据");
    const before = t.hub.chat.recent(50).length;
    await palOpts(t).sessionTools!.SendUserFile({ files: ["chart.txt"], caption: "图表", status: "normal" });
    const live = t.events.find((e) => e.event === "chat.message" && e.data.pal === pal.id && e.data.attachments?.length);
    expect(live!.data).toMatchObject({ role: "assistant", text: "图表", attachments: [{ kind: "artifact", name: "chart.txt" }] });
    expect(t.hub.chat.recent(50).length).toBe(before);
    expect(t.hub.artifacts.list().find((a) => a.mainFile === "chart.txt")!.source).toBe(pal.id);
    // read back from its transcript: the tool call carries the same id the live message had
    const entries = [{ type: "assistant", uuid: "a1", timestamp: "2026-10-19T10:00:00Z", message: { id: "msg_1", model: "m", content: [{ type: "tool_use", id: live!.data.id, name: "mcp__paloally__SendUserFile", input: { files: ["chart.txt"], status: "normal" } }] } }];
    const msgs = toPalMessages(entries as any, { pal: pal.id, assistantName: "Palo", paloName: "Palo", recall: (u) => t.hub.media.recall(u) });
    expect(msgs).toHaveLength(1);
    expect(msgs[0]).toMatchObject({ id: live!.data.id, text: "图表", pal: pal.id, attachments: [{ name: "chart.txt" }] });
    await t.hub.pals.stopAndWait();
  });

  test("a clipboard text is a card in the session's conversation too", async () => {
    const t = setup();
    const pal = await adopt(t);
    await palOpts(t).sessionTools!.copy_to_clipboard({ text: "123456", label: "验证码" });
    expect(t.events.find((e) => e.event === "chat.message" && e.data.pal === pal.id && e.data.kind === "clipboard")!.data).toMatchObject({ text: "123456", label: "验证码" });
    expect(t.hub.chat.recent(20).some((m) => m.kind === "clipboard")).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("notify_user is titled with the session's name and keeps to the proactive budget", async () => {
    const t = setup();
    const pal = await adopt(t);
    const r = await palOpts(t).sessionTools!.notify_user({ text: "要你看一下" });
    expect(r).toContain("已推送");
    expect(t.pusher.pushes.at(-1)).toMatchObject({ title: "网站", body: "要你看一下", data: { pal: pal.id } });
    expect(t.hub.chat.recent(20).some((m) => m.text === "要你看一下")).toBe(false); // nothing in the assistant's conversation
    // quiet hours hold it back, as they do the assistant's, unless it's urgent
    t.hub.config.settings.quietHours = { start: "00:00", end: "23:59" };
    (t.hub as any).router.lastOwnerActivity = () => 0;
    const n = t.pusher.pushes.length;
    expect(await palOpts(t).sessionTools!.notify_user({ text: "不急的事" })).not.toContain("已推送");
    expect(t.pusher.pushes.length).toBe(n);
    expect(await palOpts(t).sessionTools!.notify_user({ text: "急事", urgent: true })).toContain("已推送");
    expect(t.pusher.pushes.at(-1)).toMatchObject({ title: "网站", body: "急事" });
    await t.hub.pals.stopAndWait();
  });

  test("pals_list is read only and the prompt names the tools", async () => {
    const t = setup();
    const pal = await adopt(t);
    expect(JSON.parse(await palOpts(t).sessionTools!.pals_list()).pals.map((p: any) => p.id)).toContain(pal.id);
    expect(tr("pals.prompt", { paloName: "Palo" })).toMatch(/Artifact.*SendUserFile.*notify_user/s);
    setLang("en");
    try {
      expect(tr("pals.prompt", { paloName: "Palo" })).toMatch(/Artifact.*SendUserFile.*notify_user/s);
    } finally {
      setLang("zh");
    }
    await t.hub.pals.stopAndWait();
  });
});
