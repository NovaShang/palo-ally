import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { Bus } from "../src/bus.ts";
import { FakeDriver } from "./fakeDriver.ts";
import { ProbeScheduler, dueSlot, nextRunAt, probeHealth, type ProbeHost, type ProbeTrigger } from "../src/probe.ts";
import type { Watch } from "../src/types.ts";
import { inWindow, parseHHMM, zonedParts } from "../src/util.ts";
import { WatchStore, scheduleText } from "../src/watches.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

const T0 = Date.UTC(2026, 9, 4, 9, 0); // 2026-10-04 09:00 UTC

const hosts = new Map<FakeDriver, ProbeHost>();
const hostOf = (m: { driver: FakeDriver }) => hosts.get(m.driver)!;

function mk(over: Partial<ProbeHost> = {}) {
  const paths = tmpPaths();
  const driver = new FakeDriver();
  const watches = new WatchStore(paths.watches, new Bus());
  const fired: Watch[] = [];
  const triggers: ProbeTrigger[][] = [];
  let spent = 0;
  let lastActivity = 0;
  const host: ProbeHost = {
    driver,
    watches,
    timezone: () => "UTC",
    probeModel: () => "cheap",
    cwd: () => paths.home,
    mcpServers: () => ({}),
    inheritConnectors: () => false,
    lastUserActivity: () => lastActivity,
    budgetLeftUsd: () => 1 - spent,
    spend: (u) => (spent += u),
    onSchedule: (w) => fired.push(w),
    onTriggers: (t) => triggers.push(t),
    log: () => {},
    ...over,
  };
  hosts.set(driver, host);
  return {
    probe: new ProbeScheduler(host),
    driver,
    watches,
    fired,
    triggers,
    paths,
    setActivity: (t: number) => (lastActivity = t),
    spent: () => spent,
  };
}

describe("time helpers", () => {
  test("zoned parts and windows", () => {
    const p = zonedParts(Date.UTC(2026, 0, 1, 7, 30), "Asia/Shanghai");
    expect(p.hour).toBe(15);
    expect(p.dateKey).toBe("2026-01-01");
    expect(parseHHMM("8:05")).toBe(485);
    expect(parseHHMM("25:00")).toBeNull();
    expect(inWindow(parseHHMM("23:30")!, parseHHMM("23:00")!, parseHHMM("08:00")!)).toBe(true);
    expect(inWindow(parseHHMM("07:59")!, parseHHMM("23:00")!, parseHHMM("08:00")!)).toBe(true);
    expect(inWindow(parseHHMM("12:00")!, parseHHMM("23:00")!, parseHHMM("08:00")!)).toBe(false);
  });
});

