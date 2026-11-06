import { chmodSync, closeSync, fsyncSync, lstatSync, openSync, readdirSync, readSync, realpathSync, renameSync, statSync, unlinkSync, writeSync, type Stats } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { Audit } from "./audit.ts";
import { CHUNK, mimeOf } from "./artifacts.ts";
import type { Paths } from "./config.ts";
import { t } from "./i18n/index.ts";
import { newId, readJson, writeJson } from "./util.ts";

// Files on the computer (docs/files-prd.md), read, and a text file written
// back from the app's editor (`files.write`): a Pal's project
// folder, the assistant's home (its working folder and its artifacts),
// folders the owner chose, and the owner's own home folder (Palo's 文件 can
// switch to it; its dot files stay out unless asked for). Every path is resolved to its real path (symlinks
// followed) and must stay inside the scope's root; PaloAlly's own state is
// never readable, whatever the scope. Except `root`: the whole disk, by
// absolute path, for a right-pane preview tab (it keeps the file's absolute
// path); nothing is held back there for now.

export type FileScope = { kind: "pal"; id: string } | { kind: "palo" } | { kind: "home" } | { kind: "folder"; id: string } | { kind: "root" };

export interface FileEntry {
  name: string;
  kind: "file" | "dir";
  size: number;
  mtime: number; // ms
}

/** A folder the owner opened from the preview pane (「打开文件夹…」). */
export interface OwnerFolder {
  id: string;
  path: string;
  name: string;
  addedAt: number;
}

/** Hidden unless asked for (`showHidden`): heavy or machine-made. */
export const HIDDEN_NAMES: ReadonlySet<string> = new Set([".git", "node_modules", ".build", "DerivedData", ".DS_Store"]);
/** Never walked by a search (it would spend the whole budget there). */
const SEARCH_SKIP: ReadonlySet<string> = new Set([
  ...HIDDEN_NAMES, ".swiftpm", "Pods", "__pycache__", ".venv", "venv", ".cache", ".next", ".gradle", ".Trash", "SourcePackages",
]);
/** Bigger than this: its size and path only, never its bytes. */
export const MAX_READ_BYTES = 5 * 1024 * 1024;
/** What the app's editor may write back (it edits text up to 1 MB). */
export const MAX_WRITE_BYTES = 1024 * 1024;
const MAX_LIST = 2000;
const MAX_FOLDERS = 50;

export interface FileBrowserDeps {
  paths: Paths;
  audit: Audit;
  /** A Pal's project folder (its cwd), by Pal id. */
  palCwd: (id: string) => string | undefined;
  /** `~` (tests point it at a temp folder). */
  homeDir?: () => string;
  now?: () => number;
}

export class FileBrowser {
  private readonly home: () => string;
  private readonly now: () => number;

  constructor(private readonly d: FileBrowserDeps) {
    this.home = d.homeDir ?? homedir;
    this.now = d.now ?? Date.now;
  }

  private get foldersPath(): string {
    return join(this.d.paths.state, "folders.json");
  }

  // ---------------- scopes ----------------

  /** The scope's root, as a real path. */
  root(scope: FileScope): string {
    let dir: string | undefined;
    if (scope.kind === "root") return "/";
    if (scope.kind === "palo") dir = this.d.paths.home;
    else if (scope.kind === "home") dir = this.home();
    else if (scope.kind === "pal") dir = this.d.palCwd(scope.id);
    else dir = this.folders().find((f) => f.id === scope.id)?.path;
    if (!dir) throw new Error(t("files.err.noScope"));
    const real = realOrNull(dir);
    if (!real || !statSync(real).isDirectory()) throw new Error(t("files.err.rootGone"));
    return real;
  }

  /**
   * `path` (relative to the root, absolute, or `~/…`) as a real path inside
   * the scope's root; anything else is refused the same way, whether it's
   * missing or outside.
   */
  private locate(scope: FileScope, path: string): { root: string; real: string; rel: string } {
    const root = this.root(scope);
    // The whole disk: any path that exists. A policy the owner sets on the
    // computer (which folders a device may read) would go here, when there is one.
    const real = scope.kind === "root" ? (path.includes("\0") ? null : realOrNull(this.expand(path, root))) : this.inside(root, this.expand(path, root));
    if (!real) throw new Error(t("files.err.notFound"));
    if (scope.kind === "root") return { root, real, rel: real };
    return { root, real, rel: relative(root, real).split(sep).join("/") };
  }

