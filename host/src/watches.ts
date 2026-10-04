import type { Bus } from "./bus.ts";
import type { Watch } from "./types.ts";
import { newId, parseHHMM, readJson, writeJson } from "./util.ts";

export type WatchInput = {
  title: string;
  instruction: string;
  kind?: "check" | "schedule";
  intervalMinutes?: number;
  at?: string[];
  enabled?: boolean;
  skipIfActiveMinutes?: number;
};

// WatchStore persists the watch list (PRD §6.3.3). The agent registers watches
// with register_watch; the user can edit them from the client.
export class WatchStore {
  private watches: Watch[];

  constructor(private path: string, private bus: Bus) {
    this.watches = readJson<Watch[]>(path, []);
  }

  list(): Watch[] {
    return [...this.watches];
  }

  get(id: string): Watch | undefined {
    return this.watches.find((w) => w.id === id);
  }

  add(input: WatchInput, createdBy: "agent" | "user"): Watch {
    const w = validate({
      id: newId("w_"),
      title: input.title,
      instruction: input.instruction,
      kind: input.kind ?? (input.at?.length ? "schedule" : "check"),
      intervalMinutes: input.intervalMinutes,
      at: input.at,
      enabled: input.enabled ?? true,
      createdBy,
      createdAt: Date.now(),
      skipIfActiveMinutes: input.skipIfActiveMinutes,
    });
    this.watches.push(w);
    this.save();
    this.bus.emit("watch.updated", { watch: w });
    return w;
  }

  update(id: string, patch: Partial<Watch>): Watch {
    const w = this.get(id);
    if (!w) throw new Error(`没有这条盯梢：${id}`);
    const { id: _i, createdBy: _c, ...rest } = patch;
    // validate a copy first: a rejected patch must not half-apply
    const next = validate({ ...w, ...rest } as Watch);
    Object.assign(w, next);
    this.save();
    this.bus.emit("watch.updated", { watch: w });
    return w;
  }

  // touch updates bookkeeping fields without broadcasting a user-visible change.
  touch(id: string, patch: Partial<Watch>): void {
    const w = this.get(id);
    if (!w) return;
    Object.assign(w, patch);
    this.save();
  }

  remove(id: string): boolean {
    const before = this.watches.length;
    this.watches = this.watches.filter((w) => w.id !== id);
    if (before === this.watches.length) return false;
    this.save();
    this.bus.emit("watch.updated", { removed: id });
    return true;
  }

  private save(): void {
    writeJson(this.path, this.watches);
  }
}

function validate(w: Watch): Watch {
  if (!w.title?.trim()) throw new Error("watch 需要标题");
  if (!w.instruction?.trim()) throw new Error("watch 需要说明盯什么、怎么查");
  if (w.at) {
    if (!Array.isArray(w.at) || w.at.some((t) => parseHHMM(t) === null)) throw new Error("at 必须是 HH:MM 列表");
    if (!w.at.length) w.at = undefined;
  }
  if (w.kind === "check") {
    w.intervalMinutes = Math.max(5, Math.round(w.intervalMinutes ?? 60));
  } else if (!w.at && !w.intervalMinutes) {
    throw new Error("定时 watch 需要 at 或 intervalMinutes");
  } else if (w.intervalMinutes !== undefined && w.intervalMinutes !== null) {
    w.intervalMinutes = Math.max(5, Math.round(Number(w.intervalMinutes) || 5));
  }
  return w;
}
