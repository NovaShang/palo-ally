// 在终端打开 (pals.openTerminal, terminal.ts) with the fake harness: the host's
// process ends before the terminal opens, the agent waits for it and comes
// back, and words for it wait. No real terminal is ever opened (the opener is
// injected); the .command file itself is run here, with pretend shells.
import { afterAll, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import type { Paths } from "../src/config.ts";
import { transcriptPath } from "../src/handoffs.ts";
import { TERMINAL_UNSET } from "../src/harness/claude/cli.ts";
import type { PalsDeps, PalsTiming } from "../src/pals.ts";
import { chainTo, readTranscript } from "../src/rewind.ts";
import { handleRpc } from "../src/rpc.ts";
import { sweepTerminalFiles, terminalFile, terminalScript, writeTerminalFile } from "../src/terminal.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
const procs: ChildProcess[] = [];
const temps: string[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
  for (const p of procs) if (p.exitCode === null) p.kill("SIGKILL");
  for (const d of temps) rmSync(d, { recursive: true, force: true });
});

function tempDir(name = "pt-term-"): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), name)));
  temps.push(d);
  return d;
}

/** A live process that stands in for the terminal's Claude Code. */
function liveProcess(): ChildProcess {
  const p = spawn("/bin/sleep", ["120"]);
  procs.push(p);
  return p;
}
const exited = (p: ChildProcess) => new Promise<void>((r) => (p.exitCode !== null || p.signalCode !== null ? r() : p.once("exit", () => r())));

const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30], exitWaitMs: 1_000, exitPollMs: 20, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5, terminalMs: 5_000 };
const SID = "aaaa1111-0000-4000-8000-000000000001";
const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };

const echo: FakeScript = async (text, ctx) => ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null, messageId: `msg_${Math.random()}` });

function setup(o: { timing?: Partial<PalsTiming>; palScript?: FakeScript; pals?: Partial<PalsDeps>; seed?: (paths: Paths) => void; claude?: FakeClaudeDir; paths?: Paths; project?: string; forkSession?: PalsDeps["forkSession"]; opener?: (file: string) => Promise<void> } = {}) {
  const claude = o.claude ?? new FakeClaudeDir();
  if (!o.claude) dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const paths = o.paths ?? tmpPaths();
  o.seed?.(paths);
  /** What each opening found: the file's words, and whether the host's process was gone by then. */
  const opened: { file: string; script: string; mode: number; ownAlive: boolean; claims: string | undefined }[] = [];
  const ctx = makeHub({
    paths,
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false) },
    pals: {
      timing: { ...FAST, ...o.timing },
      openTerminal: async (file) => {
        const own = ctx.driver.pals.at(-1)?.proc;
        opened.push({
          file,
          script: readFileSync(file, "utf8"),
          mode: statSync(file).mode & 0o777,
          ownAlive: !!own && own.exitCode === null && own.signalCode === null,
          claims: ctx.hub.pals.list()[0]?.status,
        });
        await o.opener?.(file);
      },
      ...(o.forkSession ? { forkSession: o.forkSession } : {}),
      ...o.pals,
    },
  });
  ctx.driver.spawnPals = true;
  ctx.driver.palScript = o.palScript ?? echo;
  ctx.hub.pals.start();
  const project = o.project ?? tempDir();
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(ctx.hub, { method, params }, app)) ?? null));
  const pal = () => ctx.hub.pals.list()[0]!;
  const audit = (type: string) => ctx.hub.audit.tail(100).filter((e) => e.type === type);
  const notices = () => ctx.hub.chat.filter((m) => m.kind === "notice").map((m) => m.text);
  return { ...ctx, claude, cli, project, call, opened, pal, audit, notices };
}

async function agent(t: ReturnType<typeof setup>) {
  t.cli.bg({ sessionId: SID, name: "网站", cwd: t.project });
  t.claude.transcript(t.project, SID, [assistantEntry("列表页做好了。", { model: "claude-haiku-4-5-20251001" })]);
  const { pal } = await t.call("pals.adopt", { sessionId: SID });
  return pal;
}

