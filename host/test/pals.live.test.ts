// Live: real Claude Code sessions (Haiku) as Pals, run by the host through
// PaloAlly Helper when it's built (host/helper/build.sh; or set
// PALOALLY_HELPER_APP), otherwise directly. Costs real tokens (well under $1)
// and starts Claude Code's background service if it isn't running. Run with:
//   PALOALLY_LIVE_PALS=1 bun test test/pals.live.test.ts
//
// The last test takes over a conversation that already ended (pals-prd §10):
// a terminal session quit with /exit is listed by pals.recent (a `claude -p`
// run in the same folder isn't) and adopted with its context.
//
// Everything runs in temporary folders. Claude Code's own settings, the
// owner's sessions and any running PaloAlly host are left alone: the test
// only reads Claude Code's session registry, and its hub never installs or
// refreshes hooks. What it starts (a background job, a terminal session in a
// pty, the transcripts of its folders) is removed at the end.
import { afterAll, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { RealClaudeCli, findClaude, loginEnv, parseBackgrounded } from "../src/ccCli.ts";
import { readRegistry } from "../src/ccSessions.ts";
import { SpendMeter } from "../src/ccSpend.ts";
import { claudeConfigDir, transcriptPath } from "../src/handoffs.ts";
import { ClaudeCodeDriver } from "../src/harness/claude.ts";
import { Hub } from "../src/hub.ts";
import { HELPER_APP, findHelper, helperCandidates } from "../src/palLauncher.ts";
import type { PalsDeps } from "../src/pals.ts";
import type { Pal } from "../src/types.ts";
import { FakeDriver } from "./fakeDriver.ts";
import { RecordingPusher, testConfig, tmpPaths } from "./helpers.ts";

const LIVE = process.env.PALOALLY_LIVE_PALS === "1";
const d = LIVE ? describe : describe.skip;
const T = 600_000;

async function waitFor<T>(what: string, f: () => T | undefined | null | false | Promise<T | undefined | null | false>, ms = 120_000, every = 100): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await f();
    if (v) return v;
    await new Promise((r) => setTimeout(r, every));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function transcriptEntries(claudeDir: string, cwd: string, sid: string): any[] {
  const p = transcriptPath(claudeDir, cwd, sid);
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8")
    .split("\n")
    .filter(Boolean)
    .flatMap((l) => {
      try {
        return [JSON.parse(l)];
      } catch {
        return [];
      }
    });
}

const replied = (entries: any[], word: RegExp) =>
  entries.some((e) => e.type === "assistant" && (e.message?.content ?? []).some((b: any) => b?.type === "text" && word.test(b.text)));

// A Claude Code session in a terminal: a pty, the way the owner runs it.
// Lines on its stdin: "exit" types /exit.
const PTY = `
import os, pty, sys, time, select, fcntl, termios, struct
cwd, name, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.environ["TERM"] = "xterm-256color"
    for k in list(os.environ):
        if k.startswith("CLAUDE_CODE_") or k in ("CLAUDECODE", "PALOALLY_SESSION", "TMUX", "TMUX_PANE"): del os.environ[k]
    os.execvp("claude", ["claude", "--model", "haiku", "--permission-mode", "default", "-n", name, prompt])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
print(pid, flush=True)
while True:
    r, _, _ = select.select([fd, sys.stdin], [], [], 0.2)
    if fd in r:
        try: os.read(fd, 65536)
        except OSError: break
    if sys.stdin in r:
        line = sys.stdin.readline().strip()
        if line == "exit":
            os.write(fd, b"/exit"); time.sleep(0.4); os.write(fd, b"\\r")
        elif not line:
            break
    try:
        if os.waitpid(pid, os.WNOHANG)[0]: break
    except ChildProcessError: break
`;

d("live: Pals run by the host", () => {
  const paths = tmpPaths();
  const scratch = realpathSync(process.env.PALOALLY_LIVE_DIR ?? join(paths.root, ".."));
  const tag = Math.random().toString(36).slice(2, 6);
  const projects = { bg: "", term: "", palo: "", recent: "" };
  // (bun runs a skipped describe's body too: no folders then, as nothing would remove them)
  for (const k of Object.keys(projects) as (keyof typeof projects)[]) projects[k] = LIVE ? realpathSync(mkdtempSync(join(scratch, `pal-live-${k}-`))) : "";
  const claudeDir = claudeConfigDir();
  const cli = new RealClaudeCli();
  const helperExe = findHelper(helperCandidates(paths.root, process.env.PALOALLY_HELPER_APP ?? resolve(import.meta.dir, "../helper/build", HELPER_APP)));
  const paloName = `palo-live-${tag}`;
  const timings: Record<string, number> = {};
  const facts: Record<string, unknown> = { helper: helperExe ? "PaloAlly Helper" : "direct" };
  const shorts = new Set<string>();
  const ptys: ChildProcess[] = [];
  const hubs: Hub[] = [];
  let paloQuery: ReturnType<typeof query> | null = null;
  let paloSidSeen = "";
  let paloInput: { push: (m: SDKUserMessage) => void; end: () => void } | null = null;

  const palsDeps: Partial<PalsDeps> = {
    driver: new ClaudeCodeDriver(),
    palMode: () => "default", // a mode that asks
    palModel: () => "haiku",
    paloName: () => paloName,
    helperApp: () => (helperExe ? resolve(helperExe, "../../..") : undefined),
    launchMode: () => (helperExe ? "auto" : "direct"),
    log: (s) => logs.push(s),
  };
  const logs: string[] = [];

  function makeHubLive(): { hub: Hub; events: { event: string; data: any }[] } {
    const hub = new Hub({
      paths,
      config: testConfig((c) => (c.settings.assistantName = "Palo")),
      driver: new FakeDriver(), // the assistant itself isn't needed here
      pushers: [new RecordingPusher()],
      log: (s) => logs.push(s),
      claudeDir,
      sessions: { claudeDir, cli, away: new AwayDetector(() => null, Date.now, () => false) },
      pals: palsDeps,
    });
    const events: { event: string; data: any }[] = [];
    hub.bus.on((event, data) => events.push({ event, data }));
    hubs.push(hub);
    // Only the Pals' own checks: never sessions.start() (it would refresh the global hooks).
    hub.pals.start();
    return { hub, events };
  }

  let { hub, events } = makeHubLive();
  let bgPal: Pal;
  let termPal: Pal;
  let bgSid = "";
  let termSid = "";
  let recentSid = "";
  let printSid = "";
  const palMessages = (id: string) => events.filter((e) => e.event === "chat.message" && e.data.pal === id).map((e) => e.data);

  // Anything a Pal asks while the test isn't looking at it is allowed (SendMessage may ask).
  const autoAllow = setInterval(() => {
    for (const a of hub.approvals.listPending()) if (a.source?.kind === "pal" && a.tool !== "Bash") hub.approvals.answer(a.id, true, "test");
  }, 200);

  afterAll(async () => {
    clearInterval(autoAllow);
    for (const h of hubs) await h.pals.stopAndWait().catch(() => {});
    for (const h of hubs) h.stop();
    paloInput?.end();
    paloQuery?.close();
    for (const p of ptys) if (p.exitCode === null) p.kill("SIGKILL");
    for (const s of shorts) {
      await cli.stop(s).catch(() => {});
      const env = await loginEnv();
      spawnSync(findClaude(env) ?? "claude", ["rm", s], { env, timeout: 20_000 });
    }
    // what it cost (from the transcripts, before they go)
    const meter = new SpendMeter(claudeDir);
    const day = new Date().toISOString().slice(0, 10);
    const spent = (cwd: string, sid: string) => (sid ? meter.spentOn(cwd, sid, day, "UTC") : 0);
    const paloSid = readRegistry(join(claudeDir, "sessions")).find((e) => e.name === paloName)?.sessionId ?? paloSidSeen;
    facts.costUsd = Number((spent(projects.bg, bgSid) + spent(projects.term, termSid) + spent(projects.palo, paloSid)).toFixed(3));
    facts.recentCostUsd = Number((spent(projects.recent, recentSid) + spent(projects.recent, printSid)).toFixed(3));
    // what Claude Code kept for the test folders
    for (const dir of Object.values(projects)) {
      const proj = join(claudeDir, "projects", resolve(dir).replace(/[^A-Za-z0-9]/g, "-"));
      if (existsSync(proj)) rmSync(proj, { recursive: true, force: true });
      rmSync(dir, { recursive: true, force: true });
    }
    for (const s of shorts) rmSync(join(claudeDir, "jobs", s), { recursive: true, force: true });
    console.log(`[live] ${JSON.stringify(facts)}`);
    console.log(`[live] timings ms: ${JSON.stringify(timings)}`);
  });

  test(
    "a real background session becomes a Pal within 10 seconds: stopped first, resumed by the host under its name, its context intact",
    async () => {
      const env = await loginEnv();
      const claude = findClaude(env)!;
      const name = `live-bg-${tag}`;
      const out = spawnSync(claude, ["--bg", "-n", name, "--model", "haiku", "--permission-mode", "default", "Remember the codeword 'apricot'. Reply with exactly: ready"], { cwd: projects.bg, env, encoding: "utf8", timeout: 60_000 });
      const short = parseBackgrounded(`${out.stdout}\n${out.stderr}`);
      expect(short).toBeTruthy();
      shorts.add(short!);
      bgSid = (await waitFor("its session id", async () => (await cli.agents()).find((a) => a.id === short)?.sessionId))!;
      await waitFor("its first answer", () => replied(transcriptEntries(claudeDir, projects.bg, bgSid), /ready/i), 90_000, 500);
      const t0 = Date.now();
      const r = await hub.pals.adopt(bgSid, "test");
      timings.adoptBackground = Date.now() - t0;
      expect("pal" in r).toBe(true);
      bgPal = (r as { pal: Pal }).pal;
      expect(bgPal).toMatchObject({ name, cwd: projects.bg, sessionId: bgSid, status: "idle", createdBy: "owner" });
      expect(timings.adoptBackground).toBeLessThan(10_000);
      // the background job is stopped; the one process on the transcript is the Pal's
      expect((await cli.agents()).find((a) => a.id === short)?.pid).toBeUndefined();
      const pid = hub.pals.get(bgPal.id)!.pid!;
      expect(pid).toBeGreaterThan(0);
      const holders = readRegistry(join(claudeDir, "sessions")).filter((e) => e.sessionId === bgSid);
      await waitFor("its registry entry", () => readRegistry(join(claudeDir, "sessions")).some((e) => e.sessionId === bgSid && e.pid === pid), 20_000);
      expect(holders.every((e) => e.pid === pid)).toBe(true);
      // who macOS holds responsible for it
      if (helperExe) {
        const responsible = Number(spawnSync(helperExe, ["--check", String(pid)], { encoding: "utf8" }).stdout.trim());
        const comm = spawnSync("ps", ["-o", "comm=", "-p", String(responsible)], { encoding: "utf8" }).stdout.trim();
        facts.responsible = comm;
        expect(comm).toContain("PaloAllyHelper");
      }
    },
    T,
  );

  test(
    "the owner's words go in as the owner's (origin human in the transcript) and the answer streams to the app",
    async () => {
      const sent = await hub.pals.send(bgPal.id, "What is the codeword I asked you to remember? Reply with just the word.");
      const reply = await waitFor("its answer", () => palMessages(bgPal.id).find((m) => m.role === "assistant" && /apricot/i.test(m.text)), 120_000);
      expect(events.some((e) => e.event === "chat.delta" && e.data.pal === bgPal.id && e.data.id === reply.id)).toBe(true);
      const mine = await waitFor("its line in the transcript", () => transcriptEntries(claudeDir, projects.bg, bgSid).find((e) => e.uuid === sent.id), 20_000);
      expect(mine.origin).toEqual({ kind: "human" });
      expect(mine.message.content).toBe("What is the codeword I asked you to remember? Reply with just the word.");
      // the app reads the same ids back from history
      const { messages } = await hub.pals.history(bgPal.id);
      expect(messages.some((m) => m.id === sent.id && m.role === "user")).toBe(true);
      expect(messages.some((m) => m.id === reply.id && m.role === "assistant")).toBe(true);
    },
    T,
  );

  test(
    "its permission prompt is a card on the phone; allowed, the command runs within a second",
    async () => {
      void hub.pals.send(bgPal.id, "Use the Bash tool to run exactly this command: touch pal-live-ok.txt   Then reply with exactly: touched");
      const card = await waitFor("the card", () => hub.approvals.listPending().find((a) => a.source?.id === bgPal.id && a.tool === "Bash"), 120_000);
      expect(card.source).toEqual({ kind: "pal", id: bgPal.id, name: bgPal.name });
      expect(card.detail).toContain("touch pal-live-ok.txt");
      expect(hub.pals.list().find((p) => p.id === bgPal.id)).toMatchObject({ status: "waiting", pending: 1 });
      const t0 = Date.now();
      hub.approvals.answer(card.id, true, "app", false, "dev-live");
      await waitFor("the command to run", () => existsSync(join(projects.bg, "pal-live-ok.txt")), 60_000, 20);
      // when `touch` ran (the file's birth time), after the tap
      timings.allowToRun = Math.round(statSync(join(projects.bg, "pal-live-ok.txt")).birthtimeMs - t0);
      expect(timings.allowToRun).toBeLessThan(1_500);
      await waitFor("its reply", () => palMessages(bgPal.id).some((m) => m.role === "assistant" && /touched/i.test(m.text)), 120_000);
    },
    T,
  );

  test(
    "the assistant's SendMessage reaches the Pal (shown as the assistant's words) and the Pal answers it",
    async () => {
      const items: SDKUserMessage[] = [];
      const waiters: ((r: IteratorResult<SDKUserMessage>) => void)[] = [];
      let done = false;
      paloInput = {
        push: (m) => {
          const w = waiters.shift();
          if (w) w({ value: m, done: false });
          else items.push(m);
        },
        end: () => {
          done = true;
          for (const w of waiters.splice(0)) w({ value: undefined as never, done: true });
        },
      };
      const input: AsyncIterable<SDKUserMessage> = {
        [Symbol.asyncIterator]: () => ({
          next: () => (items.length ? Promise.resolve({ value: items.shift()!, done: false }) : done ? Promise.resolve({ value: undefined as never, done: true }) : new Promise((r) => waiters.push(r))),
        }),
      };
      const env = await loginEnv();
      paloQuery = query({
        prompt: input,
        options: {
          cwd: projects.palo,
          model: "haiku",
          permissionMode: "default", // the same class as the Pal's
          settingSources: [],
          extraArgs: { name: paloName },
          env: { ...env, PALOALLY_SESSION: "1" },
          canUseTool: async (_t, i) => ({ behavior: "allow", updatedInput: i }),
        },
      });
      void (async () => {
        try {
          for await (const _ of paloQuery!) void _;
        } catch {
          /* closed */
        }
      })();
      paloInput.push({
        type: "user",
        message: { role: "user", content: `Use the SendMessage tool (load it with ToolSearch first if needed) to send the session named "${bgPal.name}" exactly this message: "Please reply to me with SendMessage containing the single word: pong". Then reply with just: sent` },
        parent_tool_use_id: null,
      } as SDKUserMessage);
      const t0 = Date.now();
      const heard = await waitFor("the Pal to show the assistant's words", () => palMessages(bgPal.id).find((m) => m.role === "user" && m.from === "Palo" && /pong/.test(m.text)), 180_000, 250);
      timings.sendMessageToPal = Date.now() - t0;
      expect(heard.text).toContain("Please reply to me with SendMessage");
      // the Pal's answer lands in the assistant's session, from the Pal
      const paloEntry = await waitFor("the assistant's registry entry", () => readRegistry(join(claudeDir, "sessions")).find((e) => e.name === paloName));
      const paloSid = paloEntry.sessionId;
      paloSidSeen = paloSid;
      const back = await waitFor(
        "the Pal's answer to the assistant",
        () => transcriptEntries(claudeDir, projects.palo, paloSid).find((e) => e.type === "user" && e.origin?.kind === "peer" && e.origin?.name === bgPal.name && /pong/i.test(e.origin?.body ?? JSON.stringify(e.message?.content))),
        180_000,
        500,
      );
      timings.palAnswersAssistant = Date.now() - t0;
      expect(back.origin.name).toBe(bgPal.name);
    },
    T,
  );

  test(
    "a terminal session: adopting waits for /exit there (no second process meanwhile), then it's a Pal within 5 seconds, its context intact",
    async () => {
      const name = `live-term-${tag}`;
      const script = join(paths.root, "term_session.py");
      writeFileSync(script, PTY);
      const env = await loginEnv();
      const pty = spawn("python3", [script, projects.term, name, "Remember the codeword 'cobalt'. Reply with exactly: hello"], { env, stdio: ["pipe", "pipe", "inherit"] });
      ptys.push(pty);
      const entry = await waitFor("its registry entry", () => readRegistry(join(claudeDir, "sessions")).find((e) => e.name === name), 60_000, 250);
      termSid = entry.sessionId;
      await waitFor("its first answer", () => replied(transcriptEntries(claudeDir, projects.term, termSid), /hello/i), 120_000, 500);
      expect(await hub.pals.adopt(termSid, "test")).toEqual({ waiting: "exit-in-terminal" });
      await new Promise((r) => setTimeout(r, 2_000));
      // still only the terminal's process on it
      expect(readRegistry(join(claudeDir, "sessions")).filter((e) => e.sessionId === termSid).map((e) => e.pid)).toEqual([entry.pid]);
      expect(hub.pals.list().some((p) => p.sessionId === termSid)).toBe(false);
      expect((await hub.sessions.listFresh()).find((s) => s.id === termSid)?.adopting).toBe(true);
      pty.stdin!.write("exit\n");
      await waitFor("the terminal session to quit", () => {
        try {
          process.kill(entry.pid, 0);
          return false;
        } catch {
          return true;
        }
      }, 30_000, 50);
      const t0 = Date.now();
      termPal = await waitFor("the Pal", () => hub.pals.list().find((p) => p.sessionId === termSid && p.status === "idle"), 30_000, 50);
      timings.adoptAfterExit = Date.now() - t0;
      expect(timings.adoptAfterExit).toBeLessThan(5_000);
      await hub.pals.send(termPal.id, "What is the codeword I asked you to remember? Reply with just the word.");
      await waitFor("its answer", () => palMessages(termPal.id).some((m) => m.role === "assistant" && /cobalt/i.test(m.text)), 120_000);
    },
    T,
  );

  test(
    "always on: a Pal whose process is killed comes back; after the host restarts, every Pal comes back with its context",
    async () => {
      const pal = hub.pals.get(bgPal.id)!;
      const old = pal.pid!;
      process.kill(old, "SIGKILL");
      const t0 = Date.now();
      await waitFor("it to come back", () => pal.running && pal.pid !== old && hub.pals.list().find((p) => p.id === bgPal.id)?.status === "idle", 60_000, 100);
      timings.backAfterKill = Date.now() - t0;
      // the host stops (its processes end) and starts again
      await hub.pals.stopAndWait();
      hub.stop();
      expect(readRegistry(join(claudeDir, "sessions")).some((e) => e.sessionId === bgSid || e.sessionId === termSid)).toBe(false);
      ({ hub, events } = makeHubLive());
      const t1 = Date.now();
      await waitFor("every Pal back", () => hub.pals.list().length === 2 && hub.pals.list().every((p) => p.status === "idle"), 60_000, 100);
      timings.allBackAfterRestart = Date.now() - t1;
      await hub.pals.send(termPal.id, "And the codeword again? Reply with just the word.");
      await waitFor("its answer", () => palMessages(termPal.id).some((m) => m.role === "assistant" && /cobalt/i.test(m.text)), 120_000);
    },
    T,
  );

  test(
    "交还终端: the host's process is gone and the given line resumes it in the terminal with its context; 移出 takes the other out",
    async () => {
      const { resumeCommand } = await hub.pals.release(bgPal.id, "test");
      expect(resumeCommand).toBe(`cd ${projects.bg} && claude --resume ${bgSid}`);
      expect(readRegistry(join(claudeDir, "sessions")).some((e) => e.sessionId === bgSid)).toBe(false);
      const env = await loginEnv();
      const r = spawnSync(findClaude(env)!, ["-p", "--model", "haiku", "--resume", bgSid, "What is the codeword I asked you to remember? Reply with just the word."], {
        cwd: projects.bg,
        env,
        encoding: "utf8",
        timeout: 120_000,
      });
      expect(r.stdout.toLowerCase()).toContain("apricot");
      await hub.pals.remove(termPal.id, "test");
      expect(hub.pals.list()).toEqual([]);
      expect(readRegistry(join(claudeDir, "sessions")).some((e) => e.sessionId === termSid)).toBe(false);
      mkdirSync(join(paths.root, "done"), { recursive: true });
    },
    T,
  );

  test(
    "最近的对话: a terminal session quit with /exit is listed (a claude -p run isn't), and taken over at once with its context; the answer comes from it",
    async () => {
      const name = `recent-${tag}`;
      const script = join(paths.root, "term_session.py");
      writeFileSync(script, PTY);
      const env = await loginEnv();
      const pty = spawn("python3", [script, projects.recent, name, "Remember the codeword 'juniper'. Reply with exactly: noted"], { env, stdio: ["pipe", "pipe", "inherit"] });
      ptys.push(pty);
      const entry = await waitFor("its registry entry", () => readRegistry(join(claudeDir, "sessions")).find((e) => e.name === name), 60_000, 250);
      recentSid = entry.sessionId;
      await waitFor("its first answer", () => replied(transcriptEntries(claudeDir, projects.recent, recentSid), /noted/i), 120_000, 500);
      // while it runs, it's one of the others, not a recent one
      expect((await hub.pals.recent({ folder: projects.recent })).some((s) => s.sessionId === recentSid)).toBe(false);
      pty.stdin!.write("exit\n");
      await waitFor("the terminal session to quit", () => {
        try {
          process.kill(entry.pid, 0);
          return false;
        } catch {
          return true;
        }
      }, 30_000, 50);
      // a claude -p run in the same folder: programmatic, not listed
      const printed = spawnSync(findClaude(env)!, ["-p", "--model", "haiku", "--output-format", "json", "Reply with exactly: ok"], { cwd: projects.recent, env, encoding: "utf8", timeout: 120_000 });
      printSid = JSON.parse(printed.stdout).session_id;
      expect(printSid).toBeTruthy();
      const t0 = Date.now();
      const listed = await waitFor("it among the recent ones", async () => (await hub.pals.recent({ folder: projects.recent })).find((s) => s.sessionId === recentSid), 30_000, 1_000);
      timings.recentListed = Date.now() - t0;
      expect(listed).toMatchObject({ sessionId: recentSid, cwd: projects.recent, title: name });
      expect(listed.size).toBe(statSync(transcriptPath(claudeDir, projects.recent, recentSid)).size);
      expect((await hub.pals.recent({ folder: projects.recent })).map((s) => s.sessionId)).toEqual([recentSid]);
      expect(existsSync(transcriptPath(claudeDir, projects.recent, printSid))).toBe(true);
      // a fresh look at every conversation on this computer (read only)
      (hub.pals as any).recentList.invalidate();
      const t1 = Date.now();
      await hub.pals.recent();
      timings.recentFresh = Date.now() - t1;
      // taken over: no process to stop, resumed under its title
      const t2 = Date.now();
      const r = await hub.pals.adopt(recentSid, "test");
      timings.adoptEnded = Date.now() - t2;
      expect("pal" in r).toBe(true);
      const pal = (r as { pal: Pal }).pal;
      expect(pal).toMatchObject({ name, cwd: projects.recent, sessionId: recentSid, status: "idle", createdBy: "owner" });
      expect(timings.adoptEnded).toBeLessThan(10_000);
      expect((await hub.pals.recent({ folder: projects.recent })).some((s) => s.sessionId === recentSid)).toBe(false);
      // its conversation came with it, and it still knows the codeword
      const { messages } = await hub.pals.history(pal.id);
      expect(messages.some((m) => m.role === "user" && m.text.includes("juniper"))).toBe(true);
      expect(messages.some((m) => m.role === "assistant" && /noted/i.test(m.text))).toBe(true);
      await hub.pals.send(pal.id, "What is the codeword I asked you to remember? Reply with just the word.");
      await waitFor("its answer", () => palMessages(pal.id).some((m) => m.role === "assistant" && /juniper/i.test(m.text)), 120_000);
      // out of the list again, it's a recent one again
      await hub.pals.remove(pal.id, "test");
      expect(readRegistry(join(claudeDir, "sessions")).some((e) => e.sessionId === recentSid)).toBe(false);
      expect((await hub.pals.recent({ folder: projects.recent })).map((s) => s.sessionId)).toEqual([recentSid]);
    },
    T,
  );
});
