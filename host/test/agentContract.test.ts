// The contract of the two runtimes, the assistant's (Conversation, through the
// Hub) and an agent's (PalSession, through Pals), pinned before batch 7 merges
// them into one AgentSession (docs/harness-adapter-design.md §1.1, step 0).
// Each case runs the same scripted turns against both and pins what each does,
// the same or (where the table says so) differently. Kept unchanged from step 0
// to the end of the batch: it is the proof that the merge changed nothing
// anyone can see. Only public surfaces: RPCs, bus events, the fake harness.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { transcriptPath } from "../src/handoffs.ts";
import { toPalMessages } from "../src/palHistory.ts";
import { chainTo, leafOf, matchOwnerEntry, readTranscript } from "../src/rewind.ts";
import { handleRpc } from "../src/rpc.ts";
import type { ChatMessage } from "../src/types.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli } from "./fakeClaude.ts";
import { makeHub, tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
afterAll(() => {
  dirs.forEach((d) => d.cleanup());
  clis.forEach((c) => c.close());
});

const FAST = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
const at = (s: number) => new Date(Date.parse("2026-11-01T08:00:00Z") + s * 1000).toISOString();

let msgN = 0;
/** One reply in two deltas of one API message, as Claude Code streams it. */
const echo: FakeScript = async (text, ctx) => {
  const id = `msg_c${++msgN}`;
  const reply = `收到：${text}`;
  ctx.emit({ type: "text_delta", text: reply.slice(0, 3), messageId: id });
  ctx.emit({ type: "text_delta", text: reply.slice(3), messageId: id });
  ctx.emit({ type: "assistant_text", text: reply, parentToolUseId: null, messageId: id });
};

/** The assistant and one agent on the same host, both over the fake harness. */
function both(o: { script?: FakeScript; palScript?: FakeScript } = {}) {
  const claude = new FakeClaudeDir();
  dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const t = makeHub({
    script: o.script ?? echo,
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false) },
    pals: { timing: FAST, readMessages: async (sid, dir) => readTranscript(transcriptPath(claude.dir, dir, sid)) },
  });
  t.driver.palScript = o.palScript ?? echo;
  t.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-contract-")));
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(t.hub, { method, params }, app)) ?? null));
  /** A new agent in the throwaway folder, up and idle. */
  const agent = async (text?: string) => {
    const { pal } = await call("pals.create", { cwd: project, ...(text ? { text } : {}) });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === pal.id)?.status === "idle");
    return pal as { id: string; sessionId: string; name: string };
  };
  const statusOf = (id: string) => t.hub.pals.list().find((p) => p.id === id)?.status;
  const palEvents = (event: string, id: string) => t.events.filter((e) => e.event === event && e.data?.pal === id).map((e) => e.data);
  const mainEvents = (event: string) => t.events.filter((e) => e.event === event && !e.data?.pal).map((e) => e.data);
  return { ...t, claude, cli, project, call, agent, statusOf, palEvents, mainEvents };
}

