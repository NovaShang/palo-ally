import { randomBytes } from "node:crypto";
import { t } from "./i18n/index.ts";
import { spawnSync } from "node:child_process";
import { appendFileSync, closeSync, copyFileSync, existsSync, linkSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";
import { CHUNK, mimeOf } from "./artifacts.ts";
import type { Attachment } from "./types.ts";

// What travels inside the conversation besides text: images the owner sends
// from the app, and images or files the assistant sends the owner
// (send_file). The relay caps a frame at 1 MiB (bento's MaxUnit), so an image
// is kept small enough to come back in one media.get, and other files are
// read in 256 KiB chunks (media.read), like artifacts.

const TYPES: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp" };
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const MAX_FILE_BYTES = 100 * 1024 * 1024;
// media.get sends one image in one relay frame (base64-inflated).
const FRAME_SAFE_BYTES = 700_000;
// Images the app can't show inline as-is; converted with macOS sips.
const CONVERTIBLE = new Set([".heic", ".heif", ".tif", ".tiff", ".bmp"]);

function sniff(b: Buffer): string | null {
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b.subarray(0, 3).toString() === "GIF") return "image/gif";
  if (b.subarray(0, 4).toString() === "RIFF" && b.subarray(8, 12).toString() === "WEBP") return "image/webp";
  return null;
}

const newId = (p: string) => `${p}_${Date.now().toString(36)}${randomBytes(4).toString("hex")}`;

const UPLOAD_CHUNK_MAX = 256 * 1024;
const SAFE_UUID = /^[0-9a-zA-Z-]{8,64}$/;

/** One chunk of a file the owner sends from the app (media.uploadChunk). */
export interface UploadChunk {
  uploadId?: string;
  name: string;
  mediaType?: string;
  offset: number;
  data: string; // base64, ≤ 256 KiB raw
  done: boolean;
}

export class MediaStore {
  /** In-flight uploads: id → bytes received so far. */
  private uploads = new Map<string, { name: string; mediaType: string; received: number }>();

  /** remember / recall, by message uuid (null: looked, nothing there). */
  private sent = new Map<string, { text: string; attachments: Attachment[] } | null>();

  constructor(private dir: string) {}

  /**
   * Files the owner sends from the app arrive in chunks (the relay caps a
   * frame at 1 MiB). Chunks must come in order; the last one (done) turns the
   * upload into a file attachment.
   */
  uploadChunk(c: UploadChunk): { uploadId: string } | Attachment {
    const name = basename(String(c.name ?? "").replace(/\\/g, "/")).trim();
    if (!name || name === "." || name === "..") throw new Error(t("media.badName"));
    const data = Buffer.from(String(c.data ?? ""), "base64");
    if (data.length > UPLOAD_CHUNK_MAX) throw new Error(t("media.chunkMax"));
    let id = c.uploadId ? String(c.uploadId) : "";
    let up = id ? this.uploads.get(id) : undefined;
    if (id && (!up || !/^up_[a-z0-9]+$/.test(id))) throw new Error(t("media.uploadStale"));
    if (!up) {
      if (Number(c.offset ?? 0) !== 0) throw new Error(t("media.uploadFromStart"));
      id = newId("up");
      up = { name, mediaType: String(c.mediaType || "") || mimeOf(name), received: 0 };
      this.uploads.set(id, up);
      mkdirSync(join(this.dir, "uploads"), { recursive: true });
      writeFileSync(join(this.dir, "uploads", id), Buffer.alloc(0));
    }
    const part = join(this.dir, "uploads", id);
    if (Number(c.offset) !== up.received) throw new Error(t("media.chunkOrder"));
    if (up.received + data.length > MAX_FILE_BYTES) {
      this.uploads.delete(id);
      rmSync(part, { force: true });
      throw new Error(t("media.fileTooBig"));
    }
    appendFileSync(part, data);
    up.received += data.length;
    if (!c.done) return { uploadId: id };
    this.uploads.delete(id);
    if (!up.received) {
      rmSync(part, { force: true });
      throw new Error(t("media.fileEmpty"));
    }
    const fid = newId("file");
    mkdirSync(join(this.dir, fid), { recursive: true });
    renameSync(part, join(this.dir, fid, up.name));
    return { id: fid, kind: "file", mediaType: up.mediaType, name: up.name, size: up.received };
  }

  /** The attachment record for a stored image or file id, or null. */
  attachment(id: string): Attachment | null {
    const img = this.read(id);
    if (img) return { id, kind: "image", mediaType: img.mediaType };
    const path = /^file_[a-z0-9]+$/.test(id) ? this.filePath(id) : null;
    if (!path) return null;
    return { id, kind: "file", mediaType: mimeOf(path), name: basename(path), size: statSync(path).size };
  }

  save(mediaType: string, base64: string): Attachment {
    const ext = TYPES[mediaType];
    if (!ext) throw new Error(t("media.imageTypes"));
    const data = Buffer.from(base64, "base64");
    if (!data.length) throw new Error(t("media.imageEmpty"));
    if (data.length > MAX_IMAGE_BYTES) throw new Error(t("media.imageTooBig"));
    mkdirSync(this.dir, { recursive: true });
    const id = newId("img");
    writeFileSync(join(this.dir, `${id}.${ext}`), data);
    return { id, kind: "image", mediaType };
  }

