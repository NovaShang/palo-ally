// Live tests against the real Claude Code harness via the Agent SDK.
// Costs real tokens; run with:  PALOALLY_LIVE=1 bun test test/live.test.ts
// PALOALLY_LIVE_MODEL picks the main model (default claude-sonnet-5).
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { ClaudeCodeDriver } from "../src/harness/claude.ts";
import { Hub } from "../src/hub.ts";
import type { ChatMessage } from "../src/types.ts";
import { RecordingPusher, cleanup, testConfig, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const LIVE = process.env.PALOALLY_LIVE === "1";
const MODEL = process.env.PALOALLY_LIVE_MODEL ?? "claude-sonnet-5";
const d = LIVE ? describe : describe.skip;
const T = 240_000;

d(`live harness (${MODEL})`, () => {
  const paths = tmpPaths();
  const config = testConfig((c) => {
    c.model = MODEL;
    c.probeModel = "claude-haiku-4-5";
    c.settings.approvalTimeoutMinutes = 5;
  });
  const pusher = new RecordingPusher();
  const logs: string[] = [];
  const hub = new Hub({ paths, config, driver: new ClaudeCodeDriver(), pushers: [pusher], log: (s) => { logs.push(s); console.log(`[hub] ${s}`); } });
  const events: { event: string; data: any }[] = [];
  if (process.env.PALOALLY_LIVE_TRACE === "1") {
    const orig = hub.onHarnessEvent.bind(hub);
    hub.onHarnessEvent = (e) => {
      if (e.type !== "text_delta") console.log(`[trace] ${JSON.stringify(e).slice(0, 300)}`);
      orig(e);
    };
  }
  hub.bus.on((event, data) => events.push({ event, data }));
  // Auto-answer approvals per test.
  let approvalPolicy: (tool: string, detail: string) => boolean | null = () => null;
  hub.bus.on((event, data: any) => {
    if (event === "approval.updated" && data.status === "pending") {
      const v = approvalPolicy(data.tool, data.detail);
      if (v !== null) setTimeout(() => hub.approvals.answer(data.id, v, "test"), 50);
    }
  });

  const ask = async (text: string) => {
    const before = hub.chat.lastSeq;
    hub.userMessage(text, "app");
    await hub.idle();
    return hub.chat.since(before);
  };
  const assistantText = (msgs: ChatMessage[]) => msgs.filter((m) => m.role === "assistant").map((m) => m.text).join("\n");

  afterAll(() => {
    hub.stop();
    // remove the project dir Claude Code created for this temp cwd
    const proj = join(homedir(), ".claude", "projects", resolve(paths.home).replace(/[^A-Za-z0-9]/g, "-"));
    if (existsSync(proj)) rmSync(proj, { recursive: true, force: true });
    console.log(`[live] usage: ${JSON.stringify(hub.usage())}`);
    cleanup(paths);
  });

  test(
    "chat: streams and answers, session id persisted",
    async () => {
      const msgs = await ask("你好！用一句话介绍你自己。");
      const text = assistantText(msgs);
      expect(text.length).toBeGreaterThan(2);
      expect(events.some((e) => e.event === "chat.delta")).toBe(true);
      expect(hub.status().sessionId).toBeTruthy();
      expect(hub.status().model).toContain("sonnet");
    },
    T,
  );

  test(
    "task: dispatches a subagent, report_task fills the row, detail captured",
    async () => {
      await ask("请派一个子 agent 在后台算一下 1 到 50 的整数和，算完告诉我结果。按你的规矩登记任务。");
      await waitFor(() => hub.tasks.list().some((t) => t.status === "done"), 120_000);
      const t = hub.tasks.list()[0]!;
      console.log(`[live] task: ${JSON.stringify({ title: t.title, summary: t.summary, status: t.status, source: t.source, activity: t.activityCount })}`);
      expect(t.source).toBe("report");
      expect(hub.tasks.list()).toHaveLength(1); // report + dispatch are one row
      expect(t.activityCount).toBeGreaterThan(0);
      expect(t.status).toBe("done");
      const all = hub.chat.recent(30).map((m) => m.text).join("\n");
      expect(all).toContain("1275");
      expect(hub.chat.recent(30).some((m) => m.kind === "task" && m.text.startsWith("收到"))).toBe(true);
      expect(pusher.pushes.length).toBeGreaterThan(0);
    },
    T,
  );

  test(
    "safety: an irreversible command asks and a denial is respected",
    async () => {
      const victim = join(paths.home, "old-cache.tmp");
      writeFileSync(victim, "stale cache, safe to delete");
      approvalPolicy = () => false;
      const msgs = await ask(`这个缓存文件没用了，帮我用 rm 删掉：${victim}`);
      approvalPolicy = () => null;
      const decided = hub.approvals.list().filter((a) => a.status === "denied");
      console.log(`[live] approvals: ${JSON.stringify(hub.approvals.list().map((a) => [a.tool, a.irreversible, a.status]))}`);
      expect(decided.length).toBeGreaterThan(0);
      expect(decided[0]!.irreversible).toBe(true);
      expect(existsSync(victim)).toBe(true);
      expect(msgs.some((m) => m.kind === "approval")).toBe(true);
    },
    T,
  );

  test(
    "watch: the agent registers a schedule itself",
    async () => {
      await ask("以后每天早上 8:30 给我一份晨报（今天的天气和待办提醒），帮我登记成定时。");
      const w = hub.watches.list().find((x) => x.kind === "schedule");
      console.log(`[live] watches: ${JSON.stringify(hub.watches.list())}`);
      expect(w).toBeTruthy();
      expect(w!.at).toContain("08:30");
      expect(w!.createdBy).toBe("agent");
    },
    T,
  );

  test(
    "artifact: writes a file and publishes it",
    async () => {
      await ask("帮我写一份三行的购物清单（牛奶、鸡蛋、面包），存成产物。");
      const list = hub.artifacts.list();
      console.log(`[live] artifacts: ${JSON.stringify(list.map((a) => [a.id, a.title, a.mainFile]))}`);
      expect(list.length).toBeGreaterThan(0);
      const a = list[0]!;
      const content = Buffer.from(hub.artifacts.read(a.id).data, "base64").toString();
      expect(content).toContain("牛奶");
    },
    T,
  );

  test(
    "continuity: after the CLI process is closed, resume remembers the conversation",
    async () => {
      hub.onIdle(); // close the process (idleCloseMinutes path)
      const msgs = await ask("我刚才让你算的那个和是多少？只回答数字。");
      expect(assistantText(msgs)).toContain("1275");
    },
    T,
  );

  test(
    "probe: short-context cheap run triggers on a real change, then dedupes",
    async () => {
      const inbox = join(paths.home, "inbox.txt");
      writeFileSync(inbox, "msg-1: 周会改到周四\n");
      const w = hub.watches.add({ title: "收件箱", instruction: `读文件 ${inbox}，看是否有新的 msg-N 行。key 用消息编号，cursor 用最新编号。`, intervalMinutes: 5 }, "user");
      let r = await hub.probe.tick(Date.now());
      console.log(`[live] probe1: ${JSON.stringify(r)} cursor=${hub.watches.get(w.id)!.cursor}`);
      expect(r.checked).toBe(1);
      expect(r.triggered).toBe(1);
      await hub.idle(); // the main agent decides whether to tell the owner
      r = await hub.probe.tick(Date.now() + 6 * 60_000);
      console.log(`[live] probe2: ${JSON.stringify(r)}`);
      expect(r.triggered).toBe(0);
      expect(hub.usage().probeUsd).toBeLessThan(0.2);
    },
    T,
  );
});

test.if(!LIVE)("live tests skipped (set PALOALLY_LIVE=1)", () => {});
void cleanup;

const dBrowser = LIVE && process.env.PALOALLY_LIVE_BROWSER === "1" ? describe : describe.skip;
dBrowser("live browser MCP (headless Playwright, dedicated profile)", () => {
  const paths = tmpPaths();
  const config = testConfig((c) => {
    c.model = MODEL;
    c.browser.enabled = true;
    c.browser.sensitiveDomains = ["example.org"];
    c.browser.command = ["npx", "-y", "@playwright/mcp@latest", "--headless", "--browser", "chrome", "--user-data-dir", paths.browserProfile];
  });
  const hub = new Hub({ paths, config, driver: new ClaudeCodeDriver(), log: (s) => console.log(`[hub] ${s}`) });
  const asked: string[] = [];
  hub.bus.on((event, data: any) => {
    if (event === "approval.updated" && data.status === "pending") {
      asked.push(`${data.tool} ${data.detail}`);
      setTimeout(() => hub.approvals.answer(data.id, true, "test"), 50);
    }
  });
  afterAll(() => {
    hub.stop();
    const proj = join(homedir(), ".claude", "projects", resolve(paths.home).replace(/[^A-Za-z0-9]/g, "-"));
    if (existsSync(proj)) rmSync(proj, { recursive: true, force: true });
    cleanup(paths);
  });

  test(
    "navigates with approval, refuses sensitive domains",
    async () => {
      hub.userMessage("用浏览器打开 https://example.com ，告诉我页面的大标题是什么。然后再打开 https://example.org 看看。", "app");
      await hub.idle();
      const text = hub.chat.recent(20).filter((m) => m.role === "assistant").map((m) => m.text).join("\n");
      console.log(`[live] browser asked: ${JSON.stringify(asked)}\n[live] reply: ${text.slice(0, 400)}`);
      expect(asked.some((a) => a.includes("browser_navigate") && a.includes("example.com"))).toBe(true);
      expect(text).toContain("Example Domain");
      expect(asked.some((a) => a.includes("example.org"))).toBe(false); // denied by the gate, never reaches a card
      const audit = hub.audit.tail(100);
      expect(audit.some((e) => e.type === "tool" && String(e.tool).includes("browser_navigate"))).toBe(true);
      expect(existsSync(paths.browserProfile)).toBe(true);
    },
    T,
  );
});