describe("dueSlot", () => {
  const w = (over: Partial<Watch>): Watch => ({ id: "w", title: "t", kind: "schedule", instruction: "i", enabled: true, createdBy: "user", createdAt: 0, ...over });

  test("fires once at/after the slot, within catch-up, never before creation", () => {
    expect(dueSlot(w({ at: ["08:30"] }), T0, "UTC")).toBe("2026-10-04 08:30");
    expect(dueSlot(w({ at: ["08:30"], firedSlots: ["2026-10-04 08:30"] }), T0, "UTC")).toBeNull();
    expect(dueSlot(w({ at: ["10:00"] }), T0, "UTC")).toBeNull();
    // created at 08:45: the 08:30 slot today predates it
    expect(dueSlot(w({ at: ["08:30"], createdAt: T0 - 15 * 60_000 }), T0, "UTC")).toBeNull();
    // missed by more than 6h: skipped
    expect(dueSlot(w({ at: ["01:00"] }), T0 + 0, "UTC")).toBeNull();
  });

  test("slot just before midnight is caught up after it", () => {
    const now = Date.UTC(2026, 9, 5, 1, 0);
    expect(dueSlot(w({ at: ["22:30"] }), now, "UTC")).toBe("2026-10-04 22:30");
  });

  test("respects the timezone", () => {
    // 09:00 UTC is 17:00 in Shanghai
    expect(dueSlot(w({ at: ["16:55"] }), T0, "Asia/Shanghai")).toBe("2026-10-04 16:55");
    expect(dueSlot(w({ at: ["08:30"] }), T0, "Asia/Shanghai")).toBeNull();
  });

  test("monthly: only on the month's day, last day and short months included", () => {
    const at = (y: number, m: number, d: number, hh = 9, mm = 5) => Date.UTC(y, m - 1, d, hh, mm);
    const first = w({ at: ["09:00"], dayOfMonth: 1 });
    expect(dueSlot(first, at(2026, 11, 1), "UTC")).toBe("2026-11-01 09:00");
    expect(dueSlot(first, at(2026, 11, 2), "UTC")).toBeNull();
    const mid = w({ at: ["09:00"], dayOfMonth: 15 });
    expect(dueSlot(mid, at(2026, 10, 15), "UTC")).toBe("2026-10-15 09:00");
    expect(dueSlot(mid, at(2026, 10, 14), "UTC")).toBeNull();

    const last = w({ at: ["20:00"], dayOfMonth: -1 });
    const eve = (y: number, m: number, d: number) => at(y, m, d, 20, 5);
    expect(dueSlot(last, eve(2026, 10, 31), "UTC")).toBe("2026-10-31 20:00"); // 31-day month
    expect(dueSlot(last, eve(2026, 10, 30), "UTC")).toBeNull();
    expect(dueSlot(last, eve(2026, 11, 30), "UTC")).toBe("2026-11-30 20:00"); // 30-day month
    expect(dueSlot(last, eve(2027, 2, 28), "UTC")).toBe("2027-02-28 20:00"); // February
    expect(dueSlot(last, eve(2028, 2, 28), "UTC")).toBeNull(); // leap year: not yet
    expect(dueSlot(last, eve(2028, 2, 29), "UTC")).toBe("2028-02-29 20:00");

    // the 31st (or 29th) in a shorter month falls on its last day
    const d31 = w({ at: ["09:00"], dayOfMonth: 31 });
    expect(dueSlot(d31, at(2026, 11, 30), "UTC")).toBe("2026-11-30 09:00");
    expect(dueSlot(d31, at(2026, 11, 29), "UTC")).toBeNull();
    expect(dueSlot(d31, at(2026, 12, 30), "UTC")).toBeNull();
    expect(dueSlot(d31, at(2026, 12, 31), "UTC")).toBe("2026-12-31 09:00");
    expect(dueSlot(w({ at: ["09:00"], dayOfMonth: 29 }), at(2027, 2, 28), "UTC")).toBe("2027-02-28 09:00");
  });

  test("monthly: a month-end slot before midnight is caught up in the next month", () => {
    expect(dueSlot(w({ at: ["23:30"], dayOfMonth: -1 }), Date.UTC(2026, 10, 1, 1, 0), "UTC")).toBe("2026-10-31 23:30");
    expect(dueSlot(w({ at: ["23:30"], dayOfMonth: 1 }), Date.UTC(2026, 10, 1, 1, 0), "UTC")).toBeNull();
  });

  test("monthly: wall-clock time across DST changes", () => {
    // 2026-11-01: US clocks fall back at 02:00; 09:05 PST is 17:05 UTC
    expect(dueSlot(w({ at: ["09:00"], dayOfMonth: 1 }), Date.UTC(2026, 10, 1, 17, 5), "America/Los_Angeles")).toBe("2026-11-01 09:00");
    // 2027-03-14: clocks spring forward; 09:05 PDT is 16:05 UTC
    expect(dueSlot(w({ at: ["09:00"], dayOfMonth: 14 }), Date.UTC(2027, 2, 14, 16, 5), "America/Los_Angeles")).toBe("2027-03-14 09:00");
    expect(dueSlot(w({ at: ["09:00"], dayOfMonth: 14 }), Date.UTC(2027, 2, 13, 17, 5), "America/Los_Angeles")).toBeNull();
  });

  test("interval schedules", () => {
    expect(dueSlot(w({ intervalMinutes: 60, lastCheckedAt: T0 - 30 * 60_000 }), T0, "UTC")).toBeNull();
    expect(dueSlot(w({ intervalMinutes: 60, lastCheckedAt: T0 - 61 * 60_000 }), T0, "UTC")).not.toBeNull();
  });
});