describe("owner words in, a reply out", () => {
  test("both: the words go in as typed; the reply streams and ends under one id; the assistant's lands in its own log, an agent's carries its id and stays out of the assistant's", async () => {
    const t = both();
    // the assistant
    const mine = t.hub.userMessage("你好", "app")!;
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["你好"]);
    expect(t.driver.last!.sentUuids).toEqual([mine.uuid!]);
    const deltas = t.mainEvents("chat.delta");
    const final = t.hub.chat.recent(5).filter((m) => m.role === "assistant");
    expect(final.map((m) => m.text)).toEqual(["收到：你好"]);
    expect(new Set(deltas.map((d) => d.id))).toEqual(new Set([final[0]!.id]));
    expect(deltas.map((d) => d.text).join("")).toBe("收到：你好");
    // an agent
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "你好" });
    await waitFor(() => t.palEvents("chat.message", pal.id).some((m) => m.role === "assistant"));
    const proc = t.driver.pals.at(-1)!;
    expect(proc.sent).toEqual(["你好"]);
    expect(proc.opts.ownerOrigin).toBe(true);
    const pd = t.palEvents("chat.delta", pal.id);
    const pm = t.palEvents("chat.message", pal.id);
    expect(pm.map((m) => `${m.role}:${m.text}`)).toEqual(["user:你好", "assistant:收到：你好"]);
    expect(new Set(pd.map((d) => d.id))).toEqual(new Set([pm[1]!.id]));
    expect(pm[1]!.id).toMatch(/^msg_c/); // an agent's reply id is the API message's (its transcript's)
    expect(t.hub.chat.recent(10).some((m) => m.text === "收到：你好" && m.pal)).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("starting: the assistant's words go into its process at once, before it says it's up; an agent's wait until its process is ready", async () => {
    const t = both();
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const startMain = t.driver.startMain.bind(t.driver);
    t.driver.startMain = (opts) => {
      const s = startMain(opts);
      s.ready = () => gate;
      return s;
    };
    t.hub.userMessage("先说", "app");
    expect(t.driver.last!.sent).toEqual(["先说"]); // synchronously, no ready() awaited
    const startPal = t.driver.startPal.bind(t.driver);
    t.driver.startPal = (opts) => {
      const s = startPal(opts);
      s.ready = () => gate;
      return s;
    };
    const { pal } = await t.call("pals.create", { cwd: t.project, text: "后说" });
    await tick(50);
    expect(t.driver.pals.at(-1)!.sent).toEqual([]);
    expect(t.statusOf(pal.id)).toBe("starting");
    release();
    await waitFor(() => t.driver.pals.at(-1)!.sent.length === 1);
    expect(t.driver.pals.at(-1)!.sent).toEqual(["后说"]);
    await t.hub.idle();
    await t.hub.pals.stopAndWait();
  });
});

describe("host-initiated turns (assistant only)", () => {
  test("a proactive turn waits for the owner's turn to end, then runs; its words are a proactive message and a push; an agent has no queue: the assistant's words to it go in as they come", async () => {
    let hold!: () => void;
    const holding = new Promise<void>((r) => (hold = r));
    const t = both({
      script: async (text, ctx) => {
        if (text === "慢慢来") await holding;
        ctx.emit({ type: "assistant_text", text: text.startsWith("[定时]") ? "该交房租了。" : `收到：${text}`, parentToolUseId: null });
      },
    });
    t.hub.userMessage("慢慢来", "app");
    t.hub.conversation.enqueue({ text: "[定时] 提醒", origin: "schedule", proactive: true, label: "提醒" });
    await tick(20);
    expect(t.driver.last!.sent).toEqual(["慢慢来"]);
    hold();
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["慢慢来", "[定时] 提醒"]);
    const pushed = t.hub.chat.recent(5).find((m) => m.text === "该交房租了。")!;
    expect(pushed).toMatchObject({ proactive: true, channel: "schedule" });
    expect(t.pusher.pushes.some((p) => p.body.includes("房租"))).toBe(true);
    // [skip] stays silent
    t.driver.script = async (_t, ctx) => ctx.emit({ type: "assistant_text", text: "[skip]", parentToolUseId: null });
    const before = t.hub.chat.lastSeq;
    t.hub.conversation.enqueue({ text: "[定时] 再看看", origin: "schedule", proactive: true });
    await t.hub.idle();
    expect(t.hub.chat.since(before)).toEqual([]);
    // an agent: the assistant's words go straight in, as another session's
    const pal = await t.agent();
    expect(await t.hub.pals.toolSend({ name: pal.name, text: "看下测试" })).toBeTruthy();
    await waitFor(() => t.driver.pals.at(-1)!.sent.length === 1);
    expect(t.driver.pals.at(-1)!.sent[0]).toContain("看下测试");
    expect(t.driver.pals.at(-1)!.sent[0]).toMatch(/^<cross-session-message from="/);
    await t.hub.pals.stopAndWait();
  });

  test("an Ally's turn (assistant only): the owner's words wait for it to end, then go in as a turn of their own", async () => {
    let hold!: () => void;
    const holding = new Promise<void>((r) => (hold = r));
    const t = both({
      script: async (text, ctx) => {
        if (text.startsWith("[好友]")) await holding;
        ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null });
      },
    });
    t.hub.conversation.enqueue({ text: "[好友] 周六有空吗", origin: "system", proactive: true, allyId: "ally_test" });
    await tick(10);
    expect(t.hub.conversation.allyTurnAlly()).toBe("ally_test");
    t.hub.userMessage("我在", "app");
    await tick(10);
    expect(t.driver.last!.sent).toEqual(["[好友] 周六有空吗"]);
    expect(t.hub.audit.tail(10).some((e) => e.type === "ally.turn.held")).toBe(true);
    hold();
    await t.hub.idle();
    expect(t.driver.last!.sent).toEqual(["[好友] 周六有空吗", "我在"]);
    expect(t.hub.conversation.allyTurnAlly()).toBeUndefined();
    expect(t.hub.chat.recent(5).find((m) => m.text === "收到：我在")).toMatchObject({ role: "assistant" });
  });
});

