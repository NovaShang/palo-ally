import { copyFileSync, existsSync, lstatSync, openSync, readSync, closeSync, readdirSync, statSync } from "node:fs";
import { t } from "./i18n/index.ts";
import { createHash } from "node:crypto";
import { basename, dirname, extname, join, relative, resolve, sep } from "node:path";
import type { Bus } from "./bus.ts";
import type { Artifact } from "./types.ts";
import { ensureDir, readJson, writeJson } from "./util.ts";

const META = "meta.json";
export const CHUNK = 256 * 1024;

interface Meta {
  title?: string;
  type?: string;
  mainFile?: string;
  pinned?: boolean;
  updatedAt?: number;
  folder?: string;
  source?: string;
}

const MIME: Record<string, string> = {
  ".md": "text/markdown",
  ".markdown": "text/markdown",
  ".txt": "text/plain",
  ".html": "text/html",
  ".htm": "text/html",
  ".json": "application/json",
  ".csv": "text/csv",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
};

/** The name of the group an artifact is kept under (成果 → 按文件夹): one short line, no slashes. */
export function cleanFolder(raw: unknown): string {
  return typeof raw === "string" ? raw.replace(/[\\/\n\r\t]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 30) : "";
}

export function mimeOf(path: string): string {
  return MIME[extname(path).toLowerCase()] ?? "application/octet-stream";
}

