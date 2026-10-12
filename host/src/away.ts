import { spawnSync } from "node:child_process";

// Is the owner at this computer? Decides where a Claude Code session's
// permission prompt goes: at the computer it stays in the terminal as usual;
// away, it becomes a card on the phone (docs/sessions-prd.md §6.3).
// Away = the screen is locked, or no keyboard / mouse input for 3 minutes.
// Read from the OS (ioreg) and kept for a few seconds; no model involved.

export interface AwayReading {
  locked: boolean;
  idleMs: number | null; // HID idle time; null when it can't be read
}

export const AWAY_IDLE_MS = 3 * 60_000;
const CACHE_MS = 5_000;

/** `ioreg -c IOHIDSystem -k HIDIdleTime -d 4`: nanoseconds since the last input. */
export function parseHidIdle(out: string): number | null {
  const m = /"HIDIdleTime"\s*=\s*(\d+)/.exec(out);
  return m ? Math.floor(Number(m[1]) / 1e6) : null;
}

/**
 * `ioreg -n Root -d1`: the console sessions, the same dictionaries
 * CGSessionCopyCurrentDictionary returns. The owner's session (by uid) is
 * locked when it says CGSSessionScreenIsLocked=Yes, and away from the screen
 * altogether when it isn't the one on the console (fast user switching).
 * No session for the uid (no one logged in at the screen) counts as locked.
 */
export function parseScreenLocked(out: string, uid: number): boolean {
  const users = /"IOConsoleUsers"\s*=\s*\((.*)\)\s*$/m.exec(out)?.[1];
  if (!users) return false;
  for (const d of users.split(/\},\s*\{/)) {
    const id = /"kCGSSessionUserIDKey"\s*=\s*(\d+)/.exec(d);
    if (!id || Number(id[1]) !== uid) continue;
    if (/"CGSSessionScreenIsLocked"\s*=\s*Yes/.test(d)) return true;
    if (/"kCGSSessionOnConsoleKey"\s*=\s*No/.test(d)) return true;
    return false;
  }
  return true;
}

export function readAway(): AwayReading | null {
  if (process.platform !== "darwin") return null;
  const uid = process.getuid?.() ?? -1;
  const root = spawnSync("ioreg", ["-n", "Root", "-d1"], { encoding: "utf8", timeout: 2000 });
  const hid = spawnSync("ioreg", ["-c", "IOHIDSystem", "-k", "HIDIdleTime", "-d", "4"], { encoding: "utf8", timeout: 2000 });
  if (root.status !== 0 && hid.status !== 0) return null;
  return {
    locked: root.status === 0 ? parseScreenLocked(root.stdout, uid) : false,
    idleMs: hid.status === 0 ? parseHidIdle(hid.stdout) : null,
  };
}

export class AwayDetector {
  private cached: { at: number; away: boolean; reading: AwayReading | null } | null = null;

  constructor(
    private read: () => AwayReading | null = readAway,
    private now: () => number = Date.now,
    // tests force it: true = always away, false = always at the computer
    private override?: () => boolean | undefined,
  ) {}

  isAway(): boolean {
    const forced = this.override?.();
    if (forced !== undefined) return forced;
    const t = this.now();
    if (this.cached && t - this.cached.at < CACHE_MS) return this.cached.away;
    let reading: AwayReading | null = null;
    try {
      reading = this.read();
    } catch {
      reading = null;
    }
    // Unreadable (another OS, no console): behave as if the owner is there,
    // which is how Claude Code behaves without PaloAlly.
    const away = !!reading && (reading.locked || (reading.idleMs !== null && reading.idleMs >= AWAY_IDLE_MS));
    this.cached = { at: t, away, reading };
    return away;
  }

  /** The last reading, for `paloally status` and the audit trail. */
  last(): AwayReading | null {
    return this.cached?.reading ?? null;
  }
}
