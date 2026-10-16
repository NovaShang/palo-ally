// Live: 回到这里重来 (docs/rewind-prd.md) on a real Claude Code session
// (Haiku) run as a Pal, started directly (not through PaloAlly Helper).
// Costs real tokens (about $0.10). Run with:
//   PALOALLY_LIVE_REWIND=1 bun test test/rewind.live.test.ts
//
// Two turns, the second changes a file; going back to before the second
// with the files puts the file back and the model no longer knows the second
// turn. Then a third turn and a compaction after it; going back to before
// the third (a compaction after the point) still works.
//
// Everything runs in a temporary folder; what Claude Code kept for it (the
// transcripts, the file backups) is removed at the end. Claude Code's own
// settings, the owner's sessions and any running PaloAlly host are left alone.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { AwayDetector } from "../src/away.ts";
import { RealClaudeCli } from "../src/ccCli.ts";
import { usageUsd } from "../src/ccSpend.ts";
import { claudeConfigDir, transcriptPath } from "../src/handoffs.ts";
import { ClaudeCodeDriver } from "../src/harness/claude.ts";
import { Hub } from "../src/hub.ts";
import { FakeDriver } from "./fakeDriver.ts";
import { RecordingPusher, testConfig, tmpPaths } from "./helpers.ts";

const LIVE = process.env.PALOALLY_LIVE_REWIND === "1";
const d = LIVE ? describe : describe.skip;
const T = 600_000;

async function waitFor<T>(what: string, f: () => T | undefined | null | false, ms = 180_000, every = 200): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = f();
    if (v) return v;
    await new Promise((r) => setTimeout(r, every));
  }
  throw new Error(`timed out waiting for ${what}`);
}

