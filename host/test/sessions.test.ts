import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { TRUST_LINE } from "../src/ccHooks.ts";
import { pageMessages, toCCMessages } from "../src/ccSessions.ts";
import type { Courier } from "../src/courier.ts";
import { handleRpc } from "../src/rpc.ts";
import type { SessionsDeps } from "../src/sessions.ts";
import { DEAD_PID, FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, tick } from "./helpers.ts";

const dirs: FakeClaudeDir[] = [];
afterAll(() => dirs.forEach((d) => d.cleanup()));

class FakeCourier {
  sent: { to: string; label: string; message: string; mode: string }[] = [];
  fail = "";
  async send(o: { to: string; label: string; message: string; mode: string }) {
    if (this.fail) throw new Error(this.fail);
    this.sent.push(o);
    return { msgId: "m1", costUsd: 0.01 };
  }
  close() {}
}

function setup(o: { away?: boolean; sessions?: Partial<SessionsDeps> } = {}) {
  const claude = new FakeClaudeDir();
  dirs.push(claude);
  const cli = new FakeCli(claude);
  const courier = new FakeCourier();
  let away = o.away ?? true;
  const raw = new Map<string, any[]>();
  const ctx = makeHub({
    sessions: {
      claudeDir: claude.dir,
      cli,
      courier: courier as unknown as Courier,
      away: new AwayDetector(() => null, Date.now, () => away),
      readMessages: async (sid) => raw.get(sid) ?? [],
      hookWaitMs: 5_000,
      ...o.sessions,
    },
  });
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-project-")));
  const signal = () => new AbortController();
  return {
    ...ctx,
    claude,
    cli,
    courier,
    raw,
    project,
    setAway: (v: boolean) => (away = v),
    hook: (event: string, payload: Record<string, unknown>, ac = signal(), env: { jobDir?: string } = {}) =>
      ctx.hub.sessions.onHook(event, { hook_event_name: event, ...payload }, { signal: ac.signal, env }),
  };
}

const sessionsEvents = (events: { event: string; data: any }[]) => events.filter((e) => e.event === "sessions.updated").map((e) => e.data.sessions);

