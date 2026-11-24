import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { limitNotice } from "../src/copy.ts";
import { isLimitFailure } from "../src/harness/claude/auth.ts";
import { mapMessage } from "../src/harness/claude/driver.ts";
import type { LimitHit } from "../src/harness/types.ts";
import { setLang } from "../src/i18n/index.ts";
import { type LimitDeps, LimitWatch } from "../src/limitWatch.ts";
import { both, cleanupBoth } from "./bothRuntimes.ts";
import { cleanup, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

// A limit of the plan used up: told from a busy server, what it stopped
// remembered, and gone on with at the reset, unless the owner had a hand in it.

afterAll(cleanupBoth);

const HOUR = 3600_000;
const SEC = 1000;

describe("what Claude Code says of a limit", () => {
  const ev = (rate_limit_info: unknown) => mapMessage({ type: "rate_limit_event", rate_limit_info, uuid: "u", session_id: "s" } as any, { lastCost: 0, contextTokens: 0 });
  test("rate_limit_event: which, until when, and whether it blocks", () => {
    expect(ev({ status: "rejected", rateLimitType: "five_hour", resetsAt: 1_800_000_000 })).toEqual([{ type: "limit", blocked: true, kind: "session", resetsAt: 1_800_000_000_000 }]);
    expect(ev({ status: "allowed_warning", rateLimitType: "seven_day", resetsAt: 1_800_000_000_000 })).toEqual([{ type: "limit", blocked: false, kind: "weekly_all", resetsAt: 1_800_000_000_000 }]);
    expect(ev({ status: "rejected", rateLimitType: "seven_day_opus" })).toEqual([{ type: "limit", blocked: true, kind: "weekly_scoped", scope: "Opus" }]);
    // past it on extra usage, the request went through
    expect(ev({ status: "rejected", rateLimitType: "five_hour", isUsingOverage: true })).toMatchObject([{ blocked: false }]);
    // a kind it doesn't know, nothing at all
    expect(ev({ status: "rejected", rateLimitType: "monthly" })).toEqual([{ type: "limit", blocked: true, kind: "monthly" }]);
    expect(ev(undefined)).toEqual([]);
    expect(ev({ rateLimitType: "five_hour" })).toEqual([]);
  });

  test("its own error line, at its start only", () => {
    expect(isLimitFailure("You've hit your session limit · resets 3pm")).toEqual({});
    expect(isLimitFailure("You’ve reached your weekly Opus limit")).toEqual({});
    expect(isLimitFailure("Claude AI usage limit reached|1800000000")).toEqual({ resetsAt: 1_800_000_000_000 });
    expect(isLimitFailure("5-hour limit reached ∙ resets 3pm")).toEqual({});
    for (const no of ["API Error: 529 Overloaded", "rate limit reached, try again", "I think you've hit your session limit", "You have hit the limit of this API", "请求太多", "", undefined]) expect(isLimitFailure(no)).toBeNull();
  });

  test("how it's told to the owner", () => {
    const now = Date.parse("2026-11-23T08:48:00Z");
    expect(limitNotice({ kind: "session", resetsAt: Date.parse("2026-11-23T10:40:00Z") }, "UTC", now)).toBe("5 小时额度用完了，10:40 恢复，到点我自己接着做。");
    expect(limitNotice({ kind: "weekly_scoped", scope: "Opus", resetsAt: Date.parse("2026-11-26T09:00:00Z") }, "UTC", now)).toBe("本周 Opus 额度用完了，周四 09:00 恢复，到点我自己接着做。");
    expect(limitNotice({ kind: "weekly_all" }, "UTC", now)).toBe("本周额度用完了，恢复后我自己接着做。");
    expect(limitNotice({}, "UTC", now)).toBe("额度用完了，恢复后我自己接着做。");
    setLang("en");
    expect(limitNotice({ kind: "session", resetsAt: Date.parse("2026-11-23T10:40:00Z") }, "UTC", now)).toBe("The 5-hour limit is used up. It's back at 10:40, and I'll carry on by myself then.");
    setLang("zh");
  });
});

describe("remembering and going on", () => {
  function make(path?: string, over: Partial<LimitDeps> = {}) {
    const paths = tmpPaths();
    const c = {
      paths, path: path ?? `${paths.state}/limit.json`, now: 1_800_000_000_000, still: null as number | null | undefined, blocked: false, canGoOn: true,
      resumed: [] as string[], asked: [] as LimitHit[], rand: 0,
    };
    const w = new LimitWatch({
      path: c.path,
      now: () => c.now,
      random: () => c.rand,
      still: async (l) => (c.asked.push(l), c.still),
      blocked: () => c.blocked,
      canGoOn: () => c.canGoOn,
      resume: (m) => void c.resumed.push([...m.palo.map((x) => x.text), ...Object.keys(m.pals), ...m.schedules].join("+")),
      changed: () => {},
      audit: () => {},
      log: () => {},
      ...over,
    });
    return { w, c };
  }
  const at = (w: LimitWatch) => w.status();

  test("each with its own reset, a few seconds apart, once", async () => {
    const { w, c } = make();
    const reset = c.now + 2 * HOUR;
    c.rand = 0.5;
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: reset });
    c.rand = 0;
    w.hit({ kind: "pal", id: "p2", name: "笔记" }, { kind: "session", resetsAt: reset });
    w.hit({ kind: "pal", id: "p3", name: "照片" }, { kind: "weekly_scoped", scope: "Opus", resetsAt: reset + 50 * HOUR });
    expect(at(w)).toEqual({ assistant: false, agents: [{ id: "p1", name: "网站", until: reset }, { id: "p2", name: "笔记", until: reset }, { id: "p3", name: "照片", until: reset + 50 * HOUR }], schedules: 0 });
    c.now = reset + 4 * SEC;
    await w.tick();
    expect(c.resumed).toEqual([]);
    c.now = reset + 5 * SEC;
    await w.tick();
    expect(c.resumed).toEqual(["p2"]);
    c.now = reset + 25 * SEC;
    await w.tick();
    await w.tick();
    expect(c.resumed).toEqual(["p2", "p1"]);
    expect(at(w)?.agents.map((a) => a.id)).toEqual(["p3"]);
    cleanup(c.paths);
  });

  test("the assistant's: what its turns were for, and schedules, together and once each", async () => {
    const { w, c } = make();
    const l = { kind: "session", resetsAt: c.now + HOUR };
    w.hit({ kind: "palo", text: "整理纪要" }, l);
    w.hit({ kind: "palo", text: "晨报: 写晨报", watchId: "w1" }, l);
    w.hit({ kind: "palo", text: "晨报: 写晨报", watchId: "w1" }, l);
    expect(at(w)).toMatchObject({ assistant: true, schedules: 1 });
    c.now += HOUR + 5 * SEC;
    await w.tick();
    expect(c.resumed).toEqual(["整理纪要+w1"]);
    expect(at(w)).toBeUndefined();
    cleanup(c.paths);
  });

  test("kept over a restart of the host; overdue ones a few seconds apart too", async () => {
    const a = make();
    a.w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: a.c.now + HOUR });
    a.w.hit({ kind: "palo", text: "整理纪要" }, { kind: "session", resetsAt: a.c.now + HOUR });
    const b = make(a.c.path);
    b.c.now = a.c.now + 5 * HOUR;
    b.w.start();
    expect(at(b.w)).toMatchObject({ assistant: true, agents: [{ id: "p1" }] });
    await b.w.tick();
    expect(b.c.resumed).toEqual([]);
    b.c.now += 5 * SEC;
    await b.w.tick();
    expect(b.c.resumed).toEqual(["整理纪要", "p1"]);
    b.w.stop();
    const c = make(a.c.path);
    expect(at(c.w)).toBeUndefined();
    for (const x of [a, b, c]) cleanup(x.c.paths);
  });

  test("still limited at its reset: the new reset is waited for, no loop", async () => {
    const { w, c } = make();
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: c.now + HOUR });
    const next = c.now + 6 * HOUR;
    c.still = next;
    c.now += HOUR + 5 * SEC;
    for (let i = 0; i < 5; i++) await w.tick();
    expect(c.asked).toHaveLength(1);
    expect(at(w)?.agents[0]?.until).toBe(next);
    c.still = null;
    c.now = next + 5 * SEC;
    await w.tick();
    expect(c.resumed).toEqual(["p1"]);
    cleanup(c.paths);
  });

  test("no numbers to ask: tried once; failing again with no new reset, half an hour later", async () => {
    const { w, c } = make();
    c.still = undefined;
    const stale = c.now + HOUR;
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: stale });
    c.now = stale + 5 * SEC;
    await w.tick();
    expect(c.resumed).toEqual(["p1"]);
    // the try fails, naming the reset that has passed
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: stale });
    await w.tick();
    c.now += 29 * 60 * SEC;
    await w.tick();
    expect(at(w)?.agents[0]?.until).toBeGreaterThan(c.now); // never a time that's past
    expect(c.resumed).toEqual(["p1"]);
    c.now += 61 * SEC + 5 * SEC;
    await w.tick();
    expect(c.resumed).toEqual(["p1", "p1"]);
    cleanup(c.paths);
  });

  test("what the owner does in between: nothing of it goes on", async () => {
    const { w, c } = make();
    const l = { kind: "session", resetsAt: c.now + HOUR };
    const go = async () => {
      c.now = l.resetsAt + 10 * SEC;
      await w.tick();
      return c.resumed;
    };
    w.hit({ kind: "pal", id: "p1", name: "网站" }, l);
    w.forget("p1");
    w.hit({ kind: "pal", id: "p2", name: "笔记" }, l);
    w.settled({ pal: "p2" }); // its turn went through meanwhile
    w.hit({ kind: "palo", text: "整理纪要" }, l);
    w.forget(null);
    expect(await go()).toEqual([]);
    expect(c.asked).toEqual([]);
    cleanup(c.paths);
  });

  test("the owner speaks to the assistant: not resumed behind those words; met by the limit too, both are", async () => {
    const { w, c } = make();
    const l = { kind: "session", resetsAt: c.now + HOUR };
    w.hit({ kind: "palo", text: "第一件" }, l);
    w.ownerSpoke();
    expect(at(w)).toBeUndefined(); // it isn't said to be stopped while it answers
    c.now = l.resetsAt + 10 * SEC;
    await w.tick();
    expect(c.resumed).toEqual([]);
    const again = { kind: "session", resetsAt: c.now + HOUR };
    w.hit({ kind: "palo", text: "第二件" }, again);
    c.now = again.resetsAt + 10 * SEC;
    await w.tick();
    expect(c.resumed).toEqual(["第一件+第二件"]);
    // answered: gone
    w.hit({ kind: "palo", text: "第三件" }, { kind: "session", resetsAt: c.now + HOUR });
    w.ownerSpoke();
    w.settled("palo");
    c.now += 2 * HOUR;
    await w.tick();
    expect(c.resumed).toHaveLength(1);
    cleanup(c.paths);
  });

  test("the owner acts while it's being asked whether it's still limited", async () => {
    const { w, c } = make(undefined, { still: async () => (w.forget("p1"), null) });
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: c.now + HOUR });
    c.now += 2 * HOUR;
    await w.tick();
    expect(c.resumed).toEqual([]);
    cleanup(c.paths);
  });

  test("an agent that can't be told to go on is let be; no login: a minute later", async () => {
    const { w, c } = make();
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: c.now + HOUR });
    c.now += 2 * HOUR;
    c.blocked = true;
    await w.tick();
    expect(at(w)?.agents).toHaveLength(1);
    c.blocked = false;
    await w.tick();
    expect(at(w)?.agents).toHaveLength(1);
    c.now += 60 * SEC;
    c.canGoOn = false;
    await w.tick();
    expect(c.resumed).toEqual([]);
    expect(at(w)).toBeUndefined();
    cleanup(c.paths);
  });

  test("checks wait only for a limit on everything", () => {
    const { w, c } = make();
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "weekly_scoped", scope: "Opus", resetsAt: c.now + HOUR });
    expect(w.everything).toBe(false);
    w.hit({ kind: "pal", id: "p2", name: "笔记" }, { kind: "weekly_all", resetsAt: c.now + HOUR });
    expect(w.everything).toBe(true);
    c.now += 2 * HOUR;
    expect(w.everything).toBe(false);
    cleanup(c.paths);
  });
});

