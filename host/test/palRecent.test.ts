// 接管最近的对话 (docs/pals-prd.md §10): the conversations that ended on the
// computer lately (pals.recent, over a made-up listSessions), taking one
// over directly (pals.adopt), and the assistant's card for it (pal_adopt,
// helper.decide).
import { afterAll, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn } from "node:child_process";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import type { SDKSessionInfo } from "@anthropic-ai/claude-agent-sdk";
import { AwayDetector } from "../src/away.ts";
import { type RegistryEntry, readRegistry } from "../src/ccSessions.ts";
import { BEHAVIOR } from "../src/home.ts";
import { folderMatch, isOwnFolder, palNameFor, palTitle, type RecentSource, recentTitle, shortName } from "../src/palRecent.ts";
import { MAX_PALS, type PalsTiming } from "../src/pals.ts";
import { handleRpc } from "../src/rpc.ts";
import type { PalAdoptProposal } from "../src/types.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli, assistantEntry } from "./fakeClaude.ts";
import { makeHub, tick } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const cleanups: (() => void)[] = [];
afterAll(() => {
  for (const c of cleanups.splice(0)) c();
});

function liveProcess(): ChildProcess {
  const p = spawn("/bin/sleep", ["120"]);
  cleanups.push(() => p.exitCode === null && p.kill("SIGKILL"));
  return p;
}

const exited = (p: ChildProcess) => new Promise<void>((r) => (p.exitCode !== null || p.signalCode !== null ? r() : p.once("exit", () => r())));

const FAST: Partial<PalsTiming> = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };

const echo: FakeScript = async (text, ctx) => {
  ctx.emit({ type: "assistant_text", text: `收到：${text}`, parentToolUseId: null, messageId: `msg_${text.length}` });
};

const HOUR = 3600_000;

/** The SDK's listSessions / getSessionInfo over made-up sessions: `infos` as Claude Code's /resume lists them, `programmatic` (claude -p, SDK apps) only by id. */
function fakeSource() {
  const infos: SDKSessionInfo[] = [];
  const programmatic: SDKSessionInfo[] = [];
  const calls: { limit: number; includeProgrammatic: boolean }[] = [];
  const source: RecentSource = {
    list: async (o) => {
      calls.push(o);
      const all = o.includeProgrammatic ? [...infos, ...programmatic] : [...infos];
      return all.sort((a, b) => b.lastModified - a.lastModified).slice(0, o.limit);
    },
    info: async (sid) => [...infos, ...programmatic].find((i) => i.sessionId === sid),
  };
  return { infos, programmatic, calls, source };
}

