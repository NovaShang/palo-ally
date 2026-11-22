import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { getLang, t } from "./i18n/index.ts";

export function newId(prefix = ""): string {
  return prefix + randomBytes(6).toString("hex");
}

export function ensureDir(path: string): void {
  if (!existsSync(path)) mkdirSync(path, { recursive: true, mode: 0o700 });
}

export function readJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

// writeJson is atomic (write temp + rename) so a crash never leaves a torn file.
export function writeJson(path: string, value: unknown): void {
  ensureDir(dirname(path));
  const tmp = `${path}.${process.pid}.tmp`;
  // owner-only: config holds API tokens, identity holds the host key
  writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
}

export function appendJsonl(path: string, value: unknown): void {
  ensureDir(dirname(path));
  appendFileSync(path, JSON.stringify(value) + "\n", { mode: 0o600 });
}

// writeJsonl replaces a whole JSONL file, atomically like writeJson.
export function writeJsonl(path: string, rows: unknown[]): void {
  ensureDir(dirname(path));
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, rows.map((r) => JSON.stringify(r) + "\n").join(""), { mode: 0o600 });
  renameSync(tmp, path);
}

export function readJsonl<T>(path: string): T[] {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return [];
  }
  const out: T[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as T);
    } catch {
      // A torn last line after a crash is skipped, not fatal.
    }
  }
  return out;
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The process is there (EPERM: it is, only not ours to signal). */
export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}

/** `~` and `~/…` as the owner's home. */
export const expandHome = (p: string): string => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p);

/** `p` is `root` or under it. */
export function within(root: string, p: string): boolean {
  if (!root || !p) return false;
  const r = resolve(root);
  const x = resolve(p);
  return x === r || x.startsWith(r + sep);
}

export function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1) + "…";
}

// ---------- time (wall clock in a configured IANA zone) ----------

export interface ZonedParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  dateKey: string; // YYYY-MM-DD in the zone
}

export function isValidTimeZone(tz: unknown): tz is string {
  if (typeof tz !== "string" || !tz) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

export function zonedParts(ms: number, timeZone: string): ZonedParts {
  // A bad zone must never take the assistant down: fall back to UTC.
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: isValidTimeZone(timeZone) ? timeZone : "UTC",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const parts: Record<string, string> = {};
  for (const p of fmt.formatToParts(new Date(ms))) parts[p.type] = p.value;
  const year = Number(parts.year);
  const month = Number(parts.month);
  const day = Number(parts.day);
  return {
    year,
    month,
    day,
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    dateKey: `${parts.year}-${parts.month}-${parts.day}`,
  };
}

/** HH:MM of a zoned time. */
export const hhmm = (p: Pick<ZonedParts, "hour" | "minute">): string => `${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;

export function parseHHMM(s: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim());
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

// inWindow reports whether minute-of-day `t` falls in [start, end), handling
// windows that wrap midnight (23:00–08:00).
export function inWindow(t: number, start: number, end: number): boolean {
  if (start === end) return false;
  return start < end ? t >= start && t < end : t >= start || t < end;
}

export function minuteOfDay(ms: number, timeZone: string): number {
  const p = zonedParts(ms, timeZone);
  return p.hour * 60 + p.minute;
}

export function formatDuration(ms: number): string {
  const min = Math.round(ms / 60000);
  if (min < 60) return t("util.minutes", { n: min });
  const h = Math.floor(min / 60);
  const m = min % 60;
  return m ? t("util.hoursMinutes", { h, m }) : t("util.hours", { h });
}

// The BCP-47 tag for date formatting in the owner's language.
export const dateLocale = (): string => (getLang() === "zh" ? "zh-CN" : "en-US");
