// Whether the owner is looking at an app right now, so pushes don't buzz the
// phone while they're at the computer. Each connection says `presence
// {active}` when its app comes to the front or leaves it, and again every
// minute while in front; one that hasn't said so lately, or whose connection
// closed, no longer counts. An app that never says anything never counts:
// pushes go out as before.

export const PRESENCE_TTL_MS = 90_000;

export class Presence {
  private active = new Map<string, number>(); // connection id → when it last said it's in front

  constructor(private now: () => number = Date.now) {}

  /** True when this connection's state changed (not a heartbeat). */
  note(clientId: string, active: boolean): boolean {
    const t = this.now();
    const was = this.active.has(clientId) && t - this.active.get(clientId)! < PRESENCE_TTL_MS;
    if (active) this.active.set(clientId, t);
    else this.active.delete(clientId);
    return was !== active;
  }

  /** The connection closed: whatever it said no longer holds. */
  drop(clientId: string): void {
    this.active.delete(clientId);
  }

  /** Some app of the owner's is in front and said so within the last 90 s. */
  present(): boolean {
    const t = this.now();
    for (const [id, at] of this.active) {
      if (t - at < PRESENCE_TTL_MS) return true;
      this.active.delete(id);
    }
    return false;
  }
}
