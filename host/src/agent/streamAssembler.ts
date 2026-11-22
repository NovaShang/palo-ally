// The reply a session's harness is streaming right now: its id and all its
// text so far (docs/harness-adapter-design.md §1.1 row 8). Both runtimes keep
// one: a client that reconnects mid-reply takes `current()` and then keeps
// appending deltas, and a stream cut off (an error, a kill, a stop) is closed
// with what it had, so no half-written bubble keeps "typing". Where the text
// goes (the assistant's chat log, an agent's events) is the runtime's.
export class StreamAssembler {
  private openId: string | null = null;
  private text = "";

  /** The id of the reply being streamed, if one is. */
  get id(): string | null {
    return this.openId;
  }

  /** Its text so far. */
  get sofar(): string {
    return this.text;
  }

  /** The reply being streamed right now, with all its text so far (null: none, or nothing written yet). */
  current(): { id: string; text: string } | null {
    return this.openId && this.text ? { id: this.openId, text: this.text } : null;
  }

  /** A new reply begins streaming under `id`. */
  open(id: string): void {
    this.openId = id;
    this.text = "";
  }

  append(text: string): void {
    this.text += text;
  }

  /** It ended (its final words came, or nothing more is coming): what it had, if it was open. */
  take(): { id: string; text: string } | null {
    const was = this.openId ? { id: this.openId, text: this.text } : null;
    this.openId = null;
    this.text = "";
    return was;
  }
}
