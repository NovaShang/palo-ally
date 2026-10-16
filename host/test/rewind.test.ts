// 回到这里重来 (docs/rewind-prd.md) with the fake harness: the assistant's
// conversation and a Pal's go back to just before one of the owner's
// messages, as a new session forked from the old one.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { transcriptPath } from "../src/handoffs.ts";
import type { PalsTiming } from "../src/pals.ts";
import { REWIND_BUSY, REWIND_NOT_FOUND, REWIND_NO_FILES, chainTo, findEntry, hasFileCheckpoint, matchOwnerEntry, ownerText, readTranscript } from "../src/rewind.ts";
import { handleRpc } from "../src/rpc.ts";
import type { ChatMessage } from "../src/types.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli } from "./fakeClaude.ts";
import { makeHub, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
});

const at = (s: number) => new Date(Date.parse("2026-10-16T08:00:00Z") + s * 1000).toISOString();
const user = (uuid: string, parentUuid: string | null, text: string, s: number, extra: Record<string, unknown> = {}) => ({
  type: "user",
  uuid,
  parentUuid,
  timestamp: at(s),
  message: { role: "user", content: text },
  ...extra,
});
const reply = (uuid: string, parentUuid: string, text: string, s: number, id = `msg_${uuid}`) => ({
  type: "assistant",
  uuid,
  parentUuid,
  timestamp: at(s),
  message: { id, role: "assistant", model: "claude-haiku-4-5", content: [{ type: "text", text }] },
});

const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };

describe("reading the transcript", () => {
  const entries = [
    user("u1", null, "第一句", 0),
    reply("a1", "u1", "好", 1),
    { type: "file-history-snapshot", messageId: "u2", snapshot: { messageId: "u2", trackedFileBackups: {} } },
    user("u2", "a1", "第二句", 10),
    reply("a2", "u2", "嗯", 11),
    { type: "system", subtype: "compact_boundary", uuid: "cb", parentUuid: null, logicalParentUuid: "a2", timestamp: at(20) },
    user("sum", "cb", "前面说了……", 20, { isCompactSummary: true }),
    { type: "attachment", uuid: "q3", parentUuid: "sum", attachment: { type: "queued_command", source_uuid: "u3" }, timestamp: at(30) },
    user("t3", "q3", "[tool]", 31, { message: { role: "user", content: [{ type: "tool_result", tool_use_id: "x", content: "ok" }] }, toolUseResult: {} }),
  ];

  test("an owner's entry by uuid, or the attachment naming it when it was taken mid-turn; its words; never a tool result or a summary", () => {
    expect(findEntry(entries, "u2").uuid).toBe("u2");
    expect(findEntry(entries, "u3").uuid).toBe("q3");
    expect(findEntry(entries, "nope")).toBeUndefined();
    expect(ownerText(entries[3])).toBe("第二句");
    expect(ownerText(entries[6])).toBeNull();
    expect(ownerText(entries[8])).toBeNull();
    expect(ownerText({ type: "user", uuid: "p", origin: { kind: "peer" }, message: { content: "hi" } })).toBeNull();
    expect(ownerText({ type: "user", uuid: "i", message: { content: [{ type: "image" }, { type: "text", text: "看图" }] } })).toBe("看图");
  });

  test("an older message matched by its words, the nearest in time within 30 minutes, each entry once", () => {
    const two = [user("x1", null, "好的", 0), user("x2", "x1", "好的", 600)];
    const ts = Date.parse(at(590));
    expect(matchOwnerEntry(two, "好的", ts).uuid).toBe("x2");
    expect(matchOwnerEntry(two, "好的", ts, new Set(["x2"])).uuid).toBe("x1");
    expect(matchOwnerEntry(two, "好的", ts + 3 * 3600_000)).toBeUndefined();
    expect(matchOwnerEntry(two, "别的", ts)).toBeUndefined();
  });

  test("the conversation up to an entry follows parents across a compaction; file checkpoints by message", () => {
    expect(chainTo(entries, "t3").map((e) => e.uuid)).toEqual(["u1", "a1", "u2", "a2", "cb", "sum", "q3", "t3"]);
    expect(chainTo(entries, "a1").map((e) => e.uuid)).toEqual(["u1", "a1"]);
    expect(chainTo(entries, null)).toEqual([]);
    expect(hasFileCheckpoint(entries, "u2")).toBe(true);
    expect(hasFileCheckpoint(entries, "u1")).toBe(false);
  });
});