function setup(o: { spawn?: boolean; extraHolders?: () => RegistryEntry[] } = {}) {
  const claude = new FakeClaudeDir();
  const cli = new FakeCli(claude);
  cleanups.push(() => claude.cleanup(), () => cli.close());
  const raw = new Map<string, any[]>();
  const readMessages = async (sid: string) => raw.get(sid) ?? [];
  const src = fakeSource();
  const ctx = makeHub({
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false), readMessages },
    pals: {
      readMessages,
      timing: FAST,
      recentSource: src.source,
      ...(o.extraHolders ? { registry: () => [...readRegistry(join(claude.dir, "sessions")), ...o.extraHolders!()] } : {}),
    },
  });
  ctx.driver.spawnPals = o.spawn ?? false;
  ctx.driver.palScript = echo;
  ctx.hub.pals.start();
  // The owner's folders: not PaloAlly's, not a test's own temporary ones.
  const home = realpathSync(mkdtempSync(join(tmpdir(), "recent-")));
  cleanups.push(() => rmSync(home, { recursive: true, force: true }));
  const folder = (name: string) => {
    const p = join(home, name);
    mkdirSync(p, { recursive: true });
    return p;
  };
  const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(ctx.hub, { method, params }, app)) ?? null));
  let n = 0;
  /** A conversation that ended `ago` ms ago, its transcript where Claude Code keeps it. */
  const ended = (cwd: string, o: { customTitle?: string; summary?: string; firstPrompt?: string; ago?: number; programmatic?: boolean; transcript?: boolean; last?: string } = {}) => {
    const sid = `e${String(++n).padStart(7, "0")}-0000-4000-8000-000000000000`;
    if (o.transcript !== false) {
      claude.transcript(cwd, sid, [
        { type: "user", uuid: `${sid}-1`, timestamp: "2026-10-12T09:00:00Z", message: { role: "user", content: o.firstPrompt ?? "开始吧" }, origin: { kind: "human" } },
        assistantEntry(o.last ?? "做好了。", { model: "claude-sonnet-4-6" }),
      ]);
    }
    const first = o.firstPrompt ?? "开始吧";
    const info: SDKSessionInfo = {
      sessionId: sid,
      summary: o.customTitle ?? o.summary ?? first,
      lastModified: Date.now() - (o.ago ?? HOUR),
      fileSize: 999, // the SDK's; the host stats the file itself
      firstPrompt: first,
      cwd,
      ...(o.customTitle ? { customTitle: o.customTitle } : {}),
    };
    (o.programmatic ? src.programmatic : src.infos).push(info);
    return sid;
  };
  return { ...ctx, claude, cli, raw, src, call, folder, ended, home };
}

