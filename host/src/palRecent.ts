import { t } from "./i18n/index.ts";
import { getSessionInfo, listSessions, renameSession, type SDKSessionInfo } from "@anthropic-ai/claude-agent-sdk";
import { realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join, resolve, sep } from "node:path";
import { claudeConfigDir, transcriptPath } from "./handoffs.ts";
import type { RecentSession } from "./types.ts";

// 接管最近的对话 (docs/pals-prd.md §10): the Claude Code conversations on this
// computer that ended lately, from the SDK's listSessions (it reads the first
// and last 64 KB of each transcript, never the whole file). Listed as Claude
// Code's own /resume lists them: `claude -p` runs and apps built on the
// Agent SDK aren't, except a Pal the owner took out of the list. Never
// PaloAlly's own folders, nor the temporary ones its tests and Claude Code's
// agents leave. A session is listed only if a Pal can resume it: its folder
// is there and its transcript is where Claude Code keeps that folder's.
// What's running or a Pal already is left out by the caller, on every call.

export const RECENT_DAYS = 30;
export const RECENT_MAX = 50;
const SCAN = 150; // the newest transcripts looked at
const CACHE_MS = 5_000;

/** Where the sessions come from (the SDK; tests give their own). */
export interface RecentSource {
  list(o: { limit: number; includeProgrammatic: boolean }): Promise<SDKSessionInfo[]>;
  info(sessionId: string, dir?: string): Promise<SDKSessionInfo | undefined>;
}

/** A listed session, with its custom title (a Pal's name comes from it). */
export interface RecentEntry extends RecentSession {
  customTitle?: string;
  generatedTitle?: string; // Claude Code's own title for it (its summary, when that isn't its first words)
}

export interface RecentDeps {
  claudeDir: string;
  /** PaloAlly's own folders (its root, Palo's home, probes). */
  roots: () => string[];
  /** Pals the owner took out of the list (released or removed). */
  formerPals: () => { sessionId: string; cwd: string }[];
  source?: RecentSource;
  now?: () => number;
  log?: (s: string) => void;
}

// The SDK reads Claude Code's own folder (CLAUDE_CONFIG_DIR or ~/.claude);
// for any other (a test's), there's nothing it could list.
/** Retitles a session that has no process (the SDK's renameSession): only in this computer's own Claude Code folder. */
export function sdkRename(claudeDir: string): (sessionId: string, title: string, dir: string) => Promise<void> {
  return async (sid, title, dir) => {
    if (resolve(claudeDir) !== resolve(claudeConfigDir())) return;
    await renameSession(sid, title, { dir });
  };
}

export function sdkSource(claudeDir: string): RecentSource {
  const same = () => resolve(claudeDir) === resolve(claudeConfigDir());
  return {
    list: async (o) => (same() ? listSessions(o) : []),
    info: async (sid, dir) => (same() ? getSessionInfo(sid, dir ? { dir } : {}) : undefined),
  };
}

function within(root: string, p: string): boolean {
  if (!root || !p) return false;
  const r = resolve(root);
  const x = resolve(p);
  return x === r || x.startsWith(r + sep);
}

