import type { ChatMessage } from "./types.ts";

/** A page: the `limit` before message `before` (its id, or a time in ms), or the newest; oldest first. */
export function pagePalMessages(all: ChatMessage[], before: string | number | undefined, limit: number): ChatMessage[] {
  let end = all.length;
  if (typeof before === "string" && before) {
    const i = all.findIndex((m) => m.id === before);
    if (i >= 0) end = i;
  } else if (typeof before === "number" && Number.isFinite(before)) {
    end = all.findIndex((m) => m.ts >= before);
    if (end < 0) end = all.length;
  }
  return all.slice(Math.max(0, end - limit), end);
}
