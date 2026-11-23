// 回到这里重来 at its edges, the assistant's and an agent's, pinned before the
// two become one (docs/harness-adapter-design.md step 14): what refuses it,
// words that come while it's going on, going back again before speaking, the
// first message, past a compaction (the copy, and a copy that fails), files
// that can't go back, asleep. What both do in the plain cases is in
// rewind.test.ts and agentContract.test.ts.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { transcriptPath } from "../src/harness/claude/paths.ts";
import { t as tr } from "../src/i18n/index.ts";
import { chainTo, readTranscript } from "../src/harness/claude/rewind.ts";
import { rewindBusy, rewindNoFiles, rewindNotFound } from "../src/rewind.ts";
import type { ChatMessage } from "../src/types.ts";
import { both, cleanupBoth, result } from "./bothRuntimes.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

afterAll(cleanupBoth);

const at = (s: number) => new Date(Date.parse("2026-11-01T08:00:00Z") + s * 1000).toISOString();
const userE = (uuid: string, parentUuid: string | null, text: string, s: number, extra: Record<string, unknown> = {}) => ({ type: "user", uuid, parentUuid, timestamp: at(s), message: { role: "user", content: text }, origin: { kind: "human" }, ...extra });
const replyE = (uuid: string, parentUuid: string, text: string, s: number, id = `msg_${uuid}`) => ({ type: "assistant", uuid, parentUuid, timestamp: at(s), message: { id, role: "assistant", model: "claude-haiku-4-5", content: [{ type: "text", text }] } });
const compactE = (parent: string, s: number) => [
  { type: "system", subtype: "compact_boundary", uuid: "cb", parentUuid: null, logicalParentUuid: parent, timestamp: at(s) },
  userE("sum", "cb", "摘要", s, { isCompactSummary: true }),
];

const script: FakeScript = async (text, ctx) => {
  if (text.startsWith("慢")) {
    await ctx.interrupted;
    return;
  }
  if (text === "要问") await ctx.useTool("Bash", { command: "ls" }, { ask: true });
  ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: `msg_l${Math.random().toString(36).slice(2, 6)}` });
};

/** The SDK's forkSession in the test's folder; `gate` holds it, `fail` refuses. */
function forks(claudeDir: string) {
  const f = { calls: 0, gate: null as Promise<void> | null, fail: null as string | null };
  const fork = async (sessionId: string, o: { dir: string; upToMessageId: string }) => {
    f.calls++;
    if (f.gate) await f.gate;
    if (f.fail) throw new Error(f.fail);
    const entries = readTranscript(transcriptPath(claudeDir, o.dir, sessionId));
    const to = `copy-${f.calls}-${sessionId.slice(0, 8)}`;
    const p = transcriptPath(claudeDir, o.dir, to);
    const kept = chainTo(entries, o.upToMessageId).map((e) => ({ ...e, uuid: `${e.uuid}-copy`, parentUuid: e.parentUuid ? `${e.parentUuid}-copy` : null, sessionId: to, forkedFrom: { sessionId, messageUuid: e.uuid } }));
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, kept.map((e) => JSON.stringify(e)).join("\n") + "\n");
    return { sessionId: to };
  };
  return { f, fork };
}

/** The assistant after these messages, each answered, as Claude Code wrote them (a compaction before message `compactedBefore`). */
async function palo(texts: string[], o: { compactedBefore?: number } = {}) {
  const t = both({ script });
  const { f, fork } = forks(t.claude.dir);
  (t.hub.harness as any).o.forkSession = fork;
  const msgs: ChatMessage[] = [];
  for (const text of texts) {
    msgs.push(t.hub.userMessage(text, "app")!);
    await t.hub.idle();
  }
  const sid = t.hub.status().sessionId!;
  const entries: unknown[] = [];
  let parent: string | null = null;
  msgs.forEach((m, i) => {
    if (i === o.compactedBefore) {
      entries.push(...compactE(parent!, i * 10 - 1));
      parent = "sum";
    }
    entries.push(userE(m.uuid!, parent, m.text, i * 10), replyE(`a${i}`, m.uuid!, "好", i * 10 + 1));
    parent = `a${i}`;
  });
  if (texts.length) t.claude.transcript(t.paths.home, sid, entries);
  const runtime = () => JSON.parse(readFileSync(t.paths.runtime, "utf8"));
  return { ...t, f, msgs, sid, entries, runtime };
}

