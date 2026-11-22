// Idle compaction (flag `autoCompact`, the assistant's), mirroring Claude
// Code's own (2.1.299): once the session has been idle most of the prompt
// cache's one-hour life, a big context is compacted before the cache expires,
// so the next message doesn't re-read the whole thing at full price. Claude
// Code's version is server-gated and terminal-only; SDK sessions don't get it.
// The timer starts when a turn ends. (Size-based compaction is Claude Code's:
// session.compactWindowTokens.) It compacts only at a clean break.
import type { Audit } from "../audit.ts";
import type { Config } from "../config.ts";

// An idle compaction that found no clean break tries again this often while the session stays idle.
export const COMPACT_RETRY_MS = 5 * 60_000;

export class IdleCompact {
  /** Our /compact turn is queued or running, and why ("idle"). */
  reason: string | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private stamp = 0; // when the last turn ended: the idle stretch the timer belongs to
  private firedFor = 0; // the stretch an idle compaction was already started for

  constructor(
    private d: {
      session: () => Config["session"];
      contextTokens: () => number;
      cleanBreak: (now: number) => boolean;
      audit: () => Audit;
      /** Queues the harness' own /compact as a maintenance turn. */
      compact: () => void;
    },
  ) {}

  /** When the idle stretch now going began. */
  get idleStamp(): number {
    return this.stamp;
  }

  /** A turn ended: an idle stretch begins. */
  arm(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const minutes = this.d.session().idleCompactMinutes;
    this.stamp = Date.now();
    if (!(minutes > 0)) return;
    const stamp = this.stamp;
    this.timer = setTimeout(() => this.fire(stamp), minutes * 60_000);
    (this.timer as any).unref?.();
  }

  /** Cancel the idle timer (the host is shutting down). */
  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private fire(stamp: number): void {
    this.timer = null;
    if (this.maybe(stamp) === "later") {
      this.timer = setTimeout(() => this.fire(stamp), COMPACT_RETRY_MS);
      (this.timer as any).unref?.();
    }
  }

  // Compacts (the harness' native /compact, no instructions) if the idle
  // stretch that began at `stamp` is still going, the context is big enough and
  // this is a clean break. "later": still idle but not a clean break yet.
  maybe(stamp = this.stamp, now = Date.now()): "started" | "later" | null {
    const s = this.d.session();
    if (!(s.idleCompactMinutes > 0) || !stamp || stamp !== this.stamp) return null; // a newer turn began
    if (this.firedFor === stamp) return null; // once per idle stretch
    if (now - stamp < s.idleCompactMinutes * 60_000) return null;
    const tokens = this.d.contextTokens();
    if (tokens < s.idleCompactMinTokens) return null;
    if (!this.d.cleanBreak(now)) return "later";
    this.firedFor = stamp;
    this.reason = "idle";
    this.d.audit().log("session.compact.start", { reason: "idle", tokens });
    this.d.compact();
    return "started";
  }
}
