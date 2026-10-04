// Bus fans host events out to every connected client channel. Event names and
// payloads are the wire events of docs/design.md §5.3.
export type BusListener = (event: string, data: unknown) => void;

export class Bus {
  private listeners = new Set<BusListener>();

  on(fn: BusListener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  emit(event: string, data: unknown): void {
    for (const fn of this.listeners) {
      try {
        fn(event, data);
      } catch (e) {
        console.error(`[bus] listener failed on ${event}:`, e);
      }
    }
  }
}
