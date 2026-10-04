import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Attachment } from "./types.ts";

// Images the owner sends from the app. Uploaded one per RPC call (the relay
// caps a frame at 1 MiB, bento's MaxUnit), then referenced by id from
// chat.send. The app downsizes to ≤1568 px JPEG first, like bento's
// ImageAttachmentProcessor — the formats Claude accepts.

const TYPES: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp" };
const MAX_BYTES = 5 * 1024 * 1024;

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