describe("the assistant", () => {
  test("the order of things: the process ends and the status says the new session first, then chat.rewound; its context size starts over, its cost so far stays", async () => {
    const t = await palo(["一", "二"]);
    const cost = t.runtime().sessionCostUsd;
    expect(t.runtime().contextTokens).toBe(1000);
    const n = t.events.length;
    await t.call("chat.rewind", { messageId: t.msgs[1]!.id });
    const out = t.events.slice(n).filter((e) => e.event === "status" || e.event === "chat.rewound");
    expect(out.map((e) => e.event)).toEqual(["status", "chat.rewound"]);
    expect(out[0]!.data.sessionId).toBe(t.hub.status().sessionId!);
    expect(t.runtime()).toMatchObject({ sessionId: t.hub.status().sessionId!, contextTokens: 0, sessionCostUsd: cost, rewind: { from: t.sid, at: "a0", cut: t.msgs[1]!.uuid! } });
    expect(t.hub.conversation.contextTokens).toBe(0);
    expect(t.hub.backfillOwnerUuids()).toBe(0); // nothing to match until it's written
  });

  test("refused with words unanswered, a background task running, an Ally's turn or words held for one; its process and session stay", async () => {
    const t = await palo(["一", "二"]);
    const rewind = () => t.call("chat.rewind", { messageId: t.msgs[1]!.id });
    const same = () => {
      expect(t.driver.sessions).toHaveLength(1);
      expect(t.driver.last!.closed).toBe(false);
      expect(t.hub.status().sessionId).toBe(t.sid);
      expect(t.runtime().rewind).toBeUndefined();
    };
    const proc = t.driver.last!;
    // words unanswered, no turn open
    t.driver.script = async () => new Promise<void>(() => {});
    const a = t.hub.userMessage("三", "app")!;
    await tick(5);
    proc.opts.onEvent(result(proc.sessionId, []));
    expect(t.hub.status().busy).toBe(false);
    await expect(rewind()).rejects.toThrow(rewindBusy());
    proc.opts.onEvent(result(proc.sessionId, [a.uuid!]));
    same();
    // a background task
    proc.opts.onEvent({ type: "tool_use", id: "tu_a", name: "Agent", input: { description: "查", prompt: "x" }, parentToolUseId: null });
    proc.opts.onEvent({ type: "task_started", taskId: "sdk_1", toolUseId: "tu_a", description: "查", background: true } as any);
    proc.opts.onEvent({ type: "tool_result", toolUseId: "tu_a", content: "started", isError: false, parentToolUseId: null });
    proc.opts.onEvent(result(proc.sessionId, []));
    expect(t.hub.status().busy).toBe(false);
    expect(t.hub.tasks.live()).toHaveLength(1);
    await expect(rewind()).rejects.toThrow(rewindBusy());
    same();
    t.hub.tasks.markStopped(t.hub.tasks.live()[0]!.id);
    // an Ally's turn
    t.hub.conversation.enqueue({ text: "[好友] 在吗", origin: "system", proactive: true, allyId: "ally_r" });
    await expect(rewind()).rejects.toThrow(rewindBusy());
    const ally = proc.sentUuids.at(-1)!;
    proc.opts.onEvent(result(proc.sessionId, [])); // its turn is over, its message not consumed: still the Ally's
    expect(t.hub.status().busy).toBe(false);
    await expect(rewind()).rejects.toThrow(rewindBusy());
    proc.opts.onEvent(result(proc.sessionId, [ally]));
    same();
    expect(await rewind()).toEqual({ text: "二" });
  });

  test("before its first turn, or a message that isn't in the conversation as it stands: not found", async () => {
    const t = await palo([]);
    const m = t.hub.chat.add({ role: "user", kind: "text", text: "没进去", channel: "app", uuid: "u-none" });
    await expect(t.call("chat.rewind", { messageId: m.id })).rejects.toThrow(rewindNotFound());
    await expect(t.call("chat.rewind", { messageId: "nope" })).rejects.toThrow(tr("hub.err.rewindNo"));
    expect(t.driver.sessions).toHaveLength(0);
  });

  test("again before speaking: cut further back on the session the first one kept; then the next words fork that one", async () => {
    const t = await palo(["一", "二", "三"]);
    await t.call("chat.rewind", { messageId: t.msgs[2]!.id });
    const first = t.hub.status().sessionId!;
    // (what it kept up to: the third is gone, the second is there)
    expect(await t.call("chat.rewind", { messageId: t.msgs[1]!.id })).toEqual({ text: "二" });
    const second = t.hub.status().sessionId!;
    expect(second).not.toBe(first);
    expect(t.runtime().rewind).toEqual({ from: t.sid, at: "a0", cut: t.msgs[1]!.uuid! });
    t.hub.userMessage("再来", "app");
    await t.hub.idle();
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.opts).toMatchObject({ sessionId: second, fork: { fromSessionId: t.sid, at: "a0" } });
    expect(t.hub.chat.since(0).filter((m) => m.role === "user").map((m) => m.text)).toEqual(["一", "再来"]);
  });

  test("again once spoken to and written: cut in the fork, which is then the one forked from", async () => {
    const t = await palo(["一", "二"]);
    await t.call("chat.rewind", { messageId: t.msgs[1]!.id });
    const fork = t.hub.status().sessionId!;
    const m = t.hub.userMessage("二改", "app")!;
    await t.hub.idle();
    t.claude.transcript(t.paths.home, fork, [...t.entries.slice(0, 2), userE(m.uuid!, "a0", "二改", 40), replyE("n1", m.uuid!, "好", 41)]);
    await t.call("chat.rewind", { messageId: m.id });
    expect(t.runtime().rewind).toEqual({ from: fork, at: "a0", cut: m.uuid! });
  });

  test("a message taken mid-turn (an attachment naming it): cut before the attachment", async () => {
    const t = await palo(["一", "二"]);
    t.claude.transcript(t.paths.home, t.sid, [...t.entries.slice(0, 2), { type: "attachment", uuid: "q1", parentUuid: "a0", attachment: { type: "queued_command", source_uuid: t.msgs[1]!.uuid! }, timestamp: at(10) }, replyE("a1", "q1", "好", 11)]);
    await t.call("chat.rewind", { messageId: t.msgs[1]!.id });
    expect(t.runtime().rewind).toEqual({ from: t.sid, at: "a0", cut: "q1" });
  });

  test("past a compaction, words sent while it's being copied: refused, nothing changed; the words are answered in the old session", async () => {
    const t = await palo(["一", "二", "三"], { compactedBefore: 2 });
    let open!: () => void;
    t.f.gate = new Promise<void>((r) => (open = r));
    const going = t.call("chat.rewind", { messageId: t.msgs[1]!.id });
    await waitFor(() => t.f.calls === 1);
    expect(t.driver.last!.closed).toBe(false); // the copy is made first
    t.hub.userMessage("慢慢来", "app");
    open();
    await expect(going).rejects.toThrow(rewindBusy());
    expect(t.hub.status()).toMatchObject({ sessionId: t.sid, busy: true });
    expect(t.driver.sessions).toHaveLength(1);
    expect(t.driver.last!.closed).toBe(false);
    expect(t.events.some((e) => e.event === "chat.rewound")).toBe(false);
    expect(t.hub.chat.get(t.msgs[1]!.id)!.rewound).toBeFalsy();
    await t.call("stop");
  });

  test("past a compaction, the copy fails: its error as it is, nothing changed, the process stays", async () => {
    const t = await palo(["一", "二", "三"], { compactedBefore: 2 });
    t.f.fail = "disk full";
    await expect(t.call("chat.rewind", { messageId: t.msgs[1]!.id })).rejects.toThrow(/^disk full$/);
    expect(t.hub.status().sessionId).toBe(t.sid);
    expect(t.driver.last!.closed).toBe(false);
    expect(t.hub.chat.get(t.msgs[1]!.id)!.rewound).toBeFalsy();
    t.f.fail = null;
    await t.call("chat.rewind", { messageId: t.msgs[1]!.id });
    expect(t.runtime()).toMatchObject({ sessionId: `copy-2-${t.sid.slice(0, 8)}`, contextTokens: 0 });
    expect(t.runtime().rewind).toBeUndefined();
    expect(t.driver.last!.closed).toBe(true);
  });

  test("past a compaction, back to the very first message: nothing to copy, a fresh session", async () => {
    const t = await palo(["一", "二", "三"], { compactedBefore: 2 });
    await t.call("chat.rewind", { messageId: t.msgs[0]!.id });
    expect(t.f.calls).toBe(0);
    expect(t.runtime().rewind).toEqual({ from: t.sid, at: null, cut: t.msgs[0]!.uuid! });
    t.hub.userMessage("重新", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts.fork).toBeUndefined();
    expect(t.driver.last!.opts.resumeSessionId).toBeUndefined();
    expect(t.driver.last!.opts.sessionId).toBe(t.runtime().sessionId);
  });
});