describe("monthly watches", () => {
  test("validates the day and needs an at time", () => {
    const paths = tmpPaths();
    const store = new WatchStore(paths.watches, new Bus());
    const base = { title: "月底对账", instruction: "整理 daycare 账单" };
    expect(() => store.add({ ...base, at: ["20:00"], dayOfMonth: 32 }, "agent")).toThrow("day_of_month");
    expect(() => store.add({ ...base, at: ["20:00"], dayOfMonth: -2 }, "agent")).toThrow("day_of_month");
    expect(() => store.add({ ...base, kind: "schedule", intervalMinutes: 60, dayOfMonth: 1 }, "agent")).toThrow("at");
    expect(() => store.add({ ...base, kind: "check", at: ["20:00"], dayOfMonth: 1 }, "agent")).toThrow();
    const m = store.add({ ...base, at: ["20:00"], dayOfMonth: -1 }, "agent");
    expect(m.kind).toBe("schedule");
    expect(scheduleText(m)).toBe("每月最后一天 20:00");
    // a daily goal moved to monthly in place keeps its progress
    const d = store.add({ title: "财务复盘", instruction: "看上个月的支出", at: ["09:00"] }, "agent");
    store.progress(d.id, "上个月花得不多");
    const moved = store.update(d.id, { dayOfMonth: 1 });
    expect(scheduleText(moved)).toBe("每月 1 号 09:00");
    expect(moved.progress).toBe("上个月花得不多");
    // null (from the app) or 0 (from the assistant) clears it
    expect(store.update(d.id, { dayOfMonth: null as unknown as number }).dayOfMonth).toBeUndefined();
    store.update(d.id, { dayOfMonth: 15 });
    expect(scheduleText(store.update(d.id, { dayOfMonth: 0 }))).toBe("每天 09:00");
    cleanup(paths);
  });
});

