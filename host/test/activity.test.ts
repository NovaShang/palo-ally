import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ACTIVITY, describeActivity } from "../src/copy.ts";
import { Paths } from "../src/config.ts";
import { BEHAVIORS, behaviorPrompt } from "../src/home.ts";
import { cleanup, makeHub, tick } from "./helpers.ts";

describe("activity line: tool → plain Chinese", () => {
  test("built-in tools", () => {
    expect(describeActivity("Read")).toBe("在翻文件");
    expect(describeActivity("Grep")).toBe("在翻文件");
    expect(describeActivity("Edit")).toBe("在整理文件");
    expect(describeActivity("Bash")).toBe("在电脑上操作");
    expect(describeActivity("WebSearch")).toBe("在网上查");
    expect(describeActivity("Agent")).toBe("在后台办");
    expect(describeActivity("SendMessage")).toBe("在交给后台办");
  });

  test("connector tools by server and name", () => {
    expect(describeActivity("mcp__claude_ai_Gmail__search_threads")).toBe("在查邮件");
    expect(describeActivity("mcp__ms365__list-mail-messages")).toBe("在查邮件");
    expect(describeActivity("mcp__claude_ai_Google_Calendar__list_events")).toBe("在看日历");
    expect(describeActivity("mcp__ms365__get-calendar-view")).toBe("在看日历");
    expect(describeActivity("mcp__claude_ai_Notion__notion-search")).toBe("在看文档");
    expect(describeActivity("mcp__claude_ai_Google_Drive__read_file_content")).toBe("在看文档");
    expect(describeActivity("mcp__claude-in-chrome__navigate")).toBe("在网上查");
    expect(describeActivity("mcp__paloally__SendUserFile")).toBe("在准备给你的东西");
    expect(describeActivity("mcp__paloally__register_watch")).toBe("在记下来");
  });

  test("unknown tools fall back; self-showing and housekeeping tools keep the line", () => {
    expect(describeActivity("mcp__something_new__do_it")).toBe("在处理");
    expect(describeActivity("SomeFutureTool")).toBe("在处理");
    expect(describeActivity("AskUserQuestion")).toBeNull();
    expect(describeActivity("ToolSearch")).toBeNull();
  });

  test("no phrase carries internal terms, tool names or input", () => {
    const banned = [/会话/, /session/i, /agent/i, /主机/, /host/i, /tool/i, /server/i, /mcp/i, /bash/i, /claude/i, /[\/\\]/, /https?:/];
    for (const phrase of Object.values(ACTIVITY)) for (const b of banned) expect(phrase).not.toMatch(b);
    for (const tool of ["Bash", "mcp__claude_ai_Gmail__search_threads", "mcp__paloally__notify_user", "Read", "SendMessage", "mcp__x__y"]) {
      const a = describeActivity(tool) ?? "";
      expect(a).not.toContain(tool);
      for (const b of banned) expect(a).not.toMatch(b);
    }
  });
});