describe("what waits on the owner", () => {
  const question = { questions: [{ question: "方案选哪个？", header: "方案", options: [{ label: "A" }, { label: "B" }], multiSelect: false }] };
  const asking: FakeScript = async (text, ctx) => {
    if (text.includes("问")) await ctx.useTool("AskUserQuestion", question, { ask: true });
    else if (text.includes("跑")) await ctx.useTool("Bash", { command: "npm run build" }, { ask: true });
    ctx.emit({ type: "assistant_text", text: "好", parentToolUseId: null });
  };

  test("a question: the assistant's goes to 等你 and its tool is answered at once; an agent's is a blocking card with it as source, and the answer reaches it", async () => {
    const t = both({ script: asking, palScript: asking });
    t.hub.userMessage("问一下", "app");
    await t.hub.idle();
    expect(t.hub.questions.listPending()).toEqual([]);
    const item = t.hub.pending.open().find((i) => i.title === "方案选哪个？")!;
    expect(item).toMatchObject({ blocking: false, source: { kind: "palo" } });
    expect(t.driver.decisions.find((d) => d.tool === "AskUserQuestion")!.decision.behavior).toBe("deny");

    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "问一下" });
    await waitFor(() => t.hub.questions.listPending().length === 1);
    const q = t.hub.questions.listPending()[0]!;
    expect(q.source).toMatchObject({ kind: "pal", id: pal.id });
    expect(t.statusOf(pal.id)).toBe("waiting");
    expect(t.hub.pending.open().some((i) => i.blocking && i.source.kind === "pal")).toBe(true);
    await t.call("question.answer", { id: q.id, answers: { "方案选哪个？": "B" } });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    const d = t.driver.decisions.filter((x) => x.tool === "AskUserQuestion").at(-1)!.decision;
    expect(d.behavior === "allow" && d.updatedInput!.answers).toEqual({ "方案选哪个？": "B" });
    await t.hub.pals.stopAndWait();
  });

  test("a permission prompt: a card for both, the assistant's without a source, an agent's with it; allowed, the tool runs", async () => {
    const t = both({ script: asking, palScript: asking });
    t.hub.userMessage("跑一下", "app");
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    const mine = t.hub.approvals.listPending()[0]!;
    expect(mine.source).toBeUndefined();
    expect(mine.tool).toBe("Bash");
    await t.call("approval.answer", { id: mine.id, allow: true });
    await t.hub.idle();
    expect(t.driver.ran).toContain("Bash");

    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "跑一下" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    const theirs = t.hub.approvals.listPending()[0]!;
    expect(theirs.source).toMatchObject({ kind: "pal", id: pal.id });
    expect(t.statusOf(pal.id)).toBe("waiting");
    await t.call("approval.answer", { id: theirs.id, allow: true });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.driver.ran.filter((n) => n === "Bash")).toHaveLength(2);
    await t.hub.pals.stopAndWait();
  });
});

