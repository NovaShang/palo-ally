import { describe, expect, test } from "bun:test";
import { AWAY_IDLE_MS, AwayDetector, parseHidIdle, parseScreenLocked } from "../src/away.ts";

const root = (dicts: string[]) =>
  `+-o Root  <class IORegistryEntry, id 0x100000100, retain 30>\n    {\n      "IOConsoleLocked" = No\n      "IOConsoleUsers" = (${dicts.join(",")})\n    }\n`;
const user = (uid: number, extra = "") =>
  `{"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionUserNameKey"="someone","kCGSSessionUserIDKey"=${uid},"kCGSessionLoginDoneKey"=Yes${extra}}`;

describe("away detection", () => {
  test("reads the HID idle time in milliseconds", () => {
    expect(parseHidIdle(`    | |     "HIDIdleTime" = 36658226172875\n`)).toBe(36658226);
    expect(parseHidIdle("nothing here")).toBeNull();
  });

  test("the owner's console session decides whether the screen is locked", () => {
    expect(parseScreenLocked(root([user(501)]), 501)).toBe(false);
    expect(parseScreenLocked(root([user(501, `,"CGSSessionScreenIsLocked"=Yes`)]), 501)).toBe(true);
    // someone else's locked screen is not ours
    expect(parseScreenLocked(root([user(502, `,"CGSSessionScreenIsLocked"=Yes`), user(501)]), 501)).toBe(false);
    // switched out (fast user switching): not at the screen
    expect(parseScreenLocked(root([user(501).replace(`"kCGSSessionOnConsoleKey"=Yes`, `"kCGSSessionOnConsoleKey"=No`)]), 501)).toBe(true);
    // no session for this user at all
    expect(parseScreenLocked(root([user(502)]), 501)).toBe(true);
  });

  test("away when locked or idle 3 minutes; cached for a few seconds; unreadable means at the computer", () => {
    let now = 1_000_000;
    let reading: { locked: boolean; idleMs: number | null } | null = { locked: false, idleMs: 10_000 };
    let reads = 0;
    const d = new AwayDetector(() => (reads++, reading), () => now);
    expect(d.isAway()).toBe(false);
    reading = { locked: true, idleMs: 0 };
    expect(d.isAway()).toBe(false); // cached
    expect(reads).toBe(1);
    now += 5_000;
    expect(d.isAway()).toBe(true);
    reading = { locked: false, idleMs: AWAY_IDLE_MS };
    now += 5_000;
    expect(d.isAway()).toBe(true);
    reading = null;
    now += 5_000;
    expect(d.isAway()).toBe(false);
    // a test can force either answer
    expect(new AwayDetector(() => null, () => now, () => true).isAway()).toBe(true);
  });
});
