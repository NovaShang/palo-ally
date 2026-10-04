import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
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

export class MediaStore {
  constructor(private dir: string) {}

  save(mediaType: string, base64: string): Attachment {
    const ext = TYPES[mediaType];
    if (!ext) throw new Error("只支持 JPEG、PNG、GIF、WebP 图片");
    const data = Buffer.from(base64, "base64");
    if (!data.length) throw new Error("图片是空的");
    if (data.length > MAX_IMAGE_BYTES) throw new Error("图片太大（最多 5MB）");
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
    if (!existsSync(path) || !statSync(path).isFile()) throw new Error(`找不到文件：${path}`);
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
    if (size > MAX_FILE_BYTES) throw new Error("文件太大（最多 100MB）");
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
    if (!full) throw new Error("找不到这个文件");
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
