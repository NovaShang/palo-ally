import { t, tIn } from "./i18n/index.ts";
import type { RuntimeState } from "./runtime.ts";
import type { WatchStore } from "./watches.ts";

// 晨报 is just a preset scheduled goal: created once, then the owner can change
// its time, pause it or delete it like any other goal. Its output shows as a
// card titled by the goal (see Conversation.endTurn).

export const BRIEF_TITLE = "晨报"; // zh title; briefTitle() is the one in the owner's language
export const BRIEF_AT = "07:30";
export const briefTitle = (): string => t("brief.title");
export const briefInstruction = (): string => t("brief.instruction");
/** The goal by any language's title, so a language change never makes a second one. */
export const isBriefTitle = (title: string): boolean => title === BRIEF_TITLE || title === tIn("en", "brief.title");

/** Creates the 晨报 goal once per install; never again after the owner deletes it. */
export function ensureMorningBrief(watches: WatchStore, runtime: RuntimeState): boolean {
  if (runtime.data.briefCreated) return false;
  if (!watches.list().some((w) => isBriefTitle(w.title))) {
    watches.add({ title: briefTitle(), instruction: briefInstruction(), kind: "schedule", at: [BRIEF_AT] }, "user");
  }
  runtime.update({ briefCreated: true });
  return true;
}