describe("the conversations that ended lately (pals.recent)", () => {
  test("newest first, titled as Claude Code titles them; read the way /resume lists them, a few seconds at a time", async () => {
    const t = setup();
    const site = t.folder("site");
    const notes = t.folder("notes");
    const app = t.folder("app");
    const a = t.ended(site, { customTitle: "首页改成两栏", ago: 1 * HOUR });
    const long = "帮我把这个笔记库里所有关于旅行的内容整理成一份按城市分组的清单，顺便把重复的条目合并掉，再标出还没去过的地方";
    const b = t.ended(notes, { firstPrompt: long, ago: 2 * HOUR });
    const c = t.ended(app, { summary: "Fix the login redirect", firstPrompt: "登录完回不到原来那页", ago: 3 * HOUR });
    const { sessions } = await t.call("pals.recent");
    expect(sessions.map((s: any) => s.sessionId)).toEqual([a, b, c]);
    expect(sessions[0]).toEqual({ sessionId: a, cwd: site, title: "首页改成两栏", lastModified: expect.any(Number), size: expect.any(Number) });
    expect(sessions[0].size).toBe(readFileSync(join(t.claude.dir, "projects", site.replace(/[^A-Za-z0-9]/g, "-"), `${a}.jsonl`)).length);
    // no title of its own: Claude Code's summary, else its first 40 characters
    expect(sessions[1].title).toBe(`${[...long].slice(0, 40).join("")}…`);
    expect(sessions[2].title).toBe("Fix the login redirect");
    // as /resume lists them (no claude -p runs, no apps on the SDK), the newest transcripts only
    expect(t.src.calls).toEqual([{ limit: 150, includeProgrammatic: false }]);
    // read again only after a few seconds
    await t.call("pals.recent");
    expect(t.src.calls).toHaveLength(1);
    // a folder: by its path, or its name; and a limit
    expect((await t.call("pals.recent", { folder: notes })).sessions.map((s: any) => s.sessionId)).toEqual([b]);
    expect((await t.call("pals.recent", { folder: "SITE" })).sessions.map((s: any) => s.sessionId)).toEqual([a]);
    expect((await t.call("pals.recent", { folder: join(t.home, "nothing") })).sessions).toEqual([]);
    expect((await t.call("pals.recent", { limit: 2 })).sessions).toHaveLength(2);
    expect((await t.call("pals.recent", { limit: 500 })).sessions).toHaveLength(3);
  });

  test("never what's running, a Pal, PaloAlly's own or its tests' and agents' folders, a folder that's gone, a transcript that isn't there, or older than 30 days", async () => {
    const t = setup();
    const site = t.folder("site");
    const keep = t.ended(site, { customTitle: "留着的" });
    // running in a terminal (the registry), and a stopped background one (among the others)
    const term = liveProcess();
    const running = t.ended(site, { customTitle: "还开着" });
    t.claude.register({ sessionId: running, name: "还开着", cwd: site, pid: term.pid });
    const bgStopped = t.ended(site, { customTitle: "后台停着" });
    await t.cli.stop(t.cli.bg({ sessionId: bgStopped, name: "后台停着", cwd: site }));
    expect((await t.call("pals.list")).others.find((s: any) => s.id === bgStopped)).toMatchObject({ status: "stopped", kind: "background" });
    // PaloAlly's: the assistant's home, a test's folder, a Claude Code agent's scratchpad
    t.ended(t.paths.home, { customTitle: "Palo 自己" });
    const testDir = realpathSync(mkdtempSync(join(tmpdir(), "paloally-pal-")));
    const scratch = join(realpathSync(tmpdir()), `claude-${process.getuid?.() ?? 501}${Date.now() % 1000}`, "proj", "scratchpad");
    mkdirSync(scratch, { recursive: true });
    cleanups.push(() => rmSync(testDir, { recursive: true, force: true }), () => rmSync(join(scratch, "../.."), { recursive: true, force: true }));
    t.ended(testDir, { customTitle: "测试的" });
    t.ended(scratch, { customTitle: "agent 的" });
    // its folder is gone; its transcript isn't where a Pal would resume it; a month ago
    const gone = t.folder("gone");
    t.ended(gone, { customTitle: "目录没了" });
    rmSync(gone, { recursive: true });
    t.ended(site, { customTitle: "没有记录", transcript: false });
    t.ended(site, { customTitle: "上个月的", ago: 31 * 24 * HOUR });
    // claude -p runs and apps on the SDK
    t.ended(site, { customTitle: "脚本跑的", programmatic: true });
    expect((await t.call("pals.recent")).sessions.map((s: any) => s.title)).toEqual(["留着的"]);
    // one that's a Pal now isn't listed; out of the list again, it is
    const { pal } = await t.call("pals.adopt", { sessionId: keep });
    expect((await t.call("pals.recent")).sessions).toEqual([]);
    await t.call("pals.remove", { id: pal.id });
    expect((await t.call("pals.recent")).sessions.map((s: any) => s.sessionId)).toEqual([keep]);
    term.kill("SIGKILL");
    await t.hub.pals.stopAndWait();
  });

  test("a Pal the assistant opened (an SDK session from its start) is listed once the owner takes it out", async () => {
    const t = setup();
    const docs = t.folder("docs");
    await t.hub.toolHandlers().pal_propose({ name: "文档", dir: docs, duty: "写安装说明", dailyUsd: 1 });
    const { pal } = await t.call("helper.decide", { proposalId: t.hub.chat.recent(1)[0]!.proposal!.id, action: "create" });
    // its transcript, as Claude Code wrote it
    t.claude.transcript(docs, pal.sessionId, [assistantEntry("安装说明写好了。")]);
    t.src.programmatic.push({ sessionId: pal.sessionId, summary: "写安装说明", firstPrompt: "写安装说明", lastModified: Date.now(), cwd: docs });
    expect((await t.call("pals.recent")).sessions).toEqual([]);
    await t.call("pals.release", { id: pal.id });
    expect((await t.call("pals.recent")).sessions).toMatchObject([{ sessionId: pal.sessionId, cwd: docs, title: "写安装说明" }]);
    expect(JSON.parse(readFileSync(t.paths.pals, "utf8")).former).toMatchObject([{ sessionId: pal.sessionId, cwd: docs }]);
    await t.hub.pals.stopAndWait();
  });
});

