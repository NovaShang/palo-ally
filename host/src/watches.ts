import type { Bus } from "./bus.ts";
import type { GoalState, Watch } from "./types.ts";
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

const HISTORY = 8;
const PROGRESS_MAX = 80;
const GOAL_STATES: GoalState[] = ["tracking", "waiting", "done", "paused"];

export type GoalUpdate = { state?: GoalState; ratio?: number | null; outcome?: string };

// WatchStore persists the watch list (PRD §6.3.3). The agent registers watches
// with register_watch; the user can edit them from the client. The owner sees
// each one as a 「目标」: a progress line and a state on top of the mechanism.
export class WatchStore {
  private watches: Watch[];

  constructor(private path: string, private bus: Bus) {
    // Older lists have no goal fields: fill in the state from `enabled`.
    this.watches = readJson<Watch[]>(path, []).map((w) => ({ ...w, state: w.state ?? (w.enabled ? "tracking" : "paused") }));
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
      state: input.enabled === false ? "paused" : "tracking",
    });
    this.watches.push(w);
    this.save();
    this.bus.emit("watch.updated", { watch: w });
    return w;
  }

  update(id: string, patch: Partial<Watch>): Watch {
    const w = this.get(id);
    if (!w) throw new Error(`没有这个目标：${id}`);
    const { id: _i, createdBy: _c, ...rest } = patch;
    // validate a copy first: a rejected patch must not half-apply
    const next = validate(syncState(w, { ...w, ...rest } as Watch, rest));
    Object.assign(w, next);
    this.save();
    this.bus.emit("watch.updated", { watch: w });
    return w;
  }

  /**
   * A new progress line for the goal (from update_goal, a probe check or a
   * schedule run). `state` done/paused also stops the mechanism; tracking or
   * waiting runs it again.
   */
  progress(id: string, text: string, upd: GoalUpdate = {}): Watch {
    const w = this.get(id);
    if (!w) throw new Error(`没有这个目标：${id}`);
    const line = oneLine(text);
    if (upd.state && !GOAL_STATES.includes(upd.state)) throw new Error(`state 只能是 ${GOAL_STATES.join(" / ")}`);
    const now = Date.now();
    if (line) {
      w.progress = line;
      w.progressAt = now;
      w.history = [...(w.history ?? []), { at: now, text: line }].slice(-HISTORY);
    }
    if (upd.ratio === null) delete w.ratio;
    else if (upd.ratio !== undefined && Number.isFinite(upd.ratio)) w.ratio = Math.min(1, Math.max(0, upd.ratio));
    if (upd.outcome) w.outcome = oneLine(upd.outcome);
    if (upd.state) {
      w.state = upd.state;
      w.enabled = upd.state === "tracking" || upd.state === "waiting";
    }
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

// A progress line is one short line the owner reads at a glance.
export function oneLine(text: string): string {
  const plain = text.replace(/[*_`#>|]+/g, "").replace(/^\s*[-•·]\s*/gm, "");
  const first = plain.replace(/\s+/g, " ").trim().split(/(?<=[。！？!?])\s*/)[0] ?? "";
  return first.length > PROGRESS_MAX ? `${first.slice(0, PROGRESS_MAX - 1)}…` : first;
}

// Keep `enabled` (the mechanism) and `state` (what the owner sees) in step
// when a patch changes only one of them.
function syncState(before: Watch, next: Watch, patch: Partial<Watch>): Watch {
  if (patch.state && !GOAL_STATES.includes(patch.state)) throw new Error(`state 只能是 ${GOAL_STATES.join(" / ")}`);
  if (patch.state !== undefined && patch.enabled === undefined) {
    next.enabled = patch.state === "tracking" || patch.state === "waiting";
  } else if (patch.enabled !== undefined && patch.state === undefined && patch.enabled !== before.enabled) {
    next.state = patch.enabled ? (before.state === "waiting" ? "waiting" : "tracking") : "paused";
  }
  return next;
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
