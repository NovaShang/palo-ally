import type { LimitHit } from "./harness/types.ts";
import type { Missed } from "./auth.ts";
import type { StoppedWork } from "./types.ts";
import { readJson, writeJson } from "./util.ts";

// A limit of the plan used up: the turns that failed on it are remembered,
// each with when its limit resets, and go on by themselves then (the same way
// as after an expired login: hub.resumeMissed). Kept across a restart of the
// host. The owner's hand comes first: words to one, 停止, opening it in a
// terminal or going back in it, and what's remembered of it isn't resumed
// (words that fail on the limit again are remembered with what was there).
// Each goes on a few seconds apart; one still limited at its reset waits for
// the new one.

interface Held extends LimitHit {
  at: number; // when its turn failed
  due: number; // when to go on (its reset, and a moment)
}

interface HeldAssistant extends Held {
  texts: { text: string; at: number }[]; // what its turns were for
  schedules: string[]; // watch ids whose run failed
  superseded?: boolean; // the owner has spoken since: waits for how that turn ends
}

interface Saved {
  assistant?: HeldAssistant;
  agents?: Record<string, Held & { name: string }>;
}

export type LimitFailure = { kind: "palo"; text: string; watchId?: string } | { kind: "pal"; id: string; name: string };

export interface LimitDeps {
  path: string;
  now?: () => number;
  random?: () => number;
  /** When this limit now resets if it's still used up; null: there's room; undefined: the numbers can't be read. */
  still: (l: LimitHit) => Promise<number | null | undefined>;
  /** Not now (no login): tried again in a minute. */
  blocked: () => boolean;
  /** The agent can be told to go on: it's here, not open elsewhere, not at work. */
  canGoOn: (pal: string) => boolean;
  resume: (m: Missed, since: number) => Promise<void> | void;
  changed: () => void;
  audit: (type: string, data?: Record<string, unknown>) => void;
  log: (s: string) => void;
}

const RETRY_MS = 30 * 60_000; // a limit that doesn't say when it resets, or whose reset has passed
const MINUTE = 60_000;

export class LimitWatch {
  private s: Saved;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private running = false;
  private going = false;
  private now: () => number;

  constructor(private d: LimitDeps) {
    this.now = d.now ?? Date.now;
    this.s = readJson<Saved>(d.path, {});
  }

