import { t } from "./i18n/index.ts";

// 「TL;DR」: the small button under a long finished reply asks the agent
// itself (the assistant, or a session) for the recent stretch of its
// conversation in a few points, the owner's own words apart from what was
// relayed. No model call of the host's own: the ask is an owner message like
// any other, its reply the agent's next one. The app sends just the marker;
// the host puts the instruction (one wording, here and in i18n) behind it.
// The marker leads the message wherever it is kept (the session's
// transcript, the assistant's own), so its history shows it folded
// (`tldr: true`, the text without the marker) after a reload too.

/** The first line of a TL;DR ask, as it goes in. Never shown. */
export const TLDR_MARKER = "<!-- paloally:tldr -->";

/** The app's ask: the marker alone. */
export function isTldrAsk(text: string): boolean {
  return text.trim() === TLDR_MARKER;
}

/** What the ask says (shown when its fold is opened). */
export function tldrInstruction(): string {
  return t("tldr.instruction");
}

/** The ask as it goes to the agent: the marker, then the instruction. */
export function tldrPrompt(): string {
  return `${TLDR_MARKER}\n${tldrInstruction()}`;
}

/** A TL;DR ask as kept (marker first): its words without the marker; null for any other message. */
export function readTldr(text: string): string | null {
  const s = text.trimStart();
  return s.startsWith(TLDR_MARKER) ? s.slice(TLDR_MARKER.length).trim() : null;
}

/** Text with the marker taken out wherever it is (a line that would show it). */
export function stripTldrMarker(text: string): string {
  return text.includes(TLDR_MARKER) ? text.replaceAll(TLDR_MARKER, "").trim() : text;
}