// ---------------- an agent ----------------

const ENTRIES = [
  userE("p1", null, "先建 note.txt", 0),
  replyE("r1", "p1", "建好了", 1),
  { type: "file-history-snapshot", messageId: "p2", snapshot: { messageId: "p2", trackedFileBackups: { "note.txt": {} } } },
  userE("p2", "r1", "改成 two", 10),
  replyE("r2", "p2", "改好了", 11),
];

let n = 0;
/** An agent taken over from a background session with that conversation. */
async function agent(o: { entries?: unknown[]; spawn?: boolean } = {}) {
  let fork: ReturnType<typeof forks>["fork"];
  const t = both({ palScript: script, spawn: o.spawn, pals: { forkSession: (sid: string, x: any) => fork(sid, x) } });
  const made = forks(t.claude.dir);
  fork = made.fork;
  const sid = `ffff6666-0000-4000-8000-0000000000${String(++n).padStart(2, "0")}`;
  t.cli.bg({ sessionId: sid, name: "网站", cwd: t.project });
  t.claude.transcript(t.project, sid, o.entries ?? ENTRIES);
  const { pal } = await t.call("pals.adopt", { sessionId: sid });
  const rec = () => t.pal(pal.id).rec;
  const rewind = (messageId: string, over: Record<string, unknown> = {}) => t.call("pals.rewind", { id: pal.id, messageId, ...over });
  return { ...t, f: made.f, sid, id: pal.id as string, rec, rewind, proc: () => t.driver.pals.at(-1)! };
}

