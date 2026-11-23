// The process lifecycle of the assistant and of an agent (batch 7, step 12:
// one ProcessHost for both, the differences flags). Written before the
// change and kept passing through it: restarts after a crash and their
// backoff, a stop while a process is coming up, the holders check, sleep and
// wake for an agent, and the assistant's process that never sleeps, starts
// without waiting for ready, ignores holders and restarts only on demand.
import { afterAll, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { handleRpc } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli } from "./fakeClaude.ts";
import { makeHub, testConfig, tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
const procs: ChildProcess[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
  for (const p of procs) if (p.exitCode === null) p.kill("SIGKILL");
});

const FAST = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
const echo: FakeScript = async (text, ctx) => ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null });

function setup(o: { timing?: Record<string, unknown>; script?: FakeScript; maxAwake?: number } = {}) {
  const claude = new FakeClaudeDir();
  dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const t = makeHub({
    script: o.script ?? echo,
    ...(o.maxAwake ? { config: testConfig((c) => void (c.settings.maxAwake = o.maxAwake!)) } : {}),
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false) },
    pals: { timing: { ...FAST, ...o.timing } },
  });
  t.driver.palScript = echo;
  t.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-proc-")));
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(t.hub, { method, params }, app)) ?? null));
  const agent = async (text?: string) => {
    const { pal } = await call("pals.create", { cwd: project, ...(text ? { text } : {}) });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === pal.id)?.status === "idle");
    return pal as { id: string; sessionId: string; name: string };
  };
  const statusOf = (id: string) => t.hub.pals.list().find((p) => p.id === id)?.status;
  return { ...t, claude, cli, project, call, agent, statusOf };
}

function liveProcess(): ChildProcess {
  const p = spawn("/bin/sleep", ["120"]);
  procs.push(p);
  return p;
}

describe("an agent's process", () => {
  test("backoff: one that keeps failing to start again is tried after each delay in turn (five tries in ten minutes), then stays stopped saying why", async () => {
    const delays = [20, 60, 120, 120, 120];
    const t = setup({ timing: { restartMs: delays } });
    const pal = await t.agent("一");
    const starts: number[] = [];
    const startPal = t.driver.startPal.bind(t.driver);
    t.driver.startPal = (opts) => {
      starts.push(Date.now());
      return startPal(opts);
    };
    t.driver.failPalStart = () => "Claude Code process exited with code 1. stderr: Error: not logged in";
    const crashedAt = Date.now();
    t.driver.pals.at(-1)!.crash();
    await tick(5);
    expect(t.statusOf(pal.id)).toBe("starting"); // a restart is on its way
    await waitFor(() => t.statusOf(pal.id) === "stopped", 5_000);
    expect(starts).toHaveLength(5);
    const gaps = starts.map((s, i) => s - (i ? starts[i - 1]! : crashedAt));
    gaps.forEach((g, i) => expect(g).toBeGreaterThanOrEqual(delays[i]! - 5));
    expect(t.hub.pals.list().find((p) => p.id === pal.id)!.note).toContain("Claude Code 没登录");
    await tick(300);
    expect(starts).toHaveLength(5); // no more
    // the owner's words bring it back
    t.driver.failPalStart = undefined;
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(starts).toHaveLength(6);
    await t.hub.pals.stopAndWait();
  });

  test("a crash right after it came up: back after the first delay on the same session, the owner's words then go in", async () => {
    const t = setup();
    const pal = await t.agent();
    const n = t.driver.pals.length;
    t.driver.pals.at(-1)!.crash();
    await waitFor(() => t.driver.pals.length === n + 1 && t.statusOf(pal.id) === "idle", 3_000);
    const again = t.driver.pals.at(-1)!;
    expect(again.opts.resumeSessionId ?? again.opts.sessionId).toBe(pal.sessionId);
    await t.call("pals.send", { id: pal.id, text: "还在吗" });
    await waitFor(() => again.sent.length === 1);
    expect(again.sent).toEqual(["还在吗"]);
    await t.hub.pals.stopAndWait();
  });

  test("stopped while its process is coming up: nothing is sent, that process is closed, and nothing runs or restarts", async () => {
    const t = setup();
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const startPal = t.driver.startPal.bind(t.driver);
    t.driver.startPal = (opts) => {
      const s = startPal(opts);
      s.ready = () => gate;
      return s;
    };
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "后说" });
    await tick(30);
    expect(t.statusOf(pal.id)).toBe("starting");
    const session = t.hub.pals.get(pal.id)!;
    const asleep = session.sleep();
    release();
    await asleep;
    const proc = t.driver.pals.at(-1)!;
    expect(proc.closed).toBe(true);
    expect(proc.sent).toEqual([]);
    // (its first words failed to go in: listed stopped with why, as any start that failed)
    expect(t.statusOf(pal.id)).toBe("stopped");
    expect(session.running).toBe(false);
    await tick(100);
    expect(t.driver.pals).toHaveLength(1); // nothing restarted it
    await t.hub.pals.stopAndWait();
  });

  test("holders: another process on its session keeps it from starting (stopped: elsewhere, no process of its own); once that's gone the owner's words bring it back", async () => {
    const t = setup();
    const pal = await t.agent();
    await t.hub.pals.get(pal.id)!.sleep();
    const n = t.driver.pals.length;
    const term = liveProcess();
    t.claude.register({ sessionId: pal.sessionId, name: pal.name, cwd: t.project, pid: term.pid! });
    // (the words wait for it: pals.send queues them)
    expect(await t.call("pals.send", { id: pal.id, text: "先来的" })).toMatchObject({ queued: true });
    expect(t.driver.pals).toHaveLength(n);
    expect(t.hub.pals.list().find((p) => p.id === pal.id)).toMatchObject({ status: "stopped", note: expect.stringContaining("在别处开着") });
    term.kill("SIGKILL");
    t.claude.unregister(pal.sessionId);
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await waitFor(() => t.statusOf(pal.id) === "idle", 3_000);
    expect(t.driver.pals).toHaveLength(n + 1);
    expect(t.driver.pals.at(-1)!.sent).toEqual(["先来的", "在吗"]);
    await t.hub.pals.stopAndWait();
  });

  test("sleep and wake: asleep it has no process; words wake it on the same session; words sent while it's being put to sleep wait and wake it after", async () => {
    const t = setup();
    const pal = await t.agent("醒着");
    const session = t.hub.pals.get(pal.id)!;
    const asleep = session.sleep();
    const words = t.call("pals.send", { id: pal.id, text: "起来" });
    await asleep;
    await words;
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.driver.pals).toHaveLength(2);
    expect(t.driver.pals[0]!.closed).toBe(true);
    const woke = t.driver.pals[1]!;
    expect(woke.sent).toEqual(["起来"]);
    expect(woke.opts.resumeSessionId ?? woke.opts.sessionId).toBe(pal.sessionId);
    await session.sleep();
    expect(t.statusOf(pal.id)).toBe("asleep");
    expect(session.running).toBe(false);
    await t.hub.pals.stopAndWait();
  });
});

