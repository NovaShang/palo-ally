import { existsSync, openSync, readSync, closeSync, readdirSync, statSync } from "node:fs";
import { extname, join, relative, resolve, sep } from "node:path";
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
    if (!folder || !existsSync(folder) || !statSync(folder).isDirectory()) return undefined;
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
      updatedAt: Math.max(meta.updatedAt ?? 0, newest),
      files: files.map((f) => ({ path: f.path, size: f.size })),
    };
  }

  publish(slug: string, title: string, mainFile: string, type?: string, pinned?: boolean): Artifact {
    if (!/^[\w一-龥][\w.\-一-龥]*$/.test(slug)) throw new Error("slug 只能是字母数字、中文、- _ .");
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
    writeJson(join(folder, META), meta);
    const a = this.get(slug)!;
    this.signatures.set(slug, a.updatedAt);
    this.bus.emit("artifact.updated", a);
    return a;
  }

  pin(id: string, pinned: boolean): Artifact {
    const folder = this.folder(id);
    if (!folder || !existsSync(folder)) throw new Error(`没有这个产物：${id}`);
    const meta = readJson<Meta>(join(folder, META), {});
    writeJson(join(folder, META), { ...meta, pinned });
    const a = this.get(id)!;
    this.bus.emit("artifact.updated", a);
    return a;
  }

  read(id: string, path?: string, offset = 0, length = CHUNK): { data: string; size: number; mime: string; eof: boolean } {
    const a = this.get(id);
    if (!a) throw new Error(`没有这个产物：${id}`);
    const rel = path ?? a.mainFile;
    const folder = this.folder(id)!;
    const full = resolve(folder, rel);
    if (!full.startsWith(folder + sep)) throw new Error("路径越界");
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

function walk(root: string, dir = root, depth = 0): { path: string; size: number; mtime: number }[] {
  if (depth > 4) return [];
  const out: { path: string; size: number; mtime: number }[] = [];
  for (const name of readdirSync(dir)) {
    if (name.startsWith(".")) continue;
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) out.push(...walk(root, full, depth + 1));
    else out.push({ path: relative(root, full), size: st.size, mtime: st.mtimeMs });
  }
  return out;
}
