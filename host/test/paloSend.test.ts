import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { allyTurnTool } from "../src/allyGate.ts";
import { sessionOptions } from "../src/harness/claude.ts";
import { PALO_SEND_TOOL, type MainSessionOptions } from "../src/harness/types.ts";
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
  test("the Pal's process gets exactly one tool, pre-approved, and none of the assistant's", async () => {
    const t = setup();
    await adopt(t);
    const opts = palOpts(t);
    expect(typeof opts.paloSend).toBe("function");
    expect((opts as any).tools).toBeUndefined();
    const sdk = sessionOptions(opts as MainSessionOptions);
    expect(Object.keys(sdk.mcpServers!)).toEqual(["paloally"]);
    const server: any = (sdk.mcpServers as any).paloally.instance;
    expect(Object.keys(server._registeredTools)).toEqual(["palo_send"]);
    expect(sdk.allowedTools).toEqual([PALO_SEND_TOOL]);
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