describe("the process", () => {
  test("sleep: an agent sleeps and wakes on the next words in the same session; the assistant has no sleep and its status never says asleep", async () => {
    const t = both();
    const pal = await t.agent("醒着");
    await t.hub.pals.get(pal.id)!.sleep();
    expect(t.statusOf(pal.id)).toBe("asleep");
    expect(t.driver.pals.at(-1)!.closed).toBe(true);
    await t.call("pals.send", { id: pal.id, text: "起来" });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    const woke = t.driver.pals.at(-1)!;
    expect(woke.sent).toEqual(["起来"]);
    expect(woke.opts.resumeSessionId ?? woke.opts.sessionId).toBe(pal.sessionId);
    t.hub.userMessage("你也睡吗", "app");
    await t.hub.idle();
    expect(t.hub.status()).toMatchObject({ online: true, busy: false });
    expect(t.driver.sessions).toHaveLength(1);
    await t.hub.pals.stopAndWait();
  });

  test("died: an agent comes back by itself on the same session; the assistant's next words start a new process resuming its session", async () => {
    const t = both();
    t.hub.userMessage("一", "app");
    await t.hub.idle();
    const sid = t.hub.status().sessionId!;
    t.driver.last!.crash();
    await tick(20);
    expect(t.driver.sessions).toHaveLength(1); // nothing restarts it by itself
    t.hub.userMessage("二", "app");
    await t.hub.idle();
    expect(t.driver.sessions).toHaveLength(2);
    expect(t.driver.last!.opts.resumeSessionId).toBe(sid);
    expect(t.driver.last!.sent).toEqual(["二"]);

    const pal = await t.agent("一");
    const n = t.driver.pals.length;
    t.driver.pals.at(-1)!.crash();
    await waitFor(() => t.driver.pals.length === n + 1 && t.statusOf(pal.id) === "idle", 3_000);
    expect(t.driver.pals.at(-1)!.opts.resumeSessionId ?? t.driver.pals.at(-1)!.opts.sessionId).toBe(pal.sessionId);
    await t.hub.pals.stopAndWait();
  });

  test("stop: both end the turn at once, open cards are answered no, and the next words work as usual", async () => {
    const hanging: FakeScript = async (text, ctx) => {
      if (text === "卡住") {
        await ctx.useTool("Bash", { command: "sleep 999" }, { ask: true });
        await ctx.interrupted;
        return;
      }
      ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null });
    };
    const t = both({ script: hanging, palScript: hanging });
    t.hub.userMessage("卡住", "app");
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    expect(t.hub.status().busy).toBe(true);
    t.hub.userMessage("/stop", "app");
    await t.hub.idle();
    expect(t.hub.approvals.listPending()).toEqual([]);
    expect(t.hub.status().busy).toBe(false);
    t.hub.userMessage("在吗", "app");
    await t.hub.idle();
    expect(t.hub.chat.recent(1)[0]!.text).toBe("收到：在吗");

    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "卡住" });
    await waitFor(() => t.hub.approvals.listPending().length === 1);
    expect(await t.call("pals.stop", { id: pal.id })).toEqual({ ok: true });
    await waitFor(() => t.statusOf(pal.id) === "idle", 2_000);
    expect(t.hub.approvals.listPending()).toEqual([]);
    await t.call("pals.send", { id: pal.id, text: "在吗" });
    await waitFor(() => t.palEvents("chat.message", pal.id).some((m) => m.text === "收到：在吗"));
    await t.hub.pals.stopAndWait();
  });

  test("model and effort: switched live on a running one, kept for its next start", async () => {
    const t = both();
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    await t.call("model.set", { model: "default", effort: "low" });
    expect(t.driver.liveSwitches).toEqual(["model:default", "effort:low"]);
    expect(t.hub.status()).toMatchObject({ effort: "low" });
    const pal = await t.agent();
    await t.call("pals.setModel", { id: pal.id, model: "default", effort: "high" });
    expect(t.driver.liveSwitches.slice(2)).toEqual(["model:default", "effort:high"]);
    const detail = await t.call("pals.detail", { id: pal.id });
    expect(detail).toMatchObject({ effort: "high" });
    expect(detail.permissionModes).toEqual(["default", "auto", "acceptEdits", "plan"]);
    expect(detail.efforts ?? detail.models?.[0]?.efforts).toBeTruthy();
    await t.hub.pals.stopAndWait();
  });
});

