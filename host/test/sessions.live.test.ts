// Live: a real Claude Code background session (Haiku) as a helper, driven
// through the host. Costs real tokens (well under $1) and starts Claude
// Code's background service if it isn't running. Run with:
//   PALOALLY_LIVE_SESSIONS=1 bun test test/sessions.live.test.ts
//
// Claude Code's user settings stay untouched: a temporary CLAUDE_CONFIG_DIR
// isn't logged in, so the hooks go into the test project's own
// .claude/settings.json (as the spike did) and the session runs under the
// real config dir. Everything the test starts is removed at the end.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { RealClaudeCli } from "../src/ccCli.ts";
import { HOOK_EVENTS, HookInstaller, hookCommand } from "../src/ccHooks.ts";
import { claudeConfigDir, transcriptPath } from "../src/handoffs.ts";
import { Hub } from "../src/hub.ts";
import { FakeDriver } from "./fakeDriver.ts";
import { RecordingPusher, testConfig, tmpPaths } from "./helpers.ts";

const LIVE = process.env.PALOALLY_LIVE_SESSIONS === "1";
const d = LIVE ? describe : describe.skip;
const T = 900_000;

async function waitFor<T>(what: string, f: () => T | undefined | null | false, ms = 120_000, every = 250): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = f();
    if (v) return v;
    await new Promise((r) => setTimeout(r, every));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function waitUntil(what: string, f: () => Promise<boolean>, ms = 60_000, every = 1000): Promise<void> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await f()) return;
    await new Promise((r) => setTimeout(r, every));
  }
  throw new Error(`timed out waiting for ${what}`);
}