/** The terminal's claude turns up in the registry. */
function register(t: ReturnType<typeof setup>, sid = SID): ChildProcess {
  const p = liveProcess();
  t.claude.register({ sessionId: sid, name: "网站", cwd: t.project, pid: p.pid });
  return p;
}
async function quit(t: ReturnType<typeof setup>, p: ChildProcess, sid = SID) {
  p.kill("SIGKILL");
  await exited(p);
  t.claude.unregister(sid);
}

describe("opening an agent in a terminal", () => {
  test("the host's process is gone before the terminal opens; it stays on the list as open in a terminal, words for it wait, and it comes back with them when the terminal quits", async () => {
    const t = setup();
    const pal = await agent(t);
    const own = t.driver.pals[0]!.proc!;
    expect(own.exitCode).toBeNull();
    const r = await t.call("pals.openTerminal", { id: pal.id });
    expect(r.pal).toMatchObject({ id: pal.id, status: "stopped", openInTerminal: true });
    expect(t.opened).toHaveLength(1);
    expect(t.opened[0]).toMatchObject({ ownAlive: false, mode: 0o700, claims: "stopped" });
    expect(t.opened[0]!.file).toBe(join(t.paths.run, `terminal-${pal.id}.command`));
    expect(t.opened[0]!.script).toContain(`claude --resume ${SID}`);
    await exited(own);
    expect(t.audit("pal.terminal")).toEqual([expect.objectContaining({ pal: pal.id, session: SID, by: "app" })]);
    // nothing of ours starts while the terminal comes up: the owner's words wait, the assistant's and a wake are refused
    expect(await t.call("pals.send", { id: pal.id, text: "顺便看看", clientMsgId: "c1" })).toMatchObject({ seq: 0, queued: true });
    expect(await t.call("pals.send", { id: pal.id, text: "顺便看看", clientMsgId: "c1" })).toMatchObject({ seq: 0, queued: true });
    await expect(t.call("pals.wake", { id: pal.id })).rejects.toThrow("正在终端里打开");
    expect(await t.hub.pals.toolSend({ name: "网站", text: "在吗" })).toContain("正在终端里打开");
    await expect(t.call("pals.openTerminal", { id: pal.id, force: true })).rejects.toThrow("已经在终端里开着");
    await tick(250);
    expect(t.driver.pals).toHaveLength(1);
    expect(t.pal()).toMatchObject({ status: "stopped", openInTerminal: true, queued: [{ text: "顺便看看", clientMsgId: "c1" }] });
    // the terminal's claude is there
    const term = register(t);
    await waitFor(() => t.hub.pals.get(pal.id)!.rec.terminalUntil === undefined);
    await t.call("pals.send", { id: pal.id, text: "还有注册页", clientMsgId: "c2" });
    await tick(200);
    expect(t.driver.pals).toHaveLength(1);
    expect(t.pal()).toMatchObject({ status: "stopped", openInTerminal: true });
    expect(t.hub.pals.list()[0]!.queued!.map((q) => q.text)).toEqual(["顺便看看", "还有注册页"]);
    // it quits: back, with the words, in order
    await quit(t, term);
    await waitFor(() => t.driver.pals.at(-1)!.sent.length === 2);
    expect(t.driver.pals).toHaveLength(2);
    expect(t.driver.pals[1]!.opts).toMatchObject({ resumeSessionId: SID });
    expect(t.driver.pals[1]!.sent).toEqual(["顺便看看", "还有注册页"]);
    await waitFor(() => t.pal().status === "idle");
    expect(t.pal().openInTerminal).toBeUndefined();
    expect(t.pal().queued).toBeUndefined();
    expect(t.notices()).toEqual([]);
    await t.hub.pals.stopAndWait();
  });

  test("the words waiting can be called off, and those of an agent archived meanwhile are said not to have gone", async () => {
    const t = setup();
    const pal = await agent(t);
    await t.call("pals.openTerminal", { id: pal.id });
    await t.call("pals.send", { id: pal.id, text: "算了" });
    expect(await t.call("pals.adopt", { sessionId: SID, cancel: true })).toMatchObject({ dropped: 1 });
    expect(t.pal().queued).toBeUndefined();
    await t.call("pals.send", { id: pal.id, text: "还是说一下" });
    await t.call("pals.end", { id: pal.id });
    expect(t.notices()).toEqual([expect.stringContaining("1 条没发出去")]);
    expect(JSON.parse(readFileSync(t.paths.pals, "utf8")).queued).toEqual([]);
    await t.hub.pals.stopAndWait();
  });

  test("refused while it works, waits on the owner or has tasks running; with force it stops for it", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const t = setup({
      palScript: async (text, ctx) => {
        if (text === "问我") {
          await ctx.useTool("Bash", { command: "npm test" }, { ask: true, reason: "要运行命令" });
          return;
        }
        if (text === "起任务") {
          ctx.emit({ type: "background_tasks", tasks: [{ id: "t_1", description: "跑测试" }] } as any);
          return;
        }
        await gate;
      },
    });
    const pal = await agent(t);
    await t.call("pals.send", { id: pal.id, text: "问我" });
    await waitFor(() => t.pal().status === "waiting");
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("正等你点头");
    const card = t.hub.approvals.listPending()[0]!;
    await t.call("approval.answer", { id: card.id, action: "deny" });
    await waitFor(() => t.pal().status === "idle");
    await t.call("pals.send", { id: pal.id, text: "干活" });
    await waitFor(() => t.pal().status === "busy");
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("正在干活");
    expect(t.opened).toHaveLength(0);
    expect(t.driver.pals[0]!.proc!.exitCode).toBeNull();
    const r = await t.call("pals.openTerminal", { id: pal.id, force: true });
    expect(r.pal).toMatchObject({ status: "stopped", openInTerminal: true });
    expect(t.opened[0]!.ownAlive).toBe(false);
    expect(t.audit("pal.terminal")[0]).toMatchObject({ force: true });
    release();
    await t.hub.pals.stopAndWait();
  });

  test("refused with background tasks running", async () => {
    const t = setup();
    const pal = await agent(t);
    (t.hub.pals.get(pal.id) as any).taskView.running = () => [{ id: "t1" }, { id: "t2" }];
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("2 个任务");
    await t.call("pals.openTerminal", { id: pal.id, force: true });
    expect(t.opened).toHaveLength(1);
    await t.hub.pals.stopAndWait();
  });

  test("a terminal that never turns up: the agent is back after its time, said in a notice, its file gone and its words in", async () => {
    const t = setup({ timing: { terminalMs: 300 } });
    const pal = await agent(t);
    await t.call("pals.openTerminal", { id: pal.id });
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await tick(120);
    expect(t.driver.pals).toHaveLength(1);
    await waitFor(() => t.driver.pals.length === 2 && t.driver.pals[1]!.sent.length === 1);
    expect(t.driver.pals[1]!.sent).toEqual(["在吗"]);
    expect(t.notices()).toEqual(["终端里一直没打开「网站」，它回到这里了。"]);
    expect(existsSync(t.opened[0]!.file)).toBe(false);
    expect(t.audit("pal.terminal_gave_up")).toHaveLength(1);
    // and can be opened again
    await waitFor(() => t.pal().status === "idle");
    await t.call("pals.openTerminal", { id: pal.id });
    expect(t.opened).toHaveLength(2);
    await t.hub.pals.stopAndWait();
  });

  test("one quit again at once (before the guard looks): nothing is said, it just comes back", async () => {
    const t = setup({ timing: { guardMs: 1_000 } });
    const pal = await agent(t);
    await t.call("pals.openTerminal", { id: pal.id });
    const term = register(t);
    await tick(100); // the close watch saw it
    await quit(t, term);
    await waitFor(() => t.pal().status === "idle", 4_000);
    expect(t.notices()).toEqual([]);
    await t.hub.pals.stopAndWait();
  });

  test("asleep when opened: asleep again after the terminal quits, unless words wait for it", async () => {
    const t = setup();
    const pal = await agent(t);
    await (t.hub.pals as any).putToSleep(t.hub.pals.get(pal.id), "test");
    await t.call("pals.openTerminal", { id: pal.id });
    let term = register(t);
    await waitFor(() => t.hub.pals.get(pal.id)!.rec.terminalUntil === undefined);
    await quit(t, term);
    await waitFor(() => t.pal().status === "asleep");
    expect(t.driver.pals).toHaveLength(1);
    await t.call("pals.openTerminal", { id: pal.id });
    term = register(t);
    await t.call("pals.send", { id: pal.id, text: "接着做" });
    await waitFor(() => t.hub.pals.get(pal.id)!.rec.terminalUntil === undefined);
    await quit(t, term);
    await waitFor(() => t.driver.pals.at(-1)!.sent.includes("接着做"));
    expect(t.driver.pals).toHaveLength(2);
    await t.hub.pals.stopAndWait();
  });

  test("no terminal opens (the opener fails): it's back as it was, and the reason comes back", async () => {
    const t = setup({ opener: async () => Promise.reject(new Error("没有终端")) });
    const pal = await agent(t);
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("没能在终端打开：没有终端");
    await waitFor(() => t.pal().status === "idle");
    expect(t.driver.pals).toHaveLength(2);
    expect(existsSync(t.opened[0]!.file)).toBe(false);
    expect(t.hub.pals.get(pal.id)!.rec.terminalUntil).toBeUndefined();
    await t.hub.pals.stopAndWait();
  });

  test("already open in a terminal by hand: refused; and one asleep gets the same queue when it turns out to be", async () => {
    const t = setup({ timing: { guardMs: 60_000 } });
    const pal = await agent(t);
    const term = register(t);
    await expect(t.call("pals.openTerminal", { id: pal.id, force: true })).rejects.toThrow("已经在终端里开着");
    await (t.hub.pals as any).putToSleep(t.hub.pals.get(pal.id), "test");
    expect(await t.call("pals.send", { id: pal.id, text: "在吗", clientMsgId: "c9" })).toMatchObject({ queued: true });
    expect(t.driver.pals).toHaveLength(1);
    await quit(t, term);
    (t.hub.pals as any).guard();
    await waitFor(() => t.driver.pals.at(-1)!.sent.includes("在吗"));
    await t.hub.pals.stopAndWait();
  });

  test("a folder that's gone, and an id that isn't a session's: refused before anything ends", async () => {
    const t = setup();
    const pal = await agent(t);
    const rec = t.hub.pals.get(pal.id)!.rec;
    rec.sessionId = `${SID}; rm -rf x`;
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("not a Claude Code session id");
    rec.sessionId = SID;
    const { cwd } = rec;
    rec.cwd = "/no/such/folder";
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("/no/such/folder");
    rec.cwd = cwd;
    expect(t.opened).toHaveLength(0);
    expect(t.pal().status).toBe("idle");
    await t.hub.pals.stopAndWait();
  });

  test("what the list says all along: stopped with a note from the start to the give-back (wakes and the assistant's words tried meanwhile), then back; never gone, never idle or asleep in between, no finished turn", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const t = setup({ timing: { terminalMs: 500 }, palScript: async () => gate });
    const pal = await agent(t);
    await t.call("pals.send", { id: pal.id, text: "干活" });
    await waitFor(() => t.pal().status === "busy");
    await tick(60);
    const from = t.events.length;
    await t.call("pals.openTerminal", { id: pal.id, force: true });
    await t.call("pals.wake", { id: pal.id }).catch(() => {});
    await t.hub.pals.toolSend({ name: "网站", text: "在吗" });
    await tick(100);
    await waitFor(() => t.pal().status === "idle");
    await tick(60);
    const said = t.events.slice(from).filter((e) => e.event === "pals.updated").map((e) => e.data.pals.find((p: any) => p.id === pal.id));
    expect(said.every(Boolean)).toBe(true);
    // (coming up is too quick here to always be said)
    const statuses = said.map((p) => p.status).filter((s) => s !== "starting");
    expect(statuses.filter((s, i) => s !== statuses[i - 1])).toEqual(["stopped", "idle"]);
    for (const p of said.filter((p) => p.status === "stopped")) {
      expect(p.note).toBeTruthy();
      expect(p.openInTerminal).toBe(true);
    }
    expect(said.every((p) => p.finishedAt === undefined)).toBe(true);
    release();
    await t.hub.pals.stopAndWait();
  });
});