describe("the computer's sessions", () => {
  test("the list: terminal and background sessions with their state; PaloAlly's own and ended ones left out", async () => {
    const t = setup();
    const { hub, claude, cli, paths, events } = t;
    claude.register({ sessionId: "aaaa1111-1", name: "修登录", cwd: "/w/app", status: "busy" });
    claude.register({ sessionId: "bbbb2222-1", name: "数据清洗", cwd: "/w/data", kind: "bg", status: "waiting", waitingFor: "permission" });
    claude.register({ sessionId: "cccc3333-1", name: "home-1b", cwd: paths.home, entrypoint: "sdk-ts" }); // the assistant
    claude.register({ sessionId: "dddd4444-1", name: "PaloAlly", cwd: paths.courier, entrypoint: "sdk-ts" }); // the courier
    claude.register({ sessionId: "eeee5555-1", name: "旧的", cwd: "/w/old", pid: DEAD_PID }); // its process is gone
    // background sessions Claude Code knows but that aren't running
    cli.agentsList = [
      { id: "ffff6666", cwd: "/w/site", kind: "background", sessionId: "ffff6666-1", name: "网站", startedAt: Date.now() - 3600_000 },
      { id: "99990000", cwd: "/w/ancient", kind: "background", sessionId: "99990000-1", name: "很久以前", startedAt: Date.now() - 30 * 86400_000 },
    ];
    claude.transcript("/w/app", "aaaa1111-1", [assistantEntry("先看一下登录跳转。\n第二行"), assistantEntry("在跑登录相关的测试。", { usage: { input_tokens: 5, cache_read_input_tokens: 95_000, cache_creation_input_tokens: 0, output_tokens: 9 } })]);
    const list = await hub.sessions.listFresh();
    expect(list.map((s) => [s.name, s.kind, s.status])).toEqual(
      expect.arrayContaining([
        ["修登录", "terminal", "busy"],
        ["数据清洗", "background", "waiting"],
        ["网站", "background", "stopped"],
      ]),
    );
    expect(list).toHaveLength(3);
    const login = list.find((s) => s.name === "修登录")!;
    expect(login).toMatchObject({ id: "aaaa1111-1", cwd: "/w/app", lastLine: "在跑登录相关的测试。", contextTokens: 95_005 });
    expect(list.find((s) => s.name === "数据清洗")!.waitingFor).toBe("permission");
    expect(sessionsEvents(events).at(-1)).toEqual(list);
    // the main session by id, wherever it runs
    hub["runtime"].update({ sessionId: "aaaa1111-1" });
    await hub.sessions.watch.refresh();
    expect(hub.sessions.list().map((s) => s.name)).not.toContain("修登录");
  });

  test("hook events come first: the last words from Stop, waiting from a prompt, gone at SessionEnd", async () => {
    const { hub, claude, hook } = setup({ away: false });
    claude.register({ sessionId: "s1", name: "写文档", cwd: "/w/docs", status: "busy", at: Date.now() - 60_000 });
    await hub.sessions.watch.refresh();
    expect(hub.sessions.list()[0]!.status).toBe("busy");
    await hook("Stop", { session_id: "s1", cwd: "/w/docs", last_assistant_message: "**写好了**，在 docs/intro.md。\n细节如下" });
    expect(hub.sessions.list()[0]).toMatchObject({ status: "idle", lastLine: "写好了，在 docs/intro.md。" });
    expect(await hook("PermissionRequest", { session_id: "s1", cwd: "/w/docs", tool_name: "Bash", tool_input: { command: "rm -rf build" } })).toBeNull();
    expect(hub.sessions.list()[0]).toMatchObject({ status: "waiting", waitingFor: "想运行 rm -rf build" });
    await hook("SessionEnd", { session_id: "s1", reason: "prompt_input_exit" });
    expect(hub.sessions.list()).toHaveLength(0);
    // a background session that says SessionStart with its job folder
    await hook("SessionStart", { session_id: "abcd1234-x", cwd: "/w/bg", source: "resume", context_tokens: 46_941, session_title: "后台的" }, undefined, { jobDir: "/u/.claude/jobs/abcd1234" });
    expect(hub.sessions.list()[0]).toMatchObject({ name: "后台的", kind: "background", status: "idle", contextTokens: 46_941 });
  });

  test("the SessionStart hook's line says how to take PaloAlly's words", () => {
    expect(TRUST_LINE).toContain("名叫 PaloAlly 的会话");
    expect(TRUST_LINE).toContain("「主人：」");
  });

  test("a conversation: the owner, the session, other sessions, and words through PaloAlly; pages by message id", () => {
    const raw = [
      { type: "user", uuid: "1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "列表要能按日期排序" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "2", timestamp: "2026-10-12T10:00:05Z", message: { role: "assistant", content: [{ type: "thinking", thinking: "" }] } },
      { type: "assistant", uuid: "3", timestamp: "2026-10-12T10:00:06Z", message: { role: "assistant", content: [{ type: "text", text: "加上了。" }] } },
      { type: "user", uuid: "4", timestamp: "2026-10-12T10:00:07Z", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t", content: "ok" }] } },
      {
        type: "user",
        uuid: "5",
        timestamp: "2026-10-12T10:01:00Z",
        message: { role: "user", content: 'Another Claude session sent a message:\n<cross-session-message from="uds:/tmp/x.sock" from-name="笔记整理" from-mode="prompting">\n设计稿在 notes/设计.md\n</cross-session-message>\n\nThis came from another Claude session' },
        origin: { kind: "peer", name: "笔记整理" },
      },
      { type: "user", uuid: "6", timestamp: "2026-10-12T10:02:00Z", message: { role: "user", content: "…" }, origin: { kind: "peer", name: "PaloAlly", body: "主人：先别管登录页，把列表页做完" } },
      { type: "user", uuid: "7", timestamp: "2026-10-12T10:03:00Z", message: { role: "user", content: "…" }, origin: { kind: "peer", name: "PaloAlly", body: "主人的助理：主人说今晚不用部署" } },
      { type: "user", uuid: "8", timestamp: "2026-10-12T10:04:00Z", message: { role: "user", content: "<command-name>/compact</command-name>\n<command-args></command-args>" }, origin: { kind: "human" } },
      { type: "user", uuid: "9", timestamp: "2026-10-12T10:04:01Z", message: { role: "user", content: "<local-command-stdout>Compacted</local-command-stdout>" } },
      { type: "user", uuid: "10", timestamp: "2026-10-12T10:05:00Z", message: { role: "user", content: "后台任务完成" }, origin: { kind: "task-notification" } },
    ];
    const msgs = toCCMessages(raw as any, "Palo");
    expect(msgs.map((m) => [m.id, m.role, m.text, m.from])).toEqual([
      ["1", "owner", "列表要能按日期排序", undefined],
      ["3", "assistant", "加上了。", undefined],
      ["5", "peer", "设计稿在 notes/设计.md", "笔记整理"],
      ["6", "palo", "先别管登录页，把列表页做完", "主人"],
      ["7", "palo", "主人说今晚不用部署", "Palo"],
      ["8", "owner", "/compact", undefined],
    ]);
    expect(msgs[0]!.ts).toBe(Date.parse("2026-10-12T10:00:00Z"));
    expect(pageMessages(msgs, undefined, 2).map((m) => m.id)).toEqual(["7", "8"]);
    expect(pageMessages(msgs, "7", 2).map((m) => m.id)).toEqual(["5", "6"]);
    expect(pageMessages(msgs, "1", 2)).toEqual([]);
  });

  test("sessions.history reads the session's own transcript through the SDK, by its folder", async () => {
    const { hub, claude, raw } = setup();
    claude.register({ sessionId: "s1", name: "写文档", cwd: "/w/docs" });
    await hub.sessions.watch.refresh();
    raw.set("s1", [{ type: "user", uuid: "u1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "写一下" }, origin: { kind: "human" } }]);
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    expect((await handleRpc(hub, { method: "sessions.history", params: { id: "s1", limit: 10 } }, ctx)) as any).toEqual({
      messages: [{ id: "u1", ts: Date.parse("2026-10-12T10:00:00Z"), role: "owner", text: "写一下" }],
    });
    await expect(handleRpc(hub, { method: "sessions.history", params: { id: "nope" } }, ctx)).rejects.toThrow("没有这个会话");
  });
});

describe("a session's prompts on the phone", () => {
  const bash = { session_id: "s1", cwd: "/w/site", tool_name: "Bash", tool_input: { command: "npm run build && npm test -- --coverage" } };

  test("at the computer: nothing reaches the phone and the terminal asks as usual", async () => {
    const { hub, hook, pusher } = setup({ away: false });
    expect(await hook("PermissionRequest", bash)).toBeNull();
    expect(hub.approvals.list()).toHaveLength(0);
    expect(pusher.pushes).toHaveLength(0);
  });

  test("away: a card from the session, the owner allows on the phone, the hook gets Claude Code's allow; audited with the device", async () => {
    const { hub, claude, hook, pusher } = setup();
    claude.register({ sessionId: "s1", name: "网站帮手", cwd: "/w/site", status: "busy" });
    await hub.sessions.watch.refresh();
    const out = hook("PermissionRequest", bash);
    await tick(5);
    const card = hub.approvals.listPending()[0]!;
    expect(card).toMatchObject({ tool: "Bash", title: "在电脑上运行一条命令", detail: bash.tool_input.command, source: { kind: "session", id: "s1", name: "网站帮手" } });
    expect(card.suggestedScope).toBeUndefined();
    expect(hub.sessions.list()[0]).toMatchObject({ status: "waiting" });
    // no chat card: it waits at the conversation's end in the app
    expect(hub.chat.recent(5).some((m) => m.approvalId === card.id)).toBe(false);
    expect(pusher.pushes).toEqual([expect.objectContaining({ title: "网站帮手 在等你", body: "想运行：npm run build && npm test -- --coverage" })]);
    await handleRpc(hub, { method: "approval.answer", params: { id: card.id, allow: true } }, { clientId: "c", deviceId: "dev-test", channel: "app", local: false });
    expect(await out).toEqual({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });
    expect(hub.sessions.list()[0]!.status).toBe("busy");
    const audit = hub.audit.tail(20).find((e) => e.type === "approval.decided")!;
    expect(audit).toMatchObject({ status: "allowed", by: "app", device: "dev-test", session: "s1", sessionName: "网站帮手" });
  });

  test("denied on the phone: Claude Code's deny with a reason", async () => {
    const { hub, hook } = setup();
    const out = hook("PermissionRequest", bash);
    await tick(5);
    hub.approvals.answer(hub.approvals.listPending()[0]!.id, false, "app");
    expect(await out).toEqual({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "deny", message: "主人在手机上拒绝了" } } });
  });

  test("no answer in time: the hook prints nothing (the terminal keeps asking) and the card says 在电脑上等你", async () => {
    const { hub, hook } = setup({ sessions: { hookWaitMs: 50 } });
    const out = await hook("PermissionRequest", bash);
    expect(out).toBeNull();
    expect(hub.approvals.list()[0]).toMatchObject({ status: "expired", note: "在电脑上等你" });
    expect(hub.sessions.list()[0]).toMatchObject({ status: "waiting" });
  });

  test("answered at the computer meanwhile: the hook is killed, or the session goes on — the card goes", async () => {
    const { hub, claude, hook } = setup();
    // the hook went away (Claude Code kills it when the terminal's prompt is answered)
    const ac = new AbortController();
    const a = hook("PermissionRequest", bash, ac);
    await tick(5);
    ac.abort();
    expect(await a).toBeNull();
    expect(hub.approvals.list()[0]).toMatchObject({ status: "expired", note: "已在电脑上处理", decidedBy: "computer" });
    expect(hub.sessions.list()[0]!.status).toBe("busy");
    // it went on: PostToolUse / Stop
    const b = hook("PermissionRequest", bash);
    await tick(5);
    await hook("Stop", { session_id: "s1", last_assistant_message: "好了" });
    expect(await b).toBeNull();
    expect(hub.approvals.list()[0]).toMatchObject({ status: "expired", note: "已在电脑上处理" });
    // the registry: waiting, then not any more
    claude.register({ sessionId: "s1", name: "网站帮手", cwd: "/w/site", status: "busy" });
    await hub.sessions.watch.refresh();
    const c = hook("PermissionRequest", bash);
    await tick(5);
    claude.register({ sessionId: "s1", name: "网站帮手", cwd: "/w/site", status: "waiting" });
    await hub.sessions.watch.refresh();
    expect(hub.approvals.listPending()).toHaveLength(1);
    claude.register({ sessionId: "s1", name: "网站帮手", cwd: "/w/site", status: "busy" });
    await hub.sessions.watch.refresh();
    expect(await c).toBeNull();
    expect(hub.approvals.listPending()).toHaveLength(0);
  });

  test("a question (AskUserQuestion) answered on the phone goes back as the tool's input with the answers", async () => {
    const { hub, hook, pusher } = setup();
    const questions = [{ question: "方案选哪个？", header: "方案", options: [{ label: "A", description: "快" }, { label: "B", description: "稳" }], multiSelect: false }];
    const out = hook("PermissionRequest", { session_id: "s2", cwd: "/w/x", tool_name: "AskUserQuestion", tool_input: { questions } });
    await tick(5);
    const q = hub.questions.listPending()[0]!;
    expect(q.source).toEqual({ kind: "session", id: "s2", name: "x" });
    expect(pusher.pushes.at(-1)).toMatchObject({ title: "x 在等你", body: "问你：方案选哪个？" });
    await handleRpc(hub, { method: "question.answer", params: { id: q.id, answers: { "方案选哪个？": "B" } } }, { clientId: "c", deviceId: "dev-test", channel: "app", local: false });
    expect(await out).toEqual({
      hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow", updatedInput: { questions, answers: { "方案选哪个？": "B" } } } },
    });
    expect(hub.audit.tail(20).find((e) => e.type === "question.answered")).toMatchObject({ device: "dev-test", session: "s2" });
  });

  test("「X 在等你」 at most once per session in 10 minutes; the stop button leaves sessions' cards alone", async () => {
    const { hub, hook, pusher } = setup();
    const a = hook("PermissionRequest", bash);
    const b = hook("PermissionRequest", { ...bash, tool_input: { command: "ls" } });
    const c = hook("PermissionRequest", { ...bash, session_id: "s9", cwd: "/w/other" });
    await tick(5);
    expect(pusher.pushes.map((p) => p.title)).toEqual(["site 在等你", "other 在等你"]);
    hub.stopAll("app");
    expect(hub.approvals.listPending()).toHaveLength(3);
    for (const x of hub.approvals.listPending()) hub.approvals.answer(x.id, true, "app");
    await Promise.all([a, b, c]);
  });
});

describe("words into a session", () => {
  test("sent verbatim through the courier, with 主人： in front, to the session's own socket", async () => {
    const { hub, claude, courier, events } = setup();
    claude.register({ sessionId: "s1", name: "网站帮手", cwd: "/w/site" });
    await hub.sessions.watch.refresh();
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    expect(await handleRpc(hub, { method: "sessions.send", params: { id: "s1", text: "  先别管登录页，把列表页做完 " } }, ctx)).toEqual({ ok: true });
    expect(courier.sent).toEqual([{ to: "uds:/tmp/cc-socks/s1.sock", label: "网站帮手", message: "主人：先别管登录页，把列表页做完", mode: "prompting" }]);
    expect(hub.audit.tail(5).find((e) => e.type === "session.send")).toMatchObject({ session: "s1", by: "owner" });
    // then the list is sent again so the app reads the conversation
    const before = sessionsEvents(events).length;
    await tick(900);
    expect(sessionsEvents(events).length).toBeGreaterThan(before);
    // the assistant's words say they're the assistant's
    expect(await hub.toolHandlers().session_send({ name: "网站帮手", text: "主人说今晚不用部署" })).toContain("已原样送到");
    expect(courier.sent.at(-1)!.message).toBe("主人的助理：主人说今晚不用部署");
    // a bypass-mode session gets a courier of its class
    await hub.sessions.onHook("Stop", { session_id: "s1", permission_mode: "bypassPermissions" }, { signal: new AbortController().signal, env: {} });
    await hub.sessions.send("s1", "hi", "owner");
    expect(courier.sent.at(-1)!.mode).toBe("bypass");
    // a session that isn't there, or isn't running
    await expect(handleRpc(hub, { method: "sessions.send", params: { id: "nope", text: "hi" } }, ctx)).rejects.toThrow("没有这个会话");
    claude.unregister("s1");
    await hub.sessions.watch.refresh();
    expect(hub.sessions.list()).toHaveLength(0);
  });
});

describe("helpers", () => {
  test("proposed in the conversation; 开吧 starts a background session in its folder; the list shows it first", async () => {
    const { hub, cli, project, events, raw } = setup();
    const r = await hub.toolHandlers().helper_propose({ name: "网站帮手", dir: project, duty: "你负责网站：先做列表页。", dailyUsd: 5 });
    expect(r).toContain("主人点「开吧」才会开");
    const card = hub.chat.recent(1)[0]!;
    expect(card).toMatchObject({ kind: "helper", proposal: { name: "网站帮手", cwd: project, duty: "你负责网站：先做列表页。", dailyUsd: 5, status: "pending" } });
    expect(cli.started).toHaveLength(0);
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    const out = (await handleRpc(hub, { method: "helper.decide", params: { proposalId: card.proposal!.id, action: "create" } }, ctx)) as any;
    expect(cli.started).toEqual([{ cwd: project, name: "网站帮手", permissionMode: "default", prompt: "你负责网站：先做列表页。" }]);
    expect(out.session).toMatchObject({ name: "网站帮手", cwd: project, kind: "helper", status: "busy" });
    const saved = JSON.parse(readFileSync(hub.paths.helpers, "utf8"));
    expect(saved.helpers[0]).toMatchObject({ name: "网站帮手", cwd: project, dailyUsd: 5, sessionId: out.session.id, short: out.session.id.slice(0, 8), state: "active" });
    expect(Object.keys(saved.helpers[0])).toEqual(expect.arrayContaining(["createdAt"]));
    // the card shows it was started (the same message, sent again)
    const again = events.filter((e) => e.event === "chat.message" && e.data.id === card.id).at(-1)!.data;
    expect(again).toMatchObject({ seq: card.seq, proposal: { status: "created", sessionId: out.session.id } });
    expect(hub.chat.get(card.id)!.proposal!.status).toBe("created");
    // deciding twice gives the same helper
    expect(((await handleRpc(hub, { method: "helper.decide", params: { proposalId: card.proposal!.id, action: "create" } }, ctx)) as any).session.id).toBe(out.session.id);
    expect(cli.started).toHaveLength(1);
    // its handover, typed in for it, shows as the assistant's words
    raw.set(out.session.id, [
      { type: "user", uuid: "h1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "你负责网站：先做列表页。" }, origin: { kind: "human" } },
      { type: "user", uuid: "h2", timestamp: "2026-10-12T10:05:00Z", message: { role: "user", content: "你负责网站：先做列表页。" }, origin: { kind: "human" } },
    ]);
    expect((await hub.sessions.history(out.session.id)).map((m) => [m.role, m.from])).toEqual([
      ["palo", "Palo"],
      ["owner", undefined],
    ]);
  });

  test("不用 drops it; at most three helpers; a folder that isn't there is refused", async () => {
    const { hub, project, cli } = setup();
    const tools = hub.toolHandlers();
    await tools.helper_propose({ name: "一", dir: project, duty: "做事", dailyUsd: 1 });
    const p1 = hub.chat.recent(1)[0]!.proposal!;
    await hub.sessions.decide(p1.id, "discard", "app");
    expect(hub.chat.get(hub.chat.recent(1)[0]!.id)!.proposal!.status).toBe("discarded");
    expect(cli.started).toHaveLength(0);
    expect(await tools.helper_propose({ name: "二", dir: "/no/such/folder", duty: "做事", dailyUsd: 1 })).toContain("找不到目录");
    for (const n of ["A", "B", "C"]) {
      await tools.helper_propose({ name: n, dir: project, duty: "做事", dailyUsd: 1 });
      await hub.sessions.decide(hub.chat.recent(1)[0]!.proposal!.id, "create", "app");
    }
    expect(await tools.helper_propose({ name: "D", dir: project, duty: "做事", dailyUsd: 1 })).toContain("已经有 3 个帮手");
    expect(hub.sessions.list().filter((s) => s.kind === "helper")).toHaveLength(3);
  });

  test("停止 / 重启 / 删除 / 复活 go to Claude Code; only for helpers", async () => {
    const { hub, cli, claude, project } = setup();
    await hub.toolHandlers().helper_propose({ name: "网站帮手", dir: project, duty: "做网站", dailyUsd: 5 });
    const { session } = await hub.sessions.decide(hub.chat.recent(1)[0]!.proposal!.id, "create", "app");
    const id = session!.id;
    const short = id.slice(0, 8);
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    const control = (action: string) => handleRpc(hub, { method: "sessions.control", params: { id, action } }, ctx);
    await control("stop");
    expect(hub.sessions.list()[0]!.status).toBe("stopped");
    await control("restart"); // stopped: comes back from its transcript
    expect(hub.sessions.list()[0]!.status).not.toBe("stopped");
    await control("restart"); // running: respawned, same session
    await control("remove");
    expect(hub.sessions.list()[0]).toMatchObject({ id, kind: "helper", status: "stopped" });
    await control("revive");
    expect(cli.calls).toEqual([`startBg 网站帮手`, `stop ${short}`, `resumeBg ${short}`, `respawn ${short}`, `rm ${short}`, `resumeBg ${short}`]);
    expect(hub.sessions.list()[0]!.status).not.toBe("stopped");
    expect(hub.audit.tail(30).filter((e) => e.type === "helper.control").map((e) => e.action)).toEqual(["stop", "restart", "restart", "remove", "revive"]);
    claude.register({ sessionId: "t1", name: "终端的", cwd: "/w/t" });
    await hub.sessions.watch.refresh();
    await expect(handleRpc(hub, { method: "sessions.control", params: { id: "t1", action: "stop" } }, ctx)).rejects.toThrow("只能管帮手");
  });

  test("the assistant's helper_stop / helper_restart wait for the owner's tap", async () => {
    const { hub, cli, project } = setup();
    await hub.toolHandlers().helper_propose({ name: "网站帮手", dir: project, duty: "做网站", dailyUsd: 5 });
    await hub.sessions.decide(hub.chat.recent(1)[0]!.proposal!.id, "create", "app");
    expect(await hub.toolHandlers().helper_stop({ name: "网站帮手" })).toContain("主人点头后才会执行");
    const card = hub.approvals.listPending()[0]!;
    expect(card).toMatchObject({ tool: "helper_stop", title: "停掉帮手「网站帮手」" });
    expect(cli.calls).toEqual(["startBg 网站帮手"]);
    hub.approvals.answer(card.id, true, "app");
    await tick(20);
    expect(cli.calls.at(-1)).toMatch(/^stop /);
    expect(await hub.toolHandlers().helper_stop({ name: "没有的" })).toContain("没有这个会话");
  });

  test("after the Mac restarts, active helpers that aren't running are revived", async () => {
    const { hub, cli, claude, project } = setup();
    await hub.toolHandlers().helper_propose({ name: "网站帮手", dir: project, duty: "做网站", dailyUsd: 5 });
    const { session } = await hub.sessions.decide(hub.chat.recent(1)[0]!.proposal!.id, "create", "app");
    // the machine went down: nothing running
    claude.unregister(session!.id);
    for (const a of cli.agentsList) delete a.pid;
    await (hub.sessions as any).reviveAfterRestart();
    expect(cli.calls.at(-1)).toBe(`resumeBg ${session!.id.slice(0, 8)}`);
    expect(hub.sessions.list()[0]!.status).not.toBe("stopped");
    // running ones are left alone
    const n = cli.calls.length;
    await (hub.sessions as any).reviveAfterRestart();
    expect(cli.calls.length).toBe(n);
  });

  test("a helper that spends more than its daily limit is stopped, and the owner hears it", async () => {
    const { hub, cli, claude, project, pusher } = setup();
    await hub.toolHandlers().helper_propose({ name: "网站帮手", dir: project, duty: "做网站", dailyUsd: 0.04 });
    const { session } = await hub.sessions.decide(hub.chat.recent(1)[0]!.proposal!.id, "create", "app");
    const id = session!.id;
    // one API message is written as several entries; only its last usage counts
    const u = { input_tokens: 10, output_tokens: 1000, cache_read_input_tokens: 100_000, cache_creation_input_tokens: 0 };
    claude.transcript(project, id, [
      assistantEntry("a", { id: "msg_1", model: "claude-sonnet-4-6", usage: { ...u, output_tokens: 1 } }),
      assistantEntry("a", { id: "msg_1", model: "claude-sonnet-4-6", usage: u }),
      assistantEntry("b", { id: "msg_2", model: "claude-sonnet-4-6", usage: u, at: "2020-01-01T00:00:00Z" }), // another day
    ]);
    // $3/M in × 10 + $15/M out × 1000 + $0.30/M cache reads × 100k
    expect(hub.sessions.spentToday(id)).toBeCloseTo((10 * 3 + 1000 * 15 + 100_000 * 0.3) / 1e6, 6);
    await hub.sessions.checkBudgets();
    expect(cli.calls.at(-1)).toBe("stop " + id.slice(0, 8));
    await hub.sessions.checkBudgets();
    expect(cli.calls.filter((c) => c.startsWith("stop"))).toHaveLength(1); // once a day
    expect(hub.chat.recent(1)[0]!.text).toContain("超过了每天 $0.04 的上限");
    expect(pusher.pushes.at(-1)!.title).toBe("帮手停了");
    expect(hub.audit.tail(10).find((e) => e.type === "helper.budget")).toMatchObject({ session: id, dailyUsd: 0.04 });
  });
});

describe("the hooks switch", () => {
  test("sessions.hooks turns PaloAlly's entries on and off in Claude Code's settings; sessions.list says which", async () => {
    const { hub, claude } = setup();
    mkdirSync(claude.dir, { recursive: true });
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    expect(await handleRpc(hub, { method: "sessions.hooks", params: {} }, ctx)).toEqual({ enabled: false });
    expect(await handleRpc(hub, { method: "sessions.hooks", params: { enabled: true } }, ctx)).toEqual({ enabled: true });
    expect(JSON.parse(readFileSync(join(claude.dir, "settings.json"), "utf8")).hooks.PermissionRequest[0].hooks[0].timeout).toBe(300);
    expect(((await handleRpc(hub, { method: "sessions.list", params: {} }, ctx)) as any).hooks).toBe(true);
    expect(await handleRpc(hub, { method: "sessions.hooks", params: { enabled: false } }, ctx)).toEqual({ enabled: false });
    expect(hub.audit.tail(5).filter((e) => e.type === "sessions.hooks").map((e) => e.enabled)).toEqual([true, false]);
  });
});