describe("activity line: lifecycle", () => {
  test("set by tools, replaced by the next tool and by the reply, gone at turn end, never in the chat log", async () => {
    const lines: string[] = [];
    const { hub, paths } = makeHub({
      script: async (_t, ctx) => {
        ctx.emit({ type: "tool_use", id: "t1", name: "mcp__claude_ai_Gmail__search_threads", input: { query: "secret@x.com" }, parentToolUseId: null });
        await tick(5);
        ctx.emit({ type: "tool_result", toolUseId: "t1", content: "ok", isError: false, parentToolUseId: null });
        ctx.emit({ type: "tool_use", id: "t2", name: "Read", input: { file_path: "/Users/someone/private.txt" }, parentToolUseId: null });
        await tick(5);
        ctx.emit({ type: "tool_result", toolUseId: "t2", content: "ok", isError: false, parentToolUseId: null });
        ctx.emit({ type: "tool_use", id: "t3", name: "AskUserQuestion", input: {}, parentToolUseId: null });
        await tick(5);
        ctx.emit({ type: "tool_result", toolUseId: "t3", content: "ok", isError: false, parentToolUseId: null });
        ctx.emit({ type: "text_delta", text: "查到了" });
        await tick(5);
      },
    });
    hub.bus.on((e, d: any) => {
      if (e === "status" && d.activity && d.activity !== "在想" && lines.at(-1) !== d.activity) lines.push(d.activity);
    });
    hub.userMessage("看看邮件", "app");
    await hub.idle();
    // AskUserQuestion keeps the previous line rather than naming itself
    expect(lines).toEqual(["在查邮件", "在翻文件", "在写回复"]);
    expect(hub.status().activity).toBeUndefined();
    const log = readFileSync(`${paths.state}/chat.jsonl`, "utf8");
    for (const l of ["在查邮件", "在翻文件", "在写回复"]) expect(log).not.toContain(l);
    expect(lines.join(" ")).not.toContain("secret@x.com");
    expect(lines.join(" ")).not.toContain("/Users/");
    cleanup(paths);
  });

  test("background work shows as 在后台办", async () => {
    const lines: string[] = [];
    const { hub, paths } = makeHub({
      script: async (_t, ctx) => {
        ctx.emit({ type: "tool_use", id: "a1", name: "Agent", input: { description: "x" }, parentToolUseId: null });
        ctx.emit({ type: "tool_use", id: "s1", name: "Grep", input: {}, parentToolUseId: "a1" });
        await tick(5);
      },
    });
    hub.bus.on((e, d: any) => e === "status" && d.activity && d.activity !== "在想" && lines.push(d.activity));
    hub.userMessage("后台查一下", "app");
    await hub.idle();
    expect(new Set(lines)).toEqual(new Set(["在后台办"]));
    cleanup(paths);
  });
});

describe("behavior: respond first, then act", () => {
  test("a top-level rule for every channel, with varied natural acks and no plan (zh)", () => {
    const B = BEHAVIORS.zh;
    const rule = B.indexOf("## 先回应，再动手");
    expect(rule).toBeGreaterThan(0);
    expect(rule).toBeLessThan(B.indexOf("## 微信")); // before any channel-specific section
    expect(B).toContain("每一轮、每个渠道");
    for (const ack of ["好的，我来办", "收到，马上看", "好，我查一下", "行，我去弄"]) expect(B).toContain(ack);
    expect(B).toContain("不解释打算怎么做");
    expect(B).toContain("不要套固定模板");
    // the WeChat section no longer carries its own copy of the rule
    const wechat = B.slice(B.indexOf("## 微信"), B.indexOf("## 干活方式"));
    expect(wechat).not.toContain("先回一句");
  });

  test("the same rule in English, with English acks only", () => {
    const B = BEHAVIORS.en;
    const rule = B.indexOf("## Respond first, then act");
    expect(rule).toBeGreaterThan(0);
    expect(rule).toBeLessThan(B.indexOf("## WeChat")); // before any channel-specific section
    expect(B).toContain("every turn, every channel");
    for (const ack of ["Sure, on it", "Got it, looking now", "OK, let me check"]) expect(B).toContain(ack);
    expect(B).toContain("don't explain your plan");
    expect(B).toContain("don't use a fixed template");
    for (const ack of ["好的，我来办", "收到，马上看"]) expect(B).not.toContain(ack);
    const wechat = B.slice(B.indexOf("## WeChat"), B.indexOf("## How to work"));
    expect(wechat).not.toContain("one short line");
  });
});

describe("behavior: where past conversation lives", () => {
  test("points at this install's chat log, read-only, search before answering", () => {
    const prompt = behaviorPrompt(new Paths("/Users/someone/.paloally"));
    expect(prompt).toContain("/Users/someone/.paloally/state/chat.jsonl");
    expect(prompt).not.toContain("{{chatLog}}");
    expect(prompt).toContain("只读，绝不修改");
    expect(prompt).toContain("先搜原文再回答");
    const en = behaviorPrompt(new Paths("/Users/someone/.paloally"), "en");
    expect(en).toContain("/Users/someone/.paloally/state/chat.jsonl");
    expect(en).toContain("read-only, never modify it");
    expect(en).toContain("search the original text before answering");
  });
});