d("live: going back to an earlier message in a Pal", () => {
  const paths = tmpPaths();
  const claudeDir = claudeConfigDir();
  const scratch = "/tmp/paloally-rewind";
  if (LIVE) mkdirSync(scratch, { recursive: true });
  const project = LIVE ? realpathSync(mkdtempSync(join(scratch, "live-"))) : "";
  // Claude Code's auto memory is outside the conversation (a rewind leaves
  // it, as it leaves files on the assistant's side): off here, so what the
  // model knows is the conversation's alone.
  if (LIVE) {
    mkdirSync(join(project, ".claude"), { recursive: true });
    writeFileSync(join(project, ".claude", "settings.json"), JSON.stringify({ autoMemoryEnabled: false }));
  }
  const sessions = new Set<string>();
  const facts: Record<string, unknown> = {};
  const logs: string[] = [];
  const hub = new Hub({
    paths,
    config: testConfig((c) => (c.settings.assistantName = "Palo")),
    driver: new FakeDriver(), // the assistant itself isn't needed here
    pushers: [new RecordingPusher()],
    log: (s) => logs.push(s),
    claudeDir,
    sessions: { claudeDir, cli: new RealClaudeCli(), away: new AwayDetector(() => null, Date.now, () => false) },
    pals: {
      driver: new ClaudeCodeDriver(),
      palMode: () => "acceptEdits", // edits in its folder go ahead without asking
      palModel: () => "haiku",
      launchMode: () => "direct",
      paloName: () => `palo-rewind-${Math.random().toString(36).slice(2, 6)}`,
      log: (s) => logs.push(s),
    },
  });
  const events: { event: string; data: any }[] = [];
  hub.bus.on((event, data) => events.push({ event, data }));
  if (LIVE) hub.pals.start();
  // Anything it asks anyway is allowed (the test isn't looking at cards).
  const autoAllow = setInterval(() => {
    for (const a of hub.approvals.listPending()) hub.approvals.answer(a.id, true, "test");
  }, 200);
  let palId = "";
  const note = () => (existsSync(join(project, "note.txt")) ? readFileSync(join(project, "note.txt"), "utf8").trim() : "(none)");

  /** The owner's words; resolves with the Pal's last reply once its turn is over. */
  // `done`: when the turn is over, if not at its reply (a /compact has none).
  async function say(text: string, done?: () => boolean): Promise<{ id: string; reply: string }> {
    const from = events.length;
    const { id } = await hub.pals.send(palId, text);
    const pal = hub.pals.get(palId)!;
    sessions.add(pal.rec.sessionId);
    const replies = () => events.slice(from).filter((e) => e.event === "chat.message" && e.data.pal === palId && e.data.role === "assistant");
    await waitFor(`the turn after 「${text}」`, () => (done ? done() : replies().length > 0) && hub.pals.list().find((p) => p.id === palId)?.status === "idle");
    return { id, reply: (replies().at(-1)?.data.text as string) ?? "" };
  }

  afterAll(async () => {
    clearInterval(autoAllow);
    const pal = palId ? hub.pals.get(palId) : undefined;
    if (pal) {
      sessions.add(pal.rec.sessionId);
      for (const s of pal.rec.formerSessions ?? []) sessions.add(s);
    }
    await hub.pals.stopAndWait().catch(() => {});
    hub.stop();
    if (!LIVE) return;
    // what Claude Code kept for the test folder
    const proj = join(claudeDir, "projects", resolve(project).replace(/[^A-Za-z0-9]/g, "-"));
    // What it cost: every API reply once (a fork copies the ones before it).
    const replies = new Map<string, number>();
    for (const f of existsSync(proj) ? readdirSync(proj, { recursive: true }).map(String).filter((f) => f.endsWith(".jsonl")) : []) {
      for (const line of readFileSync(join(proj, f), "utf8").split("\n")) {
        if (!line.includes('"usage"')) continue;
        try {
          const e = JSON.parse(line);
          if (e.type === "assistant" && e.message?.id && e.message.usage) replies.set(e.message.id, usageUsd(e.message.model ?? "haiku", e.message.usage));
        } catch {
          /* a torn line */
        }
      }
    }
    facts.costUsd = Number([...replies.values()].reduce((a, b) => a + b, 0).toFixed(4));
    facts.replies = replies.size;
    // PALOALLY_LIVE_KEEP=1: leave them, and say what the host did (looking into a failure).
    if (process.env.PALOALLY_LIVE_KEEP === "1") {
      console.log(`[live] kept ${proj} ${project}\n${logs.join("\n")}\n${JSON.stringify(hub.audit.tail(30))}`);
      return;
    }
    if (existsSync(proj)) rmSync(proj, { recursive: true, force: true });
    for (const s of sessions) {
      for (const dir of ["file-history", "session-env", "todos"]) rmSync(join(claudeDir, dir, s), { recursive: true, force: true });
    }
    rmSync(project, { recursive: true, force: true });
    console.log(`[live] ${JSON.stringify(facts)}`);
  });

  test(
    "two turns, the second changes a file; back to before the second with the files: the file is as the first left it, and the model doesn't know the second turn",
    async () => {
      const pal = await (hub.pals as any).create({ name: "重来", cwd: project, duty: "你是测试用的 Pal。只按主人说的做，回答尽量短，一句话以内。", dailyUsd: 2 });
      palId = pal.id;
      await waitFor("the handover's turn", () => hub.pals.list().find((p) => p.id === palId)?.status === "idle");
      sessions.add(pal.rec.sessionId);
      const t0 = Date.now();
      await say("暗号是 APPLE。在当前目录建 note.txt，内容只有一行：one");
      expect(note()).toBe("one");
      const second = await say("暗号改成 BANANA。把 note.txt 的内容改成一行：two");
      expect(note()).toBe("two");
      const before = hub.pals.get(palId)!.rec.sessionId;
      facts.turnsMs = Date.now() - t0;

      expect(hub.pals.canRestoreFiles(palId, second.id)).toEqual({ canRestoreFiles: true });
      const t1 = Date.now();
      const r = await hub.pals.rewind(palId, second.id, { restoreFiles: true, by: "test" });
      facts.rewindMs = Date.now() - t1;
      expect(r).toEqual({ text: "暗号改成 BANANA。把 note.txt 的内容改成一行：two", filesRestored: true });
      expect(note()).toBe("one");
      const after = hub.pals.get(palId)!.rec;
      expect(after.sessionId).not.toBe(before);
      expect(after.rewind?.from).toBe(before);
      // its page: up to the cut
      const page = await hub.pals.history(palId);
      expect(page.messages.some((m) => m.id === second.id)).toBe(false);
      // the old session keeps everything
      expect(readFileSync(transcriptPath(claudeDir, project, before), "utf8")).toContain(second.id);

      const asked = await say("现在的暗号是哪个英文单词？只回答那个单词。");
      facts.answerAfterRewind = asked.reply;
      expect(asked.reply).toMatch(/APPLE/i);
      expect(asked.reply).not.toMatch(/BANANA/i);
      // Claude Code wrote the fork: from now on it's the Pal's own session
      expect(existsSync(transcriptPath(claudeDir, project, after.sessionId))).toBe(true);
      expect(hub.pals.get(palId)!.pendingRewind()).toBeUndefined();
      expect((await hub.pals.history(palId)).messages.some((m) => m.id === second.id)).toBe(false);
    },
    T,
  );

  test(
    "a compaction after the point: back to before a message that came before it, and the conversation goes on from there",
    async () => {
      expect(palId).not.toBe("");
      const third = await say("暗号改成 CHERRY。只回答 好。");
      const transcript = () => readFileSync(transcriptPath(claudeDir, project, hub.pals.get(palId)!.rec.sessionId), "utf8");
      await say("/compact", () => transcript().includes('"compact_boundary"'));
      facts.compacted = true;
      const r = await hub.pals.rewind(palId, third.id, { by: "test" });
      expect(r.filesRestored).toBe(false);
      const asked = await say("现在的暗号是哪个英文单词？只回答那个单词。");
      facts.answerAfterCompactRewind = asked.reply;
      expect(asked.reply).toMatch(/APPLE/i);
      expect(asked.reply).not.toMatch(/CHERRY/i);
    },
    T,
  );
});

test.if(!LIVE)("live rewind tests skipped (set PALOALLY_LIVE_REWIND=1)", () => {});
