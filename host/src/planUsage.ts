import type { LimitHit, LoginAccount, PlanLimit, PlanReport } from "./harness/types.ts";
import type { UsageStatus } from "./types.ts";
import { readJson, writeJson } from "./util.ts";

// How much of the plan of this computer's login is used, for Claude 用量
// (docs/workbench-design/usage.html). Asked of the assistant's process while
// it's up, never by starting one; the last answer is kept, so the page has
// something at once. Asked again: every minute while the page is open (the
// app asks), every 10 minutes while something is at work, and when a limit
// resets. The account and the numbers go to the owner's apps only: not to the
// audit, a log or a push.

export interface PlanUsageDeps {
  path: string; // where the last answer is kept
  /** Asks the running process; undefined: none is up. */
  ask: () => Promise<PlanReport> | undefined;
  /** The assistant or an agent is at work. */
  working: () => boolean;
  changed: (s: UsageStatus) => void;
  log: (s: string) => void;
  now?: () => number;
  timeoutMs?: number;
  tickMs?: number;
}

/** The plan's row a used-up limit is. */
function matches(l: PlanLimit, hit: LimitHit): boolean {
  return l.kind === hit.kind && (hit.scope === undefined ? hit.kind !== "weekly_scoped" || l.resetsAt === hit.resetsAt : l.scope?.toLowerCase() === hit.scope.toLowerCase());
}

const PAGE_MS = 55_000; // the page asks every minute
const WORKING_MS = 10 * 60_000;

export class PlanUsage {
  private s: UsageStatus;
  private lastAsk = 0;
  private asking: Promise<void> | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private now: () => number;

  constructor(private d: PlanUsageDeps) {
    this.now = d.now ?? Date.now;
    const kept = readJson<UsageStatus | null>(d.path, null);
    this.s = kept && Array.isArray(kept.limits) && kept.state ? kept : { state: "loading", limits: [] };
  }

  start(): void {
    this.timer ??= setInterval(() => this.tick(), this.d.tickMs ?? 60_000);
    (this.timer as any).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  get status(): UsageStatus {
    return this.s;
  }

  /** usage.get: what's known now; asked again behind it (the page open: `refresh`) when it's due, the news coming as usage.updated. */
  get(refresh = false): UsageStatus {
    if (this.now() - this.lastAsk >= (refresh ? PAGE_MS : WORKING_MS)) void this.refresh();
    return this.s;
  }

  /** The process that answers has just come up. */
  processUp(): void {
    if (this.now() - this.lastAsk >= WORKING_MS || this.s.stale) void this.refresh();
  }

  /** A turn said where a limit stands: the numbers may be old. */
  heard(): void {
    if (this.now() - this.lastAsk >= 60_000) void this.refresh();
  }

  /** A turn failed on a used-up limit: known at once, before the numbers say so. */
  usedUp(hit: LimitHit): void {
    const s = this.s;
    if (s.state === "limits" && hit.kind) {
      const i = s.limits.findIndex((l) => matches(l, hit));
      const at = hit.resetsAt ? { resetsAt: hit.resetsAt } : {};
      if (i >= 0 && s.limits[i]!.used < 100) {
        this.s = { ...s, limits: s.limits.map((l, n) => (n === i ? { ...l, used: 100, ...at } : l)) };
        writeJson(this.d.path, this.s);
        this.d.changed(this.s);
      }
    }
    this.heard();
  }

  /** Whether a limit is still used up, asked now: until when; null: there's room; undefined: no answer. */
  async still(hit: LimitHit): Promise<number | null | undefined> {
    const from = this.now();
    await this.refresh();
    const s = this.s;
    if (s.state !== "limits" || s.stale || s.at === undefined || s.at < from) return undefined;
    const now = this.now();
    const up = s.limits.filter((l) => l.used >= 100 && (l.resetsAt === undefined || l.resetsAt > now));
    // Its own; and one for everything stops it as well.
    const l = up.filter((x) => matches(x, hit) || !x.scope).sort((a, b) => (b.resetsAt ?? 0) - (a.resetsAt ?? 0))[0];
    return l ? (l.resetsAt ?? now + 30 * 60_000) : null;
  }

  /** A sign-in: whose login it is now; another account's numbers are to come. */
  signedIn(account: LoginAccount | null, changed: boolean): void {
    const acc = account ?? this.s.account;
    this.s = changed ? { state: "loading", limits: [], ...(acc ? { account: acc } : {}) } : { ...this.s, ...(acc ? { account: acc } : {}) };
    this.lastAsk = 0; // asked as soon as the fresh process is up
    writeJson(this.d.path, this.s);
    this.d.changed(this.s);
  }

  /** Once a minute: whether it's time to ask. */
  tick(): void {
    const now = this.now();
    // A limit that has reset: asked at once, and for half an hour after while the answer is still from before.
    const reset = this.s.limits.some(({ resetsAt: at }) => at !== undefined && at <= now && (this.lastAsk < at || (now - at < 30 * 60_000 && now - this.lastAsk >= 5 * 60_000)));
    if (reset || (this.d.working() && now - this.lastAsk >= WORKING_MS)) void this.refresh();
  }

  /** Asks now (once at a time). With no process up, nothing changes. */
  refresh(): Promise<void> {
    return (this.asking ??= this.read().finally(() => (this.asking = null)));
  }

  private async read(): Promise<void> {
    const asked = this.d.ask();
    if (!asked) return;
    this.lastAsk = this.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<null>((r) => {
      timer = setTimeout(() => r(null), this.d.timeoutMs ?? 15_000);
    });
    // (an error's words may name the account: not logged)
    const r = await Promise.race([asked.catch(() => null), late]);
    clearTimeout(timer);
    this.take(r ?? { plan: "unreadable", limits: [] });
  }

  private take(r: PlanReport): void {
    const was = this.s;
    const account = r.account ?? was.account;
    const acc = account ? { account } : {};
    let next: UsageStatus;
    if (r.plan === "unreadable") {
      this.d.log("plan usage: no answer this time");
      const same = !r.account || JSON.stringify([r.account.email, r.account.organization]) === JSON.stringify([was.account?.email, was.account?.organization]);
      // The numbers it had stay, as of when they came; none, or another account's: the account alone.
      next = was.state === "limits" && same ? { ...was, ...acc, stale: true } : { state: "unsupported", limits: [], ...acc };
    } else if (r.plan === "limits") {
      next = { state: "limits", limits: r.limits, ...(r.extraUsage !== undefined ? { extraUsage: r.extraUsage } : {}), ...acc, at: this.now() };
    } else {
      next = { state: r.plan, limits: [], ...acc };
    }
    if (JSON.stringify(next) === JSON.stringify(was)) return;
    this.s = next;
    writeJson(this.d.path, next);
    this.d.changed(next);
  }
}
