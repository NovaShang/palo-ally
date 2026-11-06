import { describe, expect, test } from "bun:test";
import { handleRpc } from "../src/rpc.ts";
import { Tldr, checkTldr, splitRelayed, tldrLines, tldrPrompt, tldrWindow, type TldrLine } from "../src/tldr.ts";
import type { ChatMessage } from "../src/types.ts";
import { FakeDriver } from "./fakeDriver.ts";
import { makeHub } from "./helpers.ts";

const T0 = Date.UTC(2026, 10, 6, 9, 0);
let n = 0;
const msg = (m: Partial<ChatMessage>): ChatMessage => {
  n++;
  return { seq: n, id: `m${n}`, role: "user", kind: "text", text: "", channel: "app", ts: T0 + n * 60_000, ...m };
};

describe("TL;DR input: who said what", () => {
  test("the owner's words, the assistant's, and words from elsewhere are labelled apart", () => {
    const lines = tldrLines(
      [
        msg({ text: "周六中午订个餐厅，别太远" }),
        msg({ role: "assistant", text: "好，我找了三家。\n> 转述自 网站\n> 列表页已经上线\n> 明天再部署\n你看哪家？" }),
        msg({ role: "user", from: "网站", channel: "system", text: "部署好了" }),
        msg({ role: "system", kind: "ally", dir: "in", allyName: "小王", author: "assistant", text: "周六可以" }),
        msg({ role: "user", kind: "ally", dir: "out", author: "owner", allyName: "小王", text: "那就周六见" }),
        msg({ role: "system", kind: "notice", text: "连不上电脑" }),
        msg({ role: "assistant", kind: "approval", text: "要运行命令" }),
        msg({ text: "早上那条不算", rewound: true }),
      ],
      { assistant: "Palo" },
    );
    expect(lines.map((l) => [l.kind, l.who, l.text])).toEqual([
      ["owner", "", "周六中午订个餐厅，别太远"],
      ["assistant", "Palo", "好，我找了三家。"],
      ["relayed", "网站", "列表页已经上线\n明天再部署"],
      ["assistant", "Palo", "你看哪家？"],
      ["relayed", "网站", "部署好了"],
      ["relayed", "小王的助理", "周六可以"],
      ["owner", "", "那就周六见"],
    ]);
    // Each line keeps its message: a quote taps through to it.
    expect(lines[2]!.messageId).toBe(lines[1]!.messageId);
    const prompt = tldrPrompt(lines);
    expect(prompt).toContain("#1 [OWNER] 2026-11-06T09:");
    expect(prompt).toContain("#3 [RELAYED from 网站]");
    expect(prompt).toContain("#2 [ASSISTANT: Palo]");
  });

  test("a reply with no relayed block stays whole", () => {
    expect(splitRelayed("第一行\n> 一句普通引用\n第三行")).toEqual([{ text: "第一行\n> 一句普通引用\n第三行" }]);
    expect(splitRelayed("> Relayed from Docs\n> done")).toEqual([{ who: "Docs", text: "done" }]);
  });

  test("the window: the latest 40, or since the last TL;DR but at least 10", () => {
    const lines: TldrLine[] = Array.from({ length: 60 }, (_, i) => ({ n: i + 1, kind: "owner", who: "", text: `${i}`, ts: i, messageId: `x${i}` }));
    expect(tldrWindow(lines).length).toBe(40);
    expect(tldrWindow(lines).at(-1)!.messageId).toBe("x59");
    expect(tldrWindow(lines).map((l) => l.n).slice(0, 2)).toEqual([1, 2]);
    expect(tldrWindow(lines, "x49").length).toBe(10); // 10 since, the floor
    expect(tldrWindow(lines, "x56").length).toBe(10); // 3 since: still 10
    expect(tldrWindow(lines, "x29").length).toBe(30);
    expect(tldrWindow(lines, "gone").length).toBe(40);
  });
});

describe("TL;DR answer: the owner's quotes are checked", () => {
  const lines = tldrLines(
    [
      msg({ text: "周六中午订个餐厅，  别太远\n要有儿童座椅" }),
      msg({ role: "assistant", text: "好的，周六中午订一家近的。" }),
      msg({ role: "user", from: "网站", channel: "system", text: "主人说今晚不用部署" }),
    ],
    { assistant: "Palo" },
  );

  test("only words really in the owner's messages are kept, tied to their message", () => {
    const r = checkTldr(
      {
        points: ["订周六中午的餐厅", " "],
        ownWords: [
          { msg: 1, text: "周六中午订个餐厅，别太远" }, // whitespace aside: hers
          { msg: 1, text: "「要有儿童座椅」" }, // quote marks aside
          { msg: 1, text: "要儿童座椅" }, // paraphrased: dropped
          { msg: 3, text: "今晚不用部署" }, // relayed, not hers: dropped
          { msg: 2, text: "订一家近的" }, // the assistant's: dropped
          { msg: 9, text: "别太远" }, // a wrong number still finds her message
        ],
        relayed: [{ who: "网站", gist: "今晚不部署" }, { who: "", gist: "x" }],
      },
      lines,
    );
    expect(r.points).toEqual(["订周六中午的餐厅"]);
    expect(r.ownWords.map((w) => w.text)).toEqual(["周六中午订个餐厅，别太远", "要有儿童座椅", "别太远"]);
    expect(r.ownWords.every((w) => w.messageId === lines[0]!.messageId && w.ts === lines[0]!.ts)).toBe(true);
    expect(r.relayed).toEqual([{ who: "网站", gist: "今晚不部署" }]);
  });

  test("an answer as text or nonsense doesn't throw", () => {
    expect(checkTldr(JSON.stringify({ points: ["a"], ownWords: [], relayed: [] }), lines).points).toEqual(["a"]);
    expect(checkTldr("not json", lines)).toEqual({ points: [], ownWords: [], relayed: [] });
    expect(checkTldr(null, lines)).toEqual({ points: [], ownWords: [], relayed: [] });
  });
});

