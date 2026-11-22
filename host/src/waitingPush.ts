import type { Router } from "./router.ts";
import type { ChatMessage } from "./types.ts";
import { newId } from "./util.ts";

// 「X 在等你」: a session (a Pal, or one of the computer's own sessions while
// the owner is away) put a permission prompt or a question on the phone. At
// most one such push per session every 10 minutes.
export const WAITING_PUSH_EVERY_MS = 10 * 60_000;

export interface WaitingPushDeps {
  now: () => number;
  router: Pick<Router, "proactive">;
}

export class WaitingPushes {
  private last = new Map<string, number>(); // session → its last 「在等你」

  constructor(private d: WaitingPushDeps) {}

  /**
   * The push for session `key`: `body` is what it waits for, `title` its
   * 「X 在等你」 (only read when the push goes). A question card when
   * `questionId` is given, else an approval; `pal` opens that Pal.
   */
  push(key: string, title: () => string, body: string, ids: { approvalId?: string; questionId?: string; pal?: string }): void {
    const now = this.d.now();
    if (now - (this.last.get(key) ?? 0) < WAITING_PUSH_EVERY_MS) return;
    this.last.set(key, now);
    const msg: ChatMessage = {
      seq: 0,
      id: newId("m_"),
      role: "assistant",
      kind: ids.questionId ? "question" : "approval",
      text: body,
      channel: "system",
      ts: now,
      ...(ids.pal ? { pal: ids.pal } : {}),
      ...(ids.approvalId ? { approvalId: ids.approvalId } : {}),
      ...(ids.questionId ? { questionId: ids.questionId } : {}),
    };
    void this.d.router.proactive(msg, { title: title() }).catch(() => {});
  }

  /** The session is gone: its next push isn't held back. */
  forget(key: string): void {
    this.last.delete(key);
  }

  clear(): void {
    this.last.clear();
  }
}