describe("an agent", () => {
  test("what's kept: the session it goes on in, what it was forked from, its line in the list back to what was said before", async () => {
    const t = await agent();
    expect(t.hub.pals.list()[0]!.lastLine).toBe("改好了");
    await t.rewind("p2");
    expect(t.rec()).toMatchObject({ rewind: { from: t.sid, at: "r1", cut: "p2" }, formerSessions: [t.sid] });
    expect(t.hub.pals.list()[0]!.lastLine).toBe("建好了");
    const saved = JSON.parse(readFileSync(t.paths.pals, "utf8")).pals[0];
    expect(saved).toMatchObject({ sessionId: t.rec().sessionId, rewind: { from: t.sid, at: "r1", cut: "p2" } });
    await t.hub.pals.stopAndWait();
  });

  test("back to its first message: a fresh session, its page empty; then spoken to, it's that session", async () => {
    const t = await agent();
    expect(await t.rewind("p1")).toEqual({ text: "先建 note.txt", filesRestored: false });
    expect(t.rec().rewind).toEqual({ from: t.sid, at: null, cut: "p1" });
    expect(t.proc().opts).toMatchObject({ sessionId: t.rec().sessionId });
    expect(t.proc().opts.fork).toBeUndefined();
    expect(t.proc().opts.resumeSessionId).toBeUndefined();
    expect((await t.call("pals.history", { id: t.id })).messages).toEqual([]);
    const to = t.rec().sessionId;
    await t.call("pals.send", { id: t.id, text: "重新" });
    t.claude.transcript(t.project, to, [userE("n1", null, "重新", 50)]);
    expect((await t.call("pals.history", { id: t.id })).messages.map((m: any) => m.id)).toEqual(["n1"]);
    expect(t.rec().rewind).toBeUndefined();
    expect(t.rec().sessionId).toBe(to);
    await t.hub.pals.stopAndWait();
  });

  test("again before speaking: cut further back on the session the first one kept; both its old sessions are its own", async () => {
    const t = await agent();
    await t.rewind("p2");
    const first = t.rec().sessionId;
    await expect(t.rewind("p2")).rejects.toThrow(rewindNotFound());
    expect(await t.rewind("p1")).toEqual({ text: "先建 note.txt", filesRestored: false });
    expect(t.rec().rewind).toEqual({ from: t.sid, at: null, cut: "p1" });
    expect(t.rec().formerSessions).toEqual([t.sid]);
    expect(t.rec().sessionId).not.toBe(first);
    expect(t.events.filter((e) => e.event === "chat.rewound").map((e) => e.data.ids)).toEqual([["p2", "msg_r2"], ["p1", "msg_r1"]]);
    await t.hub.pals.stopAndWait();
  });

  test("again once spoken to and written: cut in the fork, which joins its old sessions", async () => {
    const t = await agent();
    await t.rewind("p2");
    const fork = t.rec().sessionId;
    await t.call("pals.send", { id: t.id, text: "改成 three" });
    await waitFor(() => t.statusOf(t.id) === "idle");
    t.claude.transcript(t.project, fork, [ENTRIES[0], ENTRIES[1], userE("n2", "r1", "改成 three", 20), replyE("rn", "n2", "好", 21)]);
    await t.rewind("n2");
    expect(t.rec().rewind).toEqual({ from: fork, at: "r1", cut: "n2" });
    expect(t.rec().formerSessions).toEqual([t.sid, fork]);
    expect(t.proc().opts.fork).toEqual({ fromSessionId: fork, at: "r1" });
    await t.hub.pals.stopAndWait();
  });

  test("refused with a card open, words on their way in, starting or being put to sleep; a background task alone doesn't refuse it", async () => {
    const t = await agent();
    const same = () => {
      expect(t.rec().sessionId).toBe(t.sid);
      expect(t.rec().rewind).toBeUndefined();
    };
    const proc = t.proc();
    await t.call("pals.send", { id: t.id, text: "要问" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    await expect(t.rewind("p2")).rejects.toThrow(rewindBusy());
    expect(t.hub.approvals.listPending()).toHaveLength(1);
    same();
    await t.call("approval.answer", { id: t.hub.approvals.listPending()[0]!.id, allow: true });
    await waitFor(() => t.statusOf(t.id) === "idle");
    expect(t.proc()).toBe(proc);
    // being put to sleep
    const sleeping = t.pal(t.id).sleep();
    await expect(t.rewind("p2")).rejects.toThrow(rewindBusy());
    await sleeping;
    same();
    // words waking it
    const sending = t.call("pals.send", { id: t.id, text: "起来" });
    await expect(t.rewind("p2")).rejects.toThrow(rewindBusy());
    await sending;
    await waitFor(() => t.statusOf(t.id) === "idle");
    // starting
    await t.pal(t.id).sleep();
    const starting = t.call("pals.wake", { id: t.id });
    await expect(t.rewind("p2")).rejects.toThrow(rewindBusy());
    await starting;
    same();
    t.proc().opts.onEvent({ type: "background_tasks", taskIds: ["bg1"] } as any);
    expect((await t.rewind("p2")).text).toBe("改成 two");
    await t.hub.pals.stopAndWait();
  });

  test("a process elsewhere holds its session: refused saying so, its own process left alone", async () => {
    const t = await agent({ spawn: true });
    const proc = t.proc();
    const pal = t.pal(t.id);
    (pal as any).d = { ...(pal as any).d, holders: async () => [{ pid: 4242, bg: false }] };
    await expect(t.rewind("p2")).rejects.toThrow(tr("pals.heldElsewhereRewind", { name: "网站", pids: "4242" }));
    expect(proc.closed).toBe(false);
    expect(t.rec().sessionId).toBe(t.sid);
    expect(t.statusOf(t.id)).toBe("idle");
    (pal as any).d = { ...(pal as any).d, holders: async () => [] };
    await t.hub.pals.stopAndWait();
  });

  test("past a compaction, the copy fails: said so, and it comes back up on the same session; asleep, it stays asleep", async () => {
    const entries = [ENTRIES[0], ENTRIES[1], ENTRIES[3], ENTRIES[4], ...compactE("r2", 20), userE("p3", "sum", "再改", 30), replyE("r3", "p3", "好", 31)];
    const t = await agent({ entries });
    t.f.fail = "disk full";
    const first = t.proc();
    await expect(t.rewind("p2")).rejects.toThrow(tr("pals.rewindFailed", { why: "disk full" }));
    expect(first.closed).toBe(true); // the process ends first
    expect(t.proc()).not.toBe(first);
    expect(t.proc().opts).toMatchObject({ resumeSessionId: t.sid });
    expect(t.statusOf(t.id)).toBe("idle");
    expect(t.rec()).toMatchObject({ sessionId: t.sid });
    expect(t.rec().formerSessions).toBeUndefined();
    expect(t.events.some((e) => e.event === "chat.rewound")).toBe(false);
    await t.pal(t.id).sleep();
    const up = t.driver.pals.length;
    await expect(t.rewind("p2")).rejects.toThrow(tr("pals.rewindFailed", { why: "disk full" }));
    expect(t.driver.pals).toHaveLength(up);
    expect(t.statusOf(t.id)).toBe("asleep");
    // after the point only: forked, not copied
    const calls = t.f.calls;
    await t.rewind("p3");
    expect(t.f.calls).toBe(calls);
    expect(t.rec().rewind).toEqual({ from: t.sid, at: "sum", cut: "p3" });
    expect(t.statusOf(t.id)).toBe("asleep");
    // back to the very first: nothing to copy either
    await t.rewind("p1");
    expect(t.f.calls).toBe(calls);
    expect(t.rec().rewind).toEqual({ from: t.sid, at: null, cut: "p1" });
  });

  test("with the files, asleep: the files go back, it stays asleep; a process that won't start to put them back: 没法恢复, and it's as it was", async () => {
    const t = await agent();
    await t.pal(t.id).sleep();
    t.driver.failPalStart = () => "Claude Code process exited with code 1";
    await expect(t.rewind("p2", { restoreFiles: true })).rejects.toThrow(rewindNoFiles());
    expect(t.rec().sessionId).toBe(t.sid);
    expect(t.statusOf(t.id)).toBe("asleep");
    t.driver.failPalStart = undefined;
    expect(await t.rewind("p2", { restoreFiles: true })).toEqual({ text: "改成 two", filesRestored: true });
    expect(t.driver.fileRewinds.map((f) => f.uuid)).toEqual(["p2"]);
    expect(t.proc().closed).toBe(true);
    expect(t.statusOf(t.id)).toBe("asleep");
    // gone back and not spoken to since: the files of an earlier message, on the session it was cut from
    await expect(t.rewind("p1", { restoreFiles: true })).rejects.toThrow(rewindNoFiles());
    expect(t.rec().rewind).toMatchObject({ from: t.sid, cut: "p2" });
  });

  test("sent with a file: its words come back as typed, without the file's path; the assistant's handover isn't the owner's to go back to", async () => {
    const p2 = "12345678-0000-4000-8000-000000000002";
    const t = await agent({ entries: [ENTRIES[0], ENTRIES[1], userE(p2, "r1", "看这个\n[文件] /x/a.txt", 10), replyE("r2", p2, "看了", 11)] });
    t.hub.media.remember(p2, { text: "看这个", attachments: [{ kind: "file", id: "f1", name: "a.txt", mediaType: "text/plain", size: 1 }] });
    t.rec().duty = "先建 note.txt";
    await expect(t.rewind("p1")).rejects.toThrow(tr("pals.notYourMessage"));
    expect(await t.rewind(p2)).toEqual({ text: "看这个", filesRestored: false });
    await t.hub.pals.stopAndWait();
  });

  test("it can't start again after going back: gone back all the same, and the owner's next words start it on the fork", async () => {
    const t = await agent();
    t.driver.failPalStart = () => "Claude Code process exited with code 1";
    expect(await t.rewind("p2")).toEqual({ text: "改成 two", filesRestored: false });
    expect(t.rec().rewind).toEqual({ from: t.sid, at: "r1", cut: "p2" });
    t.driver.failPalStart = undefined;
    await t.call("pals.send", { id: t.id, text: "改成 three" });
    expect(t.proc().opts.fork).toEqual({ fromSessionId: t.sid, at: "r1" });
    expect(t.proc().sent).toEqual(["改成 three"]);
    await t.hub.pals.stopAndWait();
  });

  test("stopped and still winding down, it goes back at once; what's left of the old process says nothing", async () => {
    const t = await agent();
    t.driver.palScript = async () => new Promise<void>(() => {});
    const old = t.proc();
    await t.call("pals.send", { id: t.id, text: "慢慢来" });
    await waitFor(() => t.statusOf(t.id) === "busy");
    await t.call("pals.stop", { id: t.id });
    await t.rewind("p2");
    const said = t.said(t.id).length;
    old.opts.onEvent({ type: "assistant_text", text: "晚到的", parentToolUseId: null, messageId: "msg_late" });
    old.opts.onEvent(result(old.sessionId, []));
    expect(t.said(t.id)).toHaveLength(said);
    expect(t.statusOf(t.id)).toBe("idle");
    await t.hub.pals.stopAndWait();
  });
});
