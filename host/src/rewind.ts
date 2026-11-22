import { t } from "./i18n/index.ts";

// 回到这里重来 (docs/rewind-prd.md): what the host reads in a session's
// transcript to take the conversation back to just before one of the owner's
// messages. Claude Code does the rest: the session is forked from the entry
// before that message (resume + forkSession + resumeSessionAt), and a Pal's
// files go back with rewindFiles. The original transcript stays as it was.

/** Where a rewound session goes on from (kept until the fork has its own transcript). */
export interface PendingRewind {
  from: string; // the session it was forked from (it keeps everything)
  at: string | null; // the last entry kept; null: nothing is (a fresh session)
  cut: string; // the owner's message it went back to (that one and all after are gone)
}

/** What the owner is told when a turn is running. */
export const rewindBusy = (): string => t("rewind.busy");
export const rewindNoFiles = (): string => t("rewind.noFiles");
export const rewindNotFound = (): string => t("rewind.notFound");

// (What it reads in a transcript is Claude Code's: harness/claude/rewind.ts.)
export { beforeCompaction, chainTo, findEntry, forkedUuids, hasFileCheckpoint, leafOf, matchOwnerEntry, ownerText, readTranscript } from "./harness/claude/rewind.ts";
export type { ForkSession } from "./harness/claude/rewind.ts";