function realOr(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

const TEMP_ROOTS = [...new Set([tmpdir(), "/tmp", "/private/tmp"].flatMap((p) => [resolve(p), realOr(p)]))];

// The first folder under a temporary root that's PaloAlly's tests' (paloally-…,
// the old courier's courier-…) or Claude Code's own (claude-<uid>, where its
// agents' scratchpads are).
const TEMP_OWN = /^(paloally-|courier-|claude-\d+$)/;

/** PaloAlly's own folder, or a temporary one its tests or Claude Code's agents made. */
export function isOwnFolder(cwd: string, roots: string[]): boolean {
  const x = resolve(cwd);
  if (roots.some((r) => within(r, x))) return true;
  for (const t of TEMP_ROOTS) {
    if (!within(t, x) || x === t) continue;
    if (TEMP_OWN.test(x.slice(t.length + 1).split(sep)[0] ?? "")) return true;
  }
  return false;
}

/** PaloAlly's roots: this host's, and the default one (~/.paloally) of the owner's host. */
export function ownRoots(root: string): string[] {
  return [...new Set([root, join(homedir(), ".paloally")].map(realOr))];
}

const oneLine = (s?: string) => (s ?? "").replace(/\s+/g, " ").trim();
const cut = (s: string, n: number) => ([...s].length <= n ? s : `${[...s].slice(0, n).join("").trimEnd()}…`);

/** Its title: the custom one (/rename, -n, or the one Claude Code wrote), Claude Code's summary, else the first 40 characters of its first words. */
export function recentTitle(i: Pick<SDKSessionInfo, "customTitle" | "summary" | "firstPrompt">): string {
  const custom = oneLine(i.customTitle);
  if (custom) return cut(custom, 60);
  const first = oneLine(i.firstPrompt);
  const summary = oneLine(i.summary);
  if (summary && summary !== first) return cut(summary, 60);
  return first ? cut(first, 40) : "";
}

/** A name a few words long (≤ `max` characters), cut at a space when there's one late enough. */
export function shortName(s: string, max = 16): string {
  const t = oneLine(s).replace(/^["'「『“]+|["'」』”]+$/g, "");
  const c = [...t];
  if (c.length <= max) return t;
  const head = c.slice(0, max + 1).join("");
  const sp = head.lastIndexOf(" ");
  const out = sp >= 6 ? head.slice(0, sp) : c.slice(0, max).join("");
  return out.replace(/[\s,.;:!?，。；：、！？\-–—_]+$/, "");
}

/**
 * A Pal's name from its session (§13): its custom title (/rename, a rename
 * in PaloAlly, the name it was started under), else the title Claude Code
 * gave it (its summary, when that isn't just its first words), else its
 * folder's name.
 */
export function palTitle(i: Partial<Pick<SDKSessionInfo, "customTitle" | "summary" | "firstPrompt">> | undefined, cwd: string): string {
  const custom = oneLine(i?.customTitle);
  if (custom) return [...custom].slice(0, 40).join("");
  const first = oneLine(i?.firstPrompt);
  const summary = oneLine(i?.summary);
  if (summary && summary !== first) return shortName(summary);
  return shortName(basename(cwd)) || "Pal";
}

/** An adopted Pal's first name (§13's order): its custom title, Claude Code's own title, its folder's name. A first prompt doesn't make a name. */
export function palNameFor(e: { customTitle?: string; generatedTitle?: string; cwd: string }): string {
  return palTitle({ customTitle: e.customTitle, summary: e.generatedTitle ?? "", firstPrompt: "" }, e.cwd);
}

export class RecentSessions {
  private cache: { at: number; entries: RecentEntry[] } | null = null;
  private loading: Promise<RecentEntry[]> | null = null;
  private readonly source: RecentSource;

  constructor(private d: RecentDeps) {
    this.source = d.source ?? sdkSource(d.claudeDir);
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  /** The next look reads the transcripts again (a Pal left the list). */
  invalidate(): void {
    this.cache = null;
  }

  /** Every conversation that ended in the last 30 days and could be resumed, newest first (cached a few seconds). */
  async all(): Promise<RecentEntry[]> {
    if (this.cache && this.now() - this.cache.at < CACHE_MS) return this.cache.entries;
    this.loading ??= this.load().finally(() => (this.loading = null));
    return this.loading;
  }

  private async load(): Promise<RecentEntry[]> {
    const since = this.now() - RECENT_DAYS * 86400_000;
    let infos: SDKSessionInfo[] = [];
    try {
      infos = await this.source.list({ limit: SCAN, includeProgrammatic: false });
    } catch (e) {
      this.d.log?.(`recent: listSessions failed: ${e instanceof Error ? e.message : e}`);
    }
    // A Pal the assistant opened is an SDK session from its start: it's the
    // owner's all the same, once out of the list.
    const seen = new Set(infos.map((i) => i.sessionId));
    for (const f of this.d.formerPals()) {
      if (seen.has(f.sessionId)) continue;
      const i = await this.source.info(f.sessionId, f.cwd).catch(() => undefined);
      if (!i) continue;
      seen.add(f.sessionId);
      infos.push({ ...i, cwd: i.cwd || f.cwd });
    }
    const out: RecentEntry[] = [];
    for (const i of infos) {
      if (!(i.lastModified >= since)) continue;
      const e = this.check(i);
      if (typeof e !== "string") out.push(e);
    }
    out.sort((a, b) => b.lastModified - a.lastModified);
    this.cache = { at: this.now(), entries: out };
    return out;
  }

  /** One session as listed, or why it can't be taken over. */
  check(i: SDKSessionInfo): RecentEntry | string {
    if (!i.cwd) return t("pals.noFolder");
    const cwd = resolve(i.cwd);
    if (isOwnFolder(cwd, this.d.roots())) return t("pals.ownSession");
    let dir = false;
    try {
      dir = statSync(cwd).isDirectory();
    } catch {
      dir = false;
    }
    if (!dir) return t("pals.folderGone", { cwd });
    // Where a Pal resumes it from: elsewhere (a worktree's, a moved folder's)
    // it would start afresh instead.
    let size = 0;
    try {
      const st = statSync(transcriptPath(this.d.claudeDir, cwd, i.sessionId));
      if (!st.isFile()) return t("pals.noTranscript");
      size = st.size;
    } catch {
      return t("pals.noTranscript");
    }
    const custom = oneLine(i.customTitle);
    const summary = oneLine(i.summary);
    const generated = summary && summary !== custom && summary !== oneLine(i.firstPrompt) ? summary : "";
    return {
      sessionId: i.sessionId,
      cwd,
      title: recentTitle(i) || basename(cwd),
      lastModified: Math.round(i.lastModified),
      size,
      ...(custom ? { customTitle: custom } : {}),
      ...(generated ? { generatedTitle: generated } : {}),
    };
  }

  /** A session by id, listed or not (pals.adopt, pal_adopt): read afresh from its transcript. */
  async find(sessionId: string): Promise<RecentEntry | string> {
    const listed = this.cache?.entries.find((e) => e.sessionId === sessionId);
    let info: SDKSessionInfo | undefined;
    try {
      info = (listed && (await this.source.info(sessionId, listed.cwd))) || (await this.source.info(sessionId));
    } catch (e) {
      this.d.log?.(`recent: getSessionInfo failed: ${e instanceof Error ? e.message : e}`);
    }
    if (!info) return t("pals.noSession");
    return this.check({ ...info, cwd: info.cwd || listed?.cwd });
  }

  /** A full session id from a listed one's first characters (at least 6, one match). */
  async fullId(key: string): Promise<string> {
    const k = key.trim();
    if (k.length < 6 || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(k)) return k;
    const hits = (await this.all()).filter((e) => e.sessionId.startsWith(k));
    return hits.length === 1 ? hits[0]!.sessionId : k;
  }
}

/** pals.recent's `folder`: a path (the folder or under it), or a folder's name. */
export function folderMatch(folder?: string): (cwd: string) => boolean {
  const f = String(folder ?? "").trim();
  if (!f) return () => true;
  if (f.startsWith("/") || f.startsWith("~")) {
    const p = f === "~" ? homedir() : f.startsWith("~/") ? join(homedir(), f.slice(2)) : f;
    const roots = [resolve(p), realOr(p)];
    return (cwd) => roots.some((r) => within(r, cwd));
  }
  const want = f.toLowerCase();
  return (cwd) => {
    const parts = cwd.toLowerCase().split(sep).filter(Boolean);
    return parts.includes(want) || (parts.at(-1) ?? "").includes(want);
  };
}

/** What the app gets. */
export function recentWire(e: RecentEntry): RecentSession {
  return { sessionId: e.sessionId, cwd: e.cwd, title: e.title, lastModified: e.lastModified, size: e.size };
}