describe("ProbeScheduler", () => {
  test("ticks with nothing due make zero model calls", async () => {
    const { probe, driver, paths } = mk();
    const r = await probe.tick(T0);
    expect(r).toEqual({ scheduled: 0, checked: 0, triggered: 0 });
    expect(driver.probes).toHaveLength(0);
    cleanup(paths);
  });

  test("due checks run one short probe; triggers dedupe by key; cursor persists", async () => {
    const { probe, driver, watches, triggers, paths } = mk();
    const a = watches.add({ title: "老板邮件", instruction: "查 boss@x.com 的新邮件", intervalMinutes: 30 }, "agent");
    const b = watches.add({ title: "网页", instruction: "看 x.com 是否更新", intervalMinutes: 30 }, "agent");
    driver.probeResponder = () => ({
      output: { results: [{ watch_id: a.id, triggered: true, key: "msg-1", summary: "老板发来合同", cursor: "c1" }, { watch_id: b.id, triggered: false }] },
      costUsd: 0.001,
    });
    let r = await probe.tick(T0);
    expect(r.checked).toBe(2);
    expect(r.triggered).toBe(1);
    expect(driver.probes).toHaveLength(1);
    expect(driver.probes[0]!.model).toBe("cheap");
    expect(driver.probes[0]!.strictMcp).toBe(true);
    expect(driver.probes[0]!.prompt).toContain("boss@x.com");
    expect(triggers[0]![0]!.summary).toBe("老板发来合同");
    expect(watches.get(a.id)!.cursor).toBe("c1");

    // not due again within the interval
    r = await probe.tick(T0 + 10 * 60_000);
    expect(driver.probes).toHaveLength(1);

    // due again, same key → no second trigger
    r = await probe.tick(T0 + 31 * 60_000);
    expect(driver.probes).toHaveLength(2);
    expect(driver.probes[1]!.prompt).toContain("msg-1"); // recent_keys handed to the probe
    expect(r.triggered).toBe(0);
    expect(triggers).toHaveLength(1);
    cleanup(paths);
  });

  test("probe asks the harness for short context and loads only read tools", async () => {
    const { probe, driver, watches, paths } = mk();
    watches.add({ title: "x", instruction: "y", intervalMinutes: 5 }, "agent");
    await probe.tick(T0);
    const req = driver.probes[0]!;
    expect(req.tools).toEqual(["Read", "Glob", "Grep", "WebFetch", "WebSearch"]);
    expect(req.strictMcp).toBe(true);
    cleanup(paths);
  });

  test("budget exhausted skips the probe; errors back off a full interval", async () => {
    const { probe, driver, watches, paths } = mk({ budgetLeftUsd: () => 0 });
    watches.add({ title: "x", instruction: "y", intervalMinutes: 5 }, "agent");
    await probe.tick(T0);
    expect(driver.probes).toHaveLength(0);
    cleanup(paths);

    const m2 = mk();
    const w = m2.watches.add({ title: "x", instruction: "y", intervalMinutes: 5 }, "agent");
    m2.driver.probeResponder = () => ({ output: undefined, costUsd: 0.002, error: "rate limited" });
    await m2.probe.tick(T0);
    expect(m2.watches.get(w.id)!.lastCheckedAt).toBe(T0);
    expect(m2.spent()).toBeCloseTo(0.002);
    cleanup(m2.paths);
  });

  test("check watches already overdue run on the first tick after a restart", async () => {
    const first = mk();
    const a = first.watches.add({ title: "a", instruction: "x", intervalMinutes: 5 }, "agent");
    const b = first.watches.add({ title: "b", instruction: "y", intervalMinutes: 15 }, "agent");
    first.watches.touch(a.id, { lastCheckedAt: T0 - 60 * 60_000 });
    first.watches.touch(b.id, { lastCheckedAt: T0 - 5 * 60_000 }); // not due yet
    // a restart: new store over the same file, new scheduler
    const again = mk();
    const watches = new WatchStore(first.paths.watches, new Bus());
    const probe = new ProbeScheduler({ ...hostOf(again), watches });
    const r = await probe.tick(T0);
    expect(r.checked).toBe(1);
    expect(again.driver.probes[0]!.prompt).toContain(a.id);
    expect(again.driver.probes[0]!.prompt).not.toContain(b.id);
    expect(watches.get(a.id)!.lastResult).toEqual({ at: T0, ok: true });
    expect(nextRunAt(watches.get(a.id)!, T0)).toBe(T0 + 5 * 60_000);
    cleanup(first.paths);
    cleanup(again.paths);
  });

  test("a used-up budget is recorded on each goal, audited, and announced once a day", async () => {
    const audits: [string, Record<string, unknown>][] = [];
    const paused: string[] = [];
    const m = mk({
      budgetLeftUsd: () => 0,
      budgetUsd: () => 5,
      audit: (t, d) => audits.push([t, d]),
      onPaused: (reason, due) => paused.push(`${reason}|${due.length}`),
    });
    const w = m.watches.add({ title: "x", instruction: "y", intervalMinutes: 5 }, "agent");
    await m.probe.tick(T0);
    await m.probe.tick(T0 + 60_000);
    await m.probe.tick(T0 + 2 * 60_000);
    expect(m.driver.probes).toHaveLength(0);
    expect(paused).toEqual(["今天的探针预算（$5）用完了，明天再查|1"]);
    expect(audits.filter(([t]) => t === "probe.skipped")).toHaveLength(1);
    expect(m.watches.get(w.id)!.lastResult).toMatchObject({ ok: false, reason: "今天的探针预算（$5）用完了，明天再查" });
    await m.probe.tick(T0 + 24 * 3600_000); // the next day: said again
    expect(paused).toHaveLength(2);
    cleanup(m.paths);
  });

  test("probe errors are recorded on the goal and audited; runs are audited too", async () => {
    const audits: [string, Record<string, unknown>][] = [];
    const m = mk({ audit: (t, d) => audits.push([t, d]) });
    const w = m.watches.add({ title: "x", instruction: "y", intervalMinutes: 5 }, "agent");
    m.driver.probeResponder = () => ({ output: undefined, costUsd: 0, error: "You've hit your weekly limit" });
    await m.probe.tick(T0);
    expect(m.watches.get(w.id)!.lastResult).toEqual({ at: T0, ok: false, reason: "You've hit your weekly limit" });
    expect(audits.map(([t]) => t)).toEqual(["probe.error"]);
    expect(probeHealth(m.watches.list(), T0)).toMatchObject({ checks: 1, failing: 1, stale: 0, reasons: ["You've hit your weekly limit"] });

    m.driver.probeResponder = () => ({ output: { results: [{ watch_id: w.id, triggered: false }] }, costUsd: 0.01 });
    await m.probe.tick(T0 + 6 * 60_000);
    expect(m.watches.get(w.id)!.lastResult).toEqual({ at: T0 + 6 * 60_000, ok: true });
    expect(audits.at(-1)![0]).toBe("probe.run");
    expect(probeHealth(m.watches.list(), T0 + 6 * 60_000)).toMatchObject({ failing: 0, lastRunAt: T0 + 6 * 60_000 });
    // gone quiet for more than two intervals: stale
    expect(probeHealth(m.watches.list(), T0 + 30 * 60_000).stale).toBe(1);
    cleanup(m.paths);
  });

  test("schedule watches fire without a probe; skipIfActive suppresses", async () => {
    const { probe, driver, watches, fired, paths, setActivity } = mk();
    const w = watches.add({ title: "晨报", instruction: "写晨报", at: ["08:30"], skipIfActiveMinutes: 45 }, "user");
    watches.touch(w.id, { createdAt: 0 });
    await probe.tick(T0);
    expect(fired.map((x) => x.title)).toEqual(["晨报"]);
    expect(driver.probes).toHaveLength(0);
    await probe.tick(T0 + 60_000);
    expect(fired).toHaveLength(1); // once per slot

    const g = watches.add({ title: "打招呼", instruction: "hi", at: ["08:45"], skipIfActiveMinutes: 45 }, "user");
    watches.touch(g.id, { createdAt: 0 });
    setActivity(T0 - 10 * 60_000);
    await probe.tick(T0 + 2 * 60_000);
    expect(fired).toHaveLength(1);
    expect(watches.get(g.id)!.firedSlots).toContain("2026-10-04 08:45");
    cleanup(paths);
  });



  test("watch validation", () => {
    const { watches, paths } = mk();
    expect(() => watches.add({ title: "", instruction: "x" }, "user")).toThrow();
    expect(() => watches.add({ title: "a", instruction: "x", at: ["9am"] }, "user")).toThrow();
    expect(watches.add({ title: "a", instruction: "x", intervalMinutes: 1 }, "user").intervalMinutes).toBe(5);
    expect(() => watches.add({ title: "a", instruction: "x", kind: "schedule" }, "user")).toThrow();
    cleanup(paths);
  });
});