describe("the host restarted in between", () => {
  test("in the terminal's time: it isn't started, the words still wait; then the terminal is there, quits, and it comes back with them", async () => {
    const t = setup({ timing: { terminalMs: 20_000 } });
    const pal = await agent(t);
    await t.call("pals.openTerminal", { id: pal.id });
    await t.call("pals.send", { id: pal.id, text: "接着做" });
    await t.hub.pals.stopAndWait();
    const t2 = setup({ claude: t.claude, paths: t.paths, project: t.project, timing: { terminalMs: 20_000 } });
    await tick(250);
    expect(t2.driver.pals).toHaveLength(0);
    expect(t2.pal()).toMatchObject({ status: "stopped", openInTerminal: true, queued: [{ text: "接着做" }] });
    const term = register(t2);
    await waitFor(() => t2.hub.pals.get(pal.id)!.rec.terminalUntil === undefined);
    await quit(t2, term);
    await waitFor(() => t2.driver.pals[0]?.sent.length === 1);
    expect(t2.driver.pals[0]!.sent).toEqual(["接着做"]);
    expect(t2.notices()).toEqual([]);
    await t2.hub.pals.stopAndWait();
  });

  test("with the terminal open all along: it stays aside, and comes back when that quits", async () => {
    const t = setup();
    const pal = await agent(t);
    await t.call("pals.openTerminal", { id: pal.id });
    const term = register(t);
    await waitFor(() => t.hub.pals.get(pal.id)!.rec.terminalUntil === undefined);
    await t.hub.pals.stopAndWait();
    const t2 = setup({ claude: t.claude, paths: t.paths, project: t.project });
    await waitFor(() => t2.pal().status === "stopped");
    expect(t2.pal().openInTerminal).toBe(true);
    expect(await t2.call("pals.send", { id: pal.id, text: "在吗" })).toMatchObject({ queued: true });
    await quit(t2, term);
    (t2.hub.pals as any).retried.clear(); // (the 30 s between tries)
    await waitFor(() => t2.driver.pals.at(-1)?.sent.includes("在吗") ?? false);
    await t2.hub.pals.stopAndWait();
  });

  test("its time ran out while the host was down: back at once, nothing said", async () => {
    const t = setup({ timing: { terminalMs: 300 } });
    const pal = await agent(t);
    await t.call("pals.openTerminal", { id: pal.id });
    await t.hub.pals.stopAndWait();
    await tick(350);
    const t2 = setup({ claude: t.claude, paths: t.paths, project: t.project, timing: { terminalMs: 300 } });
    await waitFor(() => t2.pal().status === "idle");
    expect(t2.notices()).toEqual([]);
    await t2.hub.pals.stopAndWait();
  });
});