describe("回到这里重来", () => {
  const userE = (uuid: string, parentUuid: string | null, text: string, s: number) => ({ type: "user", uuid, parentUuid, timestamp: at(s), message: { role: "user", content: text }, origin: { kind: "human" } });
  const replyE = (uuid: string, parentUuid: string, text: string, s: number, id: string) => ({ type: "assistant", uuid, parentUuid, timestamp: at(s), message: { id, role: "assistant", model: "claude-haiku-4-5", content: [{ type: "text", text }] } });

  test("both drop the message and what came after (chat.rewound names them), give its words back, and fork the next process from the entry before it", async () => {
    const t = both();
    const msgs: ChatMessage[] = [];
    for (const text of ["第一句", "第二句"]) {
      msgs.push(t.hub.userMessage(text, "app")!);
      await t.hub.idle();
    }
    const sid = t.hub.status().sessionId!;
    t.claude.transcript(t.paths.home, sid, [userE(msgs[0]!.uuid!, null, "第一句", 0), replyE("a0", msgs[0]!.uuid!, "收到", 1, "m0"), userE(msgs[1]!.uuid!, "a0", "第二句", 10), replyE("a1", msgs[1]!.uuid!, "收到", 11, "m1")]);
    const shown = t.hub.chat.since(0).map((m) => m.id);
    expect(await t.call("chat.rewind", { messageId: msgs[1]!.id })).toEqual({ text: "第二句" });
    const ev = t.mainEvents("chat.rewound")[0]!;
    expect(ev).toEqual({ id: msgs[1]!.id, ids: shown.slice(shown.indexOf(msgs[1]!.id)) });
    t.hub.userMessage("第二句（改）", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts).toMatchObject({ fork: { fromSessionId: sid, at: "a0" } });

    // an agent, adopted from a background session with that conversation
    const psid = "dddd4444-0000-4000-8000-000000000001";
    t.cli.bg({ sessionId: psid, name: "网站", cwd: t.project });
    t.claude.transcript(t.project, psid, [userE("p1", null, "先建 note.txt", 0), replyE("r1", "p1", "建好了", 1, "msg_r1"), userE("p2", "r1", "改成 two", 10), replyE("r2", "p2", "改好了", 11, "msg_r2")]);
    const { pal } = await t.call("pals.adopt", { sessionId: psid });
    expect(await t.call("pals.rewind", { id: pal.id, messageId: "p2" })).toEqual({ text: "改成 two", filesRestored: false });
    expect(t.palEvents("chat.rewound", pal.id)[0]).toEqual({ id: "p2", ids: ["p2", "msg_r2"], pal: pal.id });
    await waitFor(() => t.statusOf(pal.id) === "idle");
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ fork: { fromSessionId: psid, at: "r1" } });
    await t.hub.pals.stopAndWait();
  });
});

describe("golden transcripts", () => {
  const dir = join(import.meta.dir, "fixtures", "transcripts");
  const names = readdirSync(dir).filter((f) => f.endsWith(".jsonl")).sort();
  const recall = (uuid: string) => (uuid === "u2" ? { text: "看这张", attachments: [{ kind: "image" as const, id: "img_1", name: "a.png", mediaType: "image/png", size: 8 }] } : uuid === "toolu_2" ? { text: "报告", attachments: [] } : undefined);

  test("the fixtures are all there", () => {
    expect(names).toEqual(["compaction.jsonl", "fork.jsonl", "images.jsonl", "peer.jsonl", "plain.jsonl", "sidechain.jsonl", "tool-results.jsonl"]);
  });

  for (const name of names) {
    test(`${name}: an agent's page, the conversation's chain and the owner's entry found by words`, () => {
      const entries = readTranscript(join(dir, name));
      expect(entries.length).toBe(readFileSync(join(dir, name), "utf8").trim().split("\n").length);
      const page = toPalMessages(entries, { pal: "pal_x", assistantName: "Palo", paloName: "paloally", duty: name === "plain.jsonl" ? "帮我看看 README" : undefined, recall: name === "images.jsonl" || name === "tool-results.jsonl" ? recall : undefined });
      const leaf = leafOf(entries);
      const chain = chainTo(entries, leaf).map((e) => e.uuid);
      const owner = entries.filter((e) => e.type === "user" && e.origin?.kind === "human" && typeof e.message?.content === "string");
      const matched = owner.map((e) => matchOwnerEntry(entries, e.message.content, Date.parse(e.timestamp))?.uuid ?? null);
      expect({ page, leaf, chain, matched }).toMatchSnapshot();
    });
  }
});