// ---------------- the assistant's conversation ----------------

function palo(script?: FakeScript, paths = tmpPaths()) {
  const t = makeHub({ script, paths });
  const claudeDir = (t.hub as any).claudeDir as string;
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(t.hub, { method, params }, app)) ?? null));
  const transcript = (sid: string, entries: unknown[]) => {
    const p = transcriptPath(claudeDir, t.paths.home, sid);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  };
  return { ...t, claudeDir, call, transcript };
}

/** What Claude Code would have written for these owner messages, each answered. */
function written(msgs: ChatMessage[], extra: (i: number) => unknown[] = () => []): unknown[] {
  const out: unknown[] = [];
  let parent: string | null = null;
  msgs.forEach((m, i) => {
    out.push(user(m.uuid!, parent, m.text, i * 10));
    out.push(reply(`a${i}`, m.uuid!, `收到：${m.text}`, i * 10 + 1));
    parent = `a${i}`;
    out.push(...extra(i));
  });
  return out;
}

/** Two answered messages, a compaction, then the third. */
function compacted(msgs: ChatMessage[]): unknown[] {
  return [
    ...written(msgs.slice(0, 2)),
    { type: "system", subtype: "compact_boundary", uuid: "cb", parentUuid: null, logicalParentUuid: "a1", timestamp: at(30) },
    user("sum", "cb", "摘要", 30, { isCompactSummary: true }),
    user(msgs[2]!.uuid!, "sum", msgs[2]!.text, 40),
    reply("a2", msgs[2]!.uuid!, "收到", 41),
  ];
}

/** The SDK's forkSession, in a test's Claude Code folder: the conversation up to an entry, with new uuids. */
function fakeForks(claudeDir: string) {
  const calls: { sessionId: string; dir: string; upToMessageId: string; title?: string }[] = [];
  const fork = async (sessionId: string, o: { dir: string; upToMessageId: string; title?: string }) => {
    calls.push({ sessionId, ...o });
    const entries = readTranscript(transcriptPath(claudeDir, o.dir, sessionId));
    const to = `copy-${calls.length}-${sessionId.slice(0, 8)}`;
    const p = transcriptPath(claudeDir, o.dir, to);
    const kept = chainTo(entries, o.upToMessageId).map((e) => ({ ...e, uuid: `${e.uuid}-copy`, parentUuid: e.parentUuid ? `${e.parentUuid}-copy` : null, sessionId: to, forkedFrom: { sessionId, messageUuid: e.uuid } }));
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, kept.map((e) => JSON.stringify(e)).join("\n") + "\n");
    return { sessionId: to };
  };
  return { calls, fork };
}