describe("gone back and not spoken to since", () => {
  const COPY = "dddd4444-0000-4000-8000-000000000009";
  const at = (s: number) => new Date(Date.parse("2026-10-16T08:00:00Z") + s * 1000).toISOString();
  const user = (uuid: string, parentUuid: string | null, text: string, s: number) => ({ type: "user", uuid, parentUuid, timestamp: at(s), origin: { kind: "human" }, message: { role: "user", content: text } });
  const reply = (uuid: string, parentUuid: string, text: string, s: number) => ({ type: "assistant", uuid, parentUuid, timestamp: at(s), message: { id: `msg_${uuid}`, role: "assistant", model: "claude-haiku-4-5", content: [{ type: "text", text }] } });

  async function rewound(to: "p1" | "p2", fail = false) {
    const calls: unknown[] = [];
    const t: ReturnType<typeof setup> = setup({
      forkSession: async (sessionId: string, o: { dir: string; upToMessageId: string; title?: string }) => {
        calls.push({ sessionId, ...o });
        if (fail) throw new Error("写不进去");
        const p = transcriptPath(t.claude.dir, o.dir, COPY);
        mkdirSync(dirname(p), { recursive: true });
        writeFileSync(p, chainTo(readTranscript(transcriptPath(t.claude.dir, o.dir, sessionId)), o.upToMessageId).map((e) => JSON.stringify(e)).join("\n") + "\n");
        return { sessionId: COPY };
      },
    } as any);
    t.cli.bg({ sessionId: SID, name: "网站", cwd: t.project });
    t.claude.transcript(t.project, SID, [user("p1", null, "先建 note.txt", 0), reply("r1", "p1", "建好了", 1), user("p2", "r1", "改成 two", 10), reply("r2", "p2", "改好了", 11)]);
    const { pal } = await t.call("pals.adopt", { sessionId: SID });
    await t.call("pals.rewind", { id: pal.id, messageId: to });
    await waitFor(() => t.pal().status === "idle");
    return { t, pal, calls, fork: t.hub.pals.get(pal.id)!.rec.sessionId };
  }

  test("the conversation as it stands is copied, the terminal resumes the copy, and the agent follows it there and back", async () => {
    const { t, pal, calls, fork } = await rewound("p2");
    await expect(t.call("pals.terminalCommand", { id: pal.id })).rejects.toThrow("先跟它说句话");
    const r = await t.call("pals.openTerminal", { id: pal.id });
    expect(calls).toEqual([{ sessionId: SID, dir: t.project, upToMessageId: "r1", title: "网站" }]);
    expect(t.opened[0]!.script).toContain(`claude --resume ${COPY}`);
    expect(t.opened[0]!.ownAlive).toBe(false);
    expect(r.pal.sessionId).toBe(COPY);
    const { rec } = t.hub.pals.get(pal.id)!;
    expect(rec.rewind).toBeUndefined();
    expect(rec.formerSessions).toEqual([SID, fork]);
    const term = register(t, COPY);
    await waitFor(() => rec.terminalUntil === undefined);
    await quit(t, term, COPY);
    await waitFor(() => t.pal().status === "idle");
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ resumeSessionId: COPY });
    expect((await t.call("pals.terminalCommand", { id: pal.id })).command).toBe(`cd ${t.project} && claude --resume ${COPY}`);
    await t.hub.pals.stopAndWait();
  });

  test("gone back to its very first message: a fresh claude under the id the record has, so the agent follows what's said there", async () => {
    const { t, pal, calls, fork } = await rewound("p1");
    expect((await t.call("pals.terminalCommand", { id: pal.id })).command).toBe(`cd ${t.project} && claude --session-id ${fork}`);
    await t.call("pals.openTerminal", { id: pal.id });
    expect(calls).toEqual([]);
    expect(t.opened[0]!.script).toContain(`claude --session-id ${fork}`);
    const term = register(t, fork);
    await waitFor(() => t.hub.pals.get(pal.id)!.rec.terminalUntil === undefined);
    t.claude.transcript(t.project, fork, [user("n1", null, "重新来", 30), reply("n2", "n1", "好", 31)]);
    await quit(t, term, fork);
    await waitFor(() => t.pal().status === "idle");
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ resumeSessionId: fork });
    await t.hub.pals.stopAndWait();
  });

  test("a copy that fails leaves it as it was", async () => {
    const { t, pal, fork } = await rewound("p2", true);
    const n = t.driver.pals.length;
    await expect(t.call("pals.openTerminal", { id: pal.id })).rejects.toThrow("没能在终端打开：写不进去");
    expect(t.opened).toHaveLength(0);
    expect(t.pal()).toMatchObject({ status: "idle", sessionId: fork });
    expect(t.driver.pals).toHaveLength(n);
    await t.hub.pals.stopAndWait();
  });
});

