// The owner's messages in a session's harness that no turn has answered yet,
// by the uuid each went in under (docs/harness-adapter-design.md §1.1 row 7).
// The assistant's runtime (conversation.ts) and an agent's (palSession.ts)
// keep one each: a result's consumed uuids take messages off it, a restart
// after a stall sends again what the harness never took. `T` is what each
// keeps with a message (its words, images, where it came from).
export class TurnLedger<T> {
  private m = new Map<string, T>();

  get size(): number {
    return this.m.size;
  }

  add(uuid: string, meta: T): void {
    this.m.set(uuid, meta);
  }

  has(uuid: string): boolean {
    return this.m.has(uuid);
  }

  get(uuid: string): T | undefined {
    return this.m.get(uuid);
  }

  delete(uuid: string): void {
    this.m.delete(uuid);
  }

  clear(): void {
    this.m.clear();
  }

  uuids(): string[] {
    return [...this.m.keys()];
  }

  values(): T[] {
    return [...this.m.values()];
  }

  entries(): [string, T][] {
    return [...this.m];
  }

  /** Takes these messages off (those it held), oldest first; what it kept with each. */
  consume(uuids: Iterable<string>): T[] {
    const out: T[] = [];
    for (const u of uuids) {
      const p = this.m.get(u);
      if (p !== undefined) out.push(p);
      this.m.delete(u);
    }
    return out;
  }

  /** Drops the ones `stale` says gave up on (lost in a crash, say). */
  expire(stale: (uuid: string, meta: T) => boolean): void {
    for (const [u, p] of this.m) if (stale(u, p)) this.m.delete(u);
  }

  /** After its process ended mid-work: which (of these; all it holds) the harness took (its transcript has them) and which it never did. */
  split(took: (uuid: string) => boolean, all = this.entries()): { taken: [string, T][]; untaken: [string, T][] } {
    const untaken = all.filter(([u]) => !took(u));
    return { taken: all.filter(([u]) => !untaken.some(([x]) => x === u)), untaken };
  }
}
