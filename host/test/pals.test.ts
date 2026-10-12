import { afterAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { transcriptPath } from "../src/handoffs.ts";
import { findHelper, makeSpawner } from "../src/palLauncher.ts";
import { pagePalMessages, toPalMessages, transcriptLastLine, transcriptModel } from "../src/palHistory.ts";
import { MAX_PALS, PALO_NAME, type PalsTiming } from "../src/pals.ts";
import { startError } from "../src/palSession.ts";
import { handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
const procs: ChildProcess[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
  for (const p of procs) if (p.exitCode === null) p.kill("SIGKILL");
});

/** A live process that stands in for a terminal session's Claude Code. */
function liveProcess(): ChildProcess {
  const p = spawn("/bin/sleep", ["120"]);
  procs.push(p);
  return p;
}

const exited = (p: ChildProcess) => new Promise<void>((r) => (p.exitCode !== null || p.signalCode !== null ? r() : p.once("exit", () => r())));

const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };

// The Pal's turn: streams its answer in two pieces of one API message, the
// way Claude Code does (the same id streamed and final).
let msgN = 0;
const echo: FakeScript = async (text, ctx) => {
  const id = `msg_${++msgN}`;
  const reply = `收到：${text}`;
  ctx.emit({ type: "text_delta", text: reply.slice(0, 3), messageId: id });
  ctx.emit({ type: "text_delta", text: reply.slice(3), messageId: id });
  ctx.emit({ type: "assistant_text", text: reply, parentToolUseId: null, messageId: id });
};

function setup(o: { spawn?: boolean; timing?: Partial<PalsTiming>; palScript?: FakeScript; settings?: string } = {}) {
  const claude = new FakeClaudeDir();
  dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const raw = new Map<string, any[]>();
  const readMessages = async (sid: string) => raw.get(sid) ?? [];
  if (o.settings) writeFileSync(join(claude.dir, "settings.json"), o.settings);
  const ctx = makeHub({
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false), readMessages },
    pals: { readMessages, timing: { ...FAST, ...o.timing } },
  });
  ctx.driver.spawnPals = o.spawn ?? false;
  ctx.driver.palScript = o.palScript ?? echo;
  ctx.hub.pals.start(); // the checks run (nothing to bring back yet)
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-pal-")));
  const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(ctx.hub, { method, params }, app)) ?? null));
  const palEvents = (name: string) => ctx.events.filter((e) => e.event === name && e.data.pal).map((e) => e.data);
  const lastList = () => ctx.events.filter((e) => e.event === "pals.updated").at(-1)?.data;
  return { ...ctx, claude, cli, raw, project, call, palEvents, lastList };
}

/** A background session of the computer's, with something said in it. */
function bgSession(t: ReturnType<typeof setup>, name = "网站", sid = "aaaa1111-0000-4000-8000-000000000001") {
  t.cli.bg({ sessionId: sid, name, cwd: t.project });
  t.claude.transcript(t.project, sid, [assistantEntry("列表页做好了。", { model: "claude-haiku-4-5-20251001" })]);
  return sid;
}