describe("taking an ended one over (pals.adopt)", () => {
  test("resumed at once as a Pal (no process to stop) under its title, short and unique, or its folder's name; its conversation comes with it", async () => {
    const t = setup();
    const site = t.folder("site");
    const notes = t.folder("notes");
    const a = t.ended(site, { customTitle: "首页改成两栏", last: "两栏的样式好了。" });
    t.raw.set(a, [
      { type: "user", uuid: "u1", timestamp: "2026-10-12T09:00:00Z", message: { role: "user", content: "把首页改成两栏" }, origin: { kind: "human" } },
      { type: "assistant", uuid: "u2", timestamp: "2026-10-12T09:01:00Z", message: { id: "msg_a", role: "assistant", content: [{ type: "text", text: "两栏的样式好了。" }] } },
    ]);
    const t0 = Date.now();
    const { pal } = await t.call("pals.adopt", { sessionId: a });
    expect(Date.now() - t0).toBeLessThan(1_000);
    expect(pal).toMatchObject({ name: "首页改成两栏", cwd: site, sessionId: a, status: "idle", createdBy: "owner", lastLine: "两栏的样式好了。", model: "claude-sonnet-4-6" });
    expect(t.cli.calls).toEqual([]); // nothing was stopped
    expect(t.driver.pals[0]!.opts).toMatchObject({ cwd: site, resumeSessionId: a, name: "首页改成两栏" });
    expect((await t.call("pals.history", { id: pal.id })).messages.map((m: any) => m.text)).toEqual(["把首页改成两栏", "两栏的样式好了。"]);
    expect(t.hub.audit.tail(10).find((e) => e.type === "pal.adopted")).toMatchObject({ session: a, name: "首页改成两栏", ended: true });
    // again: the same Pal
    expect((await t.call("pals.adopt", { sessionId: a })).pal.id).toBe(pal.id);
    // its custom title as it is (§13: the name follows Claude Code's title); no title of its own: its folder's name; a name in use gets a number
    const long = await t.call("pals.adopt", { sessionId: t.ended(site, { customTitle: "Refactor the authentication middleware" }) });
    expect(long.pal.name).toBe("Refactor the authentication middleware");
    const bare = await t.call("pals.adopt", { sessionId: t.ended(notes, { firstPrompt: "帮我把旅行的笔记按城市整理一下" }) });
    expect(bare.pal.name).toBe("notes");
    const twice = await t.call("pals.adopt", { sessionId: t.ended(notes, { customTitle: "首页改成两栏" }) });
    expect(twice.pal.name).toBe("首页改成两栏 2");
    // asked twice at once: one Pal
    const s5 = t.ended(site, { customTitle: "同时点了两次" });
    const [x, y] = await Promise.all([t.call("pals.adopt", { sessionId: s5 }), t.call("pals.adopt", { sessionId: s5 })]);
    expect(x.pal.id).toBe(y.pal.id);
    expect(t.driver.pals).toHaveLength(5);
    // a sixth is taken over too: the least recently used idle one goes to sleep (§12)
    const sixth = await t.call("pals.adopt", { sessionId: t.ended(site, { customTitle: "第六个" }) });
    expect(sixth.pal.status).toBe("idle");
    await waitFor(() => t.hub.pals.list().some((p) => p.status === "asleep"));
    expect(t.hub.pals.list().filter((p) => p.status === "asleep").map((p) => p.id)).toEqual([pal.id]);
    await t.hub.pals.stopAndWait();
  });

  test("never two writers: a process that opened it just before isn't joined; one that opens it later makes the Pal step aside", async () => {
    let holders: RegistryEntry[] = [];
    const t = setup({ spawn: true, extraHolders: () => holders });
    const site = t.folder("site");
    const sid = t.ended(site, { customTitle: "修登录" });
    const term = liveProcess();
    holders = [{ pid: term.pid!, sessionId: sid, name: "修登录", cwd: site, kind: "interactive", status: "idle" }];
    await expect(t.call("pals.adopt", { sessionId: sid })).rejects.toThrow(`它刚在别处打开了（进程 ${term.pid}）`);
    expect(t.driver.pals).toHaveLength(0);
    expect(t.hub.pals.list()).toEqual([]);
    holders = [];
    const { pal } = await t.call("pals.adopt", { sessionId: sid });
    const own = t.driver.pals[0]!.proc!;
    // the owner resumes it in a terminal: the Pal leaves at once
    t.claude.register({ sessionId: sid, name: "修登录", cwd: site, pid: term.pid });
    await waitFor(() => t.hub.pals.list()[0]!.status === "stopped", 3_000);
    await exited(own);
    expect(t.hub.pals.list()[0]).toMatchObject({ id: pal.id, note: expect.stringContaining("在别处打开了") });
    term.kill("SIGKILL");
    await t.hub.pals.stopAndWait();
  });

  test("PaloAlly's own conversation, one whose folder is gone, and one it can't find aren't taken over", async () => {
    const t = setup();
    await expect(t.call("pals.adopt", { sessionId: t.ended(t.paths.home, { customTitle: "Palo" }) })).rejects.toThrow("PaloAlly 自己的会话");
    const gone = t.folder("gone");
    const g = t.ended(gone, { customTitle: "没了" });
    rmSync(gone, { recursive: true });
    await expect(t.call("pals.adopt", { sessionId: g })).rejects.toThrow("已经不在了");
    await expect(t.call("pals.adopt", { sessionId: t.ended(t.folder("x"), { transcript: false }) })).rejects.toThrow("找不到它的对话记录");
    await expect(t.call("pals.adopt", { sessionId: "f0000000-0000-4000-8000-000000000000" })).rejects.toThrow("没有这个会话");
    expect(t.driver.pals).toHaveLength(0);
  });
});