describe("the assistant's conversation", () => {
  test("the owner's messages go to the harness under the uuid the log keeps (not a slash command)", async () => {
    const t = palo();
    const m1 = t.hub.userMessage("第一句", "app")!;
    await t.hub.idle();
    const cmd = t.hub.userMessage("/compact", "app")!;
    await t.hub.idle();
    expect(m1.uuid).toMatch(/^[0-9a-f-]{36}$/);
    expect(cmd.uuid).toBeUndefined();
    expect(t.driver.last!.sentUuids[0]).toBe(m1.uuid!);
    expect(t.hub.chat.get(m1.id)!.uuid).toBe(m1.uuid!);
  });

  test("going back to the second message: the process ends, that message and what came after leave the conversation, its words come back, and the next message forks the session from the entry before it", async () => {
    const t = palo();
    const msgs: ChatMessage[] = [];
    for (const text of ["第一句", "第二句", "第三句"]) {
      msgs.push(t.hub.userMessage(text, "app")!);
      await t.hub.idle();
    }
    const sid = t.hub.status().sessionId!;
    t.transcript(sid, written(msgs));
    const before = t.hub.chat.lastSeq;
    const proc = t.driver.last!;
    const shown = t.hub.chat.since(0).map((m) => m.id);
    const second = shown.indexOf(msgs[1]!.id);

    expect(await t.call("chat.rewind", { messageId: msgs[1]!.id })).toEqual({ text: "第二句" });
    expect(proc.closed).toBe(true);
    const ev = t.events.find((e) => e.event === "chat.rewound")!.data;
    expect(ev).toEqual({ id: msgs[1]!.id, ids: shown.slice(second) });
    // gone from what clients see, still in the log
    expect(t.hub.chat.since(0).map((m) => m.id)).toEqual(shown.slice(0, second));
    expect(t.hub.chat.get(msgs[2]!.id)).toMatchObject({ rewound: true });
    expect((await t.call("sync", {})).messages.map((m: any) => m.id)).toEqual(shown.slice(0, second));
    expect(readFileSync(t.paths.chat, "utf8")).toContain('"rewound":true');
    // a client that was away hears of it on its next sync
    const sync = await t.call("sync", { sinceSeq: before });
    expect(sync.rewound).toEqual(shown.slice(second));
    expect(sync.seq).toBe(before + 1);
    expect((await t.call("sync", { sinceSeq: before + 1 })).rewound).toBeUndefined();
    const to = t.hub.status().sessionId!;
    expect(to).not.toBe(sid);
    expect(t.hub.audit.tail(10).find((e) => e.type === "chat.rewind")).toMatchObject({ messageId: msgs[1]!.id, from: sid, to, at: "a0", dropped: 4, by: "app" });

    // the owner sends it again, edited: a new session forked from the old one after 「第一句」's answer
    t.hub.userMessage("第二句（改过）", "app");
    await t.hub.idle();
    const next = t.driver.last!;
    expect(next).not.toBe(proc);
    expect(next.opts).toMatchObject({ sessionId: to, fork: { fromSessionId: sid, at: "a0" } });
    expect(next.opts.resumeSessionId).toBeUndefined();
    expect(next.sent).toEqual(["第二句（改过）"]);
  });

  test("going back to the very first message starts a fresh session", async () => {
    const t = palo();
    const m = t.hub.userMessage("第一句", "app")!;
    await t.hub.idle();
    t.transcript(t.hub.status().sessionId!, written([m]));
    await t.call("chat.rewind", { messageId: m.id });
    t.hub.userMessage("重新开始", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts).toMatchObject({ sessionId: t.hub.status().sessionId });
    expect(t.driver.last!.opts.fork).toBeUndefined();
    expect(t.driver.last!.opts.resumeSessionId).toBeUndefined();
  });

  test("a compaction after the point: Claude Code resumes only from its last compaction, so the conversation up to the point is copied into a new session (new uuids, which the log takes up)", async () => {
    const t = palo();
    const forks = fakeForks(t.claudeDir);
    (t.hub as any).forkSession = forks.fork;
    const msgs: ChatMessage[] = [];
    for (const text of ["第一句", "第二句", "第三句"]) {
      msgs.push(t.hub.userMessage(text, "app")!);
      await t.hub.idle();
    }
    const sid = t.hub.status().sessionId!;
    // 第三句 came after Claude Code compacted the conversation
    t.transcript(sid, compacted(msgs));
    await t.call("chat.rewind", { messageId: msgs[1]!.id });
    expect(forks.calls).toEqual([{ sessionId: sid, dir: t.paths.home, upToMessageId: "a0", title: "Palo" }]);
    const copy = t.hub.status().sessionId!;
    expect(JSON.parse(readFileSync(t.paths.runtime, "utf8")).rewind).toBeUndefined();
    expect(t.hub.chat.get(msgs[0]!.id)!.uuid).toBe(`${msgs[0]!.uuid}-copy`);
    expect(t.hub.audit.tail(5).find((e) => e.type === "chat.rewind")).toMatchObject({ copied: true, to: copy });
    t.hub.userMessage("再来", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts).toMatchObject({ resumeSessionId: copy });
    expect(t.driver.last!.opts.fork).toBeUndefined();
    // and from the copy, back to its first message again
    await t.call("chat.rewind", { messageId: msgs[0]!.id });
  });

  test("a compaction before the point: forked as usual, from after it", async () => {
    const t = palo();
    const msgs: ChatMessage[] = [];
    for (const text of ["第一句", "第二句", "第三句"]) {
      msgs.push(t.hub.userMessage(text, "app")!);
      await t.hub.idle();
    }
    const sid = t.hub.status().sessionId!;
    t.transcript(sid, compacted(msgs));
    await t.call("chat.rewind", { messageId: msgs[2]!.id });
    t.hub.userMessage("再来", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts.fork).toEqual({ fromSessionId: sid, at: "sum" });
  });

  test("refused while a turn is on (the owner stops it first); nothing changes", async () => {
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    const t = palo(async (text, ctx) => {
      if (text === "慢慢来") await held;
      ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null });
    });
    const m1 = t.hub.userMessage("第一句", "app")!;
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    t.hub.userMessage("慢慢来", "app");
    await tick(5);
    t.transcript(sid, written([m1]));
    await expect(t.call("chat.rewind", { messageId: m1.id })).rejects.toThrow(REWIND_BUSY);
    expect(t.hub.status().sessionId).toBe(sid);
    // 停止 then 重来: one step for the owner
    await t.call("stop");
    expect(await t.call("chat.rewind", { messageId: m1.id })).toEqual({ text: "第一句" });
    release();
  });

  test("what can't be gone back to: a reply, a Pal's message, one not in the transcript, one already rewound", async () => {
    const t = palo();
    const m1 = t.hub.userMessage("第一句", "app")!;
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    const answer = t.hub.chat.since(0).find((m) => m.role === "assistant")!;
    await expect(t.call("chat.rewind", { messageId: answer.id })).rejects.toThrow("这一条不能回到这里");
    await expect(t.call("chat.rewind", { messageId: m1.id })).rejects.toThrow(REWIND_NOT_FOUND);
    t.transcript(sid, written([m1]));
    await t.call("chat.rewind", { messageId: m1.id });
    await expect(t.call("chat.rewind", { messageId: m1.id })).rejects.toThrow("已经撤回了");
  });

  test("not yet followed by a message, it survives a restart (the fork is made again), and once Claude Code has written the new session it's resumed as usual", async () => {
    const paths = tmpPaths();
    const t = palo(undefined, paths);
    const msgs: ChatMessage[] = [];
    for (const text of ["第一句", "第二句"]) {
      msgs.push(t.hub.userMessage(text, "app")!);
      await t.hub.idle();
    }
    const sid = t.hub.status().sessionId!;
    t.transcript(sid, written(msgs));
    await t.call("chat.rewind", { messageId: msgs[1]!.id });
    const to = t.hub.status().sessionId!;
    t.hub.stop();

    const t2 = palo(undefined, paths);
    (t2.hub as any).claudeDir = t.claudeDir; // the same computer
    (t2.hub.conversation as any).d.transcriptOf = (s: string) => transcriptPath(t.claudeDir, paths.home, s);
    expect(t2.hub.status().sessionId).toBe(to);
    // a second rewind before any message: still on what the first one kept
    await expect(t2.call("chat.rewind", { messageId: msgs[1]!.id })).rejects.toThrow("已经撤回了");
    t2.hub.userMessage("第二句（改）", "app");
    await t2.hub.idle();
    expect(t2.driver.last!.opts).toMatchObject({ sessionId: to, fork: { fromSessionId: sid, at: "a0" } });
    t2.hub.stop();

    // Claude Code wrote the fork with its first message
    t.transcript(to, [...written([msgs[0]!]), user("n1", "a0", "第二句（改）", 30)]);
    const t3 = palo(undefined, paths);
    (t3.hub.conversation as any).d.transcriptOf = (s: string) => transcriptPath(t.claudeDir, paths.home, s);
    t3.hub.userMessage("接着", "app");
    await t3.hub.idle();
    expect(t3.driver.last!.opts).toMatchObject({ resumeSessionId: to });
    expect(t3.driver.last!.opts.fork).toBeUndefined();
    expect(JSON.parse(readFileSync(paths.runtime, "utf8")).rewind).toBeUndefined();
    t3.hub.stop();
  });

  test("the owner's earlier messages, kept before they had a uuid, are matched in the transcript by their words and time", async () => {
    const t = palo();
    const m1 = t.hub.userMessage("第一句", "app")!;
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    // as an older host kept them: no uuid in the log
    const old = t.hub.chat.add({ role: "user", kind: "text", text: "以前说的", channel: "wechat", ts: Date.parse(at(100)) });
    const lost = t.hub.chat.add({ role: "user", kind: "text", text: "记录里没有", channel: "app", ts: Date.parse(at(110)) });
    t.transcript(sid, [...written([m1]), user("w1", "a0", "[来自微信] 以前说的", 100), reply("aw", "w1", "好", 101)]);
    expect(t.hub.backfillOwnerUuids()).toBe(1);
    expect(t.hub.chat.get(old.id)!.uuid).toBe("w1");
    expect(t.hub.chat.get(lost.id)!.uuid).toBeUndefined();
    expect(t.hub.backfillOwnerUuids()).toBe(0);
    expect(await t.call("chat.rewind", { messageId: old.id })).toEqual({ text: "以前说的" });
    t.hub.userMessage("再说", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts.fork).toEqual({ fromSessionId: sid, at: "a0" });
  });

  test("words held for an Ally's turn keep their uuid until they go in", async () => {
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    const t = palo(async (text, ctx) => {
      if (text.includes("Ally 来话")) await held;
      ctx.emit({ type: "assistant_text", text: "好", parentToolUseId: null });
    });
    t.hub.conversation.enqueue({ text: "Ally 来话", origin: "system", proactive: true, allyId: "ally_1" });
    await tick(5);
    const m = t.hub.userMessage("等它说完", "app")!;
    expect(t.driver.last!.sentUuids).not.toContain(m.uuid!);
    release();
    await t.hub.idle();
    expect(t.driver.last!.sentUuids).toContain(m.uuid!);
  });
});

