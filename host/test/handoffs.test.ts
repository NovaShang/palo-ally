import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import { type Handoff, HandoffTracker, isQuestion, isRequest } from "../src/handoffs.ts";
import { TaskTracker } from "../src/tasks.ts";
import type { Pal } from "../src/types.ts";
import { loadConfig } from "../src/config.ts";
import { sessionOptions } from "../src/harness/claude.ts";
import type { PalsTiming } from "../src/pals.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, testConfig, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const temps: string[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  for (const t of temps) rmSync(t, { recursive: true, force: true });
});
const temp = (name: string) => {
  const d = realpathSync(mkdtempSync(join(tmpdir(), name)));
  temps.push(d);
  return d;
};

// The tracker over agents whose list lines are set by hand (what Pals puts in pals.updated).
function setup(saved?: unknown) {
  const state = temp("paloally-state-");
  if (saved) writeFileSync(join(state, "handoffs.json"), JSON.stringify(saved));
  const bus = new Bus();
  const transitions: string[] = [];
  const tasks = new TaskTracker(join(state, "tasks.json"), join(state, "act"), bus, (t, k) => transitions.push(`${k}:${t.status}`));
  const audit = new Audit(join(state, "audit"));
  const notes: { title: string; body: string }[] = [];
  let now = Date.now();
  let spokeAt = 0;
  const agents = new Map<string, Pal>();
  const make = () =>
    new HandoffTracker({
      path: join(state, "handoffs.json"),
      tasks,
      bus,
      agent: (key) => [...agents.values()].find((p) => p.id === key || p.sessionId === key || p.name === key),
      waitsFor: () => "发 v0.1.2 吗？",
      notify: (_id, title, body) => notes.push({ title, body }),
      assistantSpokeAt: () => spokeAt,
      audit,
      now: () => now,
    });
  const tracker = make();
  // what the agent is doing now, as its line in the list says
  const is = (status: Pal["status"], o: Partial<Pal> = {}) => {
    const p: Pal = { id: "pal_1", name: "builder", cwd: "/work/app", sessionId: "peer-sess", pending: 0, createdBy: "owner", updatedAt: now, ...(agents.get("pal_1") ?? {}), tasksRunning: undefined, note: undefined, ...o, status } as Pal;
    agents.set("pal_1", p);
    bus.emit("pals.updated", { pals: [p] });
  };
  is("idle", { lastLine: "上次的事" });
  return {
    state,
    tasks,
    tracker,
    make,
    notes,
    transitions,
    agents,
    is,
    agent: () => agents.get("pal_1")!,
    row: () => tasks.list()[0]!,
    // pal_send went in: it's at work from that moment
    send: (text = "请帮我修一下发布流程，好了告诉我") => {
      is("busy");
      tracker.sent(agents.get("pal_1")!, text);
    },
    reply: (text: string) => {
      now += 1000;
      tracker.replied(agents.get("pal_1")!, text);
    },
    archive: () => {
      agents.clear();
      bus.emit("pals.updated", { pals: [] });
    },
    advance: (ms: number) => (now += ms),
    assistantSpeaks: () => (spokeAt = now),
    stored: () => JSON.parse(readFileSync(join(state, "handoffs.json"), "utf8")) as { handoffs: Handoff[] },
  };
}

describe("what counts as a handoff", () => {
  test("requests vs acks and results", () => {
    expect(isRequest("Please set up release CI and tell me when it's live")).toBe(true);
    expect(isRequest("请帮我把表格修一下")).toBe(true);
    expect(isRequest("Thanks!")).toBe(false);
    expect(isRequest("Push confirmed working. Closing this one on my side.")).toBe(false);
  });

  test("a reply that asks the owner something", () => {
    expect(isQuestion("要不要把数据库迁移一起做？")).toBe(true);
    expect(isQuestion("Which option should I take?")).toBe(true);
    expect(isQuestion("做好了，已经部署。")).toBe(false);
  });
});

