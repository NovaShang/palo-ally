import { afterAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { transcriptPath } from "../src/handoffs.ts";
import { findHelper, makeSpawner } from "../src/palLauncher.ts";
import { pagePalMessages, toPalMessages, transcriptLastLine, transcriptModel } from "../src/palHistory.ts";
import { MAX_PALS, PALO_NAME, type PalsDeps, type PalsTiming } from "../src/pals.ts";
import { type PalRecord, startError } from "../src/palSession.ts";
import type { Paths } from "../src/config.ts";
import { BEHAVIORS } from "../src/home.ts";
import { handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, testConfig, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const MAX_AWAKE = 5; // these tests set settings.maxAwake to it
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

function setup(o: { maxAwake?: number; foldDays?: number; spawn?: boolean; timing?: Partial<PalsTiming>; palScript?: FakeScript; settings?: string; pals?: Partial<PalsDeps>; seed?: (paths: Paths, claudeDir: string) => void } = {}) {
  const claude = new FakeClaudeDir();
  dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const raw = new Map<string, any[]>();
  const readMessages = async (sid: string) => raw.get(sid) ?? [];
  if (o.settings) writeFileSync(join(claude.dir, "settings.json"), o.settings);
  const paths = tmpPaths();
  o.seed?.(paths, claude.dir);
  const config = testConfig((c) => {
    if (o.maxAwake !== undefined) c.settings.maxAwake = o.maxAwake;
    if (o.foldDays !== undefined) c.settings.foldDays = o.foldDays;
  });
  const ctx = makeHub({
    paths,
    config,
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false), readMessages },
    pals: { readMessages, timing: { ...FAST, ...o.timing }, ...o.pals },
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

  test("a session it doesn't know, and room for fifty: past that adopting and proposing are refused, naming the one least recently used", async () => {
    // fifty already, all asleep (as pals.json keeps them)
    const t = setup({
      seed: (paths, claudeDir) => {
        const now = Date.now();
        const pals: PalRecord[] = Array.from({ length: MAX_PALS }, (_, i) => ({
          id: `pal_seed${i + 1}`,
          sessionId: `cccc${String(i + 1).padStart(4, "0")}-0000-4000-8000-000000000000`,
          name: `项目${i + 1}`,
          cwd: claudeDir,
          createdBy: "owner",
          createdAt: now - 100_000,
          lastUsedAt: now - 100_000 + i,
          permissionMode: "default",
          status: "asleep",
        }));
        writeFileSync(paths.pals, JSON.stringify({ pals }));
      },
    });
    // all listed, asleep; none of them started
    const list = await t.call("pals.list");
    expect(list.pals).toHaveLength(MAX_PALS);
    expect(list.pals.every((p: any) => p.status === "asleep")).toBe(true);
    expect(t.driver.pals).toHaveLength(0);
    // the one least recently used is named
    await t.call("pals.send", { id: "pal_seed1", text: "接着做" });
    await t.hub.idle();
    const more = bgSession(t, "第五十一个", "dddd0051-0000-4000-8000-000000000051");
    await expect(t.call("pals.adopt", { sessionId: more })).rejects.toThrow(`已经有 ${MAX_PALS} 个会话了，先结束一个（最久没用的是「项目2」）`);
    expect(await t.hub.toolHandlers().pal_propose({ name: "新的", dir: t.project, duty: "做事", dailyUsd: 1 })).toContain(`已经有 ${MAX_PALS} 个会话了`);
    await t.call("pals.remove", { id: "pal_seed2" });
    await expect(t.call("pals.adopt", { sessionId: "nope" })).rejects.toThrow("没有这个会话");
    expect((await t.call("pals.adopt", { sessionId: more })).pal).toMatchObject({ name: "第五十一个", status: "idle" });
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

  test("images and files, as Palo takes them: an image goes in as an image block, a file is put in its folder's .paloally/inbox (git ignores it) and named in the words; the page shows the message as sent, also read back from the transcript", async () => {
    const t = setup();
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==";
    const img = await t.call("media.upload", { mediaType: "image/png", data: png });
    const doc = await t.call("media.uploadChunk", { name: "说明.txt", mediaType: "text/plain", offset: 0, data: Buffer.from("第一行").toString("base64"), done: true });
    const sent = await t.call("pals.send", { id: pal.id, text: "看看这两个", clientMsgId: "c-att", attachments: [img.id, doc.id] });
    await waitFor(() => t.palEvents("chat.message").some((m) => m.role === "assistant"));
    const proc = t.driver.pals[0]!;
    const inbox = join(t.project, ".paloally", "inbox", doc.id, "说明.txt");
    expect(proc.sent).toEqual([`看看这两个\n[文件] ${inbox}`]);
    expect(proc.sentImages).toEqual([{ mediaType: "image/png", data: png }]);
    expect(readFileSync(inbox, "utf8")).toBe("第一行");
    expect(readFileSync(join(t.project, ".paloally", ".gitignore"), "utf8")).toContain("*");
    const mine = t.palEvents("chat.message").find((m) => m.id === sent.id)!;
    expect(mine).toMatchObject({ role: "user", text: "看看这两个", clientMsgId: "c-att", attachments: [{ id: img.id, kind: "image" }, { id: doc.id, kind: "file", name: "说明.txt" }] });
    // an image alone (no words); nothing at all is refused, as is an id that wasn't uploaded
    const only = await t.call("pals.send", { id: pal.id, text: "", attachments: [img.id] });
    await waitFor(() => proc.sent.length === 2);
    expect(proc.sent[1]).toBe("");
    expect(proc.sentImages).toHaveLength(2);
    await expect(t.call("pals.send", { id: pal.id, text: "  " })).rejects.toThrow("不能是空的");
    await expect(t.call("pals.send", { id: pal.id, text: "这个", attachments: ["img_nope"] })).rejects.toThrow("附件没传上来");
    // read back from the transcript: as sent
    t.raw.set(sid, [
      { type: "user", uuid: sent.id, timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: png } }, { type: "text", text: `看看这两个\n[文件] ${inbox}` }] }, origin: { kind: "human" } },
      { type: "user", uuid: only.id, timestamp: "2026-10-12T10:01:00Z", message: { role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: png } }] }, origin: { kind: "human" } },
      { type: "user", uuid: "u-term", timestamp: "2026-10-12T10:02:00Z", message: { role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: png } }] }, origin: { kind: "human" } },
    ] as any);
    const { messages } = await t.call("pals.history", { id: pal.id });
    expect(messages.map((m: any) => [m.id, m.text, (m.attachments ?? []).map((a: any) => a.id)])).toEqual([
      [sent.id, "看看这两个", [img.id, doc.id]],
      [only.id, "", [img.id]],
      // pasted in a terminal: no record of it here
      ["u-term", "（图片）", []],
    ]);
    expect(t.hub.audit.tail(10).filter((e) => e.type === "pal.send").at(-1)).toMatchObject({ attachments: 1 });
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

  test("the list follows it promptly (pals.updated within 300 ms): busy, a card waiting, the card answered, the turn's end, 停止 — also when Claude Code is slow to end a stopped turn", async () => {
    let slowStop = 0;
    let finish!: () => void;
    const t = setup({
      palScript: async (text, ctx) => {
        if (text === "要确认") {
          await ctx.useTool("Bash", { command: "npm run build" }, { ask: true });
          await new Promise<void>((r) => (finish = r));
          ctx.emit({ type: "assistant_text", text: "构建好了", parentToolUseId: null, messageId: "msg_build" });
          return;
        }
        ctx.emit({ type: "tool_use", id: `t-${text}`, name: "Bash", input: { command: "sleep 100" }, parentToolUseId: null });
        await ctx.interrupted;
        // Claude Code ends a stopped turn at once, or a while later (a tool slow to stop)
        if (slowStop) {
          await tick(slowStop);
          ctx.emit({ type: "text_delta", text: "停", messageId: "msg_late" });
          ctx.emit({ type: "tool_use", id: "t-late", name: "Read", input: { file_path: "/x" }, parentToolUseId: null });
        }
      },
    });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    const lists: { at: number; status: string; pending: number }[] = [];
    t.hub.bus.on((event, data: any) => {
      if (event === "pals.updated") lists.push({ at: Date.now(), status: data.pals[0]?.status, pending: data.pals[0]?.pending });
    });
    // how long after `since` the list first said `want`
    const said = async (want: string, since: number) => {
      await waitFor(() => lists.some((l) => l.at >= since && l.status === want), 3_000);
      return lists.find((l) => l.at >= since && l.status === want)!.at - since;
    };

    // a card: waiting, then answered (busy again), then the turn's end
    let t0 = Date.now();
    await t.call("pals.send", { id: pal.id, text: "要确认" });
    expect(await said("waiting", t0)).toBeLessThan(300);
    t0 = Date.now();
    await t.call("approval.answer", { id: t.hub.approvals.listPending()[0]!.id, allow: true });
    expect(await said("busy", t0)).toBeLessThan(300);
    t0 = Date.now();
    finish();
    expect(await said("idle", t0)).toBeLessThan(300);

    // 停止, Claude Code ending the turn at once
    await t.call("pals.send", { id: pal.id, text: "长活" });
    await waitFor(() => t.hub.pals.list()[0]!.status === "busy");
    t0 = Date.now();
    await t.call("pals.stop", { id: pal.id });
    expect(await said("idle", t0)).toBeLessThan(300);

    // 停止, Claude Code taking 1.5 s: the list says it stopped anyway, and
    // what's left of that turn doesn't make it busy again
    slowStop = 1_500;
    await t.call("pals.send", { id: pal.id, text: "又一个长活" });
    await waitFor(() => t.hub.pals.list()[0]!.status === "busy");
    t0 = Date.now();
    await t.call("pals.stop", { id: pal.id });
    expect(Date.now() - t0).toBeLessThan(300);
    expect(await said("idle", t0)).toBeLessThan(300);
    await waitFor(() => t.palEvents("chat.delta").some((d) => d.id === "msg_late"), 3_000);
    await tick(100);
    expect(lists.filter((l) => l.at >= t0 + 300).every((l) => l.status === "idle")).toBe(true);
    expect(t.hub.pals.list()[0]!.status).toBe("idle");
    // no error notice for the stopped turn, and the next turn works as usual
    expect(t.palEvents("chat.message").some((m) => m.kind === "notice")).toBe(false);
    slowStop = 0;
    await t.call("pals.send", { id: pal.id, text: "再来" });
    expect(await said("busy", Date.now() - 50)).toBeLessThan(400);
    await t.call("pals.stop", { id: pal.id });
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle");
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
    await expect(t.call("pals.history", { id: "pal_nope" })).rejects.toThrow("找不到这个会话");
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

describe("asleep and awake (§12)", () => {
  // Puts one to sleep now, as the host does when it's been idle long enough.
  const sleepNow = (t: ReturnType<typeof setup>, id: string) => (t.hub.pals as any).putToSleep(t.hub.pals.get(id)!, "test") as Promise<void>;
  const statusOf = (t: ReturnType<typeof setup>, id: string) => t.hub.pals.list().find((p) => p.id === id)!.status;
  const savedRec = (t: ReturnType<typeof setup>, id: string) => (JSON.parse(readFileSync(t.paths.pals, "utf8")).pals as PalRecord[]).find((r) => r.id === id)!;

  test("idle for the set time, a Pal goes to sleep: its process ends cleanly, its record stays (asleep), the list says so at once, and the watchdog no longer watches it", async () => {
    const t = setup({ spawn: true, timing: { sleepIdleMs: 300, sleepCheckMs: 30 } });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    await t.call("pals.send", { id: pal.id, text: "看一下" });
    await waitFor(() => t.palEvents("chat.message").some((m) => m.role === "assistant"));
    const proc = t.driver.pals[0]!.proc!;
    expect(t.hub.pals.stallTargets()).toHaveLength(1);
    await tick(100);
    expect(statusOf(t, pal.id)).toBe("idle");
    const t0 = Date.now();
    await waitFor(() => statusOf(t, pal.id) === "asleep", 3_000);
    expect(Date.now() - t0).toBeGreaterThan(100);
    await exited(proc);
    expect(t.driver.pals[0]!.closed).toBe(true);
    await waitFor(() => t.lastList()?.pals[0]?.status === "asleep", 1_000);
    expect(savedRec(t, pal.id)).toMatchObject({ status: "asleep", sessionId: pal.sessionId });
    expect(savedRec(t, pal.id).pid).toBeUndefined();
    expect(t.hub.pals.stallTargets()).toEqual([]);
    expect(t.hub.pals.quiet()).toBe(true);
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.slept")).toMatchObject({ pal: pal.id, why: "idle" });
    // its history still reads as usual
    expect((await t.call("pals.history", { id: pal.id })).messages).toEqual([]);
    await t.hub.pals.stopAndWait();
  });

  test("never one that's busy or waiting on the owner: it stays up however long, and sleeps once it's done", async () => {
    const t = setup({
      timing: { sleepIdleMs: 100, sleepCheckMs: 20 },
      palScript: async (text, ctx) => {
        if (text === "要确认") {
          await ctx.useTool("Bash", { command: "npm run build" }, { ask: true });
          return;
        }
        if (text === "后台") {
          ctx.emit({ type: "task_started", taskId: "bg1", toolUseId: "ag1", description: "跑全部测试", background: true });
          ctx.emit({ type: "background_tasks", taskIds: ["bg1"] });
          return;
        }
        ctx.emit({ type: "tool_use", id: `t-${text}`, name: "Bash", input: { command: "sleep 100" }, parentToolUseId: null });
        await ctx.interrupted;
      },
    });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    // busy
    await t.call("pals.send", { id: pal.id, text: "长活" });
    await waitFor(() => statusOf(t, pal.id) === "busy");
    await tick(400);
    expect(statusOf(t, pal.id)).toBe("busy");
    await t.call("pals.stop", { id: pal.id });
    await waitFor(() => statusOf(t, pal.id) === "asleep", 2_000);
    // waiting on a card (it's woken for it first)
    await t.call("pals.send", { id: pal.id, text: "要确认" });
    await waitFor(() => statusOf(t, pal.id) === "waiting");
    await tick(400);
    expect(statusOf(t, pal.id)).toBe("waiting");
    await t.call("approval.answer", { id: t.hub.approvals.listPending()[0]!.id, allow: true });
    await waitFor(() => statusOf(t, pal.id) === "asleep", 2_000);
    // a background task still running after the turn
    await t.call("pals.send", { id: pal.id, text: "后台" });
    await waitFor(() => statusOf(t, pal.id) === "idle");
    await tick(400);
    expect(statusOf(t, pal.id)).toBe("idle");
    (t.hub.pals.get(pal.id) as any).onEvent({ type: "task_notification", taskId: "bg1", status: "completed", summary: "好了" });
    await waitFor(() => statusOf(t, pal.id) === "asleep", 2_000);
    expect(t.driver.pals).toHaveLength(3);
    await t.hub.pals.stopAndWait();
  });

  test(`past ${MAX_AWAKE} awake the least recently used idle one goes to sleep; busy ones never, so six busy stay six until one is done`, async () => {
    const t = setup({
      maxAwake: MAX_AWAKE,
      timing: { sleepCheckMs: 30 },
      palScript: async (text, ctx) => {
        if (text !== "长活") return echo(text, ctx);
        ctx.emit({ type: "tool_use", id: `t-${Math.random()}`, name: "Bash", input: { command: "sleep 100" }, parentToolUseId: null });
        await ctx.interrupted;
      },
    });
    const ids: string[] = [];
    for (let i = 1; i <= MAX_AWAKE; i++) {
      ids.push((await t.call("pals.adopt", { sessionId: bgSession(t, `项目${i}`, `cccc000${i}-0000-4000-8000-00000000000${i}`) })).pal.id);
      await tick(3);
    }
    await t.call("pals.send", { id: ids[0], text: "接着做" });
    await t.hub.idle();
    await tick(100);
    expect(t.hub.pals.list().filter((p) => p.status === "asleep")).toEqual([]);
    // a sixth: 项目2 is the one used least lately
    const sixth = (await t.call("pals.adopt", { sessionId: bgSession(t, "第六个", "dddd0006-0000-4000-8000-000000000006") })).pal.id;
    await waitFor(() => t.hub.pals.list().some((p) => p.status === "asleep"), 2_000);
    expect(t.hub.pals.list().filter((p) => p.status === "asleep").map((p) => p.name)).toEqual(["项目2"]);
    expect(t.hub.audit.tail(30).find((e) => e.type === "pal.slept")).toMatchObject({ name: "项目2", why: "more awake than allowed" });
    // all five awake busy, then the asleep one woken for work: six busy, none put to sleep
    for (const id of [ids[0]!, ...ids.slice(2), sixth]) await t.call("pals.send", { id, text: "长活" });
    await t.call("pals.send", { id: ids[1], text: "长活" });
    await waitFor(() => t.hub.pals.list().filter((p) => p.status === "busy").length === 6, 2_000);
    await tick(200);
    expect(t.hub.pals.list().filter((p) => p.status === "busy")).toHaveLength(6);
    // one is done: it's the one idle, so it sleeps; back to five awake
    await t.call("pals.stop", { id: ids[3] });
    await waitFor(() => statusOf(t, ids[3]!) === "asleep", 2_000);
    expect(t.hub.pals.list().filter((p) => p.status === "busy")).toHaveLength(5);
    await t.hub.pals.stopAndWait();
  });

  test("words to an asleep Pal wake it: the same session resumes, what comes meanwhile waits and goes in after, in order; the first turn's cost is what waking cost", async () => {
    let slow = 0;
    const t = setup({
      pals: {
        launch: async () => {
          if (slow) await tick(slow);
          return { helper: null, env: { PATH: process.env.PATH ?? "/usr/bin:/bin" } };
        },
      },
    });
    t.driver.turnCost = 0.0123;
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    await t.call("pals.send", { id: pal.id, text: "第一句" });
    await waitFor(() => statusOf(t, pal.id) === "idle" && t.palEvents("chat.message").some((m) => m.role === "assistant"));
    expect(savedRec(t, pal.id).costTotalUsd).toBeCloseTo(0.0123);
    await sleepNow(t, pal.id);
    expect(statusOf(t, pal.id)).toBe("asleep");
    const lists: string[] = [];
    t.hub.bus.on((event, data: any) => {
      if (event === "pals.updated") lists.push(data.pals[0].status);
    });
    // three at once while it takes a while to come up
    slow = 300;
    const sends = ["一", "二", "三"].map((text, i) => t.call("pals.send", { id: pal.id, text, clientMsgId: `w-${i}` }));
    await tick(50);
    expect(statusOf(t, pal.id)).toBe("starting");
    const sent = await Promise.all(sends);
    expect(t.driver.pals).toHaveLength(2);
    const woken = t.driver.pals[1]!;
    expect(woken.opts.resumeSessionId).toBe(sid);
    expect(woken.opts.priorCostUsd).toBeCloseTo(0.0123);
    expect(woken.sent).toEqual(["一", "二", "三"]);
    expect(sent.map((s) => s.seq)).toEqual([...sent.map((s) => s.seq)].sort((a, b) => a - b));
    const mine = t.palEvents("chat.message").filter((m) => m.role === "user").map((m) => m.text);
    expect(mine).toEqual(["第一句", "一", "二", "三"]);
    await waitFor(() => statusOf(t, pal.id) === "idle");
    expect(lists).toContain("starting");
    // waking cost: the first turn after it (the fake's cost for a turn)
    const after = t.hub.pals.list()[0]!;
    expect(after.lastWakeUsd).toBeCloseTo(0.0123);
    expect(savedRec(t, pal.id).status).toBeUndefined();
    await waitFor(() => t.lastList()?.pals[0]?.lastWakeUsd !== undefined, 1_000);
    expect(t.hub.audit.tail(30).filter((e) => e.type === "pal.woke").map((e) => e.why)).toEqual(["owner"]);
    // pals.wake: one awake is left as it is
    expect((await t.call("pals.wake", { id: pal.id })).pal).toMatchObject({ id: pal.id, status: "idle" });
    expect(t.driver.pals).toHaveLength(2);
    // asleep: it resumes, and comes back saying so
    slow = 0;
    await sleepNow(t, pal.id);
    expect((await t.call("pals.wake", { id: pal.id })).pal).toMatchObject({ id: pal.id, status: "idle", lastWakeUsd: 0.0123 });
    expect(t.driver.pals).toHaveLength(3);
    await expect(t.call("pals.wake", { id: "pal_nope" })).rejects.toThrow("找不到这个会话");
    await t.hub.pals.stopAndWait();
  });

  test("answering a card of a Pal that went to sleep wakes it", async () => {
    const t = setup({
      palScript: async (_text, ctx) => {
        await ctx.useTool("Bash", { command: "npm run build" }, { ask: true });
      },
    });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    await t.call("pals.send", { id: pal.id, text: "构建" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    const card = t.hub.approvals.listPending()[0]!;
    // the card went unanswered (here: stopped), and it went to sleep
    await t.call("pals.stop", { id: pal.id });
    await waitFor(() => statusOf(t, pal.id) === "idle");
    await sleepNow(t, pal.id);
    expect(await t.call("approval.answer", { id: card.id, allow: true })).toEqual({ status: "denied" });
    await waitFor(() => statusOf(t, pal.id) === "idle" && t.driver.pals.length === 2);
    expect(t.hub.audit.tail(30).find((e) => e.type === "pal.woke")).toMatchObject({ pal: pal.id, why: "card" });
    await t.hub.pals.stopAndWait();
  });

  test("the assistant's pal_send reaches an asleep Pal: it's woken, the words go in as the assistant's (a SendMessage from its session to the Pal), and read back so", async () => {
    const t = setup();
    const sid = bgSession(t);
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    await sleepNow(t, pal.id);
    const tools = t.hub.toolHandlers();
    expect(await tools.pal_send({ name: "网站", text: "把登录页的测试补上，做完告诉我" })).toBe("已经送到「网站」（它刚才睡着，已经叫醒）。它回你的话会作为消息回到你这里。");
    const woken = t.driver.pals[1]!;
    expect(woken.opts.resumeSessionId).toBe(sid);
    // from is the assistant's name, not a socket: a Pal that replies by copying it still reaches the assistant after a restart
    const wrapped = `<cross-session-message from="${PALO_NAME}" from-name="${PALO_NAME}">\n把登录页的测试补上，做完告诉我\n</cross-session-message>`;
    expect(woken.sent).toEqual([wrapped]);
    expect(t.palEvents("chat.message").find((m) => m.role === "user")).toMatchObject({ text: "把登录页的测试补上，做完告诉我", from: "Palo", channel: "system", pal: pal.id });
    // read back from its transcript: the assistant's words, not the owner's
    t.raw.set(sid, [{ type: "user", uuid: "s1", timestamp: "2026-10-15T10:00:00Z", message: { role: "user", content: wrapped }, origin: { kind: "human" } }]);
    expect((await t.call("pals.history", { id: pal.id })).messages).toEqual([expect.objectContaining({ id: "s1", text: "把登录页的测试补上，做完告诉我", from: "Palo" })]);
    // transcripts from before still read back as the assistant's
    t.raw.set(sid, [{ type: "user", uuid: "s0", timestamp: "2026-10-15T09:00:00Z", message: { role: "user", content: wrapped.replace(`from="${PALO_NAME}"`, `from="paloally"`) }, origin: { kind: "human" } }]);
    expect((await t.call("pals.history", { id: pal.id })).messages).toEqual([expect.objectContaining({ id: "s0", from: "Palo" })]);
    // awake: straight in; by any case of its name
    expect(await tools.pal_send({ name: "网站", text: "还有首页" })).toBe("已经送到「网站」。它回你的话会作为消息回到你这里。");
    expect(t.driver.pals).toHaveLength(2);
    expect(await tools.pal_send({ name: "没有的", text: "在吗" })).toContain("没有叫「没有的」的会话");
    expect(await tools.pal_send({ name: "网站", text: " " })).toContain("空的");
    expect(BEHAVIORS.zh).toContain("mcp__paloally__pal_send");
    expect(BEHAVIORS.zh).toMatch(/醒着睡着都有效/);
    expect(BEHAVIORS.en).toContain("mcp__paloally__pal_send");
    expect(BEHAVIORS.en).toMatch(/whether the Pal is awake or asleep/);
    await t.hub.pals.stopAndWait();
  });

  test("after the host restarts only the Pals that were awake come back; those asleep stay asleep (pals.json says which), at most five awake", async () => {
    const t = setup({ spawn: true, maxAwake: MAX_AWAKE });
    const a = (await t.call("pals.adopt", { sessionId: bgSession(t, "甲", "aaaa0001-0000-4000-8000-000000000001") })).pal;
    const b = (await t.call("pals.adopt", { sessionId: bgSession(t, "乙", "aaaa0002-0000-4000-8000-000000000002") })).pal;
    await sleepNow(t, a.id);
    await t.hub.pals.stopAndWait();
    expect(savedRec(t, a.id).status).toBe("asleep");
    expect(savedRec(t, b.id).status).toBeUndefined();
    const { Pals } = await import("../src/pals.ts");
    const again = new Pals({ ...(t.hub.pals as any).d, timing: FAST });
    again.start();
    expect(again.list().find((p) => p.id === a.id)!.status).toBe("asleep");
    expect(again.list().find((p) => p.id === b.id)!.status).toBe("starting");
    await waitFor(() => again.list().find((p) => p.id === b.id)!.status === "idle", 5_000);
    expect(t.driver.pals.map((p) => p.opts.name)).toEqual(["甲", "乙", "乙"]);
    await again.stopAndWait();
    // seven were awake: the five used most lately come back
    const recs: PalRecord[] = JSON.parse(readFileSync(t.paths.pals, "utf8")).pals;
    const now = Date.now();
    for (let i = 1; i <= 7; i++)
      recs.push({ id: `pal_w${i}`, sessionId: `bbbb000${i}-0000-4000-8000-000000000000`, name: `醒${i}`, cwd: t.project, createdBy: "owner", createdAt: now, lastUsedAt: now + i, permissionMode: "default" });
    writeFileSync(t.paths.pals, JSON.stringify({ pals: recs }));
    const third = new Pals({ ...(t.hub.pals as any).d, timing: FAST });
    third.start();
    const back = third.list().filter((p) => p.status === "starting").map((p) => p.name);
    expect(back.sort()).toEqual(["醒3", "醒4", "醒5", "醒6", "醒7"]);
    expect(third.list().filter((p) => p.status === "asleep").map((p) => p.name).sort()).toEqual(["乙", "甲", "醒1", "醒2"]);
    await third.stopAndWait();
  });
});

describe("its name follows Claude Code's title (§13)", () => {
  // Claude Code's title for each session, as getSessionInfo reads it.
  function titled(o: { spawn?: boolean } = {}) {
    const titles = new Map<string, { customTitle?: string; summary?: string; firstPrompt?: string }>();
    const renamed: { sid: string; title: string; dir: string }[] = [];
    const t = setup({
      spawn: o.spawn,
      pals: {
        recentSource: {
          list: async () => [],
          info: async (sid) => {
            const x = titles.get(sid);
            return x ? ({ sessionId: sid, lastModified: Date.now(), summary: x.summary ?? x.customTitle ?? "", ...x } as any) : undefined;
          },
        },
        renameSession: async (sid, title, dir) => {
          renamed.push({ sid, title, dir });
          titles.set(sid, { ...titles.get(sid), customTitle: title });
        },
      },
    });
    return { ...t, titles, renamed };
  }

  test("after a turn its name is Claude Code's title again (a /rename in it): the list says so, a name another Pal has gets a number, and it stays put", async () => {
    const t = titled();
    const a = bgSession(t, "网站", "aaaa0001-0000-4000-8000-000000000001");
    const b = bgSession(t, "笔记", "aaaa0002-0000-4000-8000-000000000002");
    t.titles.set(a, { customTitle: "网站" });
    t.titles.set(b, { customTitle: "笔记" });
    const pa = (await t.call("pals.adopt", { sessionId: a })).pal;
    const pb = (await t.call("pals.adopt", { sessionId: b })).pal;
    expect([pa.name, pb.name]).toEqual(["网站", "笔记"]);
    // /rename in it: Claude Code's custom title changes; after the turn, so does the name
    t.titles.set(a, { customTitle: "网站改版" });
    await t.call("pals.send", { id: pa.id, text: "/rename 网站改版" });
    await waitFor(() => t.hub.pals.get(pa.id)!.rec.name === "网站改版");
    await waitFor(() => t.lastList()?.pals.some((p: any) => p.id === pa.id && p.name === "网站改版"), 1_000);
    expect(t.hub.audit.tail(30).find((e) => e.type === "pal.renamed")).toMatchObject({ pal: pa.id, from: "网站", to: "网站改版", by: "claude" });
    // the other one is given the same title: it gets a number, and keeps it turn after turn
    t.titles.set(b, { customTitle: "网站改版" });
    for (const text of ["一", "二", "三"]) {
      await t.call("pals.send", { id: pb.id, text });
      await t.hub.idle();
      await tick(20);
    }
    expect(t.hub.pals.get(pb.id)!.rec.name).toBe("网站改版 2");
    expect(t.hub.audit.tail(50).filter((e) => e.type === "pal.renamed" && e.pal === pb.id)).toHaveLength(1);
    // no title read back (only the head and tail are read): the name stays
    t.titles.set(a, { summary: "Fix the login redirect", firstPrompt: "修登录" });
    await t.call("pals.send", { id: pa.id, text: "再来" });
    await t.hub.idle();
    await tick(50);
    expect(t.hub.pals.get(pa.id)!.rec.name).toBe("网站改版");
    await t.hub.pals.stopAndWait();
  });

  test("its process renamed itself (the registry says so, the title wasn't read): that's its name too", async () => {
    const t = titled({ spawn: true });
    const sid = bgSession(t, "网站", "aaaa0003-0000-4000-8000-000000000003");
    t.titles.set(sid, { customTitle: "网站" });
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const pid = t.hub.pals.get(pal.id)!.pid!;
    t.titles.set(sid, {});
    t.claude.register({ sessionId: sid, name: "官网", cwd: t.project, pid, entrypoint: "sdk-ts", nameSource: "user" });
    await t.call("pals.send", { id: pal.id, text: "好" });
    await waitFor(() => t.hub.pals.get(pal.id)!.rec.name === "官网");
    await t.hub.pals.stopAndWait();
  });

  test("pals.rename: Claude Code is asked to rename it (in its process when it runs, in its transcript when asleep); the list follows; the assistant's pal_send reaches it by its new name, its old one and its id, without a restart; the next start uses the new name", async () => {
    const t = titled();
    const sid = bgSession(t, "网站", "aaaa0004-0000-4000-8000-000000000004");
    t.titles.set(sid, { customTitle: "网站" });
    const other = bgSession(t, "笔记", "aaaa0005-0000-4000-8000-000000000005");
    t.titles.set(other, { customTitle: "笔记" });
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    await t.call("pals.adopt", { sessionId: other });
    const procs = t.driver.pals.length;
    // running: Claude Code's own rename in its process
    const r = await t.call("pals.rename", { id: pal.id, name: "  官网  " });
    expect(r.pal).toMatchObject({ id: pal.id, name: "官网", status: "idle" });
    expect(t.driver.renames).toEqual([{ title: "官网", sessionId: sid }]);
    expect(t.renamed).toEqual([]);
    expect(t.lastList().pals.find((p: any) => p.id === pal.id).name).toBe("官网");
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.renamed")).toMatchObject({ from: "网站", to: "官网", by: "app" });
    t.titles.set(sid, { customTitle: "官网" }); // what Claude Code now has
    // the assistant reaches it by the new name, the old one and the id; no restart
    const tools = t.hub.toolHandlers();
    for (const name of ["官网", "网站", pal.id]) expect(await tools.pal_send({ name, text: `找你：${name}` })).toBe("已经送到「官网」。它回你的话会作为消息回到你这里。");
    expect(t.driver.pals).toHaveLength(procs);
    expect(t.driver.pals[0]!.sent.filter((s) => s.includes("找你："))).toHaveLength(3);
    expect(t.driver.pals[0]!.opts.name).toBe("网站"); // its process keeps the name it started under
    expect(JSON.parse(await tools.pals_list()).pals.find((p: any) => p.id === pal.id)).toMatchObject({ id: pal.id, name: "官网" });
    // a name another Pal has gets a number; empty, too long or the assistant's own isn't taken
    expect((await t.call("pals.rename", { id: pal.id, name: "笔记" })).pal.name).toBe("笔记 2");
    await expect(t.call("pals.rename", { id: pal.id, name: " " })).rejects.toThrow("名字不能是空的");
    await expect(t.call("pals.rename", { id: pal.id, name: "Palo" })).rejects.toThrow("助理自己的名字");
    await expect(t.call("pals.rename", { id: pal.id, name: "长".repeat(41) })).rejects.toThrow("太长");
    // asleep: into its transcript (no process to ask), and it wakes under the new name
    t.titles.set(sid, { customTitle: "笔记 2" });
    await (t.hub.pals as any).putToSleep(t.hub.pals.get(pal.id), "test");
    expect((await t.call("pals.rename", { id: pal.id, name: "官网" })).pal).toMatchObject({ name: "官网", status: "asleep" });
    expect(t.renamed).toEqual([{ sid, title: "官网", dir: t.project }]);
    await t.call("pals.wake", { id: pal.id });
    expect(t.driver.pals.at(-1)!.opts.name).toBe("官网");
    expect(t.hub.pals.get(pal.id)!.rec.name).toBe("官网");
    await expect(t.call("pals.rename", { id: "pal_nope", name: "x" })).rejects.toThrow("找不到这个会话");
    await t.hub.pals.stopAndWait();
  });

  test("renamed in a terminal while it was asleep: it wakes under that name", async () => {
    const t = titled();
    const sid = bgSession(t, "网站", "aaaa0006-0000-4000-8000-000000000006");
    t.titles.set(sid, { customTitle: "网站" });
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    await (t.hub.pals as any).putToSleep(t.hub.pals.get(pal.id), "test");
    t.titles.set(sid, { customTitle: "博客" });
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    expect(t.driver.pals.at(-1)!.opts.name).toBe("博客");
    expect(t.hub.pals.get(pal.id)!.rec.name).toBe("博客");
    expect(await t.hub.toolHandlers().pal_send({ name: "网站", text: "旧名字也行" })).toContain("已经送到「博客」");
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
    await expect(t.call("pals.remove", { id: second.id })).rejects.toThrow("找不到这个会话");
    expect(JSON.parse(readFileSync(t.paths.pals, "utf8")).pals).toEqual([]);
  });
});

describe("the assistant opens a Pal", () => {
  test("its proposal card; 开吧 starts a new session in the folder with the handover as its first message, shown as the assistant's; asking twice gives the same Pal", async () => {
    const t = setup();
    const r = await t.hub.toolHandlers().pal_propose({ name: "网站", dir: t.project, duty: "你负责主人的网站：先做列表页。", dailyUsd: 5 });
    expect(r).toContain("主人点「开吧」才会开");
    const card = t.hub.chat.recent(1)[0]!;
    expect(card).toMatchObject({ kind: "helper", text: expect.stringContaining("开一个会话「网站」"), proposal: { name: "网站", cwd: t.project, dailyUsd: 5, status: "pending" } });
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
    expect(await tools.pal_propose({ name: "三", dir: t.project, duty: "做事", dailyUsd: 1 })).toContain("已经有一个叫「三」的会话");
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
    expect(t.pusher.pushes.at(-1)!.title).toBe("会话停了");
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

describe("the owner's own sessions (workbench)", () => {
  /** Claude Code's title for each session, as getSessionInfo reads it, and the renames made. */
  function titled(o: Parameters<typeof setup>[0] = {}) {
    const titles = new Map<string, { customTitle?: string; summary?: string; firstPrompt?: string }>();
    const renamed: { sid: string; title: string }[] = [];
    const t = setup({
      ...o,
      pals: {
        ...o.pals,
        recentSource: {
          list: async () => [],
          info: async (sid) => {
            const x = titles.get(sid);
            return x ? ({ sessionId: sid, lastModified: Date.now(), summary: x.summary ?? x.customTitle ?? "", ...x } as any) : undefined;
          },
        },
        renameSession: async (sid, title) => {
          renamed.push({ sid, title });
          titles.set(sid, { ...titles.get(sid), customTitle: title });
        },
      },
    });
    return { ...t, titles, renamed };
  }
  const find = (t: ReturnType<typeof setup>, id: string) => t.hub.pals.list().find((p) => p.id === id)!;
  const rec = (t: ReturnType<typeof setup>, id: string) => (t.hub.pals.get(id) as any).rec as PalRecord;

  test("pals.create: any folder, no duty and no daily limit; it is called session-<id> inside, starts at once, and its first words go in as the owner's", async () => {
    const t = setup();
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "写个计划" });
    expect(pal).toMatchObject({ cwd: t.project, createdBy: "owner", status: "starting", attention: "idle", folded: false, pending: 0 });
    expect(pal.id).toMatch(/^pal_/);
    expect(pal.name).toBe(`session-${pal.id.slice(4, 10)}`);
    await waitFor(() => find(t, pal.id).status === "idle" && find(t, pal.id).attention === "done");
    const r = rec(t, pal.id);
    expect(r.duty).toBeUndefined();
    expect(r.dailyUsd).toBeUndefined();
    expect(r.autoNamed).toBe(true);
    // a new session of its own, no resume; the words went in as the owner's (not the assistant's)
    const proc = t.driver.pals[0]!;
    expect(proc.opts.sessionId).toBe(pal.sessionId);
    expect(proc.opts.resumeSessionId).toBeUndefined();
    expect(proc.sent).toEqual(["写个计划"]);
    const said = t.palEvents("chat.message").find((m) => m.role === "user")!;
    expect(said).toMatchObject({ text: "写个计划", pal: pal.id });
    expect(said.from).toBeUndefined();
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.created")).toMatchObject({ pal: pal.id, owner: true });
    // no spending limit: heavy spending never stops it
    expect(t.hub.pals.list()[0]!.status).toBe("idle");
    // without text it just starts and waits for the first word
    const quiet = (await t.call("pals.create", { cwd: t.project })).pal;
    await waitFor(() => find(t, quiet.id).status === "idle");
    expect(t.driver.pals[1]!.sent).toEqual([]);
    expect(find(t, quiet.id).attention).toBe("idle");
    // a name of its own: used as given, a number on a clash, never the assistant's
    const named = (await t.call("pals.create", { cwd: t.project, name: "官网" })).pal;
    const twin = (await t.call("pals.create", { cwd: t.project, name: "官网" })).pal;
    expect([named.name, twin.name]).toEqual(["官网", "官网 2"]);
    expect(rec(t, named.id).autoNamed).toBeUndefined();
    await expect(t.call("pals.create", { cwd: t.project, name: "Palo" })).rejects.toThrow("助理自己的名字");
    await expect(t.call("pals.create", { cwd: t.project, name: "长".repeat(41) })).rejects.toThrow("太长");
    // its folder: anywhere that exists, but not PaloAlly's own; a workspace has to exist
    await expect(t.call("pals.create", { cwd: "/no/such/folder" })).rejects.toThrow("找不到目录");
    await expect(t.call("pals.create", { cwd: t.paths.root })).rejects.toThrow("不能开在 PaloAlly 自己的目录里");
    await expect(t.call("pals.create", { cwd: t.project, workspaceId: "ws_000000000000" })).rejects.toThrow("找不到这个工作区");
    await expect(t.call("pals.create", {})).rejects.toThrow("要给出一个文件夹");
    // the assistant's proposal path is as it was: a duty and a limit are still needed
    expect(await t.hub.toolHandlers().pal_propose({ name: "无任务", dir: t.project, duty: "", dailyUsd: 1 })).toContain("要写清楚它负责什么");
    expect(await t.hub.toolHandlers().pal_propose({ name: "无上限", dir: t.project, duty: "做事", dailyUsd: 0 })).toContain("大于 0");
    await t.hub.pals.stopAndWait();
  });

  test("a session that fails to start stays in the list stopped, with the reason", async () => {
    const t = setup();
    t.driver.failPalStart = () => "Error: not logged in";
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "开始" });
    await waitFor(() => find(t, pal.id).status === "stopped");
    expect(find(t, pal.id).note).toContain("Claude Code 没登录");
    expect(find(t, pal.id).attention).toBe("idle");
    await t.hub.pals.stopAndWait();
  });

  test("attention: working while busy, waiting (first) while a card waits, done when a real turn ends unseen, idle once seen; status itself is unchanged", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const t = setup({
      palScript: async (text, ctx) => {
        if (text === "要确认") {
          await ctx.useTool("Bash", { command: "npm test" }, { ask: true });
          return echo(text, ctx);
        }
        if (text === "等") {
          ctx.emit({ type: "tool_use", id: "t-gate", name: "Bash", input: { command: "sleep 1" }, parentToolUseId: null });
          await Promise.race([gate, ctx.interrupted]);
        }
        return echo(text, ctx);
      },
    });
    const { pal } = await t.call("pals.create", { cwd: t.project });
    await waitFor(() => find(t, pal.id).status === "idle");
    expect(find(t, pal.id)).toMatchObject({ status: "idle", attention: "idle" });
    expect(find(t, pal.id).finishedAt).toBeUndefined();
    // busy → working
    await t.call("pals.send", { id: pal.id, text: "等" });
    await waitFor(() => find(t, pal.id).status === "busy");
    expect(find(t, pal.id).attention).toBe("working");
    release();
    // the real end of the turn → done, with the time
    await waitFor(() => find(t, pal.id).attention === "done");
    const done = find(t, pal.id);
    expect(done.status).toBe("idle");
    expect(done.finishedAt).toBeGreaterThan(0);
    expect(done.seenAt).toBeLessThan(done.finishedAt!); // the owner's words were before the end
    await waitFor(() => t.lastList()?.pals[0]?.attention === "done");
    expect(t.lastList().pals[0]).toMatchObject({ attention: "done", finishedAt: done.finishedAt });
    // seen → idle, and again does nothing
    const events = t.events.filter((e) => e.event === "pals.updated").length;
    await tick(60);
    const seen = (await t.call("pals.seen", { id: pal.id })).pal;
    expect(seen).toMatchObject({ attention: "idle", finishedAt: done.finishedAt });
    expect(seen.seenAt).toBeGreaterThanOrEqual(done.finishedAt!);
    await waitFor(() => t.events.filter((e) => e.event === "pals.updated").length > events);
    const after = t.events.filter((e) => e.event === "pals.updated").length;
    expect((await t.call("pals.seen", { id: pal.id })).pal.seenAt).toBe(seen.seenAt);
    await tick(80);
    expect(t.events.filter((e) => e.event === "pals.updated").length).toBe(after);
    // a card waits: waiting takes priority over everything, status says waiting too
    await t.call("pals.send", { id: pal.id, text: "要确认" });
    await waitFor(() => find(t, pal.id).status === "waiting");
    expect(find(t, pal.id).attention).toBe("waiting");
    await t.call("approval.answer", { id: t.hub.approvals.listPending()[0]!.id, allow: true });
    await waitFor(() => find(t, pal.id).attention === "done");
    // stopped (停止) is not a normal end: nothing new to look at
    await t.call("pals.seen", { id: pal.id });
    const finished = find(t, pal.id).finishedAt;
    t.driver.palScript = async (text, ctx) => {
      ctx.emit({ type: "tool_use", id: "t-stop", name: "Bash", input: { command: "sleep 100" }, parentToolUseId: null });
      await ctx.interrupted;
    };
    await t.call("pals.send", { id: pal.id, text: "长活" });
    await waitFor(() => find(t, pal.id).attention === "working");
    await t.call("pals.stop", { id: pal.id });
    await waitFor(() => find(t, pal.id).status === "idle");
    expect(find(t, pal.id)).toMatchObject({ attention: "idle", finishedAt: finished });
    // the host's restart doesn't write finishedAt: it is read back as it was saved
    const saved = JSON.parse(readFileSync(t.paths.pals, "utf8")).pals.find((r: PalRecord) => r.id === pal.id);
    expect(saved).toMatchObject({ finishedAt: finished });
    await t.hub.pals.stopAndWait();
  });

  test("done stays done while it sleeps, and the owner's own words count as having looked", async () => {
    const t = setup();
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "做完它" });
    await waitFor(() => find(t, pal.id).attention === "done");
    await (t.hub.pals as any).putToSleep(t.hub.pals.get(pal.id)!, "test");
    expect(find(t, pal.id)).toMatchObject({ status: "asleep", attention: "done" });
    await tick(5);
    // speaking to it wakes it and clears done; its next end is done again
    await t.call("pals.send", { id: pal.id, text: "再来" });
    await waitFor(() => find(t, pal.id).attention === "done");
    expect(find(t, pal.id).seenAt!).toBeLessThan(find(t, pal.id).finishedAt!);
    await t.hub.pals.stopAndWait();
  });

  test("seen is shared: any device marks it, pals.updated carries it to the others", async () => {
    const t = setup();
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "好" });
    await waitFor(() => find(t, pal.id).attention === "done");
    const other = { clientId: "app_2", deviceId: "dev-two", channel: "app" as const, local: false };
    const before = t.events.length;
    const r = JSON.parse(JSON.stringify(await handleRpc(t.hub, { method: "pals.seen", params: { id: pal.id } }, other)));
    expect(r.pal.attention).toBe("idle");
    const update = t.events.slice(before).find((e) => e.event === "pals.updated" && e.data.pals[0]?.seenAt);
    expect(update?.data.pals[0]).toMatchObject({ id: pal.id, attention: "idle", seenAt: r.pal.seenAt });
    // either device reads the same from the list
    expect((await t.call("pals.list")).pals[0]).toMatchObject({ attention: "idle", seenAt: r.pal.seenAt });
    await expect(t.call("pals.seen", { id: "pal_nope" })).rejects.toThrow("找不到这个会话");
    await t.hub.pals.stopAndWait();
  });

  test("folded: outside any workspace and unused for more than foldDays (not a day earlier), computed from the injected clock; 0 never folds; a workspace's members never fold", async () => {
    const DAY = 86_400_000;
    let clock = Date.now();
    const t = setup({ foldDays: 3, pals: { now: () => clock } });
    const { pal } = await t.call("pals.adopt", { sessionId: bgSession(t) });
    const t0 = rec(t, pal.id).lastUsedAt;
    expect(t0).toBe(clock);
    clock = t0 + 3 * DAY;
    expect(find(t, pal.id).folded).toBe(false); // exactly three days: not yet
    clock = t0 + 3 * DAY + 1;
    expect(find(t, pal.id).folded).toBe(true);
    // the list says so when asked again (the host checks hourly)
    (t.hub.pals as any).emitNow();
    expect(t.lastList().pals[0].folded).toBe(true);
    expect((await t.call("pals.earlier")).items).toEqual([{ kind: "folded", key: `folded:${pal.id}`, id: pal.id, sessionId: pal.sessionId, name: "网站", cwd: t.project, at: t0 }]);
    // in a workspace it stays out of 以前的
    rec(t, pal.id).workspaceId = "ws_a1b2c3d4e5f6";
    expect(find(t, pal.id)).toMatchObject({ folded: false, workspaceId: "ws_a1b2c3d4e5f6" });
    expect((await t.call("pals.earlier")).items).toEqual([]);
    delete rec(t, pal.id).workspaceId;
    // foldDays 0: never
    t.hub.updateSettings({ foldDays: 0 });
    expect(find(t, pal.id).folded).toBe(false);
    t.hub.updateSettings({ foldDays: 3 });
    expect(find(t, pal.id).folded).toBe(true);
    // resuming a folded one wakes it: used just now, so no longer folded
    const resumed = (await t.call("pals.resume", { key: `folded:${pal.id}` })).pal;
    expect(resumed).toMatchObject({ id: pal.id, folded: false });
    expect(rec(t, pal.id).lastUsedAt).toBe(clock);
    expect((await t.call("pals.earlier")).items).toEqual([]);
    await expect(t.call("pals.resume", { key: "folded:pal_gone" })).rejects.toThrow("已经不在了");
    await t.hub.pals.stopAndWait();
  });

  test("settings: foldDays 3 and maxAwake 8 by default, changed with settings.update and checked", async () => {
    const t = setup();
    expect(t.hub.config.settings).toMatchObject({ foldDays: 3, maxAwake: 8 });
    expect((await t.call("sync", {})).settings).toMatchObject({ foldDays: 3, maxAwake: 8 });
    expect((await t.call("settings.update", { patch: { foldDays: 0, maxAwake: 4 } })).settings).toMatchObject({ foldDays: 0, maxAwake: 4 });
    await expect(t.call("settings.update", { patch: { maxAwake: 0 } })).rejects.toThrow();
    await expect(t.call("settings.update", { patch: { foldDays: -1 } })).rejects.toThrow();
  });

  test("end → earlier → resume: it leaves the list and its process ends, is listed once (ended over recent), and comes back under its name with the same session", async () => {
    const recentId = { v: "" };
    // (a folder PaloAlly's tests would not call its own)
    const elsewhere = realpathSync(mkdtempSync(join(tmpdir(), "wb-")));
    const t = setup({
      pals: {
        recentSource: {
          list: async () => (recentId.v ? [{ sessionId: recentId.v, summary: "旧", customTitle: "旧对话", firstPrompt: "旧", lastModified: Date.now() - 5_000, cwd: elsewhere } as any] : []),
          info: async (sid) => (sid === recentId.v ? ({ sessionId: sid, summary: "旧", customTitle: "旧对话", lastModified: Date.now(), cwd: elsewhere } as any) : undefined),
        },
      },
    });
    const { pal } = await t.call("pals.create", { cwd: t.project, name: "官网", text: "做首页" });
    await waitFor(() => find(t, pal.id).attention === "done");
    expect((await t.call("pals.earlier")).items).toEqual([]);
    const gone = await t.call("pals.end", { id: pal.id });
    expect(gone.earlier).toMatchObject({ kind: "ended", key: `ended:${pal.sessionId}`, sessionId: pal.sessionId, name: "官网", cwd: t.project });
    expect(gone.earlier.at).toBeGreaterThan(0);
    expect(t.driver.pals[0]!.closed).toBe(true);
    expect(t.hub.pals.list()).toEqual([]);
    expect(t.lastList().pals).toEqual([]);
    expect(JSON.parse(readFileSync(t.paths.pals, "utf8")).ended).toHaveLength(1);
    // a transcript of it on the computer too: still one line
    t.claude.transcript(t.project, pal.sessionId, [assistantEntry("首页做好了")]);
    recentId.v = "11111111-0000-4000-8000-00000000000a";
    t.claude.transcript(elsewhere, recentId.v, [assistantEntry("旧的")]);
    const items = (await t.call("pals.earlier")).items;
    expect(items.map((i: any) => [i.kind, i.name])).toEqual([["recent", "旧对话"], ["ended", "官网"]].sort((a, b) => (items[0].kind === a[0] ? -1 : 1)));
    expect(items.filter((i: any) => i.sessionId === pal.sessionId)).toHaveLength(1);
    // newest first; a folder narrows
    expect(items[0].at).toBeGreaterThanOrEqual(items[1].at);
    expect((await t.call("pals.earlier", { folder: "/no/where" })).items).toEqual([]);
    expect((await t.call("pals.earlier", { limit: 1 })).items).toHaveLength(1);
    // resume the ended one: same name, folder and session, back in the list, no longer earlier
    const back = (await t.call("pals.resume", { key: `ended:${pal.sessionId}` })).pal;
    expect(back).toMatchObject({ name: "官网", cwd: t.project, sessionId: pal.sessionId, createdBy: "owner" });
    expect(back.id).not.toBe(pal.id);
    expect(t.driver.pals[1]!.opts.resumeSessionId ?? t.driver.pals[1]!.opts.sessionId).toBe(pal.sessionId);
    expect((await t.call("pals.earlier")).items.map((i: any) => i.kind)).toEqual(["recent"]);
    // the kind + sessionId form works too, a recent one is adopted
    const adopted = (await t.call("pals.resume", { kind: "recent", sessionId: recentId.v })).pal;
    expect(adopted).toMatchObject({ sessionId: recentId.v, name: "旧对话" });
    expect((await t.call("pals.earlier")).items).toEqual([]);
    // what isn't there, and what makes no sense
    await expect(t.call("pals.resume", { key: "ended:22222222-0000-4000-8000-000000000000" })).rejects.toThrow("已经不在了");
    await expect(t.call("pals.resume", { key: "nonsense" })).rejects.toThrow("看不懂");
    await expect(t.call("pals.end", { id: "pal_nope" })).rejects.toThrow("找不到这个会话");
    await t.hub.pals.stopAndWait();
  });

  test("ended keeps the newest 200 and one line per session; a session open in a terminal can't be resumed", async () => {
    const t = setup();
    const data = (t.hub.pals as any).data;
    for (let i = 0; i < 205; i++) data.ended.push({ sessionId: `s-${i}`, name: `旧${i}`, cwd: t.project, at: 1000 + i });
    const { pal } = await t.call("pals.create", { cwd: t.project, name: "新" });
    await waitFor(() => find(t, pal.id).status === "idle");
    await t.call("pals.end", { id: pal.id });
    expect(data.ended).toHaveLength(200);
    expect((await t.call("pals.earlier", { limit: 500 })).items).toHaveLength(200);
    expect((await t.call("pals.earlier", { limit: 500 })).items[0]).toMatchObject({ name: "新" });
    // the terminal has it open now
    const term = liveProcess();
    t.claude.register({ sessionId: pal.sessionId, name: "新", cwd: t.project, pid: term.pid });
    await expect(t.call("pals.resume", { key: `ended:${pal.sessionId}` })).rejects.toThrow("刚在别处打开了");
    expect(t.hub.pals.list()).toEqual([]);
    term.kill("SIGTERM");
    await exited(term);
    await t.hub.pals.stopAndWait();
  });

  test("pals.folders: the folders sessions are in, ended in or ended on the computer, most recent first, once each, never PaloAlly's own", async () => {
    const t = setup();
    const second = realpathSync(mkdtempSync(join(tmpdir(), "paloally-pal-")));
    const a = (await t.call("pals.create", { cwd: t.project, name: "甲" })).pal;
    await tick(5);
    const b = (await t.call("pals.create", { cwd: second, name: "乙" })).pal;
    await waitFor(() => find(t, b.id).status === "idle");
    await t.call("pals.create", { cwd: t.project, name: "丙" });
    await tick(5);
    await t.call("pals.end", { id: b.id });
    const { folders } = await t.call("pals.folders", {});
    expect(folders.map((f: any) => f.path)).toEqual([second, t.project]);
    expect(folders[0].name).toBe(second.split("/").at(-1));
    expect(typeof folders[0].lastUsedAt).toBe("number");
    expect(folders[0].lastUsedAt).toBeGreaterThanOrEqual(folders[1].lastUsedAt);
    expect((await t.call("pals.folders", { limit: 1 })).folders).toHaveLength(1);
    expect(a.id).toBeTruthy();
    await t.hub.pals.stopAndWait();
  });

  test("auto-naming: after its first turn it takes Claude Code's title (the first words if there is none yet), Claude Code is renamed too, a clash gets a number, and an owner's name sticks", async () => {
    const t = titled();
    const one = (await t.call("pals.create", { cwd: t.project })).pal;
    expect(one.name).toMatch(/^session-/);
    // Claude Code has made its custom title of the placeholder (it started under it) and a summary
    t.titles.set(one.sessionId, { customTitle: one.name, summary: "修登录页", firstPrompt: "修一下登录页" });
    await t.call("pals.send", { id: one.id, text: "修一下登录页" });
    await waitFor(() => find(t, one.id).name === "修登录页");
    expect(t.driver.renames.at(-1)).toEqual({ title: "修登录页", sessionId: one.sessionId }); // in its running process, as /rename
    expect(rec(t, one.id).autoNamed).toBeUndefined();
    await waitFor(() => t.lastList()?.pals.some((p: any) => p.id === one.id && p.name === "修登录页"), 1_000);
    expect(t.hub.audit.tail(30).find((e) => e.type === "pal.renamed")).toMatchObject({ pal: one.id, from: one.name, to: "修登录页", by: "auto" });
    // a second one gets the same title: a number
    const two = (await t.call("pals.create", { cwd: t.project })).pal;
    t.titles.set(two.sessionId, { customTitle: two.name, summary: "修登录页" });
    await t.call("pals.send", { id: two.id, text: "也修登录页" });
    await waitFor(() => find(t, two.id).name === "修登录页 2");
    // no title yet (nothing read): the placeholder stays until there is one; only the first words make a name
    const three = (await t.call("pals.create", { cwd: t.project })).pal;
    await t.call("pals.send", { id: three.id, text: "你好" });
    await t.hub.idle();
    await tick(40);
    expect(find(t, three.id).name).toBe(three.name);
    expect(rec(t, three.id).autoNamed).toBe(true);
    t.titles.set(three.sessionId, { customTitle: three.name, summary: "整理日志 整理日志", firstPrompt: "整理日志 整理日志" });
    await t.call("pals.send", { id: three.id, text: "接着" });
    await waitFor(() => find(t, three.id).name === "整理日志 整理日志");
    // an owner's rename ends it for good: later turns never rename it
    await t.call("pals.rename", { id: one.id, name: "登录" });
    t.titles.set(one.sessionId, { customTitle: "登录", summary: "别的标题" });
    await t.call("pals.send", { id: one.id, text: "再来" });
    await t.hub.idle();
    await tick(40);
    expect(find(t, one.id).name).toBe("登录");
    // renamed in Claude Code before any title was read: that is the name
    const four = (await t.call("pals.create", { cwd: t.project })).pal;
    t.titles.set(four.sessionId, { customTitle: "我起的名字", summary: "别的" });
    await t.call("pals.send", { id: four.id, text: "嗯" });
    await waitFor(() => find(t, four.id).name === "我起的名字");
    expect(rec(t, four.id).autoNamed).toBeUndefined();
    await t.hub.pals.stopAndWait();
  });

  test("the waiting push also fires for the owner's own sessions (called 新会话 until named); done does not push; a second wait within 10 minutes is quiet", async () => {
    const t = setup({
      palScript: async (text, ctx) => {
        if (text === "要确认") await ctx.useTool("Bash", { command: "npm test" }, { ask: true });
        return echo(text, ctx);
      },
    });
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "先打个招呼" });
    await waitFor(() => find(t, pal.id).attention === "done");
    expect(t.pusher.pushes).toEqual([]); // done is not pushed
    await t.call("pals.send", { id: pal.id, text: "要确认" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    expect(t.pusher.pushes).toEqual([expect.objectContaining({ title: "新会话 在等你", body: "想运行：npm test", data: expect.objectContaining({ pal: pal.id }) })]);
    await t.call("approval.answer", { id: t.hub.approvals.listPending()[0]!.id, allow: true });
    await waitFor(() => find(t, pal.id).attention === "done");
    expect(t.pusher.pushes).toHaveLength(1);
    // named, the push says its name
    await t.call("pals.rename", { id: pal.id, name: "官网" });
    (t.hub.pals as any).lastPush.clear();
    await t.call("pals.send", { id: pal.id, text: "要确认" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    expect(t.pusher.pushes.at(-1)!.title).toBe("官网 在等你");
    await t.hub.pals.stopAndWait();
  });

  test("maxAwake: past it the least recently used idle session sleeps, one shown in a workspace tile is passed over, busy ones never; all shown means all stay awake", async () => {
    const shown = new Set<string>();
    const t = setup({
      maxAwake: 2,
      timing: { sleepCheckMs: 30 },
      pals: { shownIds: () => shown },
      palScript: async (text, ctx) => {
        if (text !== "长活") return echo(text, ctx);
        ctx.emit({ type: "tool_use", id: `t-${Math.random()}`, name: "Bash", input: { command: "sleep 100" }, parentToolUseId: null });
        await ctx.interrupted;
      },
    });
    const ids: string[] = [];
    for (const name of ["甲", "乙"]) {
      const { pal } = await t.call("pals.create", { cwd: t.project, name });
      ids.push(pal.id);
      await waitFor(() => find(t, pal.id).status === "idle");
      await tick(4);
    }
    await tick(100);
    expect(t.hub.pals.list().filter((p) => p.status === "asleep")).toEqual([]);
    // a third: 甲 is the one used least lately
    const third = (await t.call("pals.create", { cwd: t.project, name: "丙" })).pal;
    await waitFor(() => find(t, ids[0]!).status === "asleep", 2_000);
    expect(t.hub.pals.list().filter((p) => p.status === "asleep").map((p) => p.name)).toEqual(["甲"]);
    // wake 甲 with 乙 shown in a tile: 丙 is the next out, not 乙, though 乙 was used less lately
    shown.add(ids[1]!);
    await t.call("pals.wake", { id: ids[0]! });
    await waitFor(() => find(t, third.id).status === "asleep", 2_000);
    expect(find(t, ids[1]!).status).toBe("idle");
    // all three shown: all stay awake
    await t.call("pals.wake", { id: third.id });
    shown.add(ids[0]!);
    shown.add(third.id);
    await tick(200);
    expect(t.hub.pals.list().filter((p) => p.status === "asleep")).toEqual([]);
    // busy ones are never put to sleep
    shown.clear();
    for (const id of ids) await t.call("pals.send", { id, text: "长活" });
    await t.call("pals.send", { id: third.id, text: "长活" });
    await waitFor(() => t.hub.pals.list().filter((p) => p.status === "busy").length === 3, 2_000);
    await tick(200);
    expect(t.hub.pals.list().filter((p) => p.status === "busy")).toHaveLength(3);
    await t.hub.pals.stopAndWait();
  });
});

describe("session details (workbench)", () => {
  const MODELS = [
    { value: "opus", displayName: "Opus", description: "", efforts: ["low", "medium", "high", "max"] },
    { value: "opus[1m]", displayName: "Opus 1M", description: "", efforts: ["low", "high"] },
    { value: "haiku", displayName: "Haiku", description: "", efforts: [] },
  ];
  const script: FakeScript = async (text, ctx) => {
    if (text === "/compact") {
      ctx.emit({ type: "compact", trigger: "manual", preTokens: 150_000, postTokens: 20_000 });
      return;
    }
    if (text === "start bg") {
      ctx.emit({ type: "task_started", taskId: "t_1", description: "跑全部测试", background: true, taskType: "local_bash" });
      ctx.emit({ type: "task_progress", taskId: "t_1", summary: "已跑 40 个" });
      ctx.emit({ type: "task_started", taskId: "t_2", toolUseId: "toolu_agent", description: "查调用方", taskType: "local_agent" });
    }
    if (text === "end bg") ctx.emit({ type: "task_notification", taskId: "t_1", status: "completed", summary: "好了" });
    return echo(text, ctx);
  };
  function det() {
    const opened: [string, string][] = [];
    const t = setup({ palScript: script, pals: { models: async () => MODELS as any, reveal: async (kind, cwd) => void opened.push([kind, cwd]) } });
    return { ...t, opened };
  }
  const mk = async (t: ReturnType<typeof det>) => {
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "开工" });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === pal.id)?.status === "idle", 3_000);
    return pal.id as string;
  };
  const sleepNow = (t: ReturnType<typeof det>, id: string) => (t.hub.pals as any).putToSleep(t.hub.pals.get(id)!, "test") as Promise<void>;
  const recOf = (t: ReturnType<typeof det>, id: string) => (t.hub.pals.get(id) as any).rec as PalRecord;

  test("setModel on a running session switches it live; effort is checked against the model; bad input is refused", async () => {
    const t = det();
    const id = await mk(t);
    const r = await t.call("pals.setModel", { id, model: "opus[1m]", effort: "high" });
    expect(r.pal).toMatchObject({ id, model: "opus[1m]", effort: "high" });
    expect(t.driver.liveSwitches).toEqual(["model:opus[1m]", "effort:high"]);
    expect(recOf(t, id)).toMatchObject({ model: "opus[1m]", effort: "high" });
    await t.call("pals.setModel", { id, effort: "low" }); // the other one stays
    expect(recOf(t, id).model).toBe("opus[1m]");
    await expect(t.call("pals.setModel", { id, effort: "max" })).rejects.toThrow(); // not on this model
    await expect(t.call("pals.setModel", { id, model: "haiku", effort: "low" })).rejects.toThrow();
    await expect(t.call("pals.setModel", { id, model: "nope" })).rejects.toThrow();
    await expect(t.call("pals.setModel", { id })).rejects.toThrow();
    await expect(t.call("pals.setModel", { id, effort: "turbo" })).rejects.toThrow();
    await t.hub.pals.stopAndWait();
  });

  test("setModel on a sleeping session only changes its record: it isn't woken, and the next start runs on both (effort survives a host restart too)", async () => {
    const t = det();
    const id = await mk(t);
    await sleepNow(t, id);
    expect(t.hub.pals.list().find((p) => p.id === id)!.status).toBe("asleep");
    const started = t.driver.pals.length;
    const r = await t.call("pals.setModel", { id, model: "opus", effort: "max" });
    expect(r.pal).toMatchObject({ status: "asleep", model: "opus", effort: "max" });
    expect(t.driver.pals).toHaveLength(started);
    expect(t.driver.liveSwitches).toEqual([]);
    await t.call("pals.send", { id, text: "醒醒" });
    await waitFor(() => t.driver.pals.length === started + 1);
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ model: "opus", effort: "max" });
    // the record on disk has it: a restarted host starts on it
    await t.hub.pals.stopAndWait();
    const saved = JSON.parse(readFileSync(t.paths.pals, "utf8")).pals.find((p: any) => p.id === id);
    expect(saved).toMatchObject({ model: "opus", effort: "max" });
  });

  test("contextTokens come from each result and show as contextPct on the wire (200k window, 1M for a [1m] model); detail has the shape", async () => {
    const t = det();
    const id = await mk(t);
    expect(t.hub.pals.list().find((p) => p.id === id)!.contextPct).toBe(1); // 1000 of 200000, rounded
    t.driver.contextTokens = 100_000;
    await t.call("pals.send", { id, text: "又一轮" });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === id)?.contextPct === 50, 3_000);
    await waitFor(() => t.lastList()?.pals.find((p: any) => p.id === id)?.contextPct === 50);
    await t.call("pals.setModel", { id, model: "opus[1m]" });
    expect(t.hub.pals.list().find((p) => p.id === id)!.contextPct).toBe(10);
    const d = await t.call("pals.detail", { id });
    expect(d).toMatchObject({
      pal: { id, contextPct: 10 },
      contextTokens: 100_000,
      contextWindow: 1_000_000,
      costTotalUsd: expect.any(Number),
      spentToday: expect.any(Number),
      model: "opus[1m]",
      models: [{ id: "opus", name: "Opus", efforts: ["low", "medium", "high", "max"] }, { id: "opus[1m]", name: "Opus 1M", efforts: ["low", "high"] }, { id: "haiku", name: "Haiku", efforts: [] }],
      tasks: [],
    });
    expect(d.lastCompactAt).toBeUndefined();
    await expect(t.call("pals.detail", { id: "pal_nope" })).rejects.toThrow();
    await t.hub.pals.stopAndWait();
  });

  test("pals.compact sends /compact without showing it as the owner's words; lastCompactAt is set and the context shrinks; refused while busy", async () => {
    const t = det();
    const id = await mk(t);
    t.driver.contextTokens = 150_000;
    await t.call("pals.send", { id, text: "大活" });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === id)?.contextPct === 75, 3_000);
    const shown = t.palEvents("chat.message").length;
    await t.call("pals.compact", { id });
    await waitFor(() => (recOf(t, id).lastCompactAt ?? 0) > 0, 3_000);
    await waitFor(() => t.hub.pals.list().find((p) => p.id === id)?.status === "idle", 3_000);
    expect(t.driver.pals[0]!.sent.at(-1)).toBe("/compact");
    expect(t.palEvents("chat.message").slice(shown).filter((m) => m.role === "user")).toEqual([]);
    expect(t.hub.pals.list().find((p) => p.id === id)!.contextPct).toBe(10); // 20k of 200k, not the compact turn's own result
    const d = await t.call("pals.detail", { id });
    expect(d.contextTokens).toBe(20_000);
    expect(d.lastCompactAt).toBe(recOf(t, id).lastCompactAt);
    // busy: refused
    t.driver.palScript = async (_t, ctx) => void (await new Promise<void>((r) => void ctx.interrupted.then(r)));
    await t.call("pals.send", { id, text: "慢活" });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === id)?.status === "busy", 2_000);
    await expect(t.call("pals.compact", { id })).rejects.toThrow();
    await t.call("pals.stop", { id });
    await t.hub.pals.stopAndWait();
  });

  test("tasks: started, progress and notification are tracked; a foreground subagent ends with its tool result; stopTask reaches the driver", async () => {
    const t = det();
    const id = await mk(t);
    await t.call("pals.send", { id, text: "start bg" });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === id)?.status === "idle", 3_000);
    const d = await t.call("pals.detail", { id });
    expect(d.tasks).toEqual([
      { id: "t_1", title: "跑全部测试", kind: "bg", startedAt: expect.any(Number), summary: "已跑 40 个" },
      { id: "t_2", title: "查调用方", kind: "subagent", startedAt: expect.any(Number) },
    ]);
    // a foreground subagent's own tool result ends it
    (t.driver.pals[0]! as any).opts.onEvent({ type: "tool_result", toolUseId: "toolu_agent", content: "ok", isError: false, parentToolUseId: null });
    expect((await t.call("pals.detail", { id })).tasks.map((x: any) => x.id)).toEqual(["t_1"]);
    await t.call("pals.stopTask", { id, taskId: "t_1" });
    expect(t.driver.stoppedTasks).toEqual(["t_1"]);
    await expect(t.call("pals.stopTask", { id, taskId: "t_zzz" })).rejects.toThrow();
    await t.call("pals.send", { id, text: "end bg" });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === id)?.status === "idle", 3_000);
    await waitFor(() => (t.hub.pals.get(id) as any).detailInfo().tasks.length === 0, 3_000);
    await t.hub.pals.stopAndWait();
  });

  test("pals.reveal hands the folder to the opener (finder / terminal) and nothing resumes the session; other kinds and a missing folder are refused", async () => {
    const t = det();
    const id = await mk(t);
    const started = t.driver.pals.length;
    await t.call("pals.reveal", { id, kind: "finder" });
    await t.call("pals.reveal", { id, kind: "terminal" });
    expect(t.opened).toEqual([["finder", t.project], ["terminal", t.project]]);
    expect(t.driver.pals).toHaveLength(started);
    await expect(t.call("pals.reveal", { id, kind: "vim" })).rejects.toThrow();
    recOf(t, id).cwd = join(t.project, "gone");
    await expect(t.call("pals.reveal", { id, kind: "finder" })).rejects.toThrow();
    await t.hub.pals.stopAndWait();
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
