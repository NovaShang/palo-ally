import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FakeDriver } from "./fakeDriver.ts";
import { RecordingPusher, testConfig, tmpPaths } from "./helpers.ts";
import { Hub } from "../src/hub.ts";
import { PowerWatcher, type PowerReading, parsePmset, powerLine, readSysfsPower } from "../src/power.ts";

describe("parsePmset", () => {
  test("on AC, charged", () => {
    const out = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=24379491)\t100%; charged; 0:00 remaining present: true\n";
    expect(parsePmset(out)).toEqual({ hasBattery: true, onAC: true, percent: 100 });
  });
  test("on battery", () => {
    const out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=24379491)\t76%; discharging; 5:12 remaining present: true\n";
    expect(parsePmset(out)).toEqual({ hasBattery: true, onAC: false, percent: 76 });
  });
  test("on AC, charging", () => {
    const out = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t45%; charging; 1:02 remaining present: true\n";
    expect(parsePmset(out)).toEqual({ hasBattery: true, onAC: true, percent: 45 });
  });
  test("a desktop has no battery line", () => {
    expect(parsePmset("Now drawing from 'AC Power'\n")).toEqual({ hasBattery: false, onAC: true, percent: null });
  });
  test("unrecognised output", () => {
    expect(parsePmset("")).toBeNull();
  });
});

describe("readSysfsPower", () => {
  test("a Linux laptop on battery", () => {
    const dir = mkdtempSync(join(tmpdir(), "power-"));
    mkdirSync(join(dir, "BAT0"));
    writeFileSync(join(dir, "BAT0", "type"), "Battery\n");
    writeFileSync(join(dir, "BAT0", "capacity"), "40\n");
    writeFileSync(join(dir, "BAT0", "status"), "Discharging\n");
    mkdirSync(join(dir, "AC"));
    writeFileSync(join(dir, "AC", "type"), "Mains\n");
    writeFileSync(join(dir, "AC", "online"), "0\n");
    expect(readSysfsPower(dir)).toEqual({ hasBattery: true, onAC: false, percent: 40 });
  });
  test("a server without a battery", () => {
    const dir = mkdtempSync(join(tmpdir(), "power-"));
    expect(readSysfsPower(dir)).toEqual({ hasBattery: false, onAC: true, percent: null });
    expect(readSysfsPower(join(dir, "missing"))).toBeNull();
  });
});

function watcher(readings: (PowerReading | null)[], opts: { enabled?: boolean; path?: string } = {}) {
  const alerts: { text: string; urgent: boolean }[] = [];
  const notes: string[] = [];
  const audits: { type: string; data: any }[] = [];
  let i = 0;
  const path = opts.path ?? join(mkdtempSync(join(tmpdir(), "power-")), "power.json");
  const w = new PowerWatcher({
    path,
    read: () => readings[Math.min(i++, readings.length - 1)] ?? null,
    enabled: () => opts.enabled ?? true,
    alert: (text, urgent) => alerts.push({ text, urgent }),
    note: (t) => notes.push(t),
    audit: (type, data) => audits.push({ type, data }),
  });
  return { w, alerts, notes, audits, path, tick: (n = 1) => { for (let k = 0; k < n; k++) w.tick(); } };
}
const ac = (p: number): PowerReading => ({ hasBattery: true, onAC: true, percent: p });
const batt = (p: number): PowerReading => ({ hasBattery: true, onAC: false, percent: p });

describe("PowerWatcher", () => {
  test("one heads-up per threshold, reset on AC", () => {
    const t = watcher([ac(100), batt(76), batt(70), batt(29), batt(28), batt(14), batt(10), ac(11), batt(50)]);
    t.tick(9);
    expect(t.alerts).toEqual([
      { text: "电脑拔电了（剩 76%）。没电我就会掉线，记得插上。", urgent: false },
      { text: "电量 29%，记得插电。", urgent: false },
      { text: "电量只剩 14%，快没电了。", urgent: true },
      { text: "电脑拔电了（剩 50%）。没电我就会掉线，记得插上。", urgent: false },
    ]);
    expect(t.notes).toEqual(["已接上电源。"]);
    expect(t.audits.filter((a) => a.type === "power.change").map((a) => a.data.onAC)).toEqual([true, false, true, false]);
  });

  test("unplugged when already low: one message, worded for the charge", () => {
    const t = watcher([ac(30), batt(20), batt(18), batt(13)]);
    t.tick(4);
    expect(t.alerts).toEqual([
      { text: "电脑拔电了，电量 20%，记得插电。", urgent: false },
      { text: "电量只剩 13%，快没电了。", urgent: true },
    ]);
    const u = watcher([ac(30), batt(9)]);
    u.tick(2);
    expect(u.alerts).toEqual([{ text: "电脑拔电了，电量只剩 9%，快没电了。", urgent: true }]);
  });

  test("a restart doesn't repeat what was already said", () => {
    const first = watcher([ac(90), batt(60)]);
    first.tick(2);
    expect(first.alerts.length).toBe(1);
    const again = watcher([batt(58), batt(25)], { path: first.path });
    again.tick(2);
    expect(again.alerts).toEqual([{ text: "电量 25%，记得插电。", urgent: false }]);
  });

  test("turned off: no heads-ups", () => {
    const t = watcher([ac(90), batt(60), batt(10)], { enabled: false });
    t.tick(3);
    expect(t.alerts).toEqual([]);
  });

  test("no battery: nothing to watch", () => {
    const t = watcher([{ hasBattery: false, onAC: true, percent: null }]);
    t.tick(2);
    expect(t.alerts).toEqual([]);
    expect(t.w.status().hasBattery).toBe(false);
  });

  test("status line", () => {
    expect(powerLine({ hasBattery: true, onAC: true, percent: 100, alerts: true })).toBe("接着电（100%）");
    expect(powerLine({ hasBattery: true, onAC: false, percent: 76, alerts: true })).toBe("电池 76%");
    expect(powerLine({ hasBattery: true, onAC: false, percent: 76, alerts: false })).toBe("电池 76% · 拔电提醒已关闭");
    expect(powerLine({ hasBattery: false, onAC: true, percent: null, alerts: true })).toBeNull();
  });
});

describe("power heads-ups through the hub", () => {
  test("quiet hours hold the ordinary ones; the urgent one goes through; all land in the conversation", async () => {
    const readings = [ac(100), batt(76), batt(12)];
    let i = 0;
    const pusher = new RecordingPusher();
    const hub = new Hub({
      paths: tmpPaths(),
      config: testConfig((c) => (c.settings.quietHours = { start: "00:00", end: "23:59" })),
      driver: new FakeDriver(),
      pushers: [pusher],
      log: () => {},
      readPower: () => readings[Math.min(i++, readings.length - 1)]!,
    });
    hub.power.tick();
    hub.power.tick();
    await Bun.sleep(20);
    expect(pusher.pushes.length).toBe(0);
    hub.power.tick();
    await Bun.sleep(20);
    expect(pusher.pushes.map((p) => p.body)).toEqual(["电量只剩 12%，快没电了。"]);
    const texts = hub.chat.since(0).map((m) => m.text);
    expect(texts).toContain("电脑拔电了（剩 76%）。没电我就会掉线，记得插上。");
    expect(texts).toContain("电量只剩 12%，快没电了。");
    hub.stop();
  });
});