describe("following work handed to an agent", () => {
  test("a request opens a row; an ack doesn't", () => {
    const s = setup();
    s.send("Thanks!");
    expect(s.tasks.list()).toHaveLength(0);
    s.send();
    // a neutral title until the assistant names it (never the raw message)
    expect(s.row()).toMatchObject({ status: "running", peer: "builder", title: "转交给 builder 的事" });
    expect(s.tracker.open()).toHaveLength(1);
    expect(s.tracker.inFlight()).toBe(true);
    // more work for the same agent is the same row
    s.send("再帮我看一下图标");
    expect(s.tasks.list()).toHaveLength(1);
  });

  test("busy: its latest words (not ones from before); waiting: needs_input with what it asks, and no push of the host's own", () => {
    const s = setup();
    s.send();
    s.is("busy");
    expect(s.row()).toMatchObject({ status: "running", summary: "在办" });
    s.is("busy", { lastLine: "正在改 release-mac.yml" });
    expect(s.row()).toMatchObject({ status: "running", summary: "正在改 release-mac.yml" });
    s.is("waiting");
    expect(s.row()).toMatchObject({ status: "needs_input", summary: "在 App 里等你：发 v0.1.2 吗？" });
    s.is("busy");
    expect(s.row().status).toBe("running");
    expect(s.notes).toHaveLength(0); // its card has its own push
  });

  test("it reports back, and once its turn is over the row is done, without its raw words; the assistant relays it", () => {
    const s = setup();
    s.send();
    s.reply("Installed: the latest build is on his iPhone.");
    expect(s.row()).toMatchObject({ status: "running", summary: "回话了，还在办" });
    // the assistant may tell the owner while the agent's turn still winds down
    s.advance(1000);
    s.assistantSpeaks();
    s.advance(1000);
    s.is("idle");
    expect(s.row()).toMatchObject({ status: "done", summary: "办好了" });
    expect(s.transitions).toEqual(["finished:done"]);
    expect(s.tracker.open()).toHaveLength(0);
    s.advance(10 * 60_000);
    s.tracker.tick();
    expect(s.notes).toHaveLength(0);
  });

  test("a finished handoff nobody relayed: one short line after 5 minutes", () => {
    const s = setup();
    s.assistantSpeaks(); // before its reply: not about it
    s.send();
    s.reply("Done: shipped v0.1.2.");
    s.is("idle");
    s.advance(4 * 60_000);
    s.tracker.tick();
    expect(s.notes).toHaveLength(0);
    s.advance(2 * 60_000);
    s.tracker.tick();
    expect(s.notes).toEqual([{ title: "转交的事办完了", body: "转交的事办完了：转交给 builder 的事" }]);
    s.advance(10 * 60_000);
    s.tracker.tick();
    expect(s.notes).toHaveLength(1);
  });

  test("a question through the assistant: asking, also after its turn and asleep, until it's answered", () => {
    const s = setup();
    s.send();
    s.reply("要不要把 dev 数据库一起迁移？");
    expect(s.row()).toMatchObject({ status: "needs_input", summary: "在问你，助理会转告" });
    expect(s.tracker.inFlight()).toBe(true);
    s.is("idle");
    s.is("asleep");
    expect(s.row()).toMatchObject({ status: "needs_input", summary: "在问你，助理会转告" });
    expect(s.tracker.inFlight()).toBe(false); // the owner's to answer: nothing held back for it
    // the assistant relays the owner's answer: it's working again, and done only when it says so
    s.send("迁移");
    expect(s.row().status).toBe("running");
    s.is("idle");
    expect(s.row()).toMatchObject({ status: "running", summary: "对方停下了，还没回话" });
    s.is("busy");
    s.reply("迁完了。");
    s.is("idle");
    expect(s.row().status).toBe("done");
    expect(s.notes).toHaveLength(0);
  });

  test("a question answered by the owner in the agent's own page: at work again without the assistant", () => {
    const s = setup();
    s.send();
    s.reply("用蓝色还是绿色？");
    s.is("idle");
    s.is("busy");
    expect(s.row().status).toBe("running");
    s.reply("改好了。");
    s.is("idle");
    expect(s.row().status).toBe("done");
  });

  test("its turn ends without a reply: said so; its background tasks count as work; asleep, it's settled", () => {
    const s = setup();
    s.send();
    s.is("idle", { tasksRunning: 1 });
    expect(s.row()).toMatchObject({ status: "running", summary: "在办" });
    expect(s.tracker.inFlight()).toBe(true);
    s.is("idle");
    expect(s.row()).toMatchObject({ status: "running", summary: "对方停下了，还没回话" });
    expect(s.tracker.inFlight()).toBe(false); // doesn't hold back compaction
    s.is("busy", { lastLine: "接着做" }); // it goes on by itself
    expect(s.row().summary).toBe("接着做");
    s.is("idle");
    s.is("asleep");
    expect(s.row()).toMatchObject({ status: "stopped", summary: "对方停下了，还没回话" });
    expect(s.tracker.open()).toHaveLength(0);
    s.advance(60 * 60_000);
    s.tracker.tick();
    expect(s.notes).toHaveLength(0);
  });

  test("a reply with a background task left running is still done", () => {
    const s = setup();
    s.send();
    s.reply("好了，预览服务还开着。");
    s.is("idle", { tasksRunning: 1 });
    expect(s.row().status).toBe("done");
  });

  test("more work after a reply: done only when that is reported too; a thank-you changes nothing", () => {
    const s = setup();
    s.send();
    s.reply("收到，开始改。");
    s.tracker.sent(s.agent(), "请把图标也改一下");
    s.is("idle");
    expect(s.row()).toMatchObject({ status: "running", summary: "对方停下了，还没回话" });
    s.is("busy");
    s.reply("都改好了。");
    s.tracker.sent(s.agent(), "谢谢");
    s.is("idle");
    expect(s.row().status).toBe("done");
  });

  test("asked or stopped a day with nothing more: no longer followed", () => {
    const s = setup();
    s.send();
    s.reply("选哪个方案？");
    s.is("asleep");
    s.advance(23 * 3600_000);
    s.tracker.tick();
    expect(s.row().status).toBe("needs_input");
    s.advance(2 * 3600_000);
    s.tracker.tick();
    expect(s.row()).toMatchObject({ status: "stopped", summary: "对方很久没动静，不再跟进" });
  });

  test("archived, or stopped for good, without a word: stopped, quietly; between two processes it isn't", () => {
    const s = setup();
    s.send();
    s.is("stopped"); // being restarted: no reason given
    s.is("starting");
    expect(s.row().status).toBe("running");
    s.is("busy");
    s.archive();
    expect(s.row()).toMatchObject({ status: "stopped", summary: "对方结束了，没回话" });
    expect(s.tracker.open()).toHaveLength(0);

    const e = setup();
    e.send();
    e.is("stopped", { note: "在终端里打开了" });
    expect(e.row()).toMatchObject({ status: "stopped", summary: "对方结束了，没回话" });
    expect(e.notes).toHaveLength(0);
  });

  test("the owner dismissing the row stops following it", () => {
    const s = setup();
    s.send();
    s.tasks.markStopped(s.row().id);
    s.is("busy");
    expect(s.tracker.open()).toHaveLength(0);
  });

  test("survives the host's restart: the row isn't marked interrupted and it's followed on", () => {
    const s = setup();
    s.send();
    expect(s.tasks.orphanRunning()).toHaveLength(0);
    s.tracker.stop();
    const again = s.make();
    again.start();
    expect(again.open()).toHaveLength(1);
    expect(again.inFlight()).toBe(true);
    s.is("stopped");
    s.is("starting");
    s.is("idle");
    expect(s.row()).toMatchObject({ status: "running", summary: "对方停下了，还没回话" }); // its turn was cut off
    again.stop();
  });

  test("report_task(peer): an agent's row is followed; another session's only says whose it is, and is the assistant's to end", () => {
    const s = setup();
    const t = s.tasks.report("ci", "配 CI", "running", "Mac 发版");
    expect(s.tracker.link(t.id, "builder [3fa9c1]")).toBe("ok: 跟进 builder");
    expect(s.tasks.get(t.id)!.peer).toBe("builder");
    expect(s.tracker.forPeer("builder")?.taskId).toBe(t.id);

    const o = s.tasks.report("web", "改首页", "running", "改首页");
    expect(s.tracker.link(o.id, "终端里那个")).toContain("不是 agent");
    expect(s.tasks.get(o.id)!.peer).toBe("终端里那个");
    expect(s.tracker.open()).toHaveLength(1);
    expect(s.tasks.orphanRunning()).toHaveLength(0); // a host restart doesn't cut it off
    s.tasks.report("web", "改好了", "done");
    expect(s.tasks.get(o.id)!.status).toBe("done");
  });

  test("a state file from before: an agent's hand-off goes on, another session's ends, older rows are left alone", () => {
    const old = { id: "h_1", taskId: "", request: "x", createdAt: Date.now(), state: "working", lastLine: "", checkedAt: 0, nextCheckAt: 0, seen: { size: 1 } };
    const s = setup({
      handoffs: [
        { ...old, taskId: "a", peer: { name: "builder", pid: 200, sessionId: "peer-sess", cwd: "/work/app" } },
        { ...old, id: "h_2", taskId: "b", peer: { name: "web", pid: 201, sessionId: "term-sess", cwd: "/work/web", tmux: "x" } },
        { ...old, id: "h_3", taskId: "c", peer: { name: "old", sessionId: "gone" }, state: "closed" },
      ],
      homePids: [100],
    });
    const rows = ["builder", "web"].map((n) => s.tasks.openPeer(`转交给 ${n} 的事`, "在办", n));
    const closed = s.tasks.openPeer("早先的事", "在办", "old");
    s.tasks.settlePeer(closed.id, "done", "办好了");
    const t2 = s.tracker;
    t2.open().forEach((h, i) => (h.taskId = rows[i]!.id));
    t2.start();
    expect(t2.open().map((h) => h.peer.pal)).toEqual(["pal_1"]);
    expect(s.tasks.get(rows[1]!.id)).toMatchObject({ status: "stopped", summary: "对方不是 agent，不再跟进" });
    s.is("busy");
    s.reply("做完了。");
    s.is("idle");
    expect(s.tasks.get(rows[0]!.id)!.status).toBe("done");
    expect(s.tasks.get(closed.id)).toMatchObject({ status: "done", peer: "old" });
    expect(s.stored().handoffs).toHaveLength(3);
    expect(s.notes).toHaveLength(0);
    t2.stop();
  });
});