  /**
   * A local file the assistant sends the owner. Images show inline (large or
   * HEIC/TIFF ones are converted to a ≤1568 px JPEG); anything else becomes a
   * file the app previews.
   */
  saveFile(path: string): Attachment {
    if (!existsSync(path) || !statSync(path).isFile()) throw new Error(t("media.notFound", { path }));
    const size = statSync(path).size;
    const head = Buffer.alloc(Math.min(size, 16));
    const fd = openSync(path, "r");
    try {
      readSync(fd, head, 0, head.length, 0);
    } finally {
      closeSync(fd);
    }
    const type = sniff(head);
    if (type && size <= FRAME_SAFE_BYTES) return this.save(type, readFileSync(path).toString("base64"));
    if (type || CONVERTIBLE.has(extname(path).toLowerCase())) {
      const jpeg = toJpeg(path);
      if (jpeg) return this.save("image/jpeg", jpeg.toString("base64"));
    }
    if (size > MAX_FILE_BYTES) throw new Error(t("media.fileTooBig"));
    const id = newId("file");
    const name = basename(path);
    mkdirSync(join(this.dir, id), { recursive: true });
    copyFileSync(path, join(this.dir, id, name));
    return { id, kind: "file", mediaType: mimeOf(path), name, size };
  }

  /** A stored image, or null for an unknown / malformed id. */
  read(id: string): { mediaType: string; data: string; path: string } | null {
    if (!/^img_[a-z0-9]+$/.test(id)) return null;
    for (const [mediaType, ext] of Object.entries(TYPES)) {
      const path = join(this.dir, `${id}.${ext}`);
      if (existsSync(path)) return { mediaType, data: readFileSync(path).toString("base64"), path };
    }
    return null;
  }

  /** One chunk of a stored file (same shape as artifact.read). */
  readChunk(id: string, offset = 0, length = CHUNK): { data: string; size: number; mime: string; eof: boolean } {
    const full = this.filePath(id);
    if (!full) throw new Error(t("media.noSuchFile"));
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

  /**
   * A file the owner sent a Pal, where the Pal reads it: its own folder's
   * `.paloally/inbox/<id>/<name>`. Inside its working directory Claude Code
   * reads it without asking (outside, every Read is a card); the folder
   * ignores itself for git. A hard link where it can be (no second copy),
   * else a copy. A folder it can't write to: the stored file's own path.
   */
  inbox(id: string, cwd: string): string | null {
    const from = this.filePath(id);
    if (!from) return null;
    try {
      const root = join(cwd, ".paloally");
      const dir = join(root, "inbox", id);
      const to = join(dir, basename(from));
      mkdirSync(dir, { recursive: true });
      if (!existsSync(join(root, ".gitignore"))) writeFileSync(join(root, ".gitignore"), "# PaloAlly: files sent from the app\n*\n");
      if (!existsSync(to)) {
        try {
          linkSync(from, to);
        } catch {
          copyFileSync(from, to);
        }
      }
      return to;
    } catch {
      return from;
    }
  }

  /**
   * What the owner sent a Pal under one message uuid: the words as typed and
   * what went with them. A Pal's page reads its transcript, where an image
   * is only its bytes and a file only a path; this gives the page back the
   * message as sent.
   */
  remember(uuid: string, sent: { text: string; attachments: Attachment[] }): void {
    if (!SAFE_UUID.test(uuid)) return;
    this.sent.set(uuid, sent);
    try {
      mkdirSync(join(this.dir, "sent"), { recursive: true });
      writeFileSync(join(this.dir, "sent", `${uuid}.json`), JSON.stringify(sent));
    } catch {
      /* the page then shows the transcript's words */
    }
  }

  recall(uuid: string): { text: string; attachments: Attachment[] } | undefined {
    if (!SAFE_UUID.test(uuid)) return undefined;
    const have = this.sent.get(uuid);
    if (have !== undefined) return have ?? undefined;
    const path = join(this.dir, "sent", `${uuid}.json`);
    let got: { text: string; attachments: Attachment[] } | null = null;
    if (existsSync(path)) {
      try {
        const v = JSON.parse(readFileSync(path, "utf8"));
        if (typeof v?.text === "string" && Array.isArray(v.attachments)) got = v;
      } catch {
        /* torn */
      }
    }
    this.sent.set(uuid, got);
    if (this.sent.size > 2000) this.sent.delete(this.sent.keys().next().value!);
    return got ?? undefined;
  }

  filePath(id: string): string | null {
    if (/^img_[a-z0-9]+$/.test(id)) return this.read(id)?.path ?? null;
    if (!/^file_[a-z0-9]+$/.test(id)) return null;
    const folder = join(this.dir, id);
    if (!existsSync(folder)) return null;
    const name = readdirSync(folder)[0];
    return name ? join(folder, name) : null;
  }
}

// ≤1568 px JPEG small enough for one relay frame, via macOS sips.
function toJpeg(path: string): Buffer | null {
  const out = join(tmpdir(), `paloally-${randomBytes(6).toString("hex")}.jpg`);
  try {
    for (const [edge, q] of [[1568, 80], [1200, 70], [1000, 60]] as const) {
      const r = spawnSync("sips", ["-Z", String(edge), "-s", "format", "jpeg", "-s", "formatOptions", String(q), path, "--out", out], { stdio: "ignore" });
      if (r.status !== 0 || !existsSync(out)) return null;
      const data = readFileSync(out);
      if (sniff(data) === "image/jpeg" && data.length <= FRAME_SAFE_BYTES) return data;
    }
    return null;
  } finally {
    rmSync(out, { force: true });
  }
}