// ---------------- a Pal ----------------

const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 500, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };

function palSetup(o: { forks?: (claudeDir: string) => ReturnType<typeof fakeForks> } = {}) {
  const claude = new FakeClaudeDir();
  const forks = o.forks?.(claude.dir);
  dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const t = makeHub({
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false), readMessages: async () => [] },
    pals: { timing: FAST, readMessages: async (sid, dir) => readTranscript(transcriptPath(claude.dir, dir, sid)), ...(forks ? { forkSession: forks.fork } : {}) },
  });
  t.driver.palScript = async (text, ctx) => ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null, messageId: "msg_live" });
  t.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-pal-")));
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(t.hub, { method, params }, app)) ?? null));
  return { ...t, claude, cli, project, call, forks: forks! };
}

// A Pal's session as Claude Code wrote it: two owner messages, the second
// with its files kept (file checkpointing), the assistant's words in between.
function palTranscript(t: ReturnType<typeof palSetup>, sid: string) {
  t.claude.transcript(t.project, sid, [
    user("p1", null, "先建 note.txt", 0, { origin: { kind: "human" } }),
    reply("r1", "p1", "建好了", 1, "msg_r1"),
    user("peer", "r1", "<cross-session-message from=\"paloally\" from-name=\"Palo\">\n顺便看看\n</cross-session-message>", 5),
    reply("r1b", "peer", "看了", 6, "msg_r1b"),
    { type: "file-history-snapshot", messageId: "p2", snapshot: { messageId: "p2", trackedFileBackups: { "note.txt": {} } } },
    user("p2", "r1b", "改成 two", 10, { origin: { kind: "human" } }),
    reply("r2", "p2", "改好了", 11, "msg_r2"),
  ]);
}

