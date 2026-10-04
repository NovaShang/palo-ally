import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Attachment } from "./types.ts";

// Images the owner sends from the app. Uploaded one per RPC call (the relay
// caps a frame at 1 MiB, bento's MaxUnit), then referenced by id from
// chat.send. The app downsizes to ≤1568 px JPEG first, like bento's
// ImageAttachmentProcessor — the formats Claude accepts.

const TYPES: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp" };
const MAX_BYTES = 5 * 1024 * 1024;
// media.get sends one image in one relay frame (1 MiB, base64-inflated).
const FRAME_SAFE_BYTES = 700_000;

function sniff(b: Buffer): string | null {
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b.subarray(0, 3).toString() === "GIF") return "image/gif";
  if (b.subarray(0, 4).toString() === "RIFF" && b.subarray(8, 12).toString() === "WEBP") return "image/webp";
  return null;
}

export class MediaStore {
  constructor(private dir: string) {}

  save(mediaType: string, base64: string): Attachment {
    const ext = TYPES[mediaType];
    if (!ext) throw new Error("只支持 JPEG、PNG、GIF、WebP 图片");
    const data = Buffer.from(base64, "base64");
    if (!data.length) throw new Error("图片是空的");
    if (data.length > MAX_BYTES) throw new Error("图片太大（最多 5MB）");
    mkdirSync(this.dir, { recursive: true });
    const id = `img_${Date.now().toString(36)}${randomBytes(4).toString("hex")}`;
    writeFileSync(this.file(id, ext), data);
    return { id, kind: "image", mediaType };
  }

  /**
   * An image file the assistant wants to show the owner (a screenshot, a
   * chart). Anything that isn't a small PNG/JPEG/GIF/WebP is converted with
   * macOS `sips` to a ≤1568 px JPEG so it fits one relay frame.
   */
  saveFile(path: string): Attachment {
    let data = readFileSync(path);
    let type = sniff(data);
    if (!type || data.length > FRAME_SAFE_BYTES) {
      const out = join(tmpdir(), `paloally-${randomBytes(6).toString("hex")}.jpg`);
      for (const [edge, q] of [[1568, 80], [1200, 70], [1000, 60]] as const) {
        const r = spawnSync("sips", ["-Z", String(edge), "-s", "format", "jpeg", "-s", "formatOptions", String(q), path, "--out", out], { stdio: "ignore" });
        if (r.status === 0 && existsSync(out)) {
          data = readFileSync(out);
          type = "image/jpeg";
          if (data.length <= FRAME_SAFE_BYTES) break;
        }
      }
      rmSync(out, { force: true });
      if (!type || sniff(data) !== type) throw new Error("这个文件不是能显示的图片");
      if (data.length > FRAME_SAFE_BYTES) throw new Error("图片太大，压不下来");
    }
    return this.save(type, data.toString("base64"));
  }

  /** The stored image, or null for an unknown / malformed id. */
  read(id: string): { mediaType: string; data: string; path: string } | null {
    if (!/^img_[a-z0-9]+$/.test(id)) return null;
    for (const [mediaType, ext] of Object.entries(TYPES)) {
      const path = this.file(id, ext);
      if (existsSync(path)) return { mediaType, data: readFileSync(path).toString("base64"), path };
    }
    return null;
  }

  private file(id: string, ext: string): string {
    return join(this.dir, `${id}.${ext}`);
  }
}
