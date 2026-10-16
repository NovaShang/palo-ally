import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Paths } from "../src/config.ts";
import { setLang, t } from "../src/i18n/index.ts";
import { runDoctor } from "../src/setup.ts";
import { updateLine } from "../src/update.ts";
import { formatDuration } from "../src/util.ts";
import { phase0Report } from "../src/metrics.ts";
import { powerLine } from "../src/power.ts";
import { scheduleText } from "../src/watches.ts";

const CJK = /[一-鿿]/;

afterAll(() => setLang("zh"));

describe("cli strings in English", () => {
  beforeAll(() => setLang("en"));

  test("help text", () => {
    const h = t("cli.help", { version: "1.2.3" });
    expect(h).toContain("settings language en|zh");
    expect(h).toContain("1.2.3");
    expect(CJK.test(h)).toBe(false);
  });

  test("formatDuration", () => {
    expect(formatDuration(5 * 60_000)).toBe("5 min");
    expect(formatDuration(90 * 60_000)).toBe("1 h 30 min");
    expect(formatDuration(120 * 60_000)).toBe("2 h");
  });

  test("updateLine", () => {
    const line = updateLine({
      install: { kind: "managed" },
      auto: true,
      version: "0.1.2",
      lastCheckAt: Date.now() - 3 * 3600_000,
      latest: { version: "0.1.3" },
    } as any);
    expect(line).toBe("0.1.2 (auto-update on · last checked 3 h ago · new version 0.1.3 available)");
    expect(CJK.test(line)).toBe(false);
  });

  test("scheduleText, powerLine, metrics", () => {
    expect(scheduleText({ kind: "schedule", at: ["08:30", "22:00"], intervalMinutes: undefined, dayOfMonth: -1 } as any)).toBe("the last day of every month at 08:30, 22:00");
    expect(powerLine({ hasBattery: true, onAC: true, percent: 80, alerts: false })).toBe("plugged in (80%) · unplug alerts off");
    const dir = mkdtempSync(join(tmpdir(), "pa-cli-"));
    try {
      const report = phase0Report(new Paths(dir), 7, "UTC");
      expect(report.startsWith("Last 7 days")).toBe(true);
      expect(CJK.test(report)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a doctor check", async () => {
    const dir = mkdtempSync(join(tmpdir(), "pa-cli-"));
    const lines: string[] = [];
    const log = console.log;
    console.log = (...a: unknown[]) => void lines.push(a.join(" "));
    try {
      const ok = await runDoctor(new Paths(dir), { live: false });
      expect(ok).toBe(false);
    } finally {
      console.log = log;
      rmSync(dir, { recursive: true, force: true });
    }
    const out = lines.join("\n");
    expect(out).toContain("Home folder");
    expect(out).toContain("Assistant process");
    expect(CJK.test(out)).toBe(false);
  });
});