describe("adopting a session", () => {
  test("a background session: claude stop first, then the host resumes it under a fixed name; it's a Pal, not one of the others", async () => {
    const t = setup({ settings: JSON.stringify({ permissions: { defaultMode: "acceptEdits" } }) });
    const sid = bgSession(t);
    expect((await t.call("pals.list")).others.map((s: any) => s.id)).toEqual([sid]);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    expect(pal).toMatchObject({ name: "网站", cwd: t.project, sessionId: sid, status: "idle", createdBy: "owner", pending: 0, lastLine: "列表页做好了。", model: "claude-haiku-4-5-20251001" });
    expect(pal.id).toMatch(/^pal_/);
    expect(t.cli.calls).toEqual([`stop ${sid.slice(0, 8)}`]);
    // resumed: its own session, its folder, the owner's permission mode, its transcript's model, named
    const proc = t.driver.pals[0]!;
    expect(proc.opts).toMatchObject({ cwd: t.project, resumeSessionId: sid, name: "网站", permissionMode: "acceptEdits", model: "claude-haiku-4-5-20251001", ownerOrigin: true });
    expect(proc.opts.appendSystemPrompt).toContain(`名叫「${PALO_NAME}」的会话是主人的助理`);
    expect((proc.opts as any).tools).toBeUndefined();
    const list = await t.call("pals.list");
    expect(list.pals.map((p: any) => p.id)).toEqual([pal.id]);
    expect(list.others).toEqual([]);
    expect(list).toMatchObject({ hooks: false, helper: false });
    expect(t.lastList().pals[0]).toMatchObject({ id: pal.id, status: "idle" });
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.adopted")).toMatchObject({ session: sid, name: "网站" });
    // adopting again gives the same Pal
    expect((await t.call("pals.adopt", { sessionId: sid })).pal.id).toBe(pal.id);
    expect(t.driver.pals).toHaveLength(1);
    await t.hub.pals.stopAndWait();
  });

  test("a terminal session: the host waits for it to quit there (no second process meanwhile), then takes it over within a second", async () => {
    const t = setup();
    const term = liveProcess();
    const sid = "bbbb2222-0000-4000-8000-000000000002";
    t.claude.register({ sessionId: sid, name: "修登录", cwd: t.project, pid: term.pid });
    t.claude.transcript(t.project, sid, [assistantEntry("登录跳转修好了。")]);
    expect(await t.call("pals.adopt", { sessionId: sid })).toEqual({ waiting: "exit-in-terminal" });
    expect(await t.call("pals.adopt", { sessionId: sid })).toEqual({ waiting: "exit-in-terminal" });
    await tick(200);
    expect(t.driver.pals).toHaveLength(0);
    expect((await t.call("pals.list")).others.find((s: any) => s.id === sid)).toMatchObject({ adopting: true, kind: "terminal" });
    // the owner types /exit in the terminal
    const t0 = Date.now();
    term.kill("SIGTERM");
    await exited(term);
    await waitFor(() => t.hub.pals.list().length === 1, 5_000);
    expect(Date.now() - t0).toBeLessThan(1_500);
    expect(t.hub.pals.list()[0]).toMatchObject({ sessionId: sid, name: "修登录", status: "idle" });
    expect(t.driver.pals).toHaveLength(1);
    expect(t.lastList().others.some((s: any) => s.id === sid)).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("cancelling the wait for a terminal session: the host stops waiting at once (the list says so), and quitting it later adopts nothing", async () => {
    const t = setup();
    const term = liveProcess();
    const sid = "bbbb2222-0000-4000-8000-000000000003";
    t.claude.register({ sessionId: sid, name: "修登录", cwd: t.project, pid: term.pid });
    t.claude.transcript(t.project, sid, [assistantEntry("登录跳转修好了。")]);
    expect(await t.call("pals.adopt", { sessionId: sid })).toEqual({ waiting: "exit-in-terminal" });
    await waitFor(() => t.lastList()?.others.find((s: any) => s.id === sid)?.adopting === true);
    const n = t.events.filter((e) => e.event === "pals.updated").length;
    expect(await t.call("pals.adopt", { sessionId: sid, cancel: true })).toEqual({ cancelled: true });
    // other devices hear it straight away
    const after = t.events.filter((e) => e.event === "pals.updated").slice(n);
    expect(after.length).toBeGreaterThan(0);
    expect(after.at(-1)!.data.others.find((s: any) => s.id === sid)).toMatchObject({ kind: "terminal" });
    expect(after.at(-1)!.data.others.find((s: any) => s.id === sid).adopting).toBeUndefined();
    expect(t.hub.pals.adopting(sid)).toBe(false);
    expect(t.hub.audit.tail(10).find((e) => e.type === "pal.adopt_cancelled")).toMatchObject({ session: sid, name: "修登录" });
    // quit in the terminal afterwards: nothing is adopted
    term.kill("SIGTERM");
    await exited(term);
    t.claude.unregister(sid);
    await tick(300);
    expect(t.hub.pals.list()).toEqual([]);
    expect(t.driver.pals).toHaveLength(0);
    // nothing waiting: says so; one that's a Pal comes back as it
    expect(await t.call("pals.adopt", { sessionId: sid, cancel: true })).toEqual({ cancelled: false });
    const bg = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: bg });
    expect(await t.call("pals.adopt", { sessionId: bg, cancel: true })).toEqual({ cancelled: false, pal: expect.objectContaining({ id: pal.id }) });
    expect(t.hub.pals.list()).toHaveLength(1);
    await t.hub.pals.stopAndWait();
  });

  test("never two writers: a background session that won't stop isn't adopted; a Pal's transcript opened elsewhere makes the Pal step aside and stay down while that lasts", async () => {
    const t = setup({ spawn: true });
    const sid = bgSession(t);
    t.cli.stuck = true;
    await expect(t.call("pals.adopt", { sessionId: sid })).rejects.toThrow("停不下来");
    expect(t.driver.pals).toHaveLength(0);
    t.cli.stuck = false;
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const own = t.driver.pals[0]!.proc!;
    expect(own.pid).toBeGreaterThan(0);
    // Claude Code registers the Pal's own process: that's fine
    t.claude.register({ sessionId: sid, name: "网站", cwd: t.project, pid: own.pid, entrypoint: "sdk-ts" });
    await tick(150);
    expect(t.hub.pals.list()[0]!.status).toBe("idle");
    // the owner resumes it in a terminal: the Pal leaves at once
    const term = liveProcess();
    t.claude.register({ sessionId: sid, name: "网站", cwd: t.project, pid: term.pid });
    await waitFor(() => t.hub.pals.list()[0]!.status === "stopped", 3_000);
    await exited(own);
    expect(t.hub.pals.list()[0]!.note).toContain("在别处打开了");
    // its words don't start a second process while the terminal holds it
    await expect(t.call("pals.send", { id: pal.id, text: "在吗" })).rejects.toThrow("在别处开着");
    expect(t.driver.pals).toHaveLength(1);
    expect(t.hub.pals.list()[0]).toMatchObject({ status: "stopped", note: expect.stringContaining("在别处开着") });
    // the terminal quits: it comes back by itself
    term.kill("SIGKILL");
    await exited(term);
    t.claude.unregister(sid);
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle", 3_000);
    expect(t.driver.pals).toHaveLength(2);
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    expect(t.driver.pals).toHaveLength(2);
    expect(t.hub.audit.tail(30).some((e) => e.type === "pal.elsewhere")).toBe(true);
    await t.hub.pals.stopAndWait();
  });

  test("a session it doesn't know, a session already gone, and room for five", async () => {
    const t = setup();
    await expect(t.call("pals.adopt", { sessionId: "nope" })).rejects.toThrow("没有这个会话");
    for (let i = 1; i <= MAX_PALS; i++) {
      const sid = bgSession(t, `项目${i}`, `cccc000${i}-0000-4000-8000-00000000000${i}`);
      await t.call("pals.adopt", { sessionId: sid });
      await tick(2);
    }
    // the one least recently used is named
    await t.call("pals.send", { id: t.hub.pals.get("项目1")!.id, text: "接着做" });
    await t.hub.idle();
    const sixth = bgSession(t, "第六个", "dddd0006-0000-4000-8000-000000000006");
    await expect(t.call("pals.adopt", { sessionId: sixth })).rejects.toThrow("最久没用的是「项目2」");
    await t.hub.pals.stopAndWait();
  });

  test("a resume Claude Code refuses (held by its background service) leaves no Pal and says why", async () => {
    const t = setup();
    const sid = bgSession(t);
    t.driver.failPalStart = () => "Error: That session is running in the background (aaaa1111). Run `claude stop aaaa1111` first";
    await expect(t.call("pals.adopt", { sessionId: sid })).rejects.toThrow("它还在后台跑着");
    expect(t.hub.pals.list()).toEqual([]);
    expect(JSON.parse(readFileSync(t.paths.pals, "utf8")).pals).toEqual([]);
  });
});