  /** The real path of `abs` when it exists and stays inside `root` (and out of PaloAlly's own state). */
  private inside(root: string, abs: string): string | null {
    if (abs.includes("\0")) return null;
    const real = realOrNull(abs);
    if (!real || !within(real, root) || this.forbidden(real)) return null;
    return real;
  }

  private expand(path: string, base: string): string {
    const p = path.trim();
    if (p === "~") return this.home();
    if (p.startsWith("~/")) return join(this.home(), p.slice(2));
    return isAbsolute(p) ? resolve(p) : resolve(base, p);
  }

  /** PaloAlly's own folder (keys, paired devices, the conversation): never, except the assistant's home. */
  private forbidden(real: string): boolean {
    const own = realOrNull(this.d.paths.root);
    if (!own || !within(real, own)) return false;
    const home = realOrNull(this.d.paths.home);
    return !home || !within(real, home);
  }

  // ---------------- files.list ----------------

  list(scope: FileScope, path = "", showHidden = false): { root: string; path: string; entries: FileEntry[]; truncated: boolean } {
    const { root, real, rel } = this.locate(scope, path || ".");
    if (!statSync(real).isDirectory()) throw new Error(t("files.err.notDir"));
    const entries: FileEntry[] = [];
    let names: string[];
    try {
      names = readdirSync(real);
    } catch {
      throw new Error(t("files.err.cantRead"));
    }
    for (const name of names) {
      if (!showHidden && HIDDEN_NAMES.has(name)) continue;
      // The owner's home: dot files (keys, apps' settings) only when asked for.
      if (!showHidden && scope.kind === "home" && name.startsWith(".")) continue;
      const e = this.entry(root, join(real, name), name);
      if (e) entries.push(e);
    }
    entries.sort(byKindThenName);
    return { root, path: rel, entries: entries.slice(0, MAX_LIST), truncated: entries.length > MAX_LIST };
  }

  /** One child, as the owner would see it; a link only when it points inside the root. */
  private entry(root: string, abs: string, name: string): FileEntry | null {
    if (this.forbidden(abs)) return null;
    let st: Stats;
    try {
      st = lstatSync(abs);
      if (st.isSymbolicLink()) {
        const target = this.inside(root, abs);
        if (!target) return null;
        st = statSync(target);
      }
    } catch {
      return null;
    }
    if (!st.isDirectory() && !st.isFile()) return null;
    return { name, kind: st.isDirectory() ? "dir" : "file", size: st.isDirectory() ? 0 : st.size, mtime: Math.round(st.mtimeMs) };
  }

  // ---------------- files.read ----------------

  /**
   * A chunk of a file, like artifact.read (≤ 256 KiB each). Over 5 MB: its
   * size only (`tooLarge`), nothing read. The first chunk is audited.
   */
  read(scope: FileScope, path: string, offset = 0, length = CHUNK, by = "app"):
    { data: string; size: number; mime: string; eof: boolean; tooLarge?: boolean; version: string } {
    const { real, rel } = this.locate(scope, path);
    const st = statSync(real);
    if (st.isDirectory()) throw new Error(t("files.err.isDir"));
    if (!st.isFile()) throw new Error(t("files.err.notFound"));
    const mime = mimeOf(real);
    const start = Math.max(0, Math.floor(Number(offset) || 0));
    if (start === 0) this.d.audit.log("files.read", { scope: scopeLabel(scope), path: rel, size: st.size, by, ...(st.size > MAX_READ_BYTES ? { tooLarge: true } : {}) });
    const version = versionOf(st);
    if (st.size > MAX_READ_BYTES) return { data: "", size: st.size, mime, eof: true, tooLarge: true, version };
    const len = Math.max(0, Math.min(Math.floor(Number(length) || CHUNK), CHUNK, st.size - start));
    const buf = Buffer.alloc(len);
    if (len > 0) {
      const fd = openSync(real, "r");
      try {
        readSync(fd, buf, 0, len, start);
      } finally {
        closeSync(fd);
      }
    }
    return { data: buf.toString("base64"), size: st.size, mime, eof: start + len >= st.size, version };
  }

  // ---------------- files.write ----------------