  start(): void {
    this.running = true;
    // Overdue ones (the host was off) don't all start at once either.
    const now = this.now();
    for (const h of this.held()) if (h.due < now) h.due = now + this.moment();
    this.arm();
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  /** What waits for a reset; undefined: nothing does. */
  status(): StoppedWork | undefined {
    const agents = Object.entries(this.s.agents ?? {}).map(([id, h]) => ({ id, name: h.name, until: this.until(h) }));
    const a = this.s.assistant?.superseded ? undefined : this.s.assistant;
    if (!a && !agents.length) return undefined;
    return { assistant: !!a, ...(a ? { until: this.until(a) } : {}), agents, schedules: a?.schedules.length ?? 0 };
  }

  /** A limit for everything (not one model's) is used up until later: checks wait. */
  get everything(): boolean {
    const now = this.now();
    return this.held().some((h) => (h.kind === "session" || h.kind === "weekly_all") && h.due > now);
  }

  // ---------------- what stops, and what the owner does ----------------

  /** A turn failed on a used-up limit. True: that's news (it wasn't held by the same limit already). */
  hit(f: LimitFailure, l: LimitHit): boolean {
    const now = this.now();
    const before: Held | undefined = f.kind === "pal" ? this.s.agents?.[f.id] : this.s.assistant;
    const news = !before || before.kind !== l.kind || before.scope !== l.scope || before.due <= now;
    const held: Held = { ...l, at: now, due: this.due(l) };
    if (f.kind === "pal") this.s.agents = { ...this.s.agents, [f.id]: { ...held, name: f.name } };
    else {
      const was = this.s.assistant;
      const texts = was?.texts ?? [];
      const schedules = was?.schedules ?? [];
      if (f.watchId) {
        if (!schedules.includes(f.watchId)) schedules.push(f.watchId);
      } else if (f.text.trim() && texts.length < 20) texts.push({ text: f.text.trim().slice(0, 300), at: now });
      this.s.assistant = { ...held, texts, schedules };
    }
    this.d.audit("limit.hit", { by: f.kind, kind: l.kind, resetsAt: l.resetsAt });
    this.save();
    return news;
  }

  /** An agent's turn went through, or the owner's words to the assistant were answered (or failed some other way): nothing of it waits. */
  settled(who: "palo" | { pal: string }): void {
    if (who === "palo") this.forget(null);
    else this.forget(who.pal);
  }

  /** The owner spoke to the assistant: not resumed on its own unless those words meet the limit too. */
  ownerSpoke(): void {
    if (!this.s.assistant || this.s.assistant.superseded) return;
    this.s.assistant.superseded = true;
    this.save();
  }

  /** The owner stopped it, spoke to it, opened it elsewhere, went back in it (null: the assistant). */
  forget(pal: string | null): void {
    if (pal === null) {
      if (!this.s.assistant) return;
      delete this.s.assistant;
    } else {
      if (!this.s.agents?.[pal]) return;
      delete this.s.agents[pal];
    }
    this.save();
  }

  // ---------------- going on ----------------

  private held(): Held[] {
    return [...(this.s.assistant ? [this.s.assistant] : []), ...Object.values(this.s.agents ?? {})];
  }

  private until(h: Held): number {
    return h.resetsAt && h.resetsAt > this.now() && h.resetsAt <= h.due ? h.resetsAt : h.due;
  }

  /** 5 to 45 s: they don't all start in the same second. */
  private moment(): number {
    return 5_000 + Math.round((this.d.random ?? Math.random)() * 40_000);
  }

  private due(l: LimitHit): number {
    const now = this.now();
    return (l.resetsAt && l.resetsAt > now ? l.resetsAt : now + RETRY_MS) + this.moment();
  }

  private arm(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const next = Math.min(...this.held().filter((h) => !(h as HeldAssistant).superseded).map((h) => h.due));
    if (!this.running || this.going || !Number.isFinite(next)) return;
    // (a timer longer than 24 days fires at once; and the computer sleeps)
    this.timer = setTimeout(() => void this.tick(), Math.max(0, Math.min(next - this.now(), MINUTE)));
    (this.timer as any).unref?.();
  }

  /** Whatever is due goes on. */
  async tick(): Promise<void> {
    if (this.going) return;
    this.going = true;
    try {
      const now = this.now();
      const a = this.s.assistant;
      if (a && !a.superseded && a.due <= now) await this.goOn(null, a);
      for (const [id, h] of Object.entries(this.s.agents ?? {})) if (h.due <= this.now()) await this.goOn(id, h);
    } finally {
      this.going = false;
      this.arm();
    }
  }

  private async goOn(pal: string | null, h: Held): Promise<void> {
    const mine = () => (pal === null ? this.s.assistant : this.s.agents?.[pal]);
    if (this.d.blocked()) {
      h.due = this.now() + MINUTE;
      return this.save();
    }
    const still = await this.d.still(h);
    // The owner did something about it meanwhile.
    if (mine() !== h || (h as HeldAssistant).superseded) return;
    if (typeof still === "number") {
      h.resetsAt = still;
      h.due = this.due(h);
      this.d.log(`still limited; ${pal ?? "the assistant"} waits for ${new Date(h.due).toISOString()}`);
      return this.save();
    }
    this.forget(pal);
    if (pal === null) {
      const { texts, schedules } = h as HeldAssistant;
      this.d.audit("limit.resumed", { by: "palo", texts: texts.length, schedules: schedules.length });
      await this.d.resume({ palo: texts, pals: {}, schedules }, h.at);
    } else if (this.d.canGoOn(pal)) {
      this.d.audit("limit.resumed", { by: "pal", pal });
      await this.d.resume({ palo: [], pals: { [pal]: (h as Held & { name: string }).name }, schedules: [] }, h.at);
    }
  }

  private save(): void {
    if (this.s.agents && !Object.keys(this.s.agents).length) delete this.s.agents;
    writeJson(this.d.path, this.s);
    this.d.changed();
    this.arm();
  }
}