describe("talking to a Pal", () => {
  test("the owner's words go in as typed and as the owner's; the reply streams back with the Pal's id, under one id; nothing lands in the assistant's conversation; a retried send goes in once", async () => {
    const t = setup();
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    const before = t.hub.chat.lastSeq;
    const sent = await t.call("pals.send", { id: pal.id, text: "  先别管登录页，把列表页做完 ", clientMsgId: "c-1" });
    await waitFor(() => t.palEvents("chat.message").some((m) => m.role === "assistant"));
    const proc = t.driver.pals[0]!;
    expect(proc.sent).toEqual(["先别管登录页，把列表页做完"]);
    const [mine, reply] = t.palEvents("chat.message");
    expect(mine).toMatchObject({ id: sent.id, seq: sent.seq, role: "user", kind: "text", text: "先别管登录页，把列表页做完", pal: pal.id, clientMsgId: "c-1", channel: "app" });
    expect(mine.from).toBeUndefined();
    expect(reply).toMatchObject({ role: "assistant", kind: "text", text: "收到：先别管登录页，把列表页做完", pal: pal.id });
    const deltas = t.palEvents("chat.delta");
    expect(deltas.map((d) => d.id)).toEqual([reply.id, reply.id]);
    expect(deltas.map((d) => d.text).join("")).toBe(reply.text);
    expect(t.hub.chat.lastSeq).toBe(before);
    expect(t.events.filter((e) => e.event === "chat.message" && !e.data.pal && e.data.seq > before)).toEqual([]);
    // the same send again (the app retried): one message
    expect(await t.call("pals.send", { id: pal.id, text: "先别管登录页，把列表页做完", clientMsgId: "c-1" })).toEqual(sent);
    expect(proc.sent).toHaveLength(1);
    expect(t.hub.pals.list()[0]).toMatchObject({ status: "idle", lastLine: "收到：先别管登录页，把列表页做完" });
    await t.hub.pals.stopAndWait();
  });

  test("busy while it works (with what it's doing), and 停止 ends the turn and answers its open cards no — the assistant's own are left alone", async () => {
    const t = setup({
      palScript: async (_text, ctx) => {
        ctx.emit({ type: "tool_use", id: "t1", name: "Bash", input: { command: "npm test" }, parentToolUseId: null });
        await ctx.interrupted;
      },
    });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    await t.call("pals.send", { id: pal.id, text: "跑测试" });
    await waitFor(() => t.hub.pals.list()[0]!.status === "busy");
    await tick(50);
    expect(t.hub.pals.list()[0]).toMatchObject({ status: "busy", activity: "在电脑上操作" });
    expect(await t.call("pals.stop", { id: pal.id })).toEqual({ ok: true });
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle");
    expect(t.hub.audit.tail(10).find((e) => e.type === "pal.stop")).toMatchObject({ pal: pal.id });
    await t.hub.pals.stopAndWait();
  });

  test("its permission prompt and question are cards with the Pal as source, wherever the owner is; one push per 10 minutes; allow lets it run, with the harness' always-allow on offer", async () => {
    const t = setup({
      palScript: async (text, ctx) => {
        if (text.startsWith("问")) {
          await ctx.useTool("AskUserQuestion", { questions: [{ question: "方案选哪个？", header: "方案", options: [{ label: "A" }, { label: "B" }], multiSelect: false }] }, { ask: true });
          return;
        }
        await ctx.useTool("Bash", { command: "npm run build && npm test -- --coverage" }, {
          ask: true,
          suggestions: [{ type: "addRules", behavior: "allow", destination: "localSettings", rules: [{ toolName: "Bash", ruleContent: "npm run build:*" }] }],
        });
      },
    });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    await t.call("pals.send", { id: pal.id, text: "构建" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    const card = t.hub.approvals.listPending()[0]!;
    expect(card).toMatchObject({ tool: "Bash", title: "在电脑上运行一条命令", detail: "npm run build && npm test -- --coverage", source: { kind: "pal", id: pal.id, name: "网站" }, suggestedScope: "cmd:npm run build" });
    // not in the assistant's conversation; the Pal waits
    expect(t.hub.chat.recent(5).some((m) => m.approvalId === card.id)).toBe(false);
    expect(t.hub.pals.list()[0]).toMatchObject({ status: "waiting", pending: 1 });
    expect(t.pusher.pushes).toEqual([expect.objectContaining({ title: "网站 在等你", body: "想运行：npm run build && npm test -- --coverage", data: expect.objectContaining({ pal: pal.id, approvalId: card.id }) })]);
    // the assistant's stop button doesn't touch a Pal's card
    t.hub.stopAll("app");
    expect(t.hub.approvals.listPending()).toHaveLength(1);
    await t.call("approval.answer", { id: card.id, allow: true, remember: true });
    await t.hub.idle();
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle");
    expect(t.driver.decisions.at(-1)).toMatchObject({ tool: "Bash", decision: { behavior: "allow", updatedPermissions: [expect.objectContaining({ type: "addRules" })] } });
    expect(t.hub.audit.tail(20).find((e) => e.type === "approval.decided")).toMatchObject({ status: "allowed", device: "dev-test", session: pal.id, sessionName: "网站" });
    // a question: the answers go back as its input; no second push within 10 minutes
    await t.call("pals.send", { id: pal.id, text: "问一下" });
    await waitFor(() => t.hub.questions.listPending().length === 1);
    const q = t.hub.questions.listPending()[0]!;
    expect(q.source).toEqual({ kind: "pal", id: pal.id, name: "网站" });
    expect(t.pusher.pushes).toHaveLength(1);
    await t.call("question.answer", { id: q.id, answers: { "方案选哪个？": "B" } });
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle");
    expect(t.driver.decisions.at(-1)!.decision).toMatchObject({ behavior: "allow", updatedInput: { answers: { "方案选哪个？": "B" } } });
    await t.hub.pals.stopAndWait();
  });

  test("history: its whole conversation from its transcript — the owner, its replies (one per API message), the assistant's words under its name, other sessions'; paged by id; the newest page has the reply being written", async () => {
    const t = setup({
      palScript: async (_text, ctx) => {
        ctx.emit({ type: "text_delta", text: "正在", messageId: "msg_live" });
        await ctx.interrupted;
      },
    });
    t.hub.updateSettings({ assistantName: "帕帕" });
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    t.raw.set(sid, [
      { type: "user", uuid: "u1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "列表要能按日期排序" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "a1", timestamp: "2026-10-12T10:00:05Z", message: { id: "msg_1", role: "assistant", content: [{ type: "thinking", thinking: "" }] } },
      { type: "assistant", uuid: "a2", timestamp: "2026-10-12T10:00:06Z", message: { id: "msg_1", role: "assistant", content: [{ type: "text", text: "加上了。" }] } },
      { type: "assistant", uuid: "a3", timestamp: "2026-10-12T10:00:07Z", message: { id: "msg_1", role: "assistant", content: [{ type: "tool_use", id: "t", name: "Bash", input: {} }] } },
      { type: "user", uuid: "u2", timestamp: "2026-10-12T10:00:08Z", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t", content: "ok" }] } },
      { type: "assistant", uuid: "a4", timestamp: "2026-10-12T10:00:09Z", message: { id: "msg_2", role: "assistant", content: [{ type: "text", text: "测试也过了。" }] } },
      { type: "user", uuid: "u3", timestamp: "2026-10-12T10:01:00Z", message: { role: "user", content: "Another Claude session sent a message: …" }, origin: { kind: "peer", name: PALO_NAME, body: "主人说今晚不用部署" } },
      { type: "user", uuid: "u4", timestamp: "2026-10-12T10:02:00Z", message: { role: "user", content: '<cross-session-message from="uds:/tmp/x.sock" from-name="笔记整理">\n设计稿在 notes/设计.md\n</cross-session-message>' }, origin: { kind: "peer", name: "笔记整理" } },
      { type: "user", uuid: "u5", timestamp: "2026-10-12T10:03:00Z", message: { role: "user", content: "后台任务完成" }, origin: { kind: "task-notification" } },
      { type: "user", uuid: "u6", timestamp: "2026-10-12T10:04:00Z", message: { role: "user", content: "<command-name>/compact</command-name>\n<command-args></command-args>" }, origin: { kind: "human" } },
      { type: "user", uuid: "u7", timestamp: "2026-10-12T10:04:30Z", message: { role: "user", content: "This session is being continued from a previous conversation…" }, isCompactSummary: true } as any,
    ]);
    const { messages } = await t.call("pals.history", { id: pal.id, limit: 50 });
    expect(messages.map((m: any) => [m.id, m.role, m.text, m.from ?? null])).toEqual([
      ["u1", "user", "列表要能按日期排序", null],
      ["msg_1", "assistant", "加上了。", null],
      ["msg_2", "assistant", "测试也过了。", null],
      ["u3", "user", "主人说今晚不用部署", "帕帕"],
      ["u4", "user", "设计稿在 notes/设计.md", "笔记整理"],
      ["u6", "user", "/compact", null],
      ["u7", "system", "前面的对话压缩过了", null],
    ]);
    expect(messages[0]).toMatchObject({ seq: Date.parse("2026-10-12T10:00:00Z"), ts: Date.parse("2026-10-12T10:00:00Z"), kind: "text", pal: pal.id });
    expect((await t.call("pals.history", { id: pal.id, before: "u3", limit: 2 })).messages.map((m: any) => m.id)).toEqual(["msg_1", "msg_2"]);
    expect((await t.call("pals.history", { id: pal.id, before: Date.parse("2026-10-12T10:00:06Z"), limit: 5 })).messages.map((m: any) => m.id)).toEqual(["u1"]);
    // mid-reply: the newest page carries what's been written so far
    await t.call("pals.send", { id: pal.id, text: "接着做" });
    await waitFor(() => t.palEvents("chat.delta").length > 0);
    expect((await t.call("pals.history", { id: pal.id })).streaming).toEqual({ id: "msg_live", text: "正在" });
    expect((await t.call("pals.history", { id: pal.id, before: "u3" })).streaming).toBeUndefined();
    await t.call("pals.stop", { id: pal.id });
    await expect(t.call("pals.history", { id: "pal_nope" })).rejects.toThrow("没有这个 Pal");
    await t.hub.pals.stopAndWait();
  });

  test("words another session sends a Pal show in its conversation as that session's — the assistant's under the assistant's name", async () => {
    const t = setup();
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const path = transcriptPath(t.claude.dir, t.project, sid);
    const peer = (uuid: string, name: string, body: string) =>
      JSON.stringify({ type: "user", uuid, timestamp: new Date().toISOString(), message: { role: "user", content: `<cross-session-message from="uds:/tmp/p.sock" from-name="${name}">\n${body}\n</cross-session-message>` }, origin: { kind: "peer", from: "uds:/tmp/p.sock", name, body } }) + "\n";
    appendFileSync(path, peer("p1", PALO_NAME, "把登录页的测试补上，做完告诉我"));
    appendFileSync(path, peer("p2", "笔记整理", "设计稿更新了"));
    appendFileSync(path, JSON.stringify({ type: "user", uuid: "x1", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t", content: "ok" }] } }) + "\n");
    await waitFor(() => t.palEvents("chat.message").length >= 2, 5_000);
    expect(t.palEvents("chat.message").map((m) => [m.id, m.text, m.from, m.pal])).toEqual([
      ["p1", "把登录页的测试补上，做完告诉我", "Palo", pal.id],
      ["p2", "设计稿更新了", "笔记整理", pal.id],
    ]);
    await t.hub.pals.stopAndWait();
  });
});

describe("always on", () => {
  test("a Pal whose process ends by itself comes back; one that keeps failing stops with a reason; the owner's words bring it back", async () => {
    const t = setup({ spawn: true });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    const first = t.driver.pals[0]!;
    first.proc!.kill("SIGKILL"); // Claude Code died
    await waitFor(() => t.driver.pals.length === 2 && t.hub.pals.list()[0]!.status === "idle", 3_000);
    expect(t.driver.pals[1]!.opts.resumeSessionId).toBe(first.opts.resumeSessionId);
    // it keeps failing: after a few tries it stays down and says why
    t.driver.failPalStart = () => "Claude Code process exited with code 1. stderr: Error: not logged in";
    t.driver.pals[1]!.crash();
    await waitFor(() => t.hub.pals.list()[0]!.status === "stopped", 5_000);
    expect(t.hub.pals.list()[0]!.note).toContain("Claude Code 没登录");
    t.driver.failPalStart = undefined;
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    expect(t.hub.pals.list()[0]!.status).not.toBe("stopped");
    await t.hub.pals.stopAndWait();
  });

  test("at the host's start every Pal comes back; a process a crashed host left behind is stopped first; the Pals stay out of the restart's way only when quiet", async () => {
    const t = setup({ spawn: true });
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const old = t.driver.pals[0]!.proc!;
    // the host dies without closing anything: Claude Code keeps running, registered
    t.claude.register({ sessionId: sid, name: "网站", cwd: t.project, pid: old.pid, entrypoint: "sdk-ts" });
    const dead = t.hub.pals as any;
    clearInterval(dead.guardTimer);
    clearInterval(dead.dayTimer);
    for (const p of dead.pals.values()) p.closing = true; // what happens to its processes is no longer its business
    const { Pals } = await import("../src/pals.ts");
    const again = new Pals({ ...(t.hub.pals as any).d, timing: FAST });
    again.start();
    expect(again.list()[0]).toMatchObject({ id: pal.id, status: "starting" });
    await waitFor(() => again.list()[0]!.status === "idle", 5_000);
    await exited(old);
    expect(t.driver.pals).toHaveLength(2);
    expect(t.driver.pals[1]!.opts.resumeSessionId).toBe(sid);
    expect(again.quiet()).toBe(true);
    await again.stopAndWait();
  });

  test("a busy Pal keeps the host from restarting (updates wait for a clean break)", async () => {
    const t = setup({ palScript: async (_t, ctx) => void (await ctx.interrupted) });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    expect(t.hub.quietForRestart()).toBe(true);
    await t.call("pals.send", { id: pal.id, text: "做件长的事" });
    expect(t.hub.quietForRestart()).toBe(false);
    await t.call("pals.stop", { id: pal.id });
    await waitFor(() => t.hub.quietForRestart());
    await t.hub.pals.stopAndWait();
  });
});

describe("back to the terminal", () => {
  test("交还终端: the host's process is gone before the line to resume it comes back; 移出: out of the list; the transcript stays", async () => {
    const t = setup({ spawn: true });
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const proc = t.driver.pals[0]!.proc!;
    const r = await t.call("pals.release", { id: pal.id });
    expect(r).toEqual({ resumeCommand: `cd ${t.project} && claude --resume ${sid}` });
    expect(proc.exitCode !== null || proc.signalCode !== null).toBe(true);
    expect(t.hub.pals.list()).toEqual([]);
    expect(existsSync(transcriptPath(t.claude.dir, t.project, sid))).toBe(true);
    expect(t.hub.audit.tail(10).find((e) => e.type === "pal.released")).toMatchObject({ session: sid });
    // back in the computer's list, adoptable again
    t.cli.bg({ sessionId: "eeee5555-0000-4000-8000-000000000005", name: "另一个", cwd: t.project });
    const second = (await t.call("pals.adopt", { sessionId: "eeee5555-0000-4000-8000-000000000005" })).pal;
    expect(await t.call("pals.remove", { id: second.id })).toEqual({ ok: true });
    expect(t.hub.pals.list()).toEqual([]);
    await expect(t.call("pals.remove", { id: second.id })).rejects.toThrow("没有这个 Pal");
    expect(JSON.parse(readFileSync(t.paths.pals, "utf8")).pals).toEqual([]);
  });
});

describe("the assistant opens a Pal", () => {
  test("its proposal card; 开吧 starts a new session in the folder with the handover as its first message, shown as the assistant's; asking twice gives the same Pal", async () => {
    const t = setup();
    const r = await t.hub.toolHandlers().pal_propose({ name: "网站", dir: t.project, duty: "你负责主人的网站：先做列表页。", dailyUsd: 5 });
    expect(r).toContain("主人点「开吧」才会开");
    const card = t.hub.chat.recent(1)[0]!;
    expect(card).toMatchObject({ kind: "helper", text: expect.stringContaining("开一个 Pal「网站」"), proposal: { name: "网站", cwd: t.project, dailyUsd: 5, status: "pending" } });
    expect(t.driver.pals).toHaveLength(0);
    const out = await t.call("helper.decide", { proposalId: card.proposal!.id, action: "create" });
    expect(out.pal).toMatchObject({ name: "网站", cwd: t.project, createdBy: "palo" });
    const proc = t.driver.pals[0]!;
    // a new session: its id chosen up front, no resume
    expect(proc.opts.sessionId).toBe(out.pal.sessionId);
    expect(proc.opts.resumeSessionId).toBeUndefined();
    expect(proc.sent).toEqual(["你负责主人的网站：先做列表页。"]);
    const handover = t.palEvents("chat.message").find((m) => m.role === "user")!;
    expect(handover).toMatchObject({ text: "你负责主人的网站：先做列表页。", from: "Palo", pal: out.pal.id });
    // the card says it was started (the same message, sent again)
    expect(t.hub.chat.get(card.id)!.proposal).toMatchObject({ status: "created", sessionId: out.pal.sessionId, palId: out.pal.id });
    expect((await t.call("helper.decide", { proposalId: card.proposal!.id, action: "create" })).pal.id).toBe(out.pal.id);
    expect(t.driver.pals).toHaveLength(1);
    // in history the handover is the assistant's too
    t.raw.set(out.pal.sessionId, [
      { type: "user", uuid: "h1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "你负责主人的网站：先做列表页。" }, origin: { kind: "human" } },
      { type: "user", uuid: "h2", timestamp: "2026-10-12T10:05:00Z", message: { role: "user", content: "你负责主人的网站：先做列表页。" }, origin: { kind: "human" } },
    ]);
    expect((await t.call("pals.history", { id: out.pal.id })).messages.map((m: any) => m.from ?? null)).toEqual(["Palo", null]);
    // the assistant sees it in its list, by the name it SendMessages
    const listed = JSON.parse(await t.hub.toolHandlers().pals_list());
    expect(listed.pals[0]).toMatchObject({ name: "网站", dir: t.project, openedBy: "你" });
    await t.hub.pals.stopAndWait();
  });

  test("不用 drops it; a folder that isn't there and a taken name are refused; one that didn't start stays on offer saying why", async () => {
    const t = setup();
    const tools = t.hub.toolHandlers();
    await tools.pal_propose({ name: "一", dir: t.project, duty: "做事", dailyUsd: 1 });
    const p1 = t.hub.chat.recent(1)[0]!;
    expect(await t.call("helper.decide", { proposalId: p1.proposal!.id, action: "discard" })).toEqual({});
    expect(t.hub.chat.get(p1.id)!.proposal!.status).toBe("discarded");
    expect(await tools.pal_propose({ name: "二", dir: "/no/such/folder", duty: "做事", dailyUsd: 1 })).toContain("找不到目录");
    expect(await tools.pal_propose({ name: "Palo", dir: t.project, duty: "做事", dailyUsd: 1 })).toContain("助理自己的名字");
    t.driver.failPalStart = () => "Error: not logged in";
    await tools.pal_propose({ name: "三", dir: t.project, duty: "做事", dailyUsd: 1 });
    const p3 = t.hub.chat.recent(1)[0]!;
    await expect(t.call("helper.decide", { proposalId: p3.proposal!.id, action: "create" })).rejects.toThrow("Claude Code 没登录");
    expect(t.hub.chat.get(p3.id)!.proposal).toMatchObject({ status: "pending", note: "Claude Code 没登录" });
    expect(t.hub.pals.list()).toEqual([]);
    t.driver.failPalStart = undefined;
    await t.call("helper.decide", { proposalId: p3.proposal!.id, action: "create" });
    expect(t.hub.chat.get(p3.id)!.proposal!.status).toBe("created");
    expect(t.hub.chat.get(p3.id)!.proposal!.note).toBeUndefined();
    expect(await tools.pal_propose({ name: "三", dir: t.project, duty: "做事", dailyUsd: 1 })).toContain("已经有一个叫「三」的 Pal");
    await t.hub.pals.stopAndWait();
  });

  test("past its daily limit it stops and the owner hears it; the owner's words bring it back", async () => {
    const t = setup();
    await t.hub.toolHandlers().pal_propose({ name: "网站", dir: t.project, duty: "做网站", dailyUsd: 0.04 });
    const { pal } = await t.call("helper.decide", { proposalId: t.hub.chat.recent(1)[0]!.proposal!.id, action: "create" });
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle");
    const u = { input_tokens: 10, output_tokens: 1000, cache_read_input_tokens: 100_000, cache_creation_input_tokens: 0 };
    t.claude.transcript(t.project, pal.sessionId, [assistantEntry("a", { id: "msg_1", model: "claude-sonnet-4-6", usage: u })]);
    await t.call("pals.send", { id: pal.id, text: "接着做" });
    await waitFor(() => t.hub.pals.list()[0]!.status === "stopped");
    expect(t.hub.pals.list()[0]!.note).toContain("过了每天 $0.04 的上限");
    expect(t.hub.chat.recent(3).some((m) => m.text.includes("超过了每天 $0.04 的上限"))).toBe(true);
    expect(t.pusher.pushes.at(-1)!.title).toBe("Pal 停了");
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.budget")).toMatchObject({ pal: pal.id, dailyUsd: 0.04 });
    const n = t.driver.pals.length;
    await t.call("pals.send", { id: pal.id, text: "今天还是要做完" });
    expect(t.driver.pals.length).toBe(n + 1);
    await t.hub.pals.stopAndWait();
  });
});

describe("the assistant and its Pals", () => {
  test("the assistant's own session is named, so Pals see its SendMessages as from it and answer it there", async () => {
    const t = setup();
    t.hub.userMessage("你好", "app");
    await t.hub.idle();
    expect(t.driver.sessions[0]!.opts.name).toBe(PALO_NAME);
  });
});

describe("pieces", () => {
  test("history mapping: a Pal's transcript's model and last words; startup errors in plain words", () => {
    const entries = [assistantEntry("第一句\n第二句", { model: "claude-sonnet-4-6" }), { type: "assistant", message: { model: "<synthetic>", content: [{ type: "text", text: "No response requested." }] } }];
    expect(transcriptModel(entries)).toBe("claude-sonnet-4-6");
    // the model Claude Code chose, with its context size, when it's the one that replied
    const chosen = (modelId: string) => ({ type: "attachment", attachment: { type: "model", identity: { modelId } } });
    expect(transcriptModel([chosen("claude-sonnet-4-6[1m]"), ...entries])).toBe("claude-sonnet-4-6[1m]");
    expect(transcriptModel([chosen("claude-opus-5-5[1m]"), ...entries])).toBe("claude-sonnet-4-6"); // switched since
    expect(transcriptModel([chosen("claude-opus-5-5[1m]")])).toBe("claude-opus-5-5[1m]");
    expect(transcriptLastLine(entries)).toBe("第一句");
    expect(transcriptModel([])).toBeNull();
    expect(startError("Error: That session is running in the background (fb1c). Run `claude stop fb1c` first")).toBe("它还在后台跑着，先停掉它");
    expect(startError("Error: No conversation found with session ID: x")).toBe("找不到它的对话记录");
    expect(startError("Claude Code process exited with code 1\n    at foo")).toBe("Claude Code process exited with code 1");
    const all = toPalMessages(
      [{ type: "user", uuid: "1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: [{ type: "text", text: "看图" }, { type: "image" }] }, origin: { kind: "human" } } as any],
      { pal: "pal_x", assistantName: "Palo", paloName: "Palo" },
    );
    expect(all.map((m) => m.text)).toEqual(["看图"]);
    expect(pagePalMessages(all, "missing", 10)).toEqual(all);
  });

  test("a spawner tells Claude Code's pid: directly, or as the helper reports it on descriptor 3; its input and output pass straight through", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "paloally-helper-")));
    // A stand-in helper: reports the command's pid on fd 3, then runs it.
    const fake = join(dir, "PaloAllyHelper");
    writeFileSync(fake, `#!/bin/sh\n[ "$1" = "--version" ] && { echo 1; exit 0; }\nshift\nexec 4<&0\n"$@" <&4 4<&- 3>&- &\nchild=$!\necho "{\\"pid\\":$child}" >&3\nexec 3>&- 4<&-\nwait $child\n`);
    chmodSync(fake, 0o755);
    expect(findHelper([join(dir, "missing.app"), fake])).toBe(fake);
    for (const helper of [null, fake]) {
      const pids: number[] = [];
      let gone = false;
      const p = makeSpawner(helper, { onPid: (pid) => pids.push(pid), onExit: () => (gone = true) })({ command: "/bin/cat", args: [], env: { PATH: "/usr/bin:/bin" } });
      let out = "";
      p.stdout.on("data", (d) => (out += d));
      p.stdin.write("你好\n");
      await waitFor(() => out === "你好\n" && pids.length === 1, 3_000);
      expect(pids[0]).toBeGreaterThan(0);
      p.stdin.end();
      await waitFor(() => gone, 3_000);
    }
  });
});
