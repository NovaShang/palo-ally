// "[skip]": the marker a host-initiated turn of the assistant's answers with to stay silent.
const SKIP = /^\s*\[skip\]\s*$/i;

/** The words without the "[skip]" paragraphs. */
export function stripSkip(text: string): string {
  return text
    .split(/\n{2,}/)
    .filter((p) => !SKIP.test(p))
    .join("\n\n")
    .trim();
}