describe("the assistant's process", () => {
  test("never sleeps: the agents' idle sweep and their awake limit leave it alone, its process stays up and its status never says asleep", async () => {
    const t = setup({ timing: { sleepIdleMs: 20, sleepCheckMs: 20 }, maxAwake: 1 });
    t.hub.userMessage("你好", "app");
    await t.hub.idle();
    const pal = await t.agent();
    await waitFor(() => t.statusOf(pal.id) === "asleep", 10_000);
    await tick(100);
    expect(t.driver.sessions).toHaveLength(1);
    expect(t.driver.last!.closed).toBe(false);
    expect(t.hub.status()).toMatchObject({ online: true, busy: false });
    t.hub.userMessage("还在", "app");
    await t.hub.idle();
    expect(t.driver.sessions).toHaveLength(1);
    expect(t.driver.last!.sent).toEqual(["你好", "还在"]);
    await t.hub.pals.stopAndWait();
  }, 15_000);

  test("a crash mid-turn ends the turn with a notice; nothing restarts it by itself; the next words start a process resuming the same session", async () => {
    let hold!: () => void;
    const holding = new Promise<void>((r) => (hold = r));
    const t = setup({
      script: async (text, ctx) => {
        if (text === "慢") await holding;
        ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null });
      },
    });
    t.hub.userMessage("一", "app");
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    t.hub.userMessage("慢", "app");
    await tick(10);
    expect(t.hub.status().busy).toBe(true);
    t.driver.last!.crash("Claude Code process exited with code 137");
    await tick(20);
    expect(t.hub.status().busy).toBe(false);
    expect(t.hub.chat.recent(3).some((m) => m.kind === "notice")).toBe(true);
    expect(t.driver.sessions).toHaveLength(1);
    t.hub.userMessage("二", "app");
    await t.hub.idle();
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.opts.resumeSessionId).toBe(sid);
    expect(t.driver.last!.sent).toEqual(["二"]);
    expect(t.hub.chat.recent(1)[0]!.text).toBe("收到：二");
    hold();
  });

  test("no holders check: its session registered to another live process doesn't keep it from starting or sending", async () => {
    const t = setup();
    t.hub.userMessage("一", "app");
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    const other = liveProcess();
    t.claude.register({ sessionId: sid, name: "Palo", cwd: t.paths.home, pid: other.pid! });
    t.driver.last!.crash();
    t.hub.userMessage("二", "app");
    expect(t.driver.sessions).toHaveLength(2); // at once, synchronously
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["二"]);
    other.kill("SIGKILL");
  });

  test("its login came back: between turns its process ends and a new one starts on the same session at once; during a turn it's left alone", async () => {
    let hold!: () => void;
    const holding = new Promise<void>((r) => (hold = r));
    const t = setup({
      script: async (text, ctx) => {
        if (text === "慢") await holding;
        ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null });
      },
    });
    t.hub.userMessage("一", "app");
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    const first = t.driver.last!;
    expect(t.hub.conversation.restartIdle()).toBe(true);
    expect(first.closed).toBe(true);
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.opts.resumeSessionId).toBe(sid);
    t.hub.userMessage("慢", "app");
    await tick(10);
    expect(t.hub.conversation.restartIdle()).toBe(false);
    expect(t.driver.sessions).toHaveLength(2);
    hold();
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["慢"]);
  });
});
