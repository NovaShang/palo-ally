import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { readJson, writeJson } from "./util.ts";

// The host Mac running on battery: when it dies the assistant goes offline,
// so the owner hears about it in time. Deterministic, read from the OS every
// few minutes; no model involved.

export interface PowerReading {
  hasBattery: boolean;
  onAC: boolean;
  percent: number | null; // battery charge, when there is a battery
}

/** Parses `pmset -g batt`. A desktop prints only the power source line. */
export function parsePmset(out: string): PowerReading | null {
  const src = /Now drawing from '([^']+)'/.exec(out);
  if (!src) return null;
  const onAC = !/battery/i.test(src[1]!);
  const batt = /InternalBattery[^\n]*?(\d{1,3})%/.exec(out);
  if (!batt) return { hasBattery: false, onAC: true, percent: null };
  return { hasBattery: true, onAC, percent: Math.min(100, Number(batt[1])) };
}

/** Linux laptops: /sys/class/power_supply. Servers have no battery there. */
export function readSysfsPower(dir = "/sys/class/power_supply"): PowerReading | null {
  if (!existsSync(dir)) return null;
  let percent: number | null = null;
  let hasBattery = false;
  let mainsOnline: boolean | null = null;
  let discharging = false;
  for (const name of readdirSync(dir)) {
    const read = (f: string) => {
      try {
        return readFileSync(join(dir, name, f), "utf8").trim();
      } catch {
        return "";
      }
    };
    const type = read("type");
    if (type === "Battery") {
      hasBattery = true;
      const cap = Number(read("capacity"));
      if (Number.isFinite(cap) && read("capacity") !== "") percent = cap;
      if (read("status") === "Discharging") discharging = true;
    } else if (type === "Mains") {
      mainsOnline = (mainsOnline ?? false) || read("online") === "1";
    }
  }
  if (!hasBattery) return { hasBattery: false, onAC: true, percent: null };
  return { hasBattery: true, onAC: mainsOnline ?? !discharging, percent };
}

export function readPower(): PowerReading | null {
  if (process.platform === "darwin") {
    const r = spawnSync("pmset", ["-g", "batt"], { encoding: "utf8", timeout: 5000 });
    return r.status === 0 ? parsePmset(r.stdout) : null;
  }
  if (process.platform === "linux") return readSysfsPower();
  return null;
}

/** Which heads-ups this battery stretch has already had. Reset on AC. */
interface PowerState {
  onAC: boolean | null;
  unplugged: boolean;
  low30: boolean;
  low15: boolean;
}

export interface PowerDeps {
  path: string; // persisted state, so a restart doesn't repeat the alerts
  read: () => PowerReading | null;
  enabled: () => boolean;
  /** A heads-up to the owner: lands in the conversation and is pushed (urgent ones even in quiet hours). */
  alert: (text: string, urgent: boolean) => void;
  /** A quiet line in the conversation, no push. */
  note: (text: string) => void;
  audit: (type: string, data: Record<string, unknown>) => void;
  log?: (s: string) => void;
}

export const POWER_INTERVAL_MS = 3 * 60_000;

export class PowerWatcher {
  private timer: ReturnType<typeof setInterval> | null = null;
  private last: (PowerReading & { at: number }) | null = null;
  private state: PowerState;

  constructor(private deps: PowerDeps) {
    this.state = { onAC: null, unplugged: false, low30: false, low15: false, ...readJson<Partial<PowerState>>(deps.path, {}) };
  }

  start(): void {
    this.stop();
    const first = setTimeout(() => this.tick(), 10_000);
    (first as any).unref?.();
    this.timer = setInterval(() => this.tick(), POWER_INTERVAL_MS);
    (this.timer as any).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  status(): { hasBattery: boolean; onAC: boolean | null; percent: number | null; at: number | null; alerts: boolean } {
    return {
      hasBattery: this.last?.hasBattery ?? false,
      onAC: this.last?.onAC ?? null,
      percent: this.last?.percent ?? null,
      at: this.last?.at ?? null,
      alerts: this.deps.enabled(),
    };
  }

  tick(now = Date.now()): void {
    let r: PowerReading | null;
    try {
      r = this.deps.read();
    } catch (e) {
      this.deps.log?.(`power: ${String(e)}`);
      return;
    }
    if (!r) return;
    this.last = { ...r, at: now };
    if (!r.hasBattery) {
      // A desktop (or a server): nothing to watch.
      this.stop();
      return;
    }
    const s = this.state;
    if (s.onAC !== r.onAC) this.deps.audit("power.change", { onAC: r.onAC, percent: r.percent });

    if (r.onAC) {
      const hadAlerted = s.unplugged || s.low30 || s.low15;
      this.save({ onAC: true, unplugged: false, low30: false, low15: false });
      if (hadAlerted && this.deps.enabled()) this.deps.note("已接上电源。");
      return;
    }

    const next: PowerState = { ...s, onAC: false };
    const p = r.percent;
    if (this.deps.enabled()) {
      if (!s.unplugged) {
        // One message for the unplug, worded for the charge it starts from.
        if (p !== null && p < 15) this.deps.alert(`电脑拔电了，电量只剩 ${p}%，快没电了。`, true);
        else if (p !== null && p < 30) this.deps.alert(`电脑拔电了，电量 ${p}%，记得插电。`, false);
        else this.deps.alert(`电脑拔电了${p !== null ? `（剩 ${p}%）` : ""}。没电我就会掉线，记得插上。`, false);
        next.unplugged = true;
        if (p !== null && p < 30) next.low30 = true;
        if (p !== null && p < 15) next.low15 = true;
      } else if (p !== null && p < 15 && !s.low15) {
        this.deps.alert(`电量只剩 ${p}%，快没电了。`, true);
        next.low15 = true;
        next.low30 = true;
      } else if (p !== null && p < 30 && !s.low30) {
        this.deps.alert(`电量 ${p}%，记得插电。`, false);
        next.low30 = true;
      }
    }
    this.save(next);
  }

  private save(s: PowerState): void {
    const changed = JSON.stringify(s) !== JSON.stringify(this.state);
    this.state = s;
    if (changed) writeJson(this.deps.path, s);
  }
}

/** The `paloally status` line. */
export function powerLine(p: { hasBattery: boolean; onAC: boolean | null; percent: number | null; alerts: boolean }): string | null {
  if (!p.hasBattery || p.onAC === null) return null;
  const pct = p.percent !== null ? `${p.percent}%` : "";
  const now = p.onAC ? `接着电${pct ? `（${pct}）` : ""}` : `电池 ${pct || "供电"}`;
  return p.alerts ? now : `${now} · 拔电提醒已关闭`;
}
