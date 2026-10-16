import { realpathSync } from "node:fs";
import { isAbsolute, join, resolve, sep } from "node:path";

// 「只说话不动手」(docs/allies-prd.md §11.1): while the assistant handles an
// Ally's message, the host lets through only the tools for talking back and
// for looking things up the owner already keeps. Everything else is denied,
// in either trust level, whatever Claude Code's own permission mode would
// have done (Conversation enforces it from a PreToolUse hook and again in
// canUseTool).
//
// The rule, deliberately narrow:
//   1. Talking to Allies: mcp__paloally__ally_send, mcp__paloally__ally_list.
//   2. Reading a calendar: an MCP tool whose server or tool name has a
//      calendar word as a whole word (calendar, calendars, cal, gcal, ical,
//      caldav), whose tool name has a read verb (list, get, search, find,
//      query, read, view, suggest, check, lookup, fetch, show, freebusy,
//      availability, available), and whose name has no word that writes or
//      reaches out (create, update, delete, send, respond, accept, share,
//      permission, mail, …: WRITE_WORDS below). An unknown calendar tool
//      that doesn't read this plainly is denied.
//   3. Reading the owner's memory: Read of user.md / soul.md or of a file in
//      the auto-memory folder; Grep / Glob with an explicit path inside that
//      folder and no `..` in their patterns. Not the chat log, not anything
//      else in the home folder.
//   4. Two that run nothing: AskUserQuestion (a choice card for the owner,
//      the 约时间 flow of §4.2) and ToolSearch (loads a deferred tool's
//      schema, e.g. a calendar connector's).
//   5. Telling the owner: mcp__paloally__notify_user, a push to the owner's
//      own phone, so an Ally's urgent word can reach them without waiting
//      for the turn to end (the owner's call, 2026-10-13). It only informs;
//      SendMessage to other sessions stays denied.
// Denied, among everything else: Bash, Write, Edit, NotebookEdit, WebFetch,
// WebSearch, Agent / Task (no subagents), SendMessage, the paloally tools
// that act or reach anyone but the owner (SendUserFile, register_watch, …),
// pair_link (it would let a new device into the owner's computer), mail
// tools, and any calendar tool that writes.

export interface AllyGateScope {
  home: string; // the assistant's working folder (user.md, soul.md)
  memoryDir: string; // Claude Code's auto memory for it
}

export type AllyToolVerdict = { ok: true; kind: "ally" | "calendar" | "memory" | "plumbing" | "owner" } | { ok: false };

const ALLY_TOOLS = new Set(["mcp__paloally__ally_send", "mcp__paloally__ally_list"]);
const PLUMBING = new Set(["AskUserQuestion", "ToolSearch"]);
const TELL_OWNER = "mcp__paloally__notify_user";
const CORE = ["user.md", "soul.md"];

const CALENDAR_WORDS = new Set(["calendar", "calendars", "cal", "gcal", "ical", "caldav"]);
const READ_VERBS = new Set(["list", "get", "search", "find", "query", "read", "view", "suggest", "check", "lookup", "fetch", "show", "freebusy", "availability", "available"]);
const WRITE_WORDS = new Set([
  "create", "update", "delete", "remove", "respond", "rsvp", "accept", "decline", "cancel", "forward", "send", "dismiss",
  "snooze", "move", "add", "insert", "patch", "put", "post", "set", "share", "invite", "write", "edit", "modify",
  "tentatively", "permission", "permissions", "acl", "subscribe", "unsubscribe", "import", "export", "sync", "clear",
  "reply", "quick", "quickadd", "book", "reschedule", "upload", "mail", "email", "draft", "attachment",
]);

// words splits a tool name into lowercase words: separators and camelCase.
export function toolWords(name: string): string[] {
  return name
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean)
    .map((w) => w.toLowerCase());
}

/** A read-only calendar tool, by name (rule 2 above). */
export function isCalendarReadTool(name: string): boolean {
  const m = /^mcp__(.+?)__(.+)$/.exec(name);
  if (!m || m[1] === "paloally") return false;
  const server = toolWords(m[1]!);
  const tool = toolWords(m[2]!);
  const all = [...server, ...tool];
  if (!all.some((w) => CALENDAR_WORDS.has(w))) return false;
  if (all.some((w) => WRITE_WORDS.has(w))) return false;
  return tool.some((w) => READ_VERBS.has(w));
}

// real resolves symlinks where the path exists, so a link can't lead out.
function real(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

function inside(path: string, dir: string): boolean {
  const p = real(path);
  const d = real(dir);
  return p === d || p.startsWith(d + sep);
}

/** A read of the owner's memory and nothing else (rule 3 above). */
export function isMemoryRead(name: string, input: Record<string, unknown>, scope: AllyGateScope): boolean {
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const noDots = (v: unknown) => v === undefined || (typeof v === "string" && !v.includes(".."));
  if (name === "Read") {
    const file = str(input.file_path);
    if (!file || !isAbsolute(file)) return false;
    if (CORE.some((c) => real(file) === real(join(scope.home, c)))) return true;
    return inside(file, scope.memoryDir) && real(file) !== real(scope.memoryDir);
  }
  if (name === "Grep" || name === "Glob") {
    const path = str(input.path);
    if (!path || !isAbsolute(path) || !inside(path, scope.memoryDir)) return false;
    return name === "Grep" ? noDots(input.glob) : noDots(input.pattern) && !isAbsolute(String(input.pattern ?? ""));
  }
  return false;
}

/** Whether a tool may run in a turn an Ally's message started. */
export function allyTurnTool(name: string, input: Record<string, unknown>, scope: AllyGateScope): AllyToolVerdict {
  if (ALLY_TOOLS.has(name)) return { ok: true, kind: "ally" };
  if (PLUMBING.has(name)) return { ok: true, kind: "plumbing" };
  if (name === TELL_OWNER) return { ok: true, kind: "owner" };
  if (isCalendarReadTool(name)) return { ok: true, kind: "calendar" };
  if (isMemoryRead(name, input ?? {}, scope)) return { ok: true, kind: "memory" };
  return { ok: false };
}