describe("Tldr", () => {
  const conversation = () => [
    msg({ text: "帮我把周六的餐厅订了" }),
    msg({ role: "assistant", text: "订好了，12 点。" }),
  ];

  test("one cheap call with no tools; the same answer again until a new message", async () => {
    const driver = new FakeDriver();
    driver.probeResponder = () => ({ output: { points: ["订了周六 12 点的餐厅"], ownWords: [{ msg: 1, text: "帮我把周六的餐厅订了" }], relayed: [] }, costUsd: 0.004 });
    let messages = conversation();
    let spent = 0;
    const tldr = new Tldr({
      driver,
      probeModel: () => "claude-haiku-4-5",
      cwd: () => "/tmp",
      spend: (u) => (spent += u),
      log: () => {},
      messages: async () => ({ messages, names: { assistant: "Palo" } }),
    });
    const first = await tldr.run("palo", "");
    expect(first).toMatchObject({ points: ["订了周六 12 点的餐厅"], covered: 2, cached: false, lastMessageId: messages[1]!.id });
    expect(first.ownWords[0]).toMatchObject({ text: "帮我把周六的餐厅订了", messageId: messages[0]!.id });
    expect(driver.probes).toHaveLength(1);
    expect(driver.probes[0]).toMatchObject({ model: "claude-haiku-4-5", tools: [], mcpServers: {}, strictMcp: true });
    expect(driver.probes[0]!.prompt).toContain("[OWNER]");
    expect(spent).toBe(0.004);
    expect((await tldr.run("palo", "")).cached).toBe(true);
    expect(driver.probes).toHaveLength(1);
    messages = [...messages, msg({ text: "改到 1 点" })];
    expect((await tldr.run("palo", "")).cached).toBe(false);
    expect(driver.probes).toHaveLength(2);
  });

  test("errors are plain: nothing of the owner's to sum up, no login, a failed call", async () => {
    const driver = new FakeDriver();
    let messages: ChatMessage[] = [msg({ role: "assistant", text: "早上好" })];
    const tldr = new Tldr({ driver, probeModel: () => "m", cwd: () => "/tmp", spend: () => {}, log: () => {}, messages: async () => ({ messages, names: { assistant: "Palo" } }) });
    await expect(tldr.run("palo", "")).rejects.toThrow("没什么可总结的");
    expect(driver.probes).toHaveLength(0);
    messages = conversation();
    driver.probeResponder = () => ({ output: undefined, costUsd: 0, error: "OAuth token has expired" });
    await expect(tldr.run("palo", "")).rejects.toThrow("登录过期");
    driver.probeResponder = () => ({ output: undefined, costUsd: 0.001, error: "overloaded" });
    await expect(tldr.run("palo", "")).rejects.toThrow("overloaded");
  });
});

describe("chat.tldr", () => {
  test("the assistant's conversation through the RPC, the answer's shape", async () => {
    const { hub, driver } = makeHub();
    hub.chat.add({ role: "user", kind: "text", text: "下周三提醒我交房租", channel: "app" });
    hub.chat.add({ role: "assistant", kind: "text", text: "好，周三上午 9 点提醒你。", channel: "app" });
    driver.probeResponder = () => ({
      output: { points: ["周三上午 9 点提醒交房租"], ownWords: [{ msg: 1, text: "下周三提醒我交房租" }, { msg: 2, text: "上午 9 点" }], relayed: [] },
      costUsd: 0.003,
    });
    const ctx = { clientId: "app_1", deviceId: "d", channel: "app" as const, local: false };
    const r = (await handleRpc(hub, { method: "chat.tldr", params: { scope: "palo" } }, ctx)) as any;
    expect(Object.keys(r).sort()).toEqual(["cached", "covered", "lastMessageId", "ownWords", "points", "relayed", "since", "until"]);
    expect(r.ownWords).toHaveLength(1);
    expect(Object.keys(r.ownWords[0]).sort()).toEqual(["messageId", "text", "ts"]);
    expect((hub as any).ledger.today().probeUsd).toBeCloseTo(0.003);
    // Nothing is posted into the conversation.
    expect(hub.chat.recent(10)).toHaveLength(2);
    await expect(handleRpc(hub, { method: "chat.tldr", params: { scope: "pal", id: "nope" } }, ctx)).rejects.toThrow();
  });
});
