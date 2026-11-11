import { t } from "./i18n/index.ts";

// 「X 回复了」 pushes, kept few: with many sessions working they were a
// stream on the phone while the owner sat at the computer. Only a turn that
// ran a while (a short exchange is one the owner is following anyway), each
// session at most once in 10 minutes, and at most one such push in 2
// minutes overall: sessions that finish meanwhile go out together as one
// 「3 个会话回复了」 when the 2 minutes are up.
export const DONE_PUSH = { minTurnMs: 2 * 60_000, perSessionMs: 10 * 60_000, everyMs: 2 * 60_000 };

export interface DonePush {
  title: string;
  body: string;
  /** The session it opens: only when it's about one. */
  pal?: string;
}

export interface DonePushDeps {
  now: () => number;
  send: (p: DonePush) => void;
  /** Runs `fn` in `ms` (setTimeout by default); gives back how to cancel it. */
  later?: (fn: () => void, ms: number) => () => void;
}

export class DonePushes {
  private lastBy = new Map<string, number>(); // session → its last 「回复了」
  private lastAny = -Infinity;
  private waiting = new Map<string, { name: string; line: string }>(); // finished, held for the 2 minutes
  private cancel: (() => void) | null = null;

  constructor(private d: DonePushDeps) {}

  /** A session's turn really ended after `workedMs`, its reply's first line `line`. */
  finished(id: string, name: string, line: string, workedMs: number): void {
    if (!line || workedMs < DONE_PUSH.minTurnMs) return;
    const now = this.d.now();
    if (now - (this.lastBy.get(id) ?? -Infinity) < DONE_PUSH.perSessionMs) return;
    this.waiting.delete(id); // its newer reply, in finishing order
    this.waiting.set(id, { name, line });
    const wait = this.lastAny + DONE_PUSH.everyMs - now;
    if (wait <= 0) return this.flush();
    if (this.cancel) return;
    const later = this.d.later ?? ((fn, ms) => {
      const h = setTimeout(fn, ms);
      return () => clearTimeout(h);
    });
    this.cancel = later(() => {
      this.cancel = null;
      this.flush();
    }, wait);
  }

  /** Sends what's held: one session's own push, or one for all of them. */
  flush(): void {
    const all = [...this.waiting];
    this.waiting.clear();
    if (!all.length) return;
    const now = this.d.now();
    this.lastAny = now;
    for (const [id] of all) this.lastBy.set(id, now);
    if (all.length === 1) {
      const [id, { name, line }] = all[0]!;
      return this.d.send({ title: t("pals.doneTitle", { name }), body: line, pal: id });
    }
    const names = all.map(([, w]) => w.name);
    const shown = names.slice(0, 5).join(t("turn.listSep")) + (names.length > 5 ? t("pals.doneManyMore") : "");
    this.d.send({ title: t("pals.doneManyTitle", { n: all.length }), body: shown });
  }

  stop(): void {
    this.cancel?.();
    this.cancel = null;
    this.waiting.clear();
  }
}