// ArtifactLibrary implements the artifacts/ convention (PRD §6.7): one folder
// per artifact plus meta.json. Folders the agent wrote without publishing are
// still listed with inferred metadata. A scheduled job that rewrites the same
// folder makes a "live" artifact; polling picks up the change.
export class ArtifactLibrary {
  private signatures = new Map<string, number>();
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private dir: string, private bus: Bus) {
    ensureDir(dir);
  }

  list(): Artifact[] {
    let names: string[];
    try {
      names = readdirSync(this.dir);
    } catch {
      return [];
    }
    const out: Artifact[] = [];
    for (const name of names) {
      if (name.startsWith(".")) continue;
      const a = this.get(name);
      if (a) out.push(a);
    }
    return out.sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt);
  }

  get(id: string): Artifact | undefined {
    const folder = this.folder(id);
    if (!folder || !existsSync(folder) || !lstatSync(folder).isDirectory()) return undefined;
    const meta = readJson<Meta>(join(folder, META), {});
    const files = walk(folder).filter((f) => f.path !== META);
    const newest = files.reduce((m, f) => Math.max(m, f.mtime), 0);
    const mainFile =
      meta.mainFile && files.some((f) => f.path === meta.mainFile)
        ? meta.mainFile
        : (files.find((f) => /\.(md|html)$/i.test(f.path)) ?? files[0])?.path ?? "";
    return {
      id,
      title: meta.title || id,
      type: meta.type || (mainFile ? extname(mainFile).slice(1) || "file" : "folder"),
      mainFile,
      pinned: !!meta.pinned,
      folder: cleanFolder(meta.folder),
      ...(meta.source ? { source: meta.source } : {}),
      updatedAt: Math.max(meta.updatedAt ?? 0, newest),
      files: files.map((f) => ({ path: f.path, size: f.size })),
    };
  }

  /**
   * Publishes a file the way Claude Code's own Artifact tool does: the page
   * (or any file) at `filePath`, plus supporting files mapped published path →
   * source. Publishing the same path again updates the same artifact. A file
   * already inside artifacts/<slug>/ is published in place.
   */
  publishFile(filePath: string, opts: { title?: string; files?: Record<string, string>; folder?: string; source?: string } = {}): Artifact {
    const full = resolve(filePath);
    if (!existsSync(full) || !statSync(full).isFile()) throw new Error(t("artifact.notFile", { path: filePath }));
    const name = basename(full);
    let slug: string;
    let main: string;
    const inside = relative(this.dir, full);
    if (!inside.startsWith("..") && !inside.startsWith(sep) && inside.includes(sep)) {
      slug = inside.split(sep)[0]!;
      main = inside.slice(slug.length + 1);
    } else {
      const stem = name.slice(0, name.length - extname(name).length) || "file";
      const tag = createHash("sha1").update(dirname(full)).digest("hex").slice(0, 4);
      slug = `${stem.replace(/[^\w.\-一-龥]+/g, "-").replace(/^[-.]+/, "").slice(0, 50) || "file"}-${tag}`;
      main = name;
      ensureDir(join(this.dir, slug));
      copyFileSync(full, join(this.dir, slug, name));
    }
    const folder = join(this.dir, slug);
    for (const [published, source] of Object.entries(opts.files ?? {})) {
      const dest = resolve(folder, published);
      if (!dest.startsWith(folder + sep)) throw new Error(t("artifact.outside", { path: published }));
      ensureDir(dirname(dest));
      copyFileSync(resolve(dirname(full), source), dest);
    }
    // Keep an earlier title on re-publish (not the folder-name guess list() makes).
    const prevTitle = readJson<Meta>(join(folder, META), {}).title;
    return this.publish(slug, opts.title?.trim() || prevTitle || name, main, undefined, undefined, opts.folder, opts.source);
  }

  publish(slug: string, title: string, mainFile: string, type?: string, pinned?: boolean, group?: string, source?: string): Artifact {
    if (!/^[\w一-龥][\w.\-一-龥]*$/.test(slug)) throw new Error(t("artifact.badSlug"));
    const folder = join(this.dir, slug);
    ensureDir(folder);
    const prev = readJson<Meta>(join(folder, META), {});
    const meta: Meta = {
      ...prev,
      title,
      mainFile: mainFile.replace(/^\.?\//, ""),
      type: type ?? prev.type,
      pinned: pinned ?? prev.pinned ?? false,
      updatedAt: Date.now(),
    };
    // Where it came from: "palo" or a session's id; the latest publisher wins.
    if (source) meta.source = source;
    // Publishing again without a folder keeps the one it had; an empty one takes it out.
    if (group !== undefined) {
      const f = cleanFolder(group);
      if (f) meta.folder = f;
      else delete meta.folder;
    }
    writeJson(join(folder, META), meta);
    const a = this.get(slug)!;
    this.signatures.set(slug, a.updatedAt);
    this.bus.emit("artifact.updated", a);
    return a;
  }

  pin(id: string, pinned: boolean): Artifact {
    const folder = this.folder(id);
    if (!folder || !existsSync(folder)) throw new Error(t("artifact.none", { id }));
    const meta = readJson<Meta>(join(folder, META), {});
    writeJson(join(folder, META), { ...meta, pinned });
    const a = this.get(id)!;
    this.bus.emit("artifact.updated", a);
    return a;
  }

  read(id: string, path?: string, offset = 0, length = CHUNK): { data: string; size: number; mime: string; eof: boolean } {
    const a = this.get(id);
    if (!a) throw new Error(t("artifact.none", { id }));
    const rel = path ?? a.mainFile;
    const folder = this.folder(id)!;
    const full = resolve(folder, rel);
    if (!full.startsWith(folder + sep)) throw new Error(t("artifact.fileOutside"));
    if (lstatSync(full).isSymbolicLink()) throw new Error(t("artifact.fileOutside"));
    const size = statSync(full).size;
    const len = Math.max(0, Math.min(length, CHUNK, size - offset));
    const buf = Buffer.alloc(len);
    const fd = openSync(full, "r");
    try {
      readSync(fd, buf, 0, len, offset);
    } finally {
      closeSync(fd);
    }
    return { data: buf.toString("base64"), size, mime: mimeOf(full), eof: offset + len >= size };
  }

  // watch polls for changed folders and broadcasts them.
  watch(intervalMs = 15_000): void {
    for (const a of this.list()) this.signatures.set(a.id, a.updatedAt);
    this.timer = setInterval(() => this.scan(), intervalMs);
  }

  scan(): Artifact[] {
    const changed: Artifact[] = [];
    for (const a of this.list()) {
      if (this.signatures.get(a.id) !== a.updatedAt) {
        this.signatures.set(a.id, a.updatedAt);
        changed.push(a);
        this.bus.emit("artifact.updated", a);
      }
    }
    return changed;
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private folder(id: string): string | null {
    const f = resolve(this.dir, id);
    return f.startsWith(resolve(this.dir) + sep) ? f : null;
  }
}

const MAX_FILES = 500;

// walk lists an artifact folder. Symlinks are skipped (a link to / or a
// dangling one must not break the library), and the listing is capped.
function walk(root: string, dir = root, depth = 0, out: { path: string; size: number; mtime: number }[] = []) {
  if (depth > 4 || out.length >= MAX_FILES) return out;
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return out;
  }
  for (const name of names) {
    if (name.startsWith(".") || name === "node_modules" || out.length >= MAX_FILES) continue;
    const full = join(dir, name);
    let st;
    try {
      st = lstatSync(full);
    } catch {
      continue;
    }
    if (st.isSymbolicLink()) continue;
    if (st.isDirectory()) walk(root, full, depth + 1, out);
    else out.push({ path: relative(root, full), size: st.size, mtime: st.mtimeMs });
  }
  return out;
}