  /**
   * A text file the owner edited in the app, written back whole. Only an
   * existing file, only while it is still the version the app read
   * (`baseVersion`, from `files.read`): changed meanwhile, nothing is
   * written and the app is told (`conflict`), so an edit made on the
   * computer is never lost without the owner choosing to. Written to a temp
   * file beside it and renamed over it (never half a file), its mode kept.
   */
  write(scope: FileScope, path: string, content: string, baseVersion: string, by = "app"):
    { version: string; size: number; mtime: number; conflict?: true } {
    const { real, rel } = this.locate(scope, path);
    // PaloAlly's own state, whatever the scope (`root` reads anything).
    if (this.forbidden(real)) throw new Error(t("files.err.notFound"));
    const st = statSync(real);
    if (st.isDirectory()) throw new Error(t("files.err.isDir"));
    if (!st.isFile()) throw new Error(t("files.err.notFound"));
    const bytes = Buffer.from(content, "utf8");
    if (bytes.length > MAX_WRITE_BYTES) throw new Error(t("files.err.tooLargeToWrite"));
    const now = versionOf(st);
    if (now !== baseVersion) return { version: now, size: st.size, mtime: Math.round(st.mtimeMs), conflict: true };
    const temp = join(dirname(real), `.${basename(real)}.paloally-${randomBytes(4).toString("hex")}.tmp`);
    try {
      const fd = openSync(temp, "wx", st.mode & 0o777);
      try {
        writeSync(fd, bytes, 0, bytes.length, 0);
        fsyncSync(fd);
      } finally {
        closeSync(fd);
      }
      // The umask may have taken bits off.
      chmodSync(temp, st.mode & 0o7777);
      renameSync(temp, real);
    } catch (e) {
      try {
        unlinkSync(temp);
      } catch {
        // never made
      }
      const code = (e as NodeJS.ErrnoException).code;
      throw new Error(t(code === "EACCES" || code === "EPERM" || code === "EROFS" ? "files.err.cantWrite" : "files.err.writeFailed"));
    }
    const after = statSync(real);
    this.d.audit.log("files.write", { scope: scopeLabel(scope), path: rel, bytes: bytes.length, by });
    return { version: versionOf(after), size: after.size, mtime: Math.round(after.mtimeMs) };
  }

  // ---------------- files.watch (its stat) ----------------

  /** A file's real path, size and modification time (ms); the same refusals as a read. Not audited. */
  stat(scope: FileScope, path: string): { real: string; size: number; mtime: number } {
    const { real } = this.locate(scope, path);
    const st = statSync(real);
    if (st.isDirectory()) throw new Error(t("files.err.isDir"));
    if (!st.isFile()) throw new Error(t("files.err.notFound"));
    return { real, size: st.size, mtime: Math.round(st.mtimeMs) };
  }

  // ---------------- files.search ----------------

  /**
   * File and folder names matching `query` (case-insensitive; a query with
   * "/" matches the path), best first: the name itself, then names starting
   * with it, then containing it; shallow before deep. A walk that ran out of
   * its budget says `partial`.
   */
  search(scope: FileScope, query: string, limit = 50, budget = { maxDirs: 4000, ms: 1500 }):
    { matches: { path: string; kind: "file" | "dir" }[]; partial: boolean } {
    const root = this.root(scope);
    const q = query.trim().toLowerCase().replace(/^\.\/+/, "");
    if (!q || q.includes("\0")) return { matches: [], partial: false };
    const byPath = q.includes("/");
    const scored: { score: number[]; path: string; kind: "file" | "dir" }[] = [];
    const queue: string[] = [""];
    const deadline = Date.now() + budget.ms;
    let dirs = 0;
    let partial = false;
    while (queue.length) {
      if (dirs >= budget.maxDirs || Date.now() > deadline || scored.length >= 5000) {
        partial = true;
        break;
      }
      const rel = queue.shift()!;
      dirs++;
      let kids: import("node:fs").Dirent[];
      try {
        kids = readdirSync(join(root, rel), { withFileTypes: true });
      } catch {
        continue;
      }
      for (const k of kids) {
        const childRel = rel ? `${rel}/${k.name}` : k.name;
        // The owner's home: its dot files and folders are never searched.
        if (scope.kind === "home" && k.name.startsWith(".")) continue;
        let kind: "file" | "dir" | null = k.isDirectory() ? "dir" : k.isFile() ? "file" : null;
        // A link: listed when it points inside; never walked into (no loops).
        if (k.isSymbolicLink()) {
          const target = this.inside(root, join(root, childRel));
          kind = target ? (statSync(target).isDirectory() ? "dir" : "file") : null;
        }
        if (!kind) continue;
        const score = rank(byPath ? childRel.toLowerCase() : k.name.toLowerCase(), q, childRel, kind);
        if (score) scored.push({ score, path: childRel, kind });
        if (k.isDirectory() && !SEARCH_SKIP.has(k.name) && !this.forbidden(join(root, childRel))) queue.push(childRel);
      }
    }
    scored.sort((a, b) => compareScores(a.score, b.score) || a.path.localeCompare(b.path));
    const n = Math.max(1, Math.min(Math.floor(limit) || 50, 200));
    return { matches: scored.slice(0, n).map(({ path, kind }) => ({ path, kind })), partial };
  }