async function adopted(t: ReturnType<typeof palSetup>) {
  const sid = "cccc3333-0000-4000-8000-000000000001";
  t.cli.bg({ sessionId: sid, name: "网站", cwd: t.project });
  palTranscript(t, sid);
  const { pal } = await t.call("pals.adopt", { sessionId: sid });
  return { pal, sid };
}

describe("a Pal", () => {
  test("runs with file checkpointing from now on", async () => {
    const t = palSetup();
    await adopted(t);
    expect(t.driver.pals[0]!.opts.fileCheckpointing).toBe(true);
    await t.hub.pals.stopAndWait();
  });

  test("back to before its second message with the files: Claude Code puts the files back on the old session, the Pal comes back on a fork from the entry before, and its page drops what went", async () => {
    const t = palSetup();
    const { pal, sid } = await adopted(t);
    const first = t.driver.pals[0]!;
    expect(await t.call("pals.rewind", { id: pal.id, messageId: "p2", check: true })).toEqual({ canRestoreFiles: true });
    expect(await t.call("pals.rewind", { id: pal.id, messageId: "p1", check: true })).toEqual({ canRestoreFiles: false });

    expect(await t.call("pals.rewind", { id: pal.id, messageId: "p2", restoreFiles: true })).toEqual({ text: "改成 two", filesRestored: true });
    expect(first.closed).toBe(true);
    // the files: a process of its own on the old session, file checkpointing on, asked only that
    expect(t.driver.fileRewinds).toEqual([{ sessionId: sid, uuid: "p2", dryRun: false, checkpointing: true }]);
    const restorer = t.driver.pals[1]!;
    expect(restorer.opts).toMatchObject({ resumeSessionId: sid, fileCheckpointing: true });
    expect(restorer.sent).toEqual([]);
    expect(restorer.closed).toBe(true);
    // back up at once, on a fork
    const now = t.hub.pals.list()[0]!;
    expect(now.sessionId).not.toBe(sid);
    expect(now.status).toBe("idle");
    const forked = t.driver.pals[2]!;
    expect(forked.opts).toMatchObject({ sessionId: now.sessionId, fork: { fromSessionId: sid, at: "r1b" }, fileCheckpointing: true, name: "网站" });
    expect(t.events.find((e) => e.event === "chat.rewound")!.data).toEqual({ id: "p2", ids: ["p2", "msg_r2"], pal: pal.id });
    expect(t.hub.audit.tail(20).find((e) => e.type === "pal.rewind")).toMatchObject({ pal: pal.id, messageId: "p2", from: sid, to: now.sessionId, at: "r1b", dropped: 2, files: true });
    // its page: the old session's conversation up to the cut
    const page = await t.call("pals.history", { id: pal.id });
    expect(page.messages.map((m: any) => m.id)).toEqual(["p1", "msg_r1", "peer", "msg_r1b"]);
    // its old session isn't among the ended conversations
    expect(t.hub.pals.isPal(sid)).toBe(true);

    // the owner's next words go into the fork; once Claude Code wrote it, it's the Pal's session
    await t.call("pals.send", { id: pal.id, text: "改成 three" });
    t.claude.transcript(t.project, now.sessionId, [user("p1", null, "先建 note.txt", 0, { origin: { kind: "human" } }), reply("r1", "p1", "建好了", 1, "msg_r1"), user("n2", "r1", "改成 three", 20, { origin: { kind: "human" } })]);
    expect((await t.call("pals.history", { id: pal.id })).messages.map((m: any) => m.id)).toEqual(["p1", "msg_r1", "n2"]);
    await t.hub.pals.stopAndWait();
    expect(t.hub.pals.get(pal.id)!.rec.rewind).toBeUndefined();
  });

  test("without the files: the conversation only", async () => {
    const t = palSetup();
    const { pal, sid } = await adopted(t);
    expect(await t.call("pals.rewind", { id: pal.id, messageId: "p2" })).toEqual({ text: "改成 two", filesRestored: false });
    expect(t.driver.fileRewinds).toEqual([]);
    expect(t.driver.pals.at(-1)!.opts.fork).toEqual({ fromSessionId: sid, at: "r1b" });
    await t.hub.pals.stopAndWait();
  });

  test("files that can't go back: 这一步之前的代码没法恢复, and the conversation stays as it was", async () => {
    const t = palSetup();
    const { pal, sid } = await adopted(t);
    // no checkpoint for its first message
    await expect(t.call("pals.rewind", { id: pal.id, messageId: "p1", restoreFiles: true })).rejects.toThrow(REWIND_NO_FILES);
    expect(t.driver.pals).toHaveLength(1);
    // Claude Code can't
    t.driver.filesRewound = () => ({ canRewind: false, error: "No file checkpoint found for this message." });
    await expect(t.call("pals.rewind", { id: pal.id, messageId: "p2", restoreFiles: true })).rejects.toThrow(REWIND_NO_FILES);
    const now = t.hub.pals.list()[0]!;
    expect(now.sessionId).toBe(sid);
    await waitFor(() => t.hub.pals.list()[0]!.status === "idle");
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ resumeSessionId: sid });
    expect(t.events.some((e) => e.event === "chat.rewound")).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("only the owner's own words; refused while it's working", async () => {
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    const t = palSetup();
    t.driver.palScript = async (text, ctx) => {
      if (text === "慢慢来") await held;
      ctx.emit({ type: "assistant_text", text: "好", parentToolUseId: null, messageId: "msg_x" });
    };
    const { pal } = await adopted(t);
    await expect(t.call("pals.rewind", { id: pal.id, messageId: "peer" })).rejects.toThrow("不是你说的");
    await expect(t.call("pals.rewind", { id: pal.id, messageId: "r1" })).rejects.toThrow("不是你说的");
    await expect(t.call("pals.rewind", { id: pal.id, messageId: "nope" })).rejects.toThrow(REWIND_NOT_FOUND);
    void t.call("pals.send", { id: pal.id, text: "慢慢来" });
    await waitFor(() => t.hub.pals.list()[0]!.status === "busy");
    await expect(t.call("pals.rewind", { id: pal.id, messageId: "p2" })).rejects.toThrow(REWIND_BUSY);
    await t.call("pals.stop", { id: pal.id });
    expect((await t.call("pals.rewind", { id: pal.id, messageId: "p2" })).text).toBe("改成 two");
    release();
    await t.hub.pals.stopAndWait();
  });

  test("past its last compaction: copied into a new session at once (no fork to make), and its page is the copy", async () => {
    const t = palSetup({ forks: fakeForks });
    const { forks } = t;
    const { pal, sid } = await adopted(t);
    t.claude.transcript(t.project, sid, [
      user("p1", null, "先建 note.txt", 0, { origin: { kind: "human" } }),
      reply("r1", "p1", "建好了", 1, "msg_r1"),
      user("p2", "r1", "改成 two", 10, { origin: { kind: "human" } }),
      reply("r2", "p2", "改好了", 11, "msg_r2"),
      { type: "system", subtype: "compact_boundary", uuid: "cb", parentUuid: null, logicalParentUuid: "r2", timestamp: at(20) },
      user("sum", "cb", "摘要", 20, { isCompactSummary: true }),
      user("p3", "sum", "再改", 30, { origin: { kind: "human" } }),
      reply("r3", "p3", "好", 31, "msg_r3"),
    ]);
    expect(await t.call("pals.rewind", { id: pal.id, messageId: "p2" })).toEqual({ text: "改成 two", filesRestored: false });
    expect(forks.calls).toEqual([{ sessionId: sid, dir: t.project, upToMessageId: "r1", title: "网站" }]);
    const now = t.hub.pals.get(pal.id)!.rec;
    expect(now.sessionId).toBe(`copy-1-${sid.slice(0, 8)}`);
    expect(now.rewind).toBeUndefined();
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ resumeSessionId: now.sessionId });
    expect(t.events.find((e) => e.event === "chat.rewound")!.data.ids).toEqual(["p2", "msg_r2", "sum", "p3", "msg_r3"]);
    expect((await t.call("pals.history", { id: pal.id })).messages.map((m: any) => m.id)).toEqual(["p1-copy", "msg_r1"]);
    await t.hub.pals.stopAndWait();
  });

  test("asleep, it stays asleep; woken, it comes up on the fork", async () => {
    const t = palSetup();
    const { pal, sid } = await adopted(t);
    await (t.hub.pals as any).putToSleep(t.hub.pals.get(pal.id), "test");
    const n = t.driver.pals.length;
    await t.call("pals.rewind", { id: pal.id, messageId: "p2" });
    expect(t.driver.pals).toHaveLength(n);
    expect(t.hub.pals.list()[0]!.status).toBe("asleep");
    await t.call("pals.wake", { id: pal.id });
    expect(t.driver.pals.at(-1)!.opts.fork).toEqual({ fromSessionId: sid, at: "r1b" });
    await t.hub.pals.stopAndWait();
  });

  test("the fork's copied lines aren't news: the page isn't sent its old messages again when Claude Code writes the fork", async () => {
    const t = palSetup();
    const { pal } = await adopted(t);
    await t.call("pals.rewind", { id: pal.id, messageId: "p2" });
    const to = t.hub.pals.list()[0]!.sessionId;
    const before = t.events.length;
    t.claude.transcript(t.project, to, [
      user("p1", null, "先建 note.txt", 0, { origin: { kind: "human" } }),
      reply("r1", "p1", "建好了", 1, "msg_r1"),
      user("peer", "r1", "<cross-session-message from=\"paloally\" from-name=\"Palo\">\n顺便看看\n</cross-session-message>", 5),
      reply("r1b", "peer", "看了", 6, "msg_r1b"),
      user("fresh", "r1b", "<cross-session-message from=\"paloally\" from-name=\"Palo\">\n新的话\n</cross-session-message>", 30),
    ]);
    await waitFor(() => t.events.slice(before).some((e) => e.event === "chat.message" && e.data.id === "fresh"), 5_000);
    expect(t.events.slice(before).filter((e) => e.event === "chat.message" && e.data.pal).map((e) => e.data.id)).toEqual(["fresh"]);
    await t.hub.pals.stopAndWait();
  });
});

