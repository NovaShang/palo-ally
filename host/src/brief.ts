import type { RuntimeState } from "./runtime.ts";
import type { WatchStore } from "./watches.ts";

// 晨报 is just a preset scheduled goal: created once, then the owner can change
// its time, pause it or delete it like any other goal. Its output shows as a
// card titled by the goal (see Conversation.endTurn).

export const BRIEF_TITLE = "晨报";
export const BRIEF_AT = "07:30";
export const BRIEF_INSTRUCTION = [
  "给主人写今天的晨报：主人今天需要知道的事。",
  "按重要程度排：需要主人处理的（等主人确认的操作、要主人回复的）、各个目标的进展、你注意到的值得一提的变化；连接了日历和邮箱的话，再加今天的日程和要紧的邮件。",
  "每条一行，用「- 」开头的列表，最多 6 条，中文，直接写给主人看，不要标题和客套。",
  "没什么要紧事也照样写一张短的，比如「- 今天没什么要你处理的，3 个目标都在正常推进」。这次不要回复 [skip]。",
].join("\n");

/** Creates the 晨报 goal once per install; never again after the owner deletes it. */
export function ensureMorningBrief(watches: WatchStore, runtime: RuntimeState): boolean {
  if (runtime.data.briefCreated) return false;
  if (!watches.list().some((w) => w.title === BRIEF_TITLE)) {
    watches.add({ title: BRIEF_TITLE, instruction: BRIEF_INSTRUCTION, kind: "schedule", at: [BRIEF_AT] }, "user");
  }
  runtime.update({ briefCreated: true });
  return true;
}
