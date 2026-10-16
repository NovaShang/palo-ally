// Live: a Pal (a real Claude Code session on Haiku, started directly) gets an
// image and a file from the app, as pals-prd §15 has it: the image as an
// image block, the file put in its folder's .paloally/inbox and named in the
// words. It reads the file without a permission card (its mode is the
// default one, and every card is refused and counted). Costs real tokens
// (a few cents). Run with:
//   PALOALLY_LIVE_PAL_MEDIA=1 bun test test/palMedia.live.test.ts
//
// Everything runs in a temporary folder; the transcripts Claude Code kept
// for it are removed at the end. Claude Code's own settings, the owner's
// sessions and any running PaloAlly host are left alone.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { deflateSync } from "node:zlib";
import { AwayDetector } from "../src/away.ts";
import { RealClaudeCli } from "../src/ccCli.ts";
import { usageUsd } from "../src/ccSpend.ts";
import { claudeConfigDir } from "../src/handoffs.ts";
import { ClaudeCodeDriver } from "../src/harness/claude.ts";
import { Hub } from "../src/hub.ts";
import { FakeDriver } from "./fakeDriver.ts";
import { RecordingPusher, testConfig, tmpPaths } from "./helpers.ts";

const LIVE = process.env.PALOALLY_LIVE_PAL_MEDIA === "1";
const d = LIVE ? describe : describe.skip;
const T = 300_000;

async function waitFor<T>(what: string, f: () => T | undefined | null | false, ms = 180_000, every = 200): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = f();
    if (v) return v;
    await new Promise((r) => setTimeout(r, every));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** A solid-colour PNG, w×h. */
function png(w: number, h: number, [r, g, b]: [number, number, number]): Buffer {
  const table = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf: Buffer) => {
    let c = 0xffffffff;
    for (const x of buf) c = table[(c ^ x) & 0xff]! ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const sum = Buffer.alloc(4);
    sum.writeUInt32BE(crc(body));
    return Buffer.concat([len, body, sum]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // RGB
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: w }, () => [r, g, b]).flat())]);
  const raw = Buffer.concat(Array.from({ length: h }, () => row));
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

d("live: a Pal gets an image and a file from the app", () => {
  const paths = tmpPaths();
  const claudeDir = claudeConfigDir();
  const scratch = "/tmp/paloally-pal-media";
  if (LIVE) mkdirSync(scratch, { recursive: true });
  const project = LIVE ? realpathSync(mkdtempSync(join(scratch, "live-"))) : "";
  if (LIVE) {
    mkdirSync(join(project, ".claude"), { recursive: true });
    writeFileSync(join(project, ".claude", "settings.json"), JSON.stringify({ autoMemoryEnabled: false }));
  }
  const logs: string[] = [];
  const facts: Record<string, unknown> = {};
  const hub = new Hub({
    paths,
    config: testConfig((c) => (c.settings.assistantName = "Palo")),
    driver: new FakeDriver(),
    pushers: [new RecordingPusher()],
    log: (s) => logs.push(s),
    claudeDir,
    sessions: { claudeDir, cli: new RealClaudeCli(), away: new AwayDetector(() => null, Date.now, () => false) },
    pals: {
      driver: new ClaudeCodeDriver(),
      palMode: () => "default", // reads outside its folder would be a card
      palModel: () => "haiku",
      launchMode: () => "direct",
      paloName: () => `palo-media-${Math.random().toString(36).slice(2, 6)}`,
      log: (s) => logs.push(s),
    },
  });
  const events: { event: string; data: any }[] = [];
  hub.bus.on((event, data) => events.push({ event, data }));
  if (LIVE) hub.pals.start();
  // Every card is refused, and counted: reading the inbox must not need one.
  const cards: string[] = [];
  const refuse = setInterval(() => {
    for (const a of hub.approvals.listPending()) {
      cards.push(`${a.tool}: ${a.title}`);
      hub.approvals.answer(a.id, false, "test");
    }
  }, 100);
  let palId = "";
  let sessionId = "";

  afterAll(async () => {
    clearInterval(refuse);
    await hub.pals.stopAndWait().catch(() => {});
    hub.stop();
    if (!LIVE) return;
    const proj = join(claudeDir, "projects", resolve(project).replace(/[^A-Za-z0-9]/g, "-"));
    let usd = 0;
    for (const f of existsSync(proj) ? readdirSync(proj).filter((f) => f.endsWith(".jsonl")) : []) {
      for (const line of readFileSync(join(proj, f), "utf8").split("\n")) {
        if (!line.includes('"usage"')) continue;
        try {
          const e = JSON.parse(line);
          if (e.type === "assistant" && e.message?.usage) usd += usageUsd(e.message.model ?? "haiku", e.message.usage);
        } catch {
          /* a torn line */
        }
      }
    }
    facts.costUsd = Number(usd.toFixed(4));
    if (process.env.PALOALLY_LIVE_KEEP === "1") {
      console.log(`[live] kept ${proj} ${project}\n${logs.join("\n")}`);
      return;
    }
    if (existsSync(proj)) rmSync(proj, { recursive: true, force: true });
    for (const dir of ["file-history", "session-env", "todos"]) if (sessionId) rmSync(join(claudeDir, dir, sessionId), { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
    console.log(`[live] ${JSON.stringify(facts)}`);
  });

  test(
    "it sees the image's colour and reads the file from its inbox without a card; its page shows the message as sent",
    async () => {
      const pal = await (hub.pals as any).create({ name: "看图", cwd: project, duty: "你是测试用的 Pal。回答尽量短。", dailyUsd: 1 });
      palId = pal.id;
      sessionId = pal.rec.sessionId;
      await waitFor("the handover's turn", () => hub.pals.list().find((p) => p.id === palId)?.status === "idle");
      const img = hub.media.save("image/png", png(64, 64, [220, 20, 20]).toString("base64"));
      const up = hub.media.uploadChunk({ name: "暗号.txt", mediaType: "text/plain", offset: 0, data: Buffer.from("今天的暗号是 KIWI\n").toString("base64"), done: true });
      const file = hub.media.attachment((up as any).id)!;
      const from = events.length;
      const t0 = Date.now();
      const sent = await hub.pals.send(palId, "图片是什么颜色？再读附件文件，告诉我里面的暗号。一句话回答。", undefined, [img, file]);
      await waitFor("its answer", () => {
        const done = hub.pals.list().find((p) => p.id === palId)?.status === "idle";
        return done && events.slice(from).some((e) => e.event === "chat.message" && e.data.pal === palId && e.data.role === "assistant");
      });
      facts.turnMs = Date.now() - t0;
      const reply = events.slice(from).filter((e) => e.event === "chat.message" && e.data.pal === palId && e.data.role === "assistant").map((e) => e.data.text).join("\n");
      facts.reply = reply;
      facts.cards = cards;
      expect(existsSync(join(project, ".paloally", "inbox", file.id, "暗号.txt"))).toBe(true);
      expect(reply).toMatch(/红|red/i);
      expect(reply).toMatch(/KIWI/);
      expect(cards).toEqual([]);
      const page = await hub.pals.history(palId);
      const mine = page.messages.find((m) => m.id === sent.id);
      expect(mine).toMatchObject({ text: "图片是什么颜色？再读附件文件，告诉我里面的暗号。一句话回答。" });
      expect(mine?.attachments?.map((a) => a.id)).toEqual([img.id, file.id]);
    },
    T,
  );
});

test.if(!LIVE)("live Pal media test skipped (set PALOALLY_LIVE_PAL_MEDIA=1)", () => {});