  // ---------------- files.resolve ----------------

  /**
   * Paths written in a reply, as files the app can preview. A relative path
   * resolves against the Pal's project folder (Palo: its home, then its
   * artifacts; a folder: that folder); a bare name or a path cut short is
   * looked up in the tree when it isn't there. Unresolved ones are left out.
   */
  resolve(scope: FileScope, candidates: string[]): { files: { text: string; path: string; abs: string; size: number }[] } {
    const root = this.root(scope);
    const bases = scope.kind === "palo" ? [root, join(root, "artifacts")] : [root];
    const out: { text: string; path: string; abs: string; size: number }[] = [];
    const seen = new Set<string>();
    // The tree walks for names that aren't where the reply said: a few, and
    // a second in all, so one message full of names can't keep the host busy.
    let walks = 0;
    const walkUntil = Date.now() + 1000;
    for (const raw of candidates.slice(0, 40)) {
      if (typeof raw !== "string") continue;
      const text = raw.slice(0, 1024);
      if (seen.has(text)) continue;
      seen.add(text);
      const p = cleanCandidate(text);
      if (!p) continue;
      let hit: string | null = null;
      for (const base of p.startsWith("/") || p.startsWith("~") ? [root] : bases) {
        const real = this.inside(root, this.expand(p, base));
        if (real && statSync(real).isFile()) {
          hit = real;
          break;
        }
      }
      if (!hit && !p.startsWith("/") && !p.startsWith("~") && !p.split("/").includes("..") && walks < 8 && Date.now() < walkUntil) {
        walks++;
        // A short walk: the name may sit deeper than the reply said.
        const want = p.replace(/^\.\/+/, "");
        const found = this.search(scope, want.split("/").pop()!, 20, { maxDirs: 600, ms: 300 }).matches.find(
          (m) => m.kind === "file" && (m.path === want || m.path.endsWith(`/${want}`)),
        );
        if (found) hit = this.inside(root, join(root, found.path));
      }
      if (!hit) continue;
      // `abs`: the file's absolute path, the way a right-pane tab keeps it.
      out.push({ text, path: relative(root, hit).split(sep).join("/"), abs: hit, size: statSync(hit).size });
    }
    return { files: out };
  }

  // ---------------- the owner's folders ----------------

  folders(): OwnerFolder[] {
    return readJson<OwnerFolder[]>(this.foldersPath, []);
  }

  /**
   * One level of the computer's folders, to pick one from (folders only,
   * names only; starts at the home folder).
   */
  browse(path?: string, showHidden = false): { path: string; parent: string | null; entries: FileEntry[]; truncated: boolean } {
    const at = path && path.trim() ? this.expand(path, this.home()) : this.home();
    const real = realOrNull(at);
    if (!real || !statSync(real).isDirectory()) throw new Error(t("files.err.notFound"));
    let names: string[];
    try {
      names = readdirSync(real);
    } catch {
      throw new Error(t("files.err.cantRead"));
    }
    const entries: FileEntry[] = [];
    for (const name of names) {
      if (!showHidden && (name.startsWith(".") || HIDDEN_NAMES.has(name))) continue;
      try {
        const st = statSync(join(real, name));
        if (st.isDirectory()) entries.push({ name, kind: "dir", size: 0, mtime: Math.round(st.mtimeMs) });
      } catch {
        // a broken link: not a folder
      }
    }
    entries.sort(byKindThenName);
    const parent = real === "/" ? null : dirname(real);
    return { path: real, parent, entries: entries.slice(0, MAX_LIST), truncated: entries.length > MAX_LIST };
  }

