import { t as tr } from "../../i18n/index.ts";
import { truncate } from "../../util.ts";

/**
 * Words from another session (the assistant's pal_send), as Claude Code shows a
 * SendMessage. `from` is the sender's name, not a socket: Claude Code tells a
 * session to reply by copying `from`, and the assistant's socket changes every
 * time the host restarts, so only its name keeps working.
 */
export function peerWrap(name: string, text: string): string {
  const n = name.replace(/"/g, "");
  return `<cross-session-message from="${n}" from-name="${n}">\n${text}\n</cross-session-message>`;
}

// Claude Code's reason, in a line the owner can read.
export function startError(raw: string): string {
  const s = String(raw ?? "");
  if (/running in the background|session_held_by_background/i.test(s)) return tr("pals.errBackground");
  if (/No conversation found|not found.*session|session.*not found/i.test(s)) return tr("pals.noTranscript");
  if (/not logged in|authentication|401/i.test(s)) return tr("pals.errNotLoggedIn");
  const line = s
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l && !/^at /.test(l));
  return truncate(line?.replace(/^Error:\s*/, "") ?? tr("pals.errNoStart"), 160);
}