d("live: a helper as a real background session", () => {
  const paths = tmpPaths();
  const scratch = process.env.PALOALLY_LIVE_DIR ?? join(paths.root, "..");
  const project = realpathSync(mkdtempSync(join(scratch, "palo-live-")));
  const claudeDir = claudeConfigDir();
  const cli = new RealClaudeCli();
  const pusher = new RecordingPusher();
  const logs: string[] = [];
  const hookEvents: { at: number; event: string; sid: string; payload: any }[] = [];
  const shorts = new Set<string>();
  const timings: Record<string, number> = {};
  const name = `palo-live-${Math.random().toString(36).slice(2, 6)}`;

  // The hook scripts under the temp PaloAlly root, and the project's own settings pointing at them.
  new HookInstaller({ paths, claudeDir: join(paths.root, "unused-claude") }).writeScripts();
  mkdirSync(join(project, ".claude"), { recursive: true });
  const hooks: Record<string, unknown[]> = {};
  for (const [ev, timeout] of Object.entries(HOOK_EVENTS)) hooks[ev] = [{ hooks: [{ type: "command", command: hookCommand(paths), timeout }] }];
  writeFileSync(join(project, ".claude", "settings.json"), JSON.stringify({ hooks }, null, 2));

  const hub = new Hub({
    paths,
    config: testConfig(),
    driver: new FakeDriver(),
    pushers: [pusher],
    log: (s) => logs.push(s),
    sessions: {
      claudeDir,
      cli,
      away: new AwayDetector(() => null, Date.now, () => true), // the owner is away
      hookWaitMs: 20_000,
      helperMode: () => "default", // a mode that asks
      helperModel: () => "haiku",
    },
  });
  const origOnHook = hub.sessions.onHook.bind(hub.sessions);
  hub.sessions.onHook = (event, payload, ctx) => {
    hookEvents.push({ at: Date.now(), event, sid: String(payload.session_id ?? ""), payload });
    return origOnHook(event, payload, ctx);
  };
  hub.sessions.start();

  let sid = "";
  const mine = () => hub.sessions.list().find((s) => s.id === sid);
  const helperShort = () => hub.sessions.helpers.get(sid)?.short;
  const stopEvents = () => hookEvents.filter((e) => e.sid === sid && e.event === "Stop");

  afterAll(async () => {
    const short = helperShort();
    if (short) shorts.add(short);
    for (const s of shorts) await cli.rm(s).catch(() => {});
    hub.sessions.stop();
    hub.stop();
    // what Claude Code kept for the test project
    const proj = join(claudeDir, "projects", resolve(project).replace(/[^A-Za-z0-9]/g, "-"));
    if (existsSync(proj)) rmSync(proj, { recursive: true, force: true });
    for (const s of shorts) rmSync(join(claudeDir, "jobs", s), { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
    const courierCost = hub.audit.tail(200).filter((e) => e.type === "session.send").reduce((a, e) => a + Number(e.costUsd ?? 0), 0);
    console.log(`[live] timings ms: ${JSON.stringify(timings)}`);
    console.log(`[live] helper spent ~$${spent.toFixed(4)}, courier $${courierCost.toFixed(4)}`);
  });
  let spent = 0;

  test(
    "开吧 starts it in its folder; its hooks reach the host with no terminal",
    async () => {
      expect(await hub.toolHandlers().helper_propose({ name, dir: project, duty: "Reply with exactly the word: ready", dailyUsd: 1 })).toContain("开吧");
      const proposal = hub.chat.recent(1)[0]!.proposal!;
      const t0 = Date.now();
      const { session } = await hub.sessions.decide(proposal.id, "create", "test");
      timings.create = Date.now() - t0;
      sid = session!.id;
      shorts.add(helperShort()!);
      expect(session).toMatchObject({ name, cwd: project, kind: "helper" });
      const saved = JSON.parse(readFileSync(paths.helpers, "utf8")).helpers[0];
      expect(saved).toMatchObject({ name, cwd: project, sessionId: sid, short: sid.slice(0, 8), state: "active", dailyUsd: 1 });
      await waitFor("SessionStart", () => hookEvents.find((e) => e.sid === sid && e.event === "SessionStart"));
      const stop = await waitFor("the first answer", () => stopEvents()[0]);
      timings.firstAnswer = stop.at - t0;
      expect(String(stop.payload.last_assistant_message)).toContain("ready");
      expect(stop.payload.permission_mode).toBe("default");
      await hub.sessions.watch.refresh({ agents: true });
      expect(mine()).toMatchObject({ kind: "helper", status: "idle", lastLine: expect.stringContaining("ready") });
    },
    T,
  );

  test(
    "the owner's words arrive verbatim; a permission prompt reaches the phone and the allow goes back",
    async () => {
      const words = "Use the Bash tool to run exactly this command: touch live-ok.txt   Then reply with exactly: touched";
      const t0 = Date.now();
      await hub.sessions.send(sid, words, "owner");
      timings.courierSend = Date.now() - t0;
      const card = await waitFor("the card", () => hub.approvals.listPending().find((a) => a.source?.id === sid));
      timings.promptToCard = Date.now() - t0;
      expect(card).toMatchObject({ tool: "Bash", source: { kind: "session", id: sid, name } });
      expect(card.detail).toContain("touch live-ok.txt");
      expect(pusher.pushes.some((p) => p.title === `${name} 在等你`)).toBe(true);
      expect(mine()!.status).toBe("waiting");
      const tAllow = Date.now();
      hub.approvals.answer(card.id, true, "app", false, "dev-live");
      await waitFor("the command to run", () => existsSync(join(project, "live-ok.txt")), 60_000, 50);
      timings.allowToRun = Date.now() - tAllow;
      await waitFor("its reply", () => stopEvents().some((e) => String(e.payload.last_assistant_message).includes("touched")));
      // the session's transcript has the owner's words exactly, from PaloAlly
      const lines = readFileSync(transcriptPath(claudeDir, project, sid), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
      const peer = lines.find((e) => e.origin?.kind === "peer" && e.origin?.name === "PaloAlly");
      expect(peer).toBeDefined();
      const body = peer.origin.body ?? /<cross-session-message[^>]*>\n([\s\S]*?)\n<\/cross-session-message>/.exec(peer.message.content)?.[1];
      expect(body).toBe(`主人：${words}`);
      // (the transcript may trail the Stop hook by a moment)
      let history = await hub.sessions.history(sid);
      await waitUntil("its reply in the transcript", async () => (history = await hub.sessions.history(sid)).some((m) => m.role === "assistant" && m.text.includes("touched")), 20_000, 500);
      // the handover first (the assistant's), then the owner's words
      expect(history.filter((m) => m.role === "palo").map((m) => [m.from, m.text])).toEqual([
        ["Palo", "Reply with exactly the word: ready"],
        ["主人", words],
      ]);
      expect(history.some((m) => m.role === "assistant" && m.text.includes("touched"))).toBe(true);
      expect(hub.audit.tail(50).find((e) => e.type === "approval.decided" && e.session === sid)).toMatchObject({ status: "allowed", device: "dev-live" });
    },
    T,
  );

  test(
    "a question (AskUserQuestion) answered on the phone",
    async () => {
      const t0 = Date.now();
      await hub.sessions.send(sid, "Use the AskUserQuestion tool to ask me one question, 'Pick a color', with exactly two options: Red and Blue. After I answer, reply with exactly: chose <answer>", "owner");
      timings.courierSendWarm = Date.now() - t0;
      const q = await waitFor("the question", () => hub.questions.listPending().find((x) => x.source?.id === sid));
      timings.questionToCard = Date.now() - t0;
      expect(q.items[0]!.options.map((o) => o.label)).toEqual(["Red", "Blue"]);
      hub.questions.answer(q.id, { [q.items[0]!.question]: "Blue" }, "app", "dev-live");
      const stop = await waitFor("its answer", () => stopEvents().find((e) => /chose/i.test(String(e.payload.last_assistant_message))));
      expect(String(stop.payload.last_assistant_message)).toContain("Blue");
    },
    T,
  );

  test(
    "unanswered: the card goes back to the computer (在电脑上等你), the session keeps waiting there",
    async () => {
      await hub.sessions.send(sid, "Use the Bash tool to run exactly this command: touch live-late.txt", "owner");
      const card = await waitFor("the card", () => hub.approvals.listPending().find((a) => a.source?.id === sid));
      await waitFor("the hook's limit", () => hub.approvals.get(card.id)?.status === "expired", 40_000);
      expect(hub.approvals.get(card.id)).toMatchObject({ status: "expired", note: "在电脑上等你" });
      await new Promise((r) => setTimeout(r, 3_000));
      expect(existsSync(join(project, "live-late.txt"))).toBe(false);
      expect(mine()!.status).toBe("waiting");
    },
    T,
  );

  test(
    "停止 / 重启 / 删除 / 复活: the same session, its context kept",
    async () => {
      const ctl = async (action: string) => {
        const t0 = Date.now();
        await hub.sessions.control(sid, action, "test");
        timings[action] = (timings[action] ?? 0) + Date.now() - t0;
      };
      // restart while it still waits at the computer: respawned
      await ctl("restart");
      await waitFor("respawned", () => hookEvents.filter((e) => e.sid === sid && e.event === "SessionStart").length >= 2, 60_000);
      const status = async () => (await hub.sessions.watch.refresh({ agents: true }), mine()?.status);
      await ctl("stop");
      await waitUntil("stopped", async () => (await status()) === "stopped");
      await ctl("restart"); // stopped: comes back from its transcript
      await waitUntil("running again", async () => (await status()) !== "stopped");
      await ctl("remove");
      const agents = await cli.agents();
      expect(agents.some((a) => a.sessionId === sid)).toBe(false);
      expect(mine()).toMatchObject({ kind: "helper", status: "stopped" });
      await ctl("revive");
      shorts.add(helperShort()!);
      await waitUntil("revived", async () => (await status()) !== "stopped");
      expect(hub.sessions.helpers.get(sid)!.sessionId).toBe(sid);
      // the context is still there
      const n = stopEvents().length;
      await hub.sessions.send(sid, "What exact single word did you reply with at the very start of this conversation? Answer with just that word.", "owner");
      const stop = await waitFor("its answer", () => stopEvents().slice(n).find((e) => String(e.payload.last_assistant_message).trim()));
      expect(String(stop.payload.last_assistant_message).toLowerCase()).toContain("ready");
      spent = hub.sessions.spentToday(sid);
      expect(spent).toBeGreaterThan(0);
      expect(spent).toBeLessThan(1);
    },
    T,
  );
});