describe("on the host", () => {
  const FAIL = { text: "You've hit your session limit · resets 7pm", category: "rate_limit" };
  const BUSY = { text: "API Error: 429 rate_limit_error", category: "rate_limit" };

  /** A host whose limits' clock the test moves. */
  function host(o: { spawn?: boolean } = {}) {
    let shift = 0;
    const h = both({ ...o, limits: { now: () => Date.now() + shift, random: () => 0, still: async () => null } });
    const reset = Date.now() + 2 * HOUR;
    const limited = () => {
      h.driver.limit = { blocked: true, kind: "session", resetsAt: reset };
      h.driver.resultError = FAIL;
    };
    const free = () => {
      h.driver.limit = { blocked: false, kind: "session" };
      h.driver.resultError = undefined;
    };
    /** Past the reset: what's due goes on. */
    const later = async () => {
      shift = 2 * HOUR + 10 * SEC;
      free();
      await h.hub.limits.tick();
      await h.hub.idle();
      await tick(30);
    };
    const stopped = () => h.hub.usageStatus().stopped;
    const notices = () => h.hub.chat.recent(30).filter((m) => m.kind === "notice").map((m) => m.text);
    const told = (id: string) => h.driver.pals.filter((p) => p.sessionId === h.pal(id).rec.sessionId).flatMap((p) => p.sent);
    const send = async (id: string, text: string) => {
      await h.call("pals.send", { id, text });
      await waitFor(() => !h.pal(id).busy);
      await tick(10);
    };
    const end = () => {
      h.hub.stop();
      cleanup(h.paths);
    };
    return { ...h, reset, limited, free, later, stopped, notices, told, send, end };
  }
  const goesOn = (x: string[]) => x.filter((t) => t.includes("请从断的地方接着做")).length;

  test("an agent and the assistant stop on it, are told so, and go on at the reset", async () => {
    const h = host();
    const a = await h.agent();
    h.limited();
    await h.send(a.id, "跑测试");
    h.hub.userMessage("帮我整理纪要", "app");
    await h.hub.idle();
    await tick(10);
    expect(h.stopped()).toMatchObject({ assistant: true, agents: [{ id: a.id, until: h.reset }] });
    expect(h.said(a.id).at(-1)).toContain("5 小时额度用完了");
    expect(h.notices().at(-1)).toContain("到点我自己接着做");
    expect(h.notices().join()).not.toContain("太忙");
    expect(JSON.parse(readFileSync(`${h.paths.state}/limit.json`, "utf8")).agents[a.id].name).toBe(h.pal(a.id).rec.name);
    expect(h.events.filter((e) => e.event === "usage.updated").at(-1)?.data.usage.stopped.assistant).toBe(true);
    await h.later();
    await waitFor(() => goesOn(h.told(a.id)) === 1);
    expect(h.driver.sessions.flatMap((s) => s.sent).join("\n")).toContain("帮我整理纪要");
    expect(h.stopped()).toBeUndefined();
    h.end();
  });

  test("a busy server is still a busy server: with the limit open, or nothing said of limits", async () => {
    const h = host();
    h.driver.limit = { blocked: false, kind: "session" };
    h.driver.resultError = BUSY;
    h.hub.userMessage("在吗", "app");
    await h.hub.idle();
    expect(h.notices().at(-1)).toContain("太忙");
    h.driver.limit = undefined;
    h.hub.userMessage("在吗", "app");
    await h.hub.idle();
    expect(h.notices().at(-1)).toContain("太忙");
    // overloaded while a limit is used up: not the limit
    h.limited();
    h.driver.resultError = { text: "Overloaded", category: "overloaded" };
    h.hub.userMessage("在吗", "app");
    await h.hub.idle();
    expect(h.notices().at(-1)).toContain("太忙");
    // an error of no kind (a crash) while it is, and its words in a reply that went through
    h.driver.resultError = { text: "Claude Code process exited with code 1" };
    h.hub.userMessage("在吗", "app");
    await h.hub.idle();
    expect(h.stopped()).toBeUndefined();
    h.driver.resultError = undefined;
    h.hub.userMessage("You've hit your session limit 是什么意思", "app");
    await h.hub.idle();
    expect(h.stopped()).toBeUndefined();
    h.end();
  });

  test("a process that says nothing of limits: by the error's own words", async () => {
    const h = host();
    h.driver.resultError = FAIL;
    const a = await h.agent();
    await h.send(a.id, "跑测试");
    expect(h.stopped()).toMatchObject({ agents: [{ id: a.id }] });
    expect(h.said(a.id).at(-1)).toContain("额度用完了，恢复后我自己接着做");
    h.end();
  });

  test("停止, a new message, an archive, a terminal, going back: not resumed", async () => {
    for (const act of ["pals.stop", "pals.send", "pals.end", "pals.remove", "pals.openTerminal"]) {
      const h = host();
      const a = await h.agent();
      h.limited();
      await h.send(a.id, "跑测试");
      expect(h.stopped()?.agents).toHaveLength(1);
      h.free();
      await h.call(act, { id: a.id, text: "算了，先看看别的", force: true });
      await tick(30);
      expect(h.stopped(), act).toBeUndefined();
      const sent = h.driver.pals.flatMap((p) => p.sent);
      await h.later();
      expect(goesOn(h.driver.pals.flatMap((p) => p.sent)), act).toBe(0);
      expect(h.driver.pals.flatMap((p) => p.sent).length, act).toBe(sent.length);
      h.end();
    }
  });

  test("a message that meets the limit too is remembered afresh", async () => {
    const h = host();
    const a = await h.agent();
    h.limited();
    await h.send(a.id, "跑测试");
    await h.send(a.id, "还在吗");
    expect(h.stopped()?.agents).toHaveLength(1);
    await h.later();
    await waitFor(() => goesOn(h.told(a.id)) === 1);
    h.end();
  });

  test("held already: a scheduled run and an agent's own turn say nothing more; the owner's words do", async () => {
    const h = host();
    const w = h.hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["08:00"] }, "user");
    const run = async () => {
      (h.hub as any).onSchedule(w);
      await h.hub.idle();
      await tick(10);
    };
    const lines = () => h.notices().filter((t) => t.includes("额度用完了")).length;
    h.limited();
    await run(); // the first to meet it: said
    expect(lines()).toBe(1);
    await run();
    await run();
    expect(lines()).toBe(1);
    expect(h.stopped()).toMatchObject({ assistant: true, schedules: 1 });
    h.hub.userMessage("在吗", "app");
    await h.hub.idle();
    expect(lines()).toBe(2);
    await run();
    expect(lines()).toBe(2);
    // another limit is news
    h.driver.limit = { blocked: false, kind: "session" };
    h.hub.conversation.onHarnessEvent({ type: "limit", blocked: false, kind: "session" });
    h.driver.limit = { blocked: true, kind: "weekly_all", resetsAt: h.reset };
    await run();
    expect(lines()).toBe(3);
    // an agent: the assistant's words to it, held already, add nothing; the owner's do
    const a = await h.agent();
    const said = () => h.said(a.id).filter((t) => t.includes("额度用完了")).length;
    h.driver.limit = { blocked: true, kind: "session", resetsAt: h.reset };
    await h.send(a.id, "跑测试");
    expect(said()).toBe(1);
    await h.hub.pals.toolSend({ name: a.id, text: "怎么样了" });
    await waitFor(() => !h.pal(a.id).busy);
    await tick(10);
    expect(said()).toBe(1);
    expect(h.stopped()?.agents).toHaveLength(1);
    await h.send(a.id, "还在吗");
    expect(said()).toBe(2);
    h.end();
  });

  const at = (n: number) => new Date(Date.parse("2026-11-01T08:00:00Z") + n * 1000).toISOString();
  const userE = (uuid: string, parentUuid: string | null, text: string, n: number) => ({ type: "user", uuid, parentUuid, timestamp: at(n), message: { role: "user", content: text }, origin: { kind: "human" } });
  const replyE = (uuid: string, parentUuid: string, text: string, n: number) => ({ type: "assistant", uuid, parentUuid, timestamp: at(n), message: { id: `msg_${uuid}`, role: "assistant", model: "claude-haiku-4-5", content: [{ type: "text", text }] } });

  test("going back in an agent's conversation, and in the assistant's: not resumed", async () => {
    const h = host();
    const sid = "ffff7777-0000-4000-8000-000000000001";
    h.cli.bg({ sessionId: sid, name: "网站", cwd: h.project });
    h.claude.transcript(h.project, sid, [userE("p1", null, "先建", 0), replyE("r1", "p1", "建好了", 1), userE("p2", "r1", "跑测试", 10)]);
    const { pal } = await h.call("pals.adopt", { sessionId: sid });
    h.limited();
    await h.send(pal.id, "跑测试");
    const msg = h.hub.userMessage("帮我整理纪要", "app")!;
    await h.hub.idle();
    expect(h.stopped()).toMatchObject({ assistant: true, agents: [{ id: pal.id }] });
    await h.call("pals.rewind", { id: pal.id, messageId: "p2" });
    expect(h.stopped()).toMatchObject({ assistant: true, agents: [] });
    h.claude.transcript(h.paths.home, (h.hub as any).runtime.data.sessionId, [userE("a1", null, "早", 0), replyE("a2", "a1", "早", 1), userE(msg.uuid!, "a2", "帮我整理纪要", 2)]);
    await h.call("chat.rewind", { messageId: msg.id });
    expect(h.stopped()).toBeUndefined();
    h.end();
  });

  test("opened in a terminal by hand: not resumed, not when it comes back either", async () => {
    const h = host({ spawn: true });
    const a = await h.agent();
    h.limited();
    await h.send(a.id, "跑测试");
    expect(h.stopped()?.agents).toHaveLength(1);
    const term = spawn("/bin/sleep", ["60"]);
    h.claude.register({ sessionId: a.sessionId, name: a.name, cwd: h.project, pid: term.pid });
    await waitFor(() => h.statusOf(a.id) === "stopped", 3_000);
    expect(h.stopped()).toBeUndefined();
    const gone = new Promise((r) => term.on("exit", r));
    term.kill("SIGKILL");
    await gone;
    h.claude.unregister(a.sessionId);
    await h.later();
    expect(goesOn(h.driver.pals.flatMap((p) => p.sent))).toBe(0);
    await h.hub.pals.stopAndWait();
    h.end();
  });

  test("whether an agent can be told to go on, as it stands", async () => {
    const h = host();
    const a = await h.agent();
    expect(h.hub.pals.canGoOn(a.id)).toBe(true);
    expect(h.hub.pals.canGoOn("pal_none")).toBe(false);
    h.driver.palScript = async (_t, ctx) => void (await ctx.interrupted);
    await h.call("pals.send", { id: a.id, text: "慢慢做" });
    await waitFor(() => h.pal(a.id).busy);
    expect(h.hub.pals.canGoOn(a.id)).toBe(false); // at work
    await h.call("pals.stop", { id: a.id });
    await waitFor(() => !h.pal(a.id).busy);
    expect(h.hub.pals.canGoOn(a.id)).toBe(true);
    await h.call("pals.openTerminal", { id: a.id, force: true });
    expect(h.hub.pals.canGoOn(a.id)).toBe(false);
    h.end();
  });

  test("by its own timer", async () => {
    const paths = tmpPaths();
    const resumed: string[] = [];
    const now = Date.now();
    const w = new LimitWatch({
      path: `${paths.state}/limit.json`, random: () => 0, now: () => now + 4_900 + (Date.now() - now), still: async () => null, blocked: () => false, canGoOn: () => true,
      resume: (m) => void resumed.push(...Object.keys(m.pals)), changed: () => {}, audit: () => {}, log: () => {},
    });
    w.hit({ kind: "pal", id: "p1", name: "网站" }, { kind: "session", resetsAt: now + 4_900 + 50 });
    (w as any).s.agents.p1.due = now + 4_900 + 120;
    w.start();
    await waitFor(() => resumed.length === 1, 2_000);
    expect(w.status()).toBeUndefined();
    w.stop();
    cleanup(paths);
  });

  test("compacted meanwhile: still to go on", async () => {
    const h = host();
    const a = await h.agent();
    h.limited();
    await h.send(a.id, "跑测试");
    h.free();
    await h.call("pals.compact", { id: a.id });
    await waitFor(() => !h.pal(a.id).busy);
    await tick(10);
    expect(h.stopped()?.agents).toHaveLength(1);
    await h.later();
    await waitFor(() => goesOn(h.told(a.id)) === 1);
    h.end();
  });

  test("停止 on the assistant: nothing of it goes on", async () => {
    const h = host();
    h.limited();
    h.hub.userMessage("帮我整理纪要", "app");
    await h.hub.idle();
    expect(h.stopped()?.assistant).toBe(true);
    await h.call("stop");
    expect(h.stopped()).toBeUndefined();
    const n = h.driver.sessions.flatMap((s) => s.sent).length;
    await h.later();
    expect(h.driver.sessions.flatMap((s) => s.sent).length).toBe(n);
    h.end();
  });

  test("a schedule that met it runs once; one turned off meanwhile doesn't", async () => {
    const h = host();
    const w = h.hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["08:00"] }, "user");
    const off = h.hub.watches.add({ title: "晚报", instruction: "写晚报", at: ["20:00"] }, "user");
    h.limited();
    (h.hub as any).onSchedule(w);
    await h.hub.idle();
    (h.hub as any).onSchedule(off);
    await h.hub.idle();
    expect(h.stopped()).toMatchObject({ assistant: true, schedules: 2 });
    h.hub.watches.update(off.id, { enabled: false } as any);
    const before = h.driver.sessions.flatMap((s) => s.sent).length;
    await h.later();
    const after = h.driver.sessions.flatMap((s) => s.sent).slice(before).join("\n");
    expect(after).toContain("写晨报");
    expect(after).not.toContain("写晚报");
    h.end();
  });

  test("the numbers say used up at once, and whether there's room again is asked of them", async () => {
    const h = host();
    const row = (used: number, resetsAt = h.reset) => ({ plan: "limits" as const, account: { email: "lin@example.com" }, limits: [{ kind: "session", group: "session", used, resetsAt }] });
    h.driver.plan = () => row(97);
    h.hub.conversation.ensureSession();
    await tick(10);
    h.limited();
    h.hub.userMessage("在吗", "app");
    await h.hub.idle();
    expect(h.hub.usageStatus().limits[0]).toMatchObject({ used: 100, resetsAt: h.reset });
    const pu = h.hub.planUsage;
    h.driver.plan = () => row(100, h.reset + 5 * HOUR);
    expect(await pu.still({ kind: "session" })).toBe(h.reset + 5 * HOUR);
    h.driver.plan = () => row(3);
    expect(await pu.still({ kind: "session" })).toBeNull();
    h.driver.plan = () => ({ plan: "limits" as const, limits: [{ kind: "weekly_all", group: "weekly", used: 100, resetsAt: h.reset }, { kind: "weekly_scoped", group: "weekly", used: 100, resetsAt: h.reset, scope: "Opus" }] });
    expect(await pu.still({ kind: "session" })).toBe(h.reset); // another one, for everything, stops it as well
    h.driver.plan = () => { throw new Error("x"); };
    expect(await pu.still({ kind: "session" })).toBeUndefined();
    h.end();
  });
});
