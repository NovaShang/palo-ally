import { describe, expect, test } from "bun:test";
import { Bus } from "../src/bus.ts";
import { FakeDriver } from "../src/harness/fake.ts";
import { ProbeScheduler, dueSlot, type ProbeHost, type ProbeTrigger } from "../src/probe.ts";
import type { Watch } from "../src/types.ts";
import { inWindow, parseHHMM, zonedParts } from "../src/util.ts";
import { WatchStore } from "../src/watches.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

const T0 = Date.UTC(2026, 9, 4, 9, 0); // 2026-10-04 09:00 UTC

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

  test("interval schedules", () => {
    expect(dueSlot(w({ intervalMinutes: 60, lastCheckedAt: T0 - 30 * 60_000 }), T0, "UTC")).toBeNull();
    expect(dueSlot(w({ intervalMinutes: 60, lastCheckedAt: T0 - 61 * 60_000 }), T0, "UTC")).not.toBeNull();
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