describe("pals.terminalCommand", () => {
  test("the line to copy; nothing is stopped", async () => {
    const t = setup({ project: tempDir("有 空格'引号 && x-") });
    const pal = await agent(t);
    const { command } = await t.call("pals.terminalCommand", { id: pal.id });
    expect(command).toBe(`cd '${t.project.replace(/'/g, `'\\''`)}' && claude --resume ${SID}`);
    expect(t.pal().status).toBe("idle");
    expect((await t.call("pals.list")).terminal).toBe(true);
    // what a shell makes of it is the folder
    const bin = tempDir();
    writeFileSync(join(bin, "claude"), '#!/bin/sh\npwd\necho "$@"\n');
    chmodSync(join(bin, "claude"), 0o755);
    const r = spawnSync("/bin/zsh", ["-c", command], { env: { PATH: `${bin}:/usr/bin:/bin` }, encoding: "utf8" });
    expect(r.stdout.split("\n").slice(0, 2)).toEqual([t.project, `--resume ${SID}`]);
    await t.hub.pals.stopAndWait();
  });
});

describe("the .command file", () => {
  /** A pretend home whose login shell finds a pretend claude, which says where and how it was started. */
  function home() {
    const dir = tempDir();
    const bin = join(dir, "bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "claude"), `#!/bin/sh\npwd > '${dir}/out'\necho "$*" >> '${dir}/out'\nenv > '${dir}/env'\n`);
    chmodSync(join(bin, "claude"), 0o755);
    // PATH, the owner's own settings, and a cd only in the startup files: as a real one's.
    writeFileSync(join(dir, ".zprofile"), `export PATH='${bin}':$PATH\n`);
    writeFileSync(join(dir, ".zshrc"), "export CLAUDE_CODE_USE_BEDROCK=1\ncd /\n");
    writeFileSync(join(dir, ".bash_profile"), `export PATH='${bin}':$PATH\ncd /\n`);
    return dir;
  }
  const start = (dir: string, file: string, env: Record<string, string> = {}) =>
    spawnSync(file, [], { env: { HOME: dir, ZDOTDIR: dir, PATH: "/usr/bin:/bin", TERM: "dumb", ...env }, encoding: "utf8", timeout: 20_000 });

  for (const shell of ["/bin/zsh", "/bin/bash"]) {
    test(`through the owner's login shell (${basename(shell)}): the folder whatever its name, the session, none of the host's variables; it takes itself away`, () => {
      const dir = home();
      const cwd = join(tempDir(), `有 空格 'q' "dq" $HOME \`id\` \\back; && 文件夹`);
      mkdirSync(cwd);
      const run = { command: `claude --resume ${SID}`, unset: TERMINAL_UNSET };
      const runDir = join(tempDir(), "run dir");
      const file = terminalFile(runDir, "pal_ab12");
      writeTerminalFile(file, terminalScript(cwd, run, { shell }), runDir);
      expect(statSync(file).mode & 0o777).toBe(0o700);
      const r = start(dir, file, {
        SHELL: shell,
        PALOALLY_SESSION: "1",
        PALOALLY_HOME: "/x",
        CLAUDECODE: "1",
        CLAUDE_CODE_ENTRYPOINT: "sdk-ts",
        CLAUDE_CODE_ARTIFACT: "1",
        CLAUDE_AGENT_SDK_VERSION: "0.3",
        CLAUDE_CONFIG_DIR: "/kept",
        KEPT: "a\nCLAUDE_CODE_FAKE=1",
      });
      expect(r.error).toBeUndefined();
      expect(existsSync(join(dir, "out"))).toBe(true);
      expect(readFileSync(join(dir, "out"), "utf8")).toBe(`${cwd}\n--resume ${SID}\n`);
      const env = readFileSync(join(dir, "env"), "utf8").split("\n").map((l) => l.split("=")[0]);
      for (const v of ["PALOALLY_SESSION", "PALOALLY_HOME", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_ARTIFACT", "CLAUDE_AGENT_SDK_VERSION"]) expect(env).not.toContain(v);
      expect(env).toContain("CLAUDE_CONFIG_DIR");
      expect(env).toContain("KEPT");
      // the owner's own, from their shell, are there
      if (shell === "/bin/zsh") expect(env).toContain("CLAUDE_CODE_USE_BEDROCK");
      expect(existsSync(file)).toBe(false);
    });
  }

  test("a folder that's gone by then: it says so and starts nothing", () => {
    const dir = home();
    const runDir = tempDir();
    const file = terminalFile(runDir, "pal_x");
    writeTerminalFile(file, terminalScript("/no/such/folder", { command: "claude", unset: TERMINAL_UNSET }), runDir);
    const r = start(dir, file);
    expect(r.status).toBe(1);
    expect(existsSync(join(dir, "out"))).toBe(false);
  });

  test("the file's name is the agent's id and nothing else; leftovers older than the time are swept", () => {
    const runDir = tempDir();
    expect(terminalFile(runDir, "../../pal_1")).toBe(join(runDir, "terminal-pal_1.command"));
    const file = terminalFile(runDir, "pal_1");
    writeTerminalFile(file, "#!/bin/sh\n", runDir);
    writeFileSync(join(runDir, "host.sock.txt"), "");
    sweepTerminalFiles(runDir, 1_000, Date.now());
    expect(existsSync(file)).toBe(true);
    sweepTerminalFiles(runDir, 1_000, Date.now() + 5_000);
    expect(existsSync(file)).toBe(false);
    expect(existsSync(join(runDir, "host.sock.txt"))).toBe(true);
  });
});
