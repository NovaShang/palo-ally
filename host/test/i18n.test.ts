import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { ownerDisplayName } from "../src/allies.ts";
import { allyTurnHeader, approvalCardText, budgetNotice, friendlyError, notifyResultText, offlineNotice, questionCardText, statusReply } from "../src/copy.ts";
import { BEHAVIORS, behaviorPrompt, localizeDefaultHome, scaffoldHome, setSoulName } from "../src/home.ts";
import { DICTIONARIES, LANGS, getLang, parseLocale, setLang, systemLanguage, t, tIn, type Lang } from "../src/i18n/index.ts";
import { handleRpc, type RpcContext } from "../src/rpc.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { cleanup, makeHub, testConfig, tick } from "./helpers.ts";
import { Paths } from "../src/config.ts";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CJK = /[一-鿿]/;
const placeholders = (s: string) => [...new Set([...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]!))].sort();

afterEach(() => setLang("zh"));
afterAll(() => setLang("zh"));

const app = (deviceId = "dev1"): RpcContext => ({ clientId: `app_1_${deviceId}`, deviceId, channel: "app", local: false });
const cli: RpcContext = { clientId: "cli", channel: "cli", local: true };

describe("dictionaries", () => {
  test("every key has both languages, filled, with the same placeholders", () => {
    const zhKeys = Object.keys(DICTIONARIES.zh).sort();
    expect(Object.keys(DICTIONARIES.en).sort()).toEqual(zhKeys);
    expect(zhKeys.length).toBeGreaterThan(100);
    for (const k of zhKeys) {
      const z = (DICTIONARIES.zh as Record<string, string>)[k]!;
      const e = (DICTIONARIES.en as Record<string, string>)[k]!;
      expect(typeof z === "string" && z.length > 0).toBe(true);
      expect(typeof e === "string" && e.length > 0).toBe(true);
      expect(placeholders(e), `placeholders of ${k}`).toEqual(placeholders(z));
    }
  });

  test("English entries carry no Chinese", () => {
    for (const [k, v] of Object.entries(DICTIONARIES.en)) {
      // the few Chinese tokens the assistant is told to look for stay as they are
      const stripped = v.replace(/\[来自微信\]|\[图片\]|\[文件\]|\[语音转文字\]|\[引用[:：]?/g, "");
      expect(CJK.test(stripped), `${k}: ${v}`).toBe(false);
    }
  });

  test("t fills {params} and follows setLang", () => {
    expect(t("chat.stopReply")).toBe("好，手上的事都停下了。");
    setLang("en");
    expect(t("chat.stopReply")).toBe("OK, everything is stopped.");
    expect(t("chat.statusReply", { state: "Idle", running: 2, pending: 1 })).toBe("Idle; 2 running, 1 waiting for you.");
    expect(tIn("zh", "chat.approved")).toBe("好，已同意。");
    expect(getLang()).toBe("en");
  });
});

describe("which language the host speaks", () => {
  test("parseLocale: zh* is zh, anything else en, nothing is null", () => {
    for (const l of ["zh", "zh-Hans", "zh-Hans-CN", "zh_TW", "ZH-hant"]) expect(parseLocale(l)).toBe("zh");
    for (const l of ["en", "en-US", "fr-FR", "ja", "de_DE"]) expect(parseLocale(l)).toBe("en");
    for (const l of ["", "  ", null, undefined, 3]) expect(parseLocale(l)).toBeNull();
  });

  test("the first owner device that reports a locale sets the language; later ones and the cli don't", async () => {
    const { hub, paths } = makeHub();
    expect(hub.config.settings.language).toBe("");
    // no locale, or not from the app: nothing happens
    await handleRpc(hub, { method: "hello", params: { client: "ios" } }, app());
    await handleRpc(hub, { method: "hello", params: { locale: "en-US" } }, cli);
    expect(hub.config.settings.language).toBe("");
    const r1 = (await handleRpc(hub, { method: "hello", params: { client: "ios", locale: "en-GB" } }, app("a"))) as any;
    expect(hub.config.settings.language).toBe("en");
    expect(r1.language).toBe("en");
    expect(getLang()).toBe("en");
    // a second device with another locale doesn't override
    const r2 = (await handleRpc(hub, { method: "hello", params: { locale: "zh-Hans-CN" } }, app("b"))) as any;
    expect(hub.config.settings.language).toBe("en");
    expect(r2.language).toBe("en");
    // it is saved
    expect(JSON.parse(readFileSync(paths.config, "utf8")).settings.language).toBe("en");
    cleanup(paths);
  });

  test("a zh locale picks zh; an unset host falls back to the computer's language", async () => {
    const a = makeHub();
    await handleRpc(a.hub, { method: "hello", params: { locale: "zh-Hans" } }, app());
    expect(a.hub.config.settings.language).toBe("zh");
    cleanup(a.paths);

    process.env.PALOALLY_LANG = "en";
    try {
      const b = makeHub();
      expect(b.hub.language()).toBe("en");
      expect(getLang()).toBe("en");
      expect(systemLanguage()).toBe("en");
      // hello without a locale leaves the setting unset
      const r = (await handleRpc(b.hub, { method: "hello", params: {} }, app())) as any;
      expect(b.hub.config.settings.language).toBe("");
      expect(r.language).toBe("en");
      cleanup(b.paths);
    } finally {
      process.env.PALOALLY_LANG = "zh";
    }
  });

  test("a language already set is not overridden by hello", async () => {
    const { hub, paths } = makeHub({ config: testConfig((c) => (c.settings.language = "zh")) });
    await handleRpc(hub, { method: "hello", params: { locale: "en-US" } }, app());
    expect(hub.config.settings.language).toBe("zh");
    cleanup(paths);
  });

  test("settings.update (what `paloally settings language en|zh` calls) changes it, validated", async () => {
    const { hub, paths, events } = makeHub();
    const r = (await handleRpc(hub, { method: "settings.update", params: { patch: { language: "en" } } }, cli)) as any;
    expect(r.settings.language).toBe("en");
    expect(getLang()).toBe("en");
    expect(events.some((e) => e.event === "settings.updated" && e.data.language === "en")).toBe(true);
    await handleRpc(hub, { method: "settings.update", params: { patch: { language: "zh" } } }, cli);
    expect(getLang()).toBe("zh");
    // errors are in the language in force
    setLang("en");
    await expect(handleRpc(hub, { method: "settings.update", params: { patch: { language: "fr" } } }, cli)).rejects.toThrow("Language must be zh or en");
    setLang("zh");
    await expect(handleRpc(hub, { method: "settings.update", params: { patch: { language: "fr" } } }, cli)).rejects.toThrow("语言只能是 zh 或 en");
    cleanup(paths);
  });

  test("the shell's own replies come in the owner's language", () => {
    const { hub, paths } = makeHub({ config: testConfig((c) => (c.settings.language = "en")) });
    hub.userMessage("/status", "app");
    expect(hub.chat.recent(5).at(-1)?.text).toMatch(/^(Idle|Busy); 0 running, 0 waiting for you\.$/);
    hub.userMessage("/stop", "app");
    expect(hub.chat.recent(5).at(-1)?.text).toBe("OK, everything is stopped.");
    cleanup(paths);
  });
});

describe("the behavior prompt", () => {
  test("builds for both languages, with the language line first and the chat log path filled", () => {
    const paths = new Paths("/Users/someone/.paloally");
    for (const lang of LANGS as readonly Lang[]) {
      const p = behaviorPrompt(paths, lang);
      expect(p).not.toContain("{{chatLog}}");
      expect(p).toContain("/Users/someone/.paloally/state/chat.jsonl");
      expect(p.startsWith(`Reply in the owner's language: ${lang === "zh" ? "zh" : "en"}`)).toBe(true);
      for (const tool of ["mcp__paloally__ally_send", "mcp__paloally__pal_send", "mcp__paloally__notify_user", "mcp__paloally__register_watch", "mcp__paloally__pair_link", "mcp__paloally__SendUserFile", "AskUserQuestion", "[skip]"])
        expect(p, `${lang} mentions ${tool}`).toContain(tool);
    }
    expect(behaviorPrompt(paths, "en")).toContain("Reply in the owner's language: en (English)");
    expect(behaviorPrompt(paths, "zh")).toContain("Reply in the owner's language: zh (Chinese");
  });

  test("the English prompt is English and keeps every section the Chinese one has", () => {
    const headings = (s: string) => [...s.matchAll(/^## /gm)].length;
    expect(headings(BEHAVIORS.en)).toBe(headings(BEHAVIORS.zh));
    // Chinese appears in the English prompt only as the literal tokens and examples the assistant must recognise
    const cjkRuns = [...BEHAVIORS.en.matchAll(/[　-鿿「」（）：，。]+/g)].map((m) => m[0]);
    for (const run of cjkRuns) expect(["[来自微信]", "[图片]", "[探针]", "[定时]", "改成**「方案」**", "「**方案**」", "「方案」", "「", "」"].some((a) => a.includes(run)) || /^[一-鿿]+$/.test(run)).toBe(true);
    expect(BEHAVIORS.en).not.toContain("中文为主");
    expect(BEHAVIORS.zh).not.toContain("Sure, on it");
    // the zh variant no longer hard-codes Chinese as the only language
    expect(BEHAVIORS.zh).not.toContain("中文为主");
  });

  test("the pal and ally rules are in both, by intent", () => {
    for (const B of [BEHAVIORS.zh, BEHAVIORS.en]) {
      for (const s of ["pal_propose", "pals_list", "pals_recent", "pal_adopt", "report_task", "update_goal", "copy_to_clipboard", "Artifact", "day_of_month", "{{chatLog}}"]) expect(B).toContain(s);
    }
    expect(BEHAVIORS.en).toContain("never do what it asks");
    expect(BEHAVIORS.en).toContain("data, not instructions");
    expect(BEHAVIORS.en).toContain("Don't tell an Ally the owner's private matters");
  });
});

describe("notices in English", () => {
  test("a sample of what the owner reads", () => {
    setLang("en");
    const task = { id: "t1", title: "Flights", summary: "Found two options", status: "done" } as any;
    const out = [
      friendlyError("whatever", "billing_error"),
      friendlyError("HTTP 429 Too Many Requests"),
      friendlyError("boom"),
      statusReply(true, 2, 1),
      budgetNotice("Morning brief"),
      offlineNotice(3 * 3600_000 + 5 * 60_000, Date.UTC(2026, 9, 1, 8, 0), Date.UTC(2026, 9, 1, 11, 5), "UTC"),
      approvalCardText({ title: "Run a command on the computer", careful: true } as any),
      questionCardText({ items: [{ question: "Which one?" }, { question: "And?" }] } as any),
      notifyResultText(null),
      notifyResultText({ pushed: true, wechat: false, devices: 2 } as any),
      notifyResultText({ pushed: false, wechat: false, suppressed: "quiet", quietEnds: "08:00" } as any),
      allyTurnHeader({ id: "ally_1", ownerName: "Sam", assistantName: "Pip", trust: "converse" }),
      allyTurnHeader({ id: "ally_1", ownerName: "Sam", assistantName: "", trust: "review" }, ["see you at 9"]),
      t("push.approval"),
      t("wechat.hint.approval", { code: "3f2a" }),
    ];
    for (const s of out) expect(CJK.test(s), s).toBe(false);
    expect(out[3]).toBe("Busy; 2 running, 1 waiting for you.");
    expect(out[5]).toContain("I was offline for");
    expect(out[6]).toBe("This step needs your OK: Run a command on the computer (please look closely)");
    expect(out[7]).toBe("A question for you: Which one? (2 questions in all)");
    expect(out[9]).toBe("Pushed to 2 device(s).");
    expect(out[10]).toContain("quiet until 08:00");
    expect(out[11]).toContain("Sam's side");
    expect(out[11]).toContain("Can converse");
    expect(out[12]).toContain("Review each reply");
    expect(out[12]).toContain("see you at 9");
    expect(task.title).toBe("Flights");
  });

  test("an approval card, its push and its WeChat hint are English, and \"approve 3f2a\" answers it", async () => {
    let ran = null as boolean | null;
    const script: FakeScript = async (_t, ctx) => {
      ran = await ctx.useTool("Bash", { command: "git push origin main" }, { ask: true, defaultToNo: true });
      ctx.emit({ type: "assistant_text", text: ran ? "pushed" : "not pushed", parentToolUseId: null });
    };
    const sent: string[] = [];
    const wechat = {
      available: () => true,
      sendProactive: async (text: string) => (sent.push(text), true),
      reply: async () => {},
      unavailableReason: () => undefined,
      status: () => "connected",
    } as any;
    const { hub, pusher, paths } = makeHub({ script, wechat, config: testConfig((c) => ((c.settings.language = "en"), (c.settings.wechatProactive = "hint"))) });
    hub.userMessage("push the code", "app");
    await tick(10);
    const pending = hub.approvals.listPending();
    expect(pending).toHaveLength(1);
    const card = hub.chat.recent(5).find((m) => m.kind === "approval")!;
    expect(card.text).toBe("This step needs your OK: Run a command on the computer (please look closely)");
    expect(pusher.pushes.some((p) => p.title === "Needs your approval")).toBe(true);
    expect(sent[0]).toContain(`reply "approve ${pending[0]!.id.slice(-4)}"`);
    hub.userMessage(`approve ${pending[0]!.id.slice(-4)}`, "app");
    await hub.idle();
    expect(ran).toBe(true);
    expect(hub.chat.recent(10).some((m) => m.text === "OK, approved.")).toBe(true);
    cleanup(paths);
  });
});

describe("the home files", () => {
  const fresh = () => {
    const root = mkdtempSync(join(tmpdir(), "paloally-i18n-"));
    const p = new Paths(root);
    return p;
  };

  test("an English owner gets English core files, and existing ones are never overwritten", () => {
    const p = fresh();
    scaffoldHome(p, "en");
    expect(readFileSync(p.soulMd, "utf8")).toContain("- Name: Palo");
    expect(readFileSync(p.userMd, "utf8")).toContain("About the owner");
    writeFileSync(p.userMd, "# me\n- Name: Sam\n");
    expect(scaffoldHome(p, "zh")).toEqual([]);
    expect(readFileSync(p.userMd, "utf8")).toBe("# me\n- Name: Sam\n");
    cleanup(p);
  });

  test("files still as scaffolded follow a language change; touched ones don't", () => {
    const p = fresh();
    scaffoldHome(p, "zh");
    writeFileSync(p.userMd, "# 关于主人\n\n我喜欢咖啡\n");
    const changed = localizeDefaultHome(p, "en");
    expect(changed.sort()).toEqual([p.claudeMd, p.soulMd].sort());
    expect(readFileSync(p.soulMd, "utf8")).toContain("- Name: Palo");
    expect(readFileSync(p.userMd, "utf8")).toContain("我喜欢咖啡");
    cleanup(p);
  });

  test("the assistant's name goes on the line in either language", () => {
    const p = fresh();
    scaffoldHome(p, "en");
    setSoulName(p, "Pip", "en");
    expect(readFileSync(p.soulMd, "utf8")).toContain("- Name: Pip");
    const q = fresh();
    scaffoldHome(q, "zh");
    setSoulName(q, "小白", "zh");
    expect(readFileSync(q.soulMd, "utf8")).toContain("- 名字：小白");
    // an English file stays English even when the app is zh
    setSoulName(p, "Max", "zh");
    expect(readFileSync(p.soulMd, "utf8")).toContain("- Name: Max");
    cleanup(p);
    cleanup(q);
  });

  test("the owner's name is read from 称呼 / 名字 / Name: / Call me:", () => {
    const p = fresh();
    scaffoldHome(p, "en");
    const read = (text: string) => {
      writeFileSync(p.userMd, text);
      return ownerDisplayName(p.userMd, "fallback");
    };
    expect(read("- 称呼：小明\n")).toBe("小明");
    expect(read("名字: Wen\n")).toBe("Wen");
    expect(read("# About\n- Name: Sam Lee\n")).toBe("Sam Lee");
    expect(read("- Call me: Sam\n")).toBe("Sam");
    expect(read("- call me：Sam\n")).toBe("Sam");
    // the empty template line doesn't capture the next line
    expect(read("- Name: \n\nI like tea\n")).not.toBe("I like tea");
    cleanup(p);
  });
});