describe("the assistant brings one back (pals_recent, pal_adopt)", () => {
  test("it lists them, its card adopts on 接管 only (the card says so, with the Pal), and a second 接管 gives the same Pal", async () => {
    const t = setup();
    const site = t.folder("site");
    const notes = t.folder("notes");
    const a = t.ended(site, { customTitle: "首页改成两栏", ago: HOUR });
    t.ended(notes, { customTitle: "旅行清单", ago: 2 * HOUR });
    const tools = t.hub.toolHandlers();
    const listed = JSON.parse(await tools.pals_recent({}));
    expect(listed.sessions.map((s: any) => s.title)).toEqual(["首页改成两栏", "旅行清单"]);
    expect(listed.sessions[0]).toEqual({ sessionId: a, dir: site.startsWith(homedir()) ? `~${site.slice(homedir().length)}` : site, title: "首页改成两栏", lastActive: expect.stringMatching(/^\d{4}-\d\d-\d\d \d\d:\d\d$/) });
    expect(JSON.parse(await tools.pals_recent({ folder: "notes" })).sessions.map((s: any) => s.title)).toEqual(["旅行清单"]);
    expect(JSON.parse(await tools.pals_recent({ folder: "nowhere" }))).toEqual({ sessions: [], note: "这个目录里没有最近退出的对话" });

    // a card, nothing started; by its first characters too
    const said = await tools.pal_adopt({ sessionId: a.slice(0, 8) });
    expect(said).toContain("主人点「接管」才会接，现在还没接");
    const card = t.hub.chat.recent(1)[0]!;
    expect(card).toMatchObject({ role: "assistant", kind: "pal_adopt", channel: "system", text: expect.stringContaining("接管「首页改成两栏」（") });
    expect(card.proposal).toEqual({ id: expect.stringMatching(/^pa_/), sessionId: a, cwd: site, title: "首页改成两栏", status: "pending" });
    expect(t.driver.pals).toHaveLength(0);
    expect(await tools.pal_adopt({ sessionId: a })).toContain("已经有一张接管它的卡片");

    // 接管: the Pal, and the card (the same message, sent again) says so
    const before = t.events.filter((e) => e.event === "chat.message" && e.data.id === card.id).length;
    const { pal } = await t.call("helper.decide", { proposalId: card.proposal!.id, action: "create" });
    expect(pal).toMatchObject({ sessionId: a, cwd: site, name: "首页改成两栏", status: "idle" });
    expect(t.hub.chat.get(card.id)!.proposal).toEqual({ ...(card.proposal as PalAdoptProposal), status: "adopted", palId: pal.id });
    const resent = t.events.filter((e) => e.event === "chat.message" && e.data.id === card.id);
    expect(resent.length).toBe(before + 1);
    expect(resent.at(-1)!.data).toMatchObject({ seq: card.seq, kind: "pal_adopt", proposal: { status: "adopted", palId: pal.id } });
    expect((await t.call("helper.decide", { proposalId: card.proposal!.id, action: "create" })).pal.id).toBe(pal.id);
    expect(t.driver.pals).toHaveLength(1);
    // it's a Pal now, not a recent one
    expect(await tools.pal_adopt({ sessionId: a })).toContain("已经是 Pal「首页改成两栏」");
    expect(JSON.parse(await tools.pals_recent({})).sessions.map((s: any) => s.title)).toEqual(["旅行清单"]);
    expect(t.hub.audit.tail(20).map((e) => e.type)).toEqual(expect.arrayContaining(["pal.adopt_proposed", "pal.adopt_accepted"]));
    await t.hub.pals.stopAndWait();
  });

  test("不用 adopts nothing; one that couldn't be taken over says why on the card and can be tapped again; what isn't an ended one gets no card", async () => {
    const t = setup();
    const site = t.folder("site");
    const tools = t.hub.toolHandlers();
    const a = t.ended(site, { customTitle: "不要了" });
    await tools.pal_adopt({ sessionId: a });
    const no = t.hub.chat.recent(1)[0]!;
    expect(await t.call("helper.decide", { proposalId: no.proposal!.id, action: "discard" })).toEqual({});
    expect(t.hub.chat.get(no.id)!.proposal!.status).toBe("discarded");
    expect(await t.call("helper.decide", { proposalId: no.proposal!.id, action: "create" })).toEqual({});
    expect(t.driver.pals).toHaveLength(0);

    // Claude Code won't resume it: failed, with why; tapped again once it would, adopted
    const b = t.ended(site, { customTitle: "再试一次" });
    await tools.pal_adopt({ sessionId: b });
    const retry = t.hub.chat.recent(1)[0]!;
    t.driver.failPalStart = () => "Error: not logged in";
    expect(await t.call("helper.decide", { proposalId: retry.proposal!.id, action: "create" })).toEqual({});
    expect(t.hub.chat.get(retry.id)!.proposal).toMatchObject({ status: "failed", note: "Claude Code 没登录" });
    expect(t.hub.pals.list()).toEqual([]);
    t.driver.failPalStart = undefined;
    const { pal } = await t.call("helper.decide", { proposalId: retry.proposal!.id, action: "create" });
    expect(t.hub.chat.get(retry.id)!.proposal).toEqual({ ...(retry.proposal as PalAdoptProposal), status: "adopted", palId: pal.id });

    // opened in a terminal after the card: not taken over (no waiting behind a card)
    const c = t.ended(site, { customTitle: "又打开了" });
    await tools.pal_adopt({ sessionId: c });
    const opened = t.hub.chat.recent(1)[0]!;
    const term = liveProcess();
    t.claude.register({ sessionId: c, name: "又打开了", cwd: site, pid: term.pid });
    expect(await t.call("helper.decide", { proposalId: opened.proposal!.id, action: "create" })).toEqual({});
    expect(t.hub.chat.get(opened.id)!.proposal).toMatchObject({ status: "failed", note: expect.stringContaining("先在终端里退出它") });
    expect(t.hub.pals.adopting(c)).toBe(false);

    // no card: running now, unknown, PaloAlly's own
    expect(await tools.pal_adopt({ sessionId: c })).toContain("现在还开着");
    expect(await tools.pal_adopt({ sessionId: "f0000000-0000-4000-8000-000000000000" })).toBe("没提：没有这个会话");
    expect(await tools.pal_adopt({ sessionId: t.ended(t.paths.home, { customTitle: "Palo" }) })).toContain("PaloAlly 自己的会话");
    expect(await tools.pal_adopt({ sessionId: "" })).toContain("pals_recent");
    term.kill("SIGKILL");
    await t.hub.pals.stopAndWait();
  });

  test("with fifty Pals it asks the owner to make room first", async () => {
    const t = setup();
    const site = t.folder("site");
    for (let i = 1; i <= MAX_PALS; i++) {
      await t.call("pals.adopt", { sessionId: t.ended(site, { customTitle: `项目${i}` }) });
      await tick(2);
    }
    expect(await t.hub.toolHandlers().pal_adopt({ sessionId: t.ended(site, { customTitle: "第六个" }) })).toContain("最久没用的「项目1」");
    expect(t.hub.chat.recent(5).some((m) => m.kind === "pal_adopt")).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("its instructions: look first, ask when there are several, then the card", () => {
    expect(BEHAVIOR).toContain("mcp__paloally__pals_recent");
    expect(BEHAVIOR).toContain("mcp__paloally__pal_adopt");
    expect(BEHAVIOR).toMatch(/有好几个候选时，先用 AskUserQuestion 让主人选/);
  });
});

describe("looking without taking over (§14)", () => {
  test("sessions.history reads a conversation that ended (its folder from Claude Code's record) without taking it over or writing to it; an open page asking again sees what was added, and an unchanged transcript isn't read again", async () => {
    const t = setup();
    const site = t.folder("site");
    const sid = t.ended(site, { customTitle: "首页改成两栏" });
    const path = join(t.claude.dir, "projects", site.replace(/[^A-Za-z0-9]/g, "-"), `${sid}.jsonl`);
    const line = (uuid: string, role: "user" | "assistant", text: string) =>
      role === "user"
        ? { type: "user", uuid, timestamp: "2026-10-12T09:00:00Z", message: { role: "user", content: text }, origin: { kind: "human" } }
        : { type: "assistant", uuid, timestamp: "2026-10-12T09:01:00Z", message: { id: `msg_${uuid}`, role: "assistant", content: [{ type: "text", text }] } };
    t.raw.set(sid, [line("u1", "user", "把首页改成两栏"), line("a1", "assistant", "两栏的样式好了。")]);
    const before = readFileSync(path, "utf8");
    const first = await t.call("sessions.history", { id: sid });
    expect(first.messages.map((m: any) => [m.role, m.text])).toEqual([["owner", "把首页改成两栏"], ["assistant", "两栏的样式好了。"]]);
    // nothing taken over, nothing written
    expect(t.hub.pals.list()).toEqual([]);
    expect(t.driver.pals).toHaveLength(0);
    expect(readFileSync(path, "utf8")).toBe(before);
    // the transcript didn't change: not read again (what the reader would say now isn't asked)
    t.raw.set(sid, [...t.raw.get(sid)!, line("u2", "user", "还没写进记录")]);
    expect((await t.call("sessions.history", { id: sid })).messages).toHaveLength(2);
    // Claude Code wrote more (a live one going on): the next look has it
    appendFileSync(path, JSON.stringify(line("u2", "user", "还没写进记录")) + "\n");
    t.raw.set(sid, [...t.raw.get(sid)!, line("a2", "assistant", "新的一句")]);
    const next = await t.call("sessions.history", { id: sid });
    expect(next.messages.map((m: any) => m.text).slice(-2)).toEqual(["还没写进记录", "新的一句"]);
    // older pages as before; one it doesn't know isn't found
    expect((await t.call("sessions.history", { id: sid, before: "a2", limit: 1 })).messages.map((m: any) => m.id)).toEqual(["u2"]);
    await expect(t.call("sessions.history", { id: "f0000000-0000-4000-8000-000000000000" })).rejects.toThrow("没有这个会话");
    await t.hub.pals.stopAndWait();
  });
});

describe("pieces", () => {
  test("titles, names, PaloAlly's folders and the folder filter", () => {
    expect(recentTitle({ customTitle: "  首页\n改成两栏 ", summary: "x", firstPrompt: "y" })).toBe("首页 改成两栏");
    expect(recentTitle({ summary: "Fix the login redirect", firstPrompt: "登录完回不到原来那页" })).toBe("Fix the login redirect");
    expect(recentTitle({ summary: "a".repeat(50), firstPrompt: "a".repeat(50) })).toBe(`${"a".repeat(40)}…`);
    expect(recentTitle({ summary: "" })).toBe("");
    expect(shortName("Refactor the authentication middleware")).toBe("Refactor the");
    expect(shortName("把所有旅行笔记按城市整理成清单并合并重复")).toBe("把所有旅行笔记按城市整理成清单并");
    expect(shortName("「网站」")).toBe("网站");
    expect(palNameFor({ customTitle: "", cwd: "/Users/someone/code/palo-ally" })).toBe("palo-ally");
    expect(palNameFor({ customTitle: "修登录", cwd: "/x" })).toBe("修登录");
    // §13's order: a custom title, then Claude Code's own title (short), then the folder
    expect(palNameFor({ generatedTitle: "Fix the login redirect after sign in", cwd: "/x/site" })).toBe("Fix the login");
    expect(palNameFor({ customTitle: "网站", generatedTitle: "Fix the login", cwd: "/x/site" })).toBe("网站");
    expect(palTitle({ customTitle: "  首页\n改成两栏 ", summary: "x", firstPrompt: "y" }, "/x/site")).toBe("首页 改成两栏");
    expect(palTitle({ summary: "Fix the login redirect", firstPrompt: "登录完回不到原来那页" }, "/x/site")).toBe("Fix the login");
    expect(palTitle({ summary: "登录完回不到原来那页", firstPrompt: "登录完回不到原来那页" }, "/x/site")).toBe("site");
    expect(palTitle(undefined, "/x/site")).toBe("site");
    expect(palTitle({ customTitle: "a".repeat(60) }, "/x")).toBe("a".repeat(40));
    const tmp = realpathSync(tmpdir());
    expect(isOwnFolder("/Users/someone/.paloally/home", ["/Users/someone/.paloally"])).toBe(true);
    expect(isOwnFolder(join(tmp, "paloally-test-x", "home"), [])).toBe(true);
    expect(isOwnFolder(join(tmp, "courier-abc"), [])).toBe(true);
    expect(isOwnFolder("/private/tmp/claude-501/-Users-someone-code-x/3f2a/scratchpad", [])).toBe(true);
    expect(isOwnFolder("/private/tmp/claude-notes", [])).toBe(false);
    expect(isOwnFolder(join(tmp, "pal-live-recent-x"), [])).toBe(false);
    expect(isOwnFolder("/Users/someone/code/site", ["/Users/someone/.paloally"])).toBe(false);
    expect(folderMatch("/Users/someone/code")("/Users/someone/code/site")).toBe(true);
    expect(folderMatch("/Users/someone/code/si")("/Users/someone/code/site")).toBe(false);
    expect(folderMatch("Site")("/Users/someone/code/site")).toBe(true);
    expect(folderMatch("code")("/Users/someone/code/site")).toBe(true);
    expect(folderMatch("")("/anything")).toBe(true);
  });
});
