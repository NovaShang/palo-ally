// 「TL;DR」 is gone (it was a button under a long reply that asked the agent
// for the recent stretch in a few points). What stays is for what it left
// behind: an older app still sends its marker on its own, which now does
// nothing, and older transcripts have asks that start with the marker, which
// is taken out wherever such a line is shown.

/** The marker the old app sent, and old asks still start with. Never shown. */
export const TLDR_MARKER = "<!-- paloally:tldr -->";

/** An older app's 「TL;DR」 tap: the marker alone. */
export function isTldrAsk(text: string): boolean {
  return text.trim() === TLDR_MARKER;
}

/** Text with the marker taken out wherever it is. */
export function stripTldrMarker(text: string): string {
  return text.includes(TLDR_MARKER) ? text.replaceAll(TLDR_MARKER, "").trim() : text;
}