describe("goals (what the owner sees on a watch)", () => {
  test("old watch lists get a state; enabled and state stay in step", () => {
    const paths = tmpPaths();
    writeFileSync(
      paths.watches,
      JSON.stringify([
        { id: "w_a", title: "老", kind: "check", instruction: "i", intervalMinutes: 60, enabled: true, createdBy: "agent" },
        { id: "w_b", title: "停", kind: "check", instruction: "i", intervalMinutes: 60, enabled: false, createdBy: "agent" },
      ]),
    );
    const watches = new WatchStore(paths.watches, new Bus());
    expect(watches.get("w_a")!.state).toBe("tracking");
    expect(watches.get("w_b")!.state).toBe("paused");
    expect(watches.update("w_a", { enabled: false }).state).toBe("paused");
    expect(watches.update("w_a", { enabled: true }).state).toBe("tracking");
    expect(watches.update("w_a", { state: "done" }).enabled).toBe(false);
    expect(() => watches.update("w_a", { state: "bogus" as any })).toThrow();
    cleanup(paths);
  });

  test("progress keeps one short line, a small history, and state", () => {
    const paths = tmpPaths();
    const watches = new WatchStore(paths.watches, new Bus());
    const w = watches.add({ title: "机票", instruction: "每天比价", intervalMinutes: 60 }, "agent");
    watches.progress(w.id, "**现在最低 ¥4,860**。比昨天便宜 ¥320，还在看。");
    expect(watches.get(w.id)!.progress).toBe("现在最低 ¥4,860。");
    for (let i = 0; i < 12; i++) watches.progress(w.id, `第 ${i} 次`);
    expect(watches.get(w.id)!.history).toHaveLength(8);
    const done = watches.progress(w.id, "订好了", { state: "done", outcome: "东航 MU5100，¥4,620", ratio: 1 });
    expect(done.enabled).toBe(false);
    expect(done.outcome).toBe("东航 MU5100，¥4,620");
    expect(done.ratio).toBe(1);
    expect(watches.progress(w.id, "", { state: "tracking" }).enabled).toBe(true);
    expect(watches.get(w.id)!.progress).toBe("订好了"); // an empty line doesn't erase the last one
    cleanup(paths);
  });

  test("a probe check records the goal's progress line without an extra model call", async () => {
    const { probe, driver, watches, paths } = mk();
    const a = watches.add({ title: "机票", instruction: "比价", intervalMinutes: 30 }, "agent");
    const b = watches.add({ title: "老板邮件", instruction: "查邮件", intervalMinutes: 30 }, "agent");
    const c = watches.add({ title: "网页", instruction: "看更新", intervalMinutes: 30 }, "agent");
    driver.probeResponder = () => ({
      output: {
        results: [
          { watch_id: a.id, triggered: false, progress: "现在最低 ¥4,860" },
          { watch_id: b.id, triggered: true, key: "m1", summary: "老板发来合同，要你周五前签" },
          { watch_id: c.id, triggered: false },
        ],
      },
      costUsd: 0.001,
    });
    await probe.tick(T0);
    expect(driver.probes).toHaveLength(1);
    expect(watches.get(a.id)!.progress).toBe("现在最低 ¥4,860");
    expect(watches.get(b.id)!.progress).toBe("老板发来合同，要你周五前签");
    expect(watches.get(c.id)!.progress).toBeUndefined();
    expect(driver.probes[0]!.systemPrompt).toContain("progress");
    cleanup(paths);
  });
});