  /** Remember a folder the owner picked. The disk's root, the home folder itself and PaloAlly's own are refused. */
  addFolder(path: string, by = "app"): OwnerFolder {
    const real = path && path.trim() ? realOrNull(this.expand(path, this.home())) : null;
    if (!real || !statSync(real).isDirectory()) throw new Error(t("files.err.notFound"));
    const own = realOrNull(this.d.paths.root) ?? this.d.paths.root;
    const home = realOrNull(this.home()) ?? this.home();
    if (real === "/" || real === home || within(own, real) || within(real, own)) throw new Error(t("files.err.folderNotAllowed"));
    const list = this.folders();
    const had = list.find((f) => f.path === real);
    if (had) return had;
    if (list.length >= MAX_FOLDERS) throw new Error(t("files.err.tooManyFolders", { max: MAX_FOLDERS }));
    const folder: OwnerFolder = { id: newId("fld_"), path: real, name: basename(real), addedAt: this.now() };
    writeJson(this.foldersPath, [...list, folder]);
    this.d.audit.log("files.folder.added", { id: folder.id, path: real, by });
    return folder;
  }

  removeFolder(id: string, by = "app"): void {
    const list = this.folders();
    const f = list.find((x) => x.id === id);
    if (!f) throw new Error(t("files.err.noScope"));
    writeJson(this.foldersPath, list.filter((x) => x.id !== id));
    this.d.audit.log("files.folder.removed", { id, path: f.path, by });
  }
}

/** A scope from the wire; anything else is refused. */
export function parseScope(v: unknown): FileScope {
  const s = v as { kind?: unknown; id?: unknown } | null;
  if (s && s.kind === "palo") return { kind: "palo" };
  if (s && s.kind === "home") return { kind: "home" };
  if (s && s.kind === "root") return { kind: "root" };
  if (s && (s.kind === "pal" || s.kind === "folder") && typeof s.id === "string" && s.id) return { kind: s.kind, id: s.id.slice(0, 100) };
  throw new Error(t("files.err.noScope"));
}

export function scopeLabel(s: FileScope): string {
  return s.kind === "palo" || s.kind === "home" || s.kind === "root" ? s.kind : `${s.kind}:${s.id}`;
}

/** A file's version as the editor knows it: its modification time (ms) and size. */
export function versionOf(st: Stats): string {
  return `${Math.round(st.mtimeMs)}:${st.size}`;
}

function realOrNull(p: string): string | null {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
}

/** `p` is `root` or below it (both real paths). */
function within(p: string, root: string): boolean {
  if (p === root) return true;
  return p.startsWith(root.endsWith(sep) ? root : root + sep);
}

function byKindThenName(a: FileEntry, b: FileEntry): number {
  if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
  return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
}

/** How well `hay` (a lowercased name or path) matches `q`: lower is better; null when it doesn't. */
function rank(hay: string, q: string, rel: string, kind: "file" | "dir"): number[] | null {
  let how: number;
  if (hay === q || hay.endsWith(`/${q}`)) how = 0;
  else if (hay.startsWith(q) || hay.includes(`/${q}`)) how = 1;
  else if (hay.includes(q)) how = 2;
  else return null;
  return [how, kind === "file" ? 0 : 1, rel.split("/").length, rel.length];
}

function compareScores(a: number[], b: number[]): number {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i]! - b[i]!;
  return 0;
}

/** A path as written in a reply: quotes, a trailing `:line[:col]` and closing punctuation off. */
export function cleanCandidate(text: string): string | null {
  let p = text.trim();
  for (let prev = ""; prev !== p; ) {
    prev = p;
    p = p.replace(/^[`'"「（(]+|[`'"」）)]+$/gu, "").replace(/[.,;:!?。，；：！？、]+$/u, "");
  }
  p = p.replace(/:\d{1,6}(:\d{1,6})?$/, "");
  if (!p || p === "/" || p === "~" || p === "." || p === ".." || p.length > 1024) return null;
  return p;
}