describe("in a host: the assistant's pal_send, the agent's own events and its palo_send", () => {
  const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
  const SID = "dddd1111-0000-4000-8000-000000000001";

  async function host() {
    const claude = new FakeClaudeDir();
    dirs.push(claude);
    const cli = new FakeCli(claude);
    const project = temp("paloally-pal-");
    const t = makeHub({ sessions: { claudeDir: claude.dir, cli }, pals: { readMessages: async () => [], timing: FAST } });
    t.hub.pals.start();
    cli.bg({ sessionId: SID, name: "网站", cwd: project });
    claude.transcript(project, SID, [assistantEntry("列表页做好了。")]);
    const r = await t.hub.pals.adopt(SID, "test");
    if (!("pal" in r)) throw new Error("not adopted");
    return { ...t, pal: r.pal, send: (text: string) => t.hub.toolHandlers().pal_send({ name: "网站", text }), rows: () => t.hub.tasks.list() };
  }

  test("the row appears when the words go in, follows the agent's work and its card, and is done once it has replied and stopped", async () => {
    const t = await host();
    let go!: () => void;
    t.driver.palScript = async (_text, ctx) => {
      await tick(20);
      ctx.emit({ type: "assistant_text", text: "先看一下登录页。", parentToolUseId: null });
      await new Promise<void>((r) => (go = r));
      void ctx.opts.canUseTool({ toolName: "AskUserQuestion", input: { questions: [{ question: "用哪张图？", header: "图", options: [{ label: "A", description: "a" }, { label: "B", description: "b" }] }] }, toolUseId: "tu_q", signal: new AbortController().signal } as any);
      await new Promise<void>((r) => (go = r));
      await ctx.opts.paloSend!("登录页改好了。");
      await new Promise<void>((r) => (go = r));
    };
    expect(await t.send("请把登录页改好，好了告诉我")).toContain("网站");
    expect(t.rows()).toHaveLength(1);
    expect(t.rows()[0]).toMatchObject({ status: "running", peer: "网站", title: "转交给 网站 的事" });
    // the assistant names it
    await t.hub.toolHandlers().report_task({ id: "login", summary: "改登录页", status: "running", title: "改登录页", peer: "网站" });
    expect(t.rows()).toHaveLength(1);
    await waitFor(() => t.rows()[0]!.summary === "先看一下登录页。");
    expect(t.hub.conversation.cleanBreak(Date.now() + 3600_000)).toBe(false);
    go();
    await waitFor(() => t.rows()[0]!.status === "needs_input");
    expect(t.rows()[0]!.summary).toBe("在 App 里等你：用哪张图？");
    t.hub.questions.answer(t.hub.questions.listPending()[0]!.id, { "用哪张图？": ["A"] } as any, "app");
    await waitFor(() => t.rows()[0]!.status === "running");
    go();
    await waitFor(() => t.rows()[0]!.summary === "回话了，还在办");
    go();
    await waitFor(() => t.rows()[0]!.status === "done");
    expect(t.rows()[0]).toMatchObject({ title: "改登录页", summary: "办好了", peer: "网站" });
    // its words reached the assistant, whose relay counts as having told the owner
    await t.hub.idle();
    (t.hub.handoffs as any).relayFallbacks(Date.now() + 6 * 60_000);
    expect(t.hub.chat.recent(20).some((m) => m.kind === "task")).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("the assistant skips the reply: the host's one line, with the row's title", async () => {
    const t = await host();
    t.driver.script = async (_text, ctx) => ctx.emit({ type: "assistant_text", text: "[skip]", parentToolUseId: null });
    t.driver.palScript = async (_text, ctx) => {
      await tick(20);
      await ctx.opts.paloSend!("改好了。");
    };
    await t.send("请把登录页改好");
    await waitFor(() => t.rows()[0]!.status === "done");
    await t.hub.idle();
    (t.hub.handoffs as any).relayFallbacks(Date.now() + 6 * 60_000);
    await waitFor(() => t.pusher.pushes.some((p) => p.title === "转交的事办完了"));
    expect(t.hub.chat.recent(5).at(-1)).toMatchObject({ kind: "task", text: "转交的事办完了：转交给 网站 的事" });
    await t.hub.pals.stopAndWait();
  });

  test("SendMessage to another session opens no row, and nothing follows it", async () => {
    const t = await host();
    t.driver.script = async (_text, ctx) => {
      await ctx.useTool("SendMessage", { to: "网站", message: "请帮我看一下" });
      ctx.emit({ type: "assistant_text", text: "发了", parentToolUseId: null });
    };
    t.hub.userMessage("问问它", "app");
    await t.hub.idle();
    expect(t.rows()).toHaveLength(0);
    expect(t.hub.handoffs.open()).toHaveLength(0);
    await t.hub.pals.stopAndWait();
  });
});

describe("native compaction at clean breaks", () => {
  const compactScript = async (text: string, ctx: any) => {
    if (text === "/compact") {
      ctx.emit({ type: "compact", trigger: "manual", preTokens: 230_000, postTokens: 18_000 });
      ctx.emit({ type: "assistant_text", text: "Compacted.", parentToolUseId: null });
      return;
    }
    ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null });
  };
  const later = (min: number) => Date.now() + min * 60_000;

  test("idle 54 minutes with 200k+ of context: compacts once, never mid-exchange", async () => {
    const { hub, driver } = makeHub({ script: compactScript });
    driver.contextTokens = 230_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    expect(hub.conversation.contextTokens).toBe(230_000);
    // the app's status carries it as a percent of the model's window
    // (past a 200k model's window: it runs on the long one)
    expect(hub.status()).toMatchObject({ contextTokens: 230_000, contextWindow: 1_000_000, contextPct: 23 });
    // the owner just spoke and the cache is warm: nothing
    expect(hub.conversation.maybeIdleCompact()).toBeNull();
    expect(hub.conversation.maybeIdleCompact(undefined, later(53))).toBeNull();
    expect(hub.conversation.maybeIdleCompact(undefined, later(54))).toBe("started");
    await hub.idle();
    expect(driver.last!.sent.at(-1)).toBe("/compact");
    const audit = hub.audit.tail(20);
    expect(audit.find((e) => e.type === "session.compact")).toMatchObject({ reason: "idle", preTokens: 230_000, postTokens: 18_000 });
    expect(hub.conversation.contextTokens).toBe(18_000);
    // nothing shown or pushed for the housekeeping turn
    expect(hub.chat.recent(20).some((m) => m.text.includes("Compacted"))).toBe(false);
    // and it doesn't repeat in the same idle stretch
    expect(hub.conversation.maybeIdleCompact(undefined, later(120))).toBeNull();
  });

  test("the timer armed after a turn fires once, and a newer turn cancels it", async () => {
    const cfg = testConfig((c) => (c.session.idleCompactMinutes = 0.0005)); // 30 ms
    const { hub, driver } = makeHub({ script: compactScript, config: cfg });
    driver.contextTokens = 230_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    // fake the owner having been quiet for a while: the real timer is only 30 ms
    (hub.chat as any).lastUserActivity = () => 0;
    await tick(120);
    await hub.idle();
    expect(driver.last!.sent.filter((t) => t === "/compact")).toHaveLength(1);
    await tick(120);
    expect(driver.last!.sent.filter((t) => t === "/compact")).toHaveLength(1);
    // a turn in between: the new turn's own timer is what counts
    driver.contextTokens = 230_000;
    hub.userMessage("在吗", "app");
    await hub.idle();
    const stale = (hub.conversation as any).idleStamp - 1;
    expect(hub.conversation.maybeIdleCompact(stale, later(90))).toBeNull();
    hub.conversation.stopIdleCompact();
  });

  test("not below the token threshold, while a turn runs, or with work queued", async () => {
    let release!: () => void;
    const { hub, driver } = makeHub({
      script: async (text, ctx) => {
        if (text === "慢") await new Promise<void>((r) => (release = r));
        ctx.emit({ type: "assistant_text", text: "ok", parentToolUseId: null });
      },
    });
    driver.contextTokens = 230_000;
    hub.userMessage("慢", "app");
    await tick(10);
    expect(hub.conversation.maybeIdleCompact(undefined, later(90))).toBeNull(); // no turn has ended yet
    hub.userMessage("排队", "app");
    release();
    await hub.idle();
    driver.contextTokens = 199_000;
    hub.userMessage("快", "app");
    await hub.idle();
    expect(hub.conversation.maybeIdleCompact(undefined, later(90))).toBeNull(); // below 200k
  });

  test("something running or queued at fire time: no compaction yet, asked again later", async () => {
    let release!: () => void;
    const { hub, driver } = makeHub({
      script: async (text, ctx) => {
        if (text === "慢") await new Promise<void>((r) => (release = r));
        ctx.emit({ type: "assistant_text", text: "ok", parentToolUseId: null });
      },
    });
    driver.contextTokens = 230_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    hub.userMessage("慢", "app");
    await tick(10);
    // a turn is running: not a clean break (its end starts a new idle stretch)
    expect(hub.conversation.maybeIdleCompact(undefined, later(90))).toBe("later");
    release();
    await hub.idle();
    expect(hub.conversation.maybeIdleCompact(undefined, later(90))).toBe("started");
    await hub.idle();
  });

  test("no compaction is enqueued before the 晨报", async () => {
    const { hub, driver } = makeHub({ script: compactScript, config: testConfig() });
    driver.contextTokens = 260_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    const brief = { id: "w1", title: "晨报", kind: "schedule", due: Date.now() } as any;
    (hub as any).onSchedule(brief);
    await tick(20);
    expect(driver.last!.sent).not.toContain("/compact");
    expect("maybeCompact" in hub.conversation).toBe(false);
  });

  test("the main session asks Claude Code to autocompact near the window; a Pal's does not", () => {
    const base = { cwd: "/tmp", permissionMode: "auto", appendSystemPrompt: "", mcpServers: {}, canUseTool: async () => ({ behavior: "allow" }), onEvent: () => {} } as any;
    const main: any = sessionOptions({ ...base, tools: {} as any, compactWindowTokens: 200_000 });
    expect(main.settings).toEqual({ autoCompactWindow: 200_000, precomputeCompactionEnabled: true });
    expect(main.settingSources).toEqual(["user", "project", "local"]);
    expect(sessionOptions({ ...base, tools: {} as any, compactWindowTokens: 0 }).settings).toBeUndefined();
    expect(sessionOptions({ ...base, compactWindowTokens: 200_000 }).settings).toBeUndefined(); // a Pal
    expect(sessionOptions({ ...base }).settings).toBeUndefined();
  });

  test("the conversation hands the configured window to the main session", async () => {
    const { hub, driver } = makeHub({ script: compactScript, config: testConfig((c) => (c.session.compactWindowTokens = 123_000)) });
    hub.userMessage("你好", "app");
    await hub.idle();
    expect(driver.last!.opts.compactWindowTokens).toBe(123_000);
  });

  test("saved configs lose the old triggers and get the new defaults", () => {
    const paths = tmpPaths();
    writeFileSync(paths.config, JSON.stringify({ session: { compactAfterTokens: 300_000, idleCompactHours: 5, compactBeforeBrief: false } }));
    const cfg = loadConfig(paths);
    expect(cfg.session).toEqual({ compactWindowTokens: 200_000, idleCompactMinutes: 54, idleCompactMinTokens: 200_000 });
    writeFileSync(paths.config, JSON.stringify({ session: { idleCompactMinutes: 30 } }));
    expect(loadConfig(paths).session).toMatchObject({ idleCompactMinutes: 30, compactWindowTokens: 200_000 });
  });

  test("the harness' own auto-compaction is logged as such", async () => {
    const { hub } = makeHub({
      script: async (_t, ctx) => {
        ctx.emit({ type: "compact", trigger: "auto", preTokens: 950_000, postTokens: 40_000 });
        ctx.emit({ type: "assistant_text", text: "ok", parentToolUseId: null });
      },
    });
    hub.userMessage("你好", "app");
    await hub.idle();
    expect(hub.audit.tail(20).find((e) => e.type === "session.compact")).toMatchObject({ reason: "native", trigger: "auto", preTokens: 950_000 });
  });

  test("an open handoff holds compaction back", async () => {
    const { hub, driver } = makeHub({ script: compactScript });
    driver.contextTokens = 230_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    const real = hub.handoffs.inFlight.bind(hub.handoffs);
    (hub.handoffs as any).inFlight = () => true;
    expect(hub.conversation.maybeIdleCompact(undefined, later(90))).toBe("later");
    (hub.handoffs as any).inFlight = real;
    expect(hub.conversation.maybeIdleCompact(undefined, later(90))).toBe("started");
    await hub.idle();
  });
});
