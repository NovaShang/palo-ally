import { describe, expect, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import { HandoffTracker, SessionRegistry, isQuestion, isRequest, summarizeTail, transcriptPath } from "../src/handoffs.ts";
import { TaskTracker } from "../src/tasks.ts";
import { readJsonl } from "../src/util.ts";
import { makeHub, testConfig, tick } from "./helpers.ts";

const HOME = "/tmp/paloally-home-test";

function ts(ms: number) {
  return new Date(ms).toISOString();
}
function assistantText(text: string, at: number) {
  return { type: "assistant", timestamp: ts(at), message: { content: [{ type: "text", text }] } };
}
function assistantTool(name: string, id: string, input: unknown, at: number) {
  return { type: "assistant", timestamp: ts(at), message: { content: [{ type: "tool_use", id, name, input }] } };
}
function toolResult(id: string, at: number) {
  return { type: "user", timestamp: ts(at), message: { content: [{ type: "tool_result", tool_use_id: id, content: "ok" }] } };
}

// A fake ~/.claude: the session registry and transcripts, like Claude Code writes them.
function fakeClaude() {
  const dir = mkdtempSync(join(tmpdir(), "paloally-claude-"));
  mkdirSync(join(dir, "sessions"), { recursive: true });
  const alive = new Set<number>();
  const registry = new SessionRegistry(join(dir, "sessions"), (pid) => alive.has(pid));
  const session = (pid: number, sessionId: string, name: string, cwd: string, status = "busy", extra: Record<string, unknown> = {}) => {
    alive.add(pid);
    writeFileSync(join(dir, "sessions", `${pid}.json`), JSON.stringify({ pid, sessionId, name, cwd, status, statusUpdatedAt: Date.now(), ...extra }));
  };
  const end = (pid: number) => {
    alive.delete(pid);
    rmSync(join(dir, "sessions", `${pid}.json`), { force: true });
  };
  const write = (cwd: string, sessionId: string, entries: unknown[]) => {
    const p = transcriptPath(dir, cwd, sessionId);
    mkdirSync(dirname(p), { recursive: true });
    appendFileSync(p, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  };
  return { dir, registry, session, end, write };
}

function setup() {
  const claude = fakeClaude();
  const state = mkdtempSync(join(tmpdir(), "paloally-state-"));
  const bus = new Bus();
  const transitions: string[] = [];
  const tasks = new TaskTracker(join(state, "tasks.json"), join(state, "act"), bus, (t, k) => transitions.push(`${k}:${t.status}`));
  const audit = new Audit(join(state, "audit"));
  const notes: { title: string; body: string }[] = [];
  let now = Date.now();
  let spokeAt = 0;
  const make = () =>
    new HandoffTracker({
      path: join(state, "handoffs.json"),
      claudeDir: claude.dir,
      homeCwd: () => HOME,
      selfSessionId: () => "home-sess",
      tasks,
      notify: (_id, title, body) => notes.push({ title, body }),
      assistantSpokeAt: () => spokeAt,
      audit,
      log: () => {},
      now: () => now,
      registry: claude.registry,
    });
  const tracker = make();
  // the assistant itself, as a registered session
  claude.session(100, "home-sess", "home-ab", HOME, "idle");
  claude.session(200, "peer-sess", "builder", "/work/app", "busy", { tmux: "bento:@1.%2" });
  return {
    claude,
    tasks,
    tracker,
    make,
    notes,
    transitions,
    advance: (ms: number) => (now += ms),
    assistantSpeaks: () => (spokeAt = now),
    now: () => now,
    // run a full check right now, whatever the schedule says
    check: (t = tracker) => {
      for (const h of t.open()) h.nextCheckAt = 0;
      t.tick();
    },
  };
}

function handOff(s: ReturnType<typeof setup>, message = "请帮我修一下发布流程，好了告诉我", to = "builder") {
  s.tracker.onSend("tu_1", { to, message });
  s.tracker.onSendResult("tu_1", '{"success":true}', false);
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

describe("reading Claude Code's own state", () => {
  test("the registry resolves names, name [ref] and uds addresses", () => {
    const c = fakeClaude();
    c.session(42, "s42", "worker", "/w");
    expect(c.registry.resolve("worker")?.sessionId).toBe("s42");
    expect(c.registry.resolve("worker [3fa9c1]")?.sessionId).toBe("s42");
    expect(c.registry.resolve("uds:/tmp/cc-socks/42.sock")?.sessionId).toBe("s42");
    expect(c.registry.resolve("nobody")).toBeUndefined();
    c.end(42);
    expect(c.registry.resolve("worker")).toBeUndefined();
  });

  test("the transcript tail: latest words, an open question, replies", () => {
    const t0 = Date.now();
    const tail = summarizeTail([
      assistantText("先看一下现在的发布脚本。", t0),
      assistantTool("AskUserQuestion", "q1", { questions: [{ question: "用哪个版本号？" }] }, t0 + 1),
      assistantTool("SendMessage", "s1", { to: "home-ab", message: "测好了，修复已经提交。" }, t0 + 2),
    ]);
    expect(tail.lastText).toBe("先看一下现在的发布脚本。");
    expect(tail.pendingQuestion?.text).toBe("用哪个版本号？");
    expect(tail.replies).toEqual([{ to: "home-ab", text: "测好了，修复已经提交。", at: t0 + 2 }]);
    // once answered, the question isn't pending any more
    expect(summarizeTail([assistantTool("AskUserQuestion", "q1", { questions: [{ question: "x" }] }, t0), toolResult("q1", t0 + 1)]).pendingQuestion).toBeUndefined();
  });
});

describe("following a handoff", () => {
  test("a request to a peer opens a row; an ack or a message to the assistant itself doesn't", () => {
    const s = setup();
    s.tracker.onSend("tu_a", { to: "builder", message: "Thanks!" });
    s.tracker.onSendResult("tu_a", '{"success":true}', false);
    s.tracker.onSend("tu_b", { to: "home-ab", message: "请帮我看一下" });
    s.tracker.onSendResult("tu_b", '{"success":true}', false);
    expect(s.tasks.list()).toHaveLength(0);
    handOff(s);
    const [task] = s.tasks.list();
    // a neutral title until the assistant names it (never the raw message)
    expect(task).toMatchObject({ status: "running", peer: "builder", title: "转交给 builder 的事" });
    expect(s.tracker.open()).toHaveLength(1);
    // a failed send opens nothing
    s.tracker.onSend("tu_c", { to: "builder", message: "请再帮我看一下" });
    s.tracker.onSendResult("tu_c", "error", true);
    expect(s.tasks.list()).toHaveLength(1);
  });

  test("busy → the row shows its latest words; waiting → needs_input and one push", () => {
    const s = setup();
    handOff(s);
    const t0 = s.now();
    s.claude.write("/work/app", "peer-sess", [assistantText("正在改 release-mac.yml", t0 + 1000)]);
    s.check();
    expect(s.tasks.list()[0]).toMatchObject({ status: "running", summary: "正在改 release-mac.yml" });

    s.claude.session(200, "peer-sess", "builder", "/work/app", "waiting", { waitingFor: "input needed" });
    s.claude.write("/work/app", "peer-sess", [assistantTool("AskUserQuestion", "q9", { questions: [{ question: "发 v0.1.2 吗？" }] }, t0 + 2000)]);
    s.check();
    expect(s.tasks.list()[0]).toMatchObject({ status: "needs_input", summary: "在电脑上等你：发 v0.1.2 吗？" });
    expect(s.notes).toHaveLength(1);
    expect(s.notes[0]!.title).toBe("转交的事在等你回答");
    expect(s.notes[0]!.body).toBe("「转交给 builder 的事」在 builder 那边等你回答，去那台电脑上看一下。");
    s.check(); // same question: no second push
    expect(s.notes).toHaveLength(1);
  });

  test("a question relayed through the assistant shows as asking, without a push of its own", () => {
    const s = setup();
    handOff(s);
    s.claude.session(200, "peer-sess", "builder", "/work/app", "idle");
    s.claude.write("/work/app", "peer-sess", [assistantTool("SendMessage", "m1", { to: "home-ab", message: "要不要把 dev 数据库一起迁移？" }, s.now() + 1000)]);
    s.check();
    expect(s.tasks.list()[0]).toMatchObject({ status: "needs_input", summary: "在问你，助理会转告" });
    expect(s.notes).toHaveLength(0);
    // the assistant relays the owner's answer: it's working again
    s.tracker.onSend("tu_2", { to: "builder", message: "迁移，谢谢" });
    s.tracker.onSendResult("tu_2", '{"success":true}', false);
    expect(s.tasks.list()[0]!.status).toBe("running");
  });

  test("it reports back and goes idle: done, without the peer's raw words; the assistant relays it", () => {
    const s = setup();
    handOff(s);
    s.claude.session(200, "peer-sess", "builder", "/work/app", "idle");
    s.claude.write("/work/app", "peer-sess", [assistantTool("SendMessage", "m1", { to: "uds:/tmp/cc-socks/100.sock", message: "Installed: the latest build is on his iPhone." }, s.now() + 1000)]);
    s.check();
    expect(s.tasks.list()[0]).toMatchObject({ status: "done", summary: "办好了" });
    expect(s.transitions).toContain("finished:done");
    expect(s.tracker.open()).toHaveLength(0);
    expect(s.notes).toHaveLength(0);
    // the assistant tells the owner itself: no fallback line
    s.advance(60_000);
    s.assistantSpeaks();
    s.advance(10 * 60_000);
    s.tracker.tick();
    expect(s.notes).toHaveLength(0);
  });

  test("a finished handoff nobody relayed: one short Chinese line after 5 minutes", () => {
    const s = setup();
    handOff(s);
    s.claude.session(200, "peer-sess", "builder", "/work/app", "idle");
    s.claude.write("/work/app", "peer-sess", [assistantTool("SendMessage", "m1", { to: "home-ab", message: "Done: shipped v0.1.2." }, s.now() + 1000)]);
    s.check();
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

  test("the session ends without a word: stopped, quietly", () => {
    const s = setup();
    handOff(s);
    s.claude.end(200);
    s.check();
    expect(s.tasks.list()[0]).toMatchObject({ status: "stopped", summary: "对方的会话结束了，没回话" });
    expect(s.tracker.open()).toHaveLength(0);
  });

  test("idle with no reply: noted after a while, given up after a day", () => {
    const s = setup();
    handOff(s);
    s.claude.session(200, "peer-sess", "builder", "/work/app", "idle");
    s.check();
    expect(s.tasks.list()[0]!.status).toBe("running");
    s.advance(3 * 3600_000);
    s.check();
    expect(s.tasks.list()[0]!.summary).toBe("对方停下了，还没回话");
    expect(s.tracker.inFlight()).toBe(false); // idle handoffs don't hold back compaction
    s.advance(25 * 3600_000);
    s.check();
    expect(s.tasks.list()[0]!.status).toBe("stopped");
  });

  test("the owner dismissing the row stops following it", () => {
    const s = setup();
    handOff(s);
    s.tasks.markStopped(s.tasks.list()[0]!.id);
    s.check();
    expect(s.tracker.open()).toHaveLength(0);
  });

  test("survives an assistant restart: the row isn't marked interrupted and tracking goes on", () => {
    const s = setup();
    handOff(s);
    const orphaned = s.tasks.orphanRunning();
    expect(orphaned).toHaveLength(0);
    const again = s.make();
    expect(again.open()).toHaveLength(1);
    expect(again.inFlight()).toBe(true);
  });

  test("report_task(peer) links a row to a session explicitly", () => {
    const s = setup();
    const t = s.tasks.report("ci", "配 CI", "running", "Mac 发版");
    expect(s.tracker.link(t.id, "builder")).toContain("ok");
    expect(s.tasks.get(t.id)!.peer).toBe("builder");
    expect(s.tracker.link(t.id, "nobody")).toContain("找不到");
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

  test("over 200k: compacts once the owner has gone quiet, never mid-exchange", async () => {
    const { hub, driver } = makeHub({ script: compactScript });
    driver.contextTokens = 230_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    expect(hub.conversation.contextTokens).toBe(230_000);
    // the owner just spoke: not a clean break
    expect(hub.conversation.maybeCompact()).toBeNull();
    expect(hub.conversation.maybeCompact({}, later(6))).toBe("tokens");
    await hub.idle();
    expect(driver.last!.sent.at(-1)).toBe("/compact");
    const audit = hub.audit.tail(20);
    expect(audit.find((e) => e.type === "session.compact")).toMatchObject({ reason: "tokens", preTokens: 230_000, postTokens: 18_000 });
    expect(hub.conversation.contextTokens).toBe(18_000);
    // nothing shown or pushed for the housekeeping turn
    expect(hub.chat.recent(20).some((m) => m.text.includes("Compacted"))).toBe(false);
    // and it doesn't repeat
    expect(hub.conversation.maybeCompact({}, later(12))).toBeNull();
  });

  test("not while a turn runs, work is in flight, or under the thresholds", async () => {
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
    expect(hub.conversation.maybeCompact({}, later(10))).toBeNull(); // mid-turn
    release();
    await hub.idle();
    driver.contextTokens = 1000;
    hub.userMessage("快", "app");
    await hub.idle();
    expect(hub.conversation.maybeCompact({}, later(10))).toBeNull(); // small context
  });

  test("idle for hours, or right before the 晨报, with some context built up", async () => {
    const { hub, driver } = makeHub({ script: compactScript, config: testConfig() });
    driver.contextTokens = 60_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    expect(hub.conversation.maybeCompact({}, later(30))).toBeNull(); // quiet, but not for hours
    expect(hub.conversation.maybeCompact({ beforeBrief: true }, later(30))).toBe("brief");
    await hub.idle();
    expect(hub.audit.tail(20).find((e) => e.type === "session.compact")).toMatchObject({ reason: "brief" });
    // after compacting, idle needs new activity first
    expect(hub.conversation.maybeCompact({}, later(4 * 60))).toBeNull();
    hub.userMessage("在吗", "app");
    await hub.idle();
    expect(hub.conversation.maybeCompact({}, later(4 * 60))).toBe("idle");
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
    expect(hub.audit.tail(20).find((e) => e.type === "session.compact")).toMatchObject({ reason: "harness:auto", preTokens: 950_000 });
  });

  test("an open handoff holds compaction back", async () => {
    const { hub, driver } = makeHub({ script: compactScript });
    driver.contextTokens = 230_000;
    hub.userMessage("你好", "app");
    await hub.idle();
    const real = hub.handoffs.inFlight.bind(hub.handoffs);
    (hub.handoffs as any).inFlight = () => true;
    expect(hub.conversation.maybeCompact({}, later(10))).toBeNull();
    (hub.handoffs as any).inFlight = real;
    expect(hub.conversation.maybeCompact({}, later(10))).toBe("tokens");
    await hub.idle();
  });
});

// keep readJsonl referenced for local debugging of audit files
void readJsonl;
