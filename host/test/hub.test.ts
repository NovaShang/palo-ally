import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import type { WechatChannel, WechatReplyTarget } from "../src/hub.ts";
import type { FakeScript } from "./fakeDriver.ts";
import type { ChatMessage } from "../src/types.ts";
import { readJson, readJsonl, writeJson } from "../src/util.ts";
import { cleanup, makeHub, testConfig, tick } from "./helpers.ts";

const texts = (msgs: ChatMessage[]) => msgs.map((m) => `${m.role}:${m.text}`);

class FakeWechat implements WechatChannel {
  replies: { target: WechatReplyTarget; text: string }[] = [];
  proactive: string[] = [];
  status() {
    return "connected" as const;
  }
  available() {
    return true;
  }
  async reply(target: WechatReplyTarget, text: string) {
    this.replies.push({ target, text });
  }
  async sendProactive(text: string) {
    this.proactive.push(text);
    return true;
  }
  typing: string[] = [];
  async startTyping() {
    this.typing.push("on");
  }
  async stopTyping() {
    this.typing.push("off");
  }
}

describe("Hub: main conversation", () => {
  test("streams deltas then a final message with the same id", async () => {
    const { hub, events, paths } = makeHub();
    hub.userMessage("你好", "app");
    await hub.idle();
    const deltas = events.filter((e) => e.event === "chat.delta");
    expect(deltas.map((d) => d.data.text).join("")).toBe("收到：你好");
    const final = events.filter((e) => e.event === "chat.message").map((e) => e.data as ChatMessage);
    expect(texts(final)).toEqual(["user:你好", "assistant:收到：你好"]);
    expect(final[1]!.id).toBe(deltas[0]!.data.id);
    // busy went true then false
    const busy = events.filter((e) => e.event === "status").map((e) => e.data.busy);
    expect(busy).toContain(true);
    expect(busy[busy.length - 1]).toBe(false);
    // history persisted with increasing seq
    const log = readJsonl<ChatMessage>(paths.chat);
    expect(log.map((m) => m.seq)).toEqual([1, 2]);
    cleanup(paths);
  });

  test("the harness answers owner messages in the order they were sent", async () => {
    const order: string[] = [];
    const script: FakeScript = async (t, ctx) => {
      order.push(`start ${t}`);
      await tick(20);
      ctx.emit({ type: "assistant_text", text: `re ${t}`, parentToolUseId: null });
      order.push(`end ${t}`);
    };
    const { hub, paths } = makeHub({ script });
    hub.userMessage("a", "app");
    hub.userMessage("b", "cli");
    await hub.idle();
    expect(order).toEqual(["start a", "end a", "start b", "end b"]);
    cleanup(paths);
  });

  test("session id is persisted and resumed after an idle close", async () => {
    const { hub, driver, paths } = makeHub({ config: testConfig((c) => (c.session.idleCloseMinutes = 1)) });
    hub.userMessage("1", "app");
    await hub.idle();
    const sid = readJson<any>(paths.runtime, {}).sessionId;
    expect(sid).toBeTruthy();
    hub.onIdle();
    expect(driver.last!.closed).toBe(true);
    hub.userMessage("2", "app");
    await hub.idle();
    expect(driver.sessions).toHaveLength(2);
    expect(driver.last!.opts.resumeSessionId).toBe(sid);
    hub.stop();
    cleanup(paths);
  });

  test("harness error surfaces a notice and the next message restarts the session", async () => {
    let n = 0;
    const { hub, driver, paths } = makeHub({
      script: async (_t, ctx) => {
        if (n++ === 0) ctx.emit({ type: "error", message: "rate limited" });
        else ctx.emit({ type: "assistant_text", text: "ok", parentToolUseId: null });
      },
    });
    hub.userMessage("a", "app");
    await hub.idle();
    expect(texts(hub.chat.recent(5)).some((t) => t.includes("太忙了"))).toBe(true); // "rate limited" → friendly text
    hub.userMessage("b", "app");
    await hub.idle();
    expect(driver.sessions.length).toBe(2);
    expect(hub.chat.recent(1)[0]!.text).toBe("ok");
    cleanup(paths);
  });
});

describe("Hub: proactive", () => {
  test("[skip] stays silent; real content is a proactive message + push", async () => {
    let reply = "[skip]";
    const { hub, pusher, paths } = makeHub({ script: async (_t, ctx) => ctx.emit({ type: "assistant_text", text: reply, parentToolUseId: null }) });
    const w = hub.watches.add({ title: "邮件", instruction: "查邮件", intervalMinutes: 5 }, "agent");
    (hub as any).onProbeTriggers([{ watch: w, summary: "老板来信" }]);
    await hub.idle();
    expect(hub.chat.recent(10)).toHaveLength(0);
    expect(pusher.pushes).toHaveLength(0);

    reply = "老板发来了合同，需要你今天签。";
    (hub as any).onProbeTriggers([{ watch: w, summary: "老板来信" }]);
    await hub.idle();
    const m = hub.chat.recent(1)[0]!;
    expect(m.proactive).toBe(true);
    expect(m.channel).toBe("probe");
    expect(pusher.pushes[0]!.body).toContain("合同");
    const metrics = readJsonl<any>(paths.metrics);
    expect(metrics.filter((x) => x.type === "skip")).toHaveLength(1);
    cleanup(paths);
  });

  test("schedule watch goes to the main agent with the instruction", async () => {
    const { hub, driver, paths } = makeHub();
    const w = hub.watches.add({ title: "晨报", instruction: "整理今天的日程", at: ["08:30"] }, "user");
    (hub as any).onSchedule(w);
    await hub.idle();
    expect(driver.last!.sent[0]).toBe("[定时·晨报] 整理今天的日程");
    cleanup(paths);
  });

  test("quiet hours suppress pushes but keep the chat; no daily total", async () => {
    const { hub, pusher, paths } = makeHub({
      config: testConfig((c) => {
        c.settings.quietHours = { start: "00:00", end: "23:59" };
      }),
    });
    const h = hub.toolHandlers();
    expect(await h.notify_user({ text: "普通提醒" })).toContain("免打扰");
    expect(pusher.pushes).toHaveLength(0);
    expect(await h.notify_user({ text: "紧急！", urgent: true })).toBe("已推送");
    expect(pusher.pushes).toHaveLength(1);
    hub.updateSettings({ quietHours: null });
    for (let i = 0; i < 12; i++) expect(await h.notify_user({ text: `提醒 ${i}` })).toBe("已推送"); // heavy use is fine
    expect(pusher.pushes).toHaveLength(13);
    cleanup(paths);
  });

  test("harness-initiated turn (background task done) is shown proactively", async () => {
    const { hub, driver, pusher, paths } = makeHub();
    hub.userMessage("hi", "app");
    await hub.idle();
    const s = driver.last!;
    s.opts.onEvent({ type: "assistant_text", text: "后台那件事办完了：结果在资料库。", parentToolUseId: null });
    s.opts.onEvent({ type: "result", isError: false, text: "", costUsd: 0, totalCostUsd: 0, contextTokens: 1, sessionId: s.sessionId });
    const m = hub.chat.recent(1)[0]!;
    expect(m.proactive).toBe(true);
    expect(m.text).toContain("办完了");
    expect(pusher.pushes).toHaveLength(1);
    cleanup(paths);
  });

  test("offline gap is reported on start", () => {
    const { hub, paths, pusher } = makeHub();
    writeJson(paths.runtime, { lastHeartbeat: Date.now() - 3 * 3600_000 });
    const { hub: hub2 } = makeHub({ paths });
    hub2.start({ probe: false, watchArtifacts: false });
    const m = hub2.chat.recent(1)[0]!;
    expect(m.text).toContain("我掉线了");
    expect(m.text).toContain("3 小时");
    hub2.stop();
    void hub;
    void pusher;
    cleanup(paths);
  });

  test("main budget cap drops proactive turns", async () => {
    const { hub, driver, paths } = makeHub({ config: testConfig((c) => (c.budget.mainDailyUsd = 0.0005)) });
    driver.turnCost = 0.001;
    hub.userMessage("hi", "app");
    await hub.idle();
    const w = hub.watches.add({ title: "x", instruction: "y", at: ["08:00"] }, "user");
    (hub as any).onSchedule(w);
    await hub.idle();
    expect(driver.last!.sent).toEqual(["hi"]);
    cleanup(paths);
  });
});

describe("Hub: tasks via report_task", () => {
  test("receipt + result messages, push on completion, detail grouped", async () => {
    const script: FakeScript = async (t, ctx) => {
      const tools = ctx.opts.tools;
      ctx.emit({ type: "tool_use", id: "ag1", name: "Agent", input: { description: "比价机票", prompt: "..." }, parentToolUseId: null });
      await tools.report_task({ id: "flights", summary: "去比较周五去纽约的机票", status: "running", title: "比价机票" });
      ctx.emit({ type: "tool_use", id: "s1", name: "WebSearch", input: { query: "SFO JFK friday" }, parentToolUseId: "ag1" });
      ctx.emit({ type: "tool_result", toolUseId: "s1", content: "3 results", isError: false, parentToolUseId: "ag1" });
      ctx.emit({ type: "tool_result", toolUseId: "ag1", content: "UA 最便宜 $320", isError: false, parentToolUseId: null });
      await tools.report_task({ id: "flights", summary: "UA 周五 8 点那班最便宜，$320", status: "done" });
      void t;
    };
    const { hub, pusher, paths } = makeHub({ script });
    hub.userMessage("帮我看看周五去纽约的机票", "app");
    await hub.idle();
    const msgs = hub.chat.recent(10).filter((m) => m.kind === "task");
    expect(msgs.map((m) => m.text)).toEqual(["收到，开始办：去比较周五去纽约的机票", "✅ 比价机票：UA 周五 8 点那班最便宜，$320"]);
    expect(pusher.pushes).toHaveLength(1);
    expect(pusher.pushes[0]!.title).toBe("比价机票");
    const task = hub.tasks.list()[0]!;
    expect(task.status).toBe("done");
    expect(hub.tasks.activity(task.id).map((a) => a.kind)).toEqual(["tool_use", "tool_result"]);
    cleanup(paths);
  });

  test("task.stop stops a running task", async () => {
    const script: FakeScript = async (_t, ctx) => {
      ctx.emit({ type: "tool_use", id: "ag", name: "Agent", input: { description: "长任务", run_in_background: true }, parentToolUseId: null });
      ctx.emit({ type: "task_started", taskId: "sdk-9", toolUseId: "ag", description: "长任务", background: true });
    };
    const { hub, driver, paths } = makeHub({ script });
    hub.userMessage("go", "app");
    await hub.idle();
    const t = hub.tasks.list()[0]!;
    expect(t.status).toBe("running");
    await hub.stopTask(t.id);
    expect(driver.stoppedTasks).toEqual(["sdk-9"]);
    expect(hub.tasks.get(t.id)!.status).toBe("stopped");
    cleanup(paths);
  });
});

describe("Hub: relaying the harness' approvals", () => {
  test("a harness prompt becomes a card + push; WeChat '同意 xxxx' answers it (first answer wins)", async () => {
    let ran = null as boolean | null;
    const script: FakeScript = async (_t, ctx) => {
      ran = await ctx.useTool("Bash", { command: "git push origin main" }, { ask: true, defaultToNo: true });
      ctx.emit({ type: "assistant_text", text: ran ? "推上去了" : "没推", parentToolUseId: null });
    };
    const wechat = new FakeWechat();
    const { hub, pusher, paths } = makeHub({ script, wechat });
    hub.userMessage("把代码推上去", "app");
    await tick(10);
    const pending = hub.approvals.listPending();
    expect(pending).toHaveLength(1);
    expect(pending[0]!.careful).toBe(true); // the harness' defaultToNo
    const card = hub.chat.recent(5).find((m) => m.kind === "approval")!;
    expect(card.approvalId).toBe(pending[0]!.id);
    expect(pusher.pushes.some((p) => p.title === "需要你确认")).toBe(true);
    expect(wechat.proactive[0]).toContain("有个操作等你确认");
    expect(wechat.proactive[0]).not.toContain("git push");
    hub.userMessage(`同意 ${pending[0]!.id.slice(-4)}`, "wechat", { userId: "u", contextToken: "c" });
    await hub.idle();
    expect(ran).toBe(true);
    expect(hub.approvals.answer(pending[0]!.id, false, "app")!.status).toBe("allowed");
    expect(hub.audit.tail(50).some((e) => e.type === "approval.decided" && e.by === "wechat")).toBe(true);
    cleanup(paths);
  });

  test("tools the harness doesn't ask about just run (no gate of our own)", async () => {
    let ran = null as boolean | null;
    const { hub, paths } = makeHub({ script: async (_t, ctx) => void (ran = await ctx.useTool("Bash", { command: "rm -rf /tmp/x" })) });
    hub.userMessage("清理", "app");
    await hub.idle();
    expect(ran).toBe(true);
    expect(hub.approvals.list()).toHaveLength(0);
    cleanup(paths);
  });

  test("'always allow' returns the harness' own suggested rule", async () => {
    const rule = [{ type: "addRules", behavior: "allow", destination: "localSettings", rules: [{ toolName: "Bash", ruleContent: "npm test:*" }] }];
    const { hub, driver, paths } = makeHub({ script: async (_t, ctx) => void (await ctx.useTool("Bash", { command: "npm test" }, { ask: true, suggestions: rule })) });
    hub.userMessage("跑测试", "app");
    await tick(10);
    const a = hub.approvals.listPending()[0]!;
    expect(a.suggestedScope).toBe("cmd:npm test");
    hub.approvals.answer(a.id, true, "app", true);
    await hub.idle();
    expect(driver.appliedPermissions).toEqual(rule);
    cleanup(paths);
  });

  test("stop: interrupts and denies open prompts, and nothing stays blocked", async () => {
    let result = null as boolean | null;
    const script: FakeScript = async (t, ctx) => {
      if (t === "push") result = await ctx.useTool("Bash", { command: "rm -rf /tmp/x" }, { ask: true });
      else ctx.emit({ type: "assistant_text", text: "ok", parentToolUseId: null });
    };
    const { hub, paths } = makeHub({ script });
    hub.userMessage("push", "app");
    await tick(10);
    expect(hub.approvals.listPending()).toHaveLength(1);
    hub.userMessage("/stop", "wechat", { userId: "u", contextToken: "c" });
    await hub.idle();
    await tick(10);
    expect(result).toBe(false);
    
    hub.userMessage("在吗", "app");
    await hub.idle();
    expect(hub.chat.recent(1)[0]!.text).toBe("ok");
    cleanup(paths);
  });

  test("approvals answer only with their code; a bare 'ok'/'同意' is just conversation", async () => {
    const script: FakeScript = async (_t, ctx) => {
      if (_t === "x") await Promise.all([ctx.useTool("Bash", { command: "a" }, { ask: true }), ctx.useTool("Bash", { command: "b" }, { ask: true })]);
    };
    const { hub, driver, paths } = makeHub({ script });
    hub.userMessage("x", "app");
    await tick(10);
    hub.userMessage("ok", "app");
    hub.userMessage("同意", "app");
    expect(hub.approvals.listPending()).toHaveLength(2);
    expect(driver.last!.sent).toEqual(["x", "ok", "同意"]);
    const [a, b] = hub.approvals.listPending();
    hub.userMessage(`拒绝 ${a!.id.slice(-4)}`, "app");
    hub.userMessage(`同意 ${b!.id.slice(-4)}`, "app");
    await hub.idle();
    expect(hub.approvals.list().map((x) => x.status).sort()).toEqual(["allowed", "denied"]);
    cleanup(paths);
  });
});

describe("Hub: WeChat routing", () => {
  test("a WeChat turn is answered on WeChat; app turns are not", async () => {
    const wechat = new FakeWechat();
    const { hub, driver, paths } = makeHub({ wechat });
    hub.userMessage("帮我记一下", "wechat", { userId: "owner", contextToken: "ctx1" });
    await hub.idle();
    expect(driver.last!.sent[0]).toBe("[来自微信] 帮我记一下");
    expect(wechat.replies).toEqual([{ target: { userId: "owner", contextToken: "ctx1" }, text: "收到：[来自微信] 帮我记一下" }]);
    hub.userMessage("hi", "app");
    await hub.idle();
    expect(wechat.replies).toHaveLength(1);
    cleanup(paths);
  });

  test("each paragraph reaches WeChat as it's written, with typing in between; no duplicate final", async () => {
    const wechat = new FakeWechat();
    const script: FakeScript = async (_t, ctx) => {
      ctx.emit({ type: "assistant_text", text: "收到，我去查一下。", parentToolUseId: null });
      await ctx.useTool("WebSearch", { query: "q" });
      ctx.emit({ type: "assistant_text", text: "查到了三家，正在比价。", parentToolUseId: null });
      ctx.emit({ type: "assistant_text", text: "结论：选第二家。", parentToolUseId: null });
    };
    const { hub, paths } = makeHub({ script, wechat });
    hub.userMessage("帮我订餐厅", "wechat", { userId: "owner", contextToken: "c" });
    await hub.idle();
    await tick(20);
    expect(wechat.replies.map((r) => r.text)).toEqual(["收到，我去查一下。", "查到了三家，正在比价。", "结论：选第二家。"]);
    expect(wechat.typing[0]).toBe("on");
    expect(wechat.typing.at(-1)).toBe("off");
    cleanup(paths);
  });
});

describe("Hub: talking while it works", () => {
  test("an owner message mid-turn is sent right away and answered", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const script: FakeScript = async (t, ctx) => {
      if (t === "做个大东西") await gate;
      ctx.emit({ type: "assistant_text", text: `回：${t}`, parentToolUseId: null });
    };
    const { hub, driver, paths } = makeHub({ script });
    hub.userMessage("做个大东西", "app");
    await tick(5);
    hub.userMessage("好了吗", "app");
    await tick(5);
    expect(driver.last!.sent).toEqual(["做个大东西", "好了吗"]); // not held back by the hub
    release();
    await hub.idle();
    const replies = hub.chat.recent(10).filter((m) => m.role === "assistant").map((m) => m.text);
    expect(replies).toEqual(["回：做个大东西", "回：好了吗"]);
    expect(hub.chat.recent(10).every((m) => !m.proactive)).toBe(true);
    cleanup(paths);
  });

  test("owner speaking during a proactive turn: both get shown, [skip] never leaks", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const script: FakeScript = async (t, ctx) => {
      if (t.startsWith("[定时")) {
        ctx.emit({ type: "assistant_text", text: "晨报第一段", parentToolUseId: null });
        await gate;
        ctx.emit({ type: "assistant_text", text: "晨报第二段", parentToolUseId: null });
        return;
      }
      ctx.emit({ type: "assistant_text", text: `回：${t}`, parentToolUseId: null });
    };
    const { hub, paths } = makeHub({ script });
    (hub as any).onSchedule(hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["08:30"] }, "user"));
    await tick(5);
    hub.userMessage("在吗", "app");
    release();
    await hub.idle();
    const shown = hub.chat.recent(10).filter((m) => m.role === "assistant");
    expect(shown.map((m) => m.text)).toEqual(["晨报第一段\n\n晨报第二段", "回：在吗"]);
    expect(shown[0]!.proactive).toBe(true);
    expect(shown[1]!.proactive).toBeFalsy();
    expect(shown.some((m) => m.text.includes("[skip]"))).toBe(false);
    cleanup(paths);
  });

  test("a harness-started turn that goes quiet is closed, so nothing gets stuck", async () => {
    const { timing } = await import("../src/hub.ts");
    timing.implicitQuietMs = 30;
    const { hub, driver, paths } = makeHub();
    hub.userMessage("hi", "app");
    await hub.idle();
    driver.last!.opts.onEvent({ type: "tool_use", id: "x", name: "Bash", input: {}, parentToolUseId: null });
    expect(hub.status().busy).toBe(true);
    expect(hub.status().activity).toBe("正在电脑上跑命令");
    await tick(60);
    expect(hub.status().busy).toBe(true); // a tool is still running: not "quiet"
    driver.last!.opts.onEvent({ type: "tool_result", toolUseId: "x", content: "ok", isError: false, parentToolUseId: null });
    await tick(60);
    expect(hub.status().busy).toBe(false);
    hub.userMessage("还在吗", "app");
    await hub.idle();
    expect(hub.chat.recent(1)[0]!.text).toBe("收到：还在吗");
    timing.implicitQuietMs = 90_000;
    cleanup(paths);
  });

  test("activity describes long tool calls while busy", async () => {
    const { hub, driver, paths } = makeHub({
      script: async (_t, ctx) => {
        ctx.emit({ type: "tool_start", name: "Write", parentToolUseId: null });
        await tick(10);
      },
    });
    const seen: string[] = [];
    hub.bus.on((e, d: any) => e === "status" && d.activity && seen.push(d.activity));
    hub.userMessage("写个大文件", "app");
    await hub.idle();
    expect(seen).toContain("正在写文件");
    expect(hub.status().activity).toBeUndefined();
    void driver;
    cleanup(paths);
  });
});

describe("Hub: restarts", () => {
  test("interrupted tasks and an unanswered message are handed back to the assistant", async () => {
    const { hub, paths } = makeHub({ script: async () => {} });
    hub.tasks.report("pdf", "做介绍 PDF", "running", "介绍文档");
    hub.chat.add({ role: "user", kind: "text", text: "好了吗", channel: "app" });
    const { hub: again, driver } = makeHub({ paths });
    again.start({ probe: false, watchArtifacts: false });
    await again.idle();
    const sent = driver.last!.sent[0]!;
    expect(sent).toContain("「介绍文档」");
    expect(sent).toContain("「好了吗」");
    again.stop();
    void hub;
    cleanup(paths);
  });

  test("restartWhenIdle waits for work to finish", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const { hub, paths } = makeHub({ script: async () => gate });
    hub.userMessage("忙一下", "app");
    let exited = false;
    const p = hub.restartWhenIdle(10_000, () => (exited = true));
    await tick(50);
    expect(exited).toBe(false);
    release();
    expect(await p).toBe("restarting");
    await tick(300);
    expect(exited).toBe(true);
    cleanup(paths);
  });

  test("per-turn cost stays a delta across a resume", async () => {
    const { ClaudeCodeDriver: _d } = await import("../src/harness/claude.ts");
    const { mapMessage } = await import("../src/harness/claude.ts");
    const state = { lastCost: 0.9, contextTokens: 0 }; // resumed session had already spent $0.90
    const [e] = mapMessage({ type: "result", subtype: "success", total_cost_usd: 0.95, session_id: "s", result: "", user_message_uuids: ["u1"] } as any, state);
    expect((e as any).costUsd).toBeCloseTo(0.05);
    expect((e as any).consumedUuids).toEqual(["u1"]);
    void _d;
  });
});

describe("Hub: interruptions", () => {
  test("quiet hours don't apply while the owner is active", async () => {
    const { hub, pusher, paths } = makeHub({ config: testConfig((c) => (c.settings.quietHours = { start: "00:00", end: "23:59" })) });
    hub.chat.add({ role: "user", kind: "text", text: "在", channel: "app" });
    expect(await hub.toolHandlers().notify_user({ text: "有事" })).toBe("已推送");
    expect(pusher.pushes).toHaveLength(1);
    cleanup(paths);
  });
});

describe("Hub: slash commands", () => {
  test("list merges harness commands, ours win, terminal-only ones hidden; loads on demand", async () => {
    const { hub, driver, paths } = makeHub();
    const list = await hub.loadCommands();
    expect(driver.sessions).toHaveLength(1); // started a session just to learn the list
    const names = list.map((c) => c.name);
    expect(names.slice(0, 2)).toEqual(["stop", "status"]);
    expect(names).toContain("compact");
    expect(names).toContain("pdf");
    expect(names).not.toContain("doctor");
    expect(names.filter((n) => n === "status")).toHaveLength(1);
    expect(list.find((c) => c.name === "pdf")!.argumentHint).toBe("<file>");
    cleanup(paths);
  });

  test("slash commands from WeChat reach the harness verbatim", async () => {
    const wechat = new FakeWechat();
    const { hub, driver, paths } = makeHub({ wechat });
    hub.userMessage("/compact", "wechat", { userId: "u", contextToken: "c" });
    await hub.idle();
    expect(driver.last!.sent[0]).toBe("/compact");
    cleanup(paths);
  });
});

describe("Hub: model & effort", () => {
  test("lists models, switches live, persists, and new sessions start with it", async () => {
    const { hub, driver, paths } = makeHub();
    const info = await hub.modelInfo();
    expect(info.models.map((m) => m.value)).toEqual(["default", "haiku"]);
    expect(info.effort).toBeNull();
    const st = await hub.setModel({ model: "haiku", effort: "low" });
    expect(st.effort).toBe("low");
    expect(driver.liveSwitches).toEqual(["model:haiku", "effort:low"]);
    expect(JSON.parse(await Bun.file(paths.config).text())).toMatchObject({ model: "haiku", effort: "low" });
    await hub.setModel({ effort: null });
    expect(hub.status().effort).toBeUndefined();
    hub.onIdle(); // close the process; the next one must start with the saved choice
    driver.last!.close();
    hub.userMessage("hi", "app");
    await hub.idle();
    expect(driver.last!.opts.model).toBe("haiku");
    await expect(hub.setModel({ effort: "turbo" })).rejects.toThrow();
    cleanup(paths);
  });
});

describe("Hub: settings can't break it", () => {
  test("bad timezone / quiet hours / timeouts are rejected; a bad file loads with defaults", async () => {
    const { hub, paths } = makeHub();
    expect(() => hub.updateSettings({ timezone: "Pacific Time" } as any)).toThrow("时区");
    expect(() => hub.updateSettings({ quietHours: { start: "23:00" } } as any)).toThrow("免打扰");
    expect(() => hub.updateSettings({ approvalTimeoutMinutes: 0 } as any)).toThrow();
    expect(() => hub.updateSettings({ nope: 1 } as any)).toThrow("没有这个设置");
    expect(hub.updateSettings({ timezone: "Asia/Shanghai" }).timezone).toBe("Asia/Shanghai");
    const { loadConfig } = await import("../src/config.ts");
    const raw = JSON.parse(await Bun.file(paths.config).text());
    raw.settings.timezone = "Mars/Olympus";
    raw.settings.quietHours = { start: "x" };
    writeJson(paths.config, raw);
    const cfg = loadConfig(paths);
    expect(cfg.settings.timezone).not.toBe("Mars/Olympus");
    expect(cfg.settings.quietHours).toEqual({ start: "23:00", end: "08:00" });
    // and a bad zone in memory never throws in the hot path
    hub.config.settings.timezone = "Bogus/Zone";
    hub.userMessage("hi", "app");
    await hub.idle();
    expect(hub.chat.recent(1)[0]!.text).toBe("收到：hi");
    cleanup(paths);
  });

  test("CLI-written config isn't clobbered by the daemon's stale copy", async () => {
    const { hub, paths } = makeHub();
    const raw = JSON.parse((await Bun.file(paths.config).exists()) ? await Bun.file(paths.config).text() : "{}");
    writeJson(paths.config, { ...raw, wechat: { enabled: true, baseUrl: "https://x" } });
    hub.updateSettings({ probeIntervalMinutes: 3 });
    const after = JSON.parse(await Bun.file(paths.config).text());
    expect(after.wechat.enabled).toBe(true);
    expect(after.settings.probeIntervalMinutes).toBe(3);
    cleanup(paths);
  });
});

describe("Hub: review regressions", () => {
  test("a hung pusher can't block notify_user or the turn", async () => {
    const { hub, paths } = makeHub();
    (hub as any).router.pushers = [{ name: "stuck", available: () => true, push: () => new Promise(() => {}) }];
    const t0 = Date.now();
    expect(await hub.toolHandlers().notify_user({ text: "有事" })).toBe("已推送");
    expect(Date.now() - t0).toBeLessThan(3000);
    cleanup(paths);
  });

  test("a stream cut off by an error is finalized; stop unsticks a hung tool", async () => {
    const { hub, driver, paths, events } = makeHub({
      script: async (t, ctx) => {
        if (t === "hang") {
          ctx.emit({ type: "tool_use", id: "h1", name: "Bash", input: { command: "sleep 9999" }, parentToolUseId: null });
          await new Promise(() => {});
        }
        ctx.emit({ type: "text_delta", text: "写到一半" });
        ctx.emit({ type: "error", message: "boom" });
      },
    });
    hub.userMessage("go", "app");
    await hub.idle();
    const deltaId = events.find((e) => e.event === "chat.delta")!.data.id;
    expect(hub.chat.recent(5).some((m) => m.id === deltaId && m.text === "写到一半")).toBe(true);
    hub.userMessage("hang", "app");
    await tick(10);
    expect(hub.status().busy).toBe(true);
    hub.stopAll("test");
    expect(hub.status().busy).toBe(false);
    void driver;
    cleanup(paths);
  });

  test("retried chat.send with the same clientMsgId runs once; memory writes refuse stale bases", async () => {
    const { handleRpc } = await import("../src/rpc.ts");
    const { hub, driver, paths } = makeHub();
    const ctx = { clientId: "c", channel: "app" as const, local: false };
    const a = (await handleRpc(hub, { method: "chat.send", params: { text: "发邮件", clientMsgId: "k1" } }, ctx)) as any;
    const b = (await handleRpc(hub, { method: "chat.send", params: { text: "发邮件", clientMsgId: "k1" } }, ctx)) as any;
    await hub.idle();
    expect(b).toEqual(a);
    expect(driver.last!.sent).toEqual(["发邮件"]);
    const r = (await handleRpc(hub, { method: "memory.read", params: { path: "user.md" } }, ctx)) as any;
    await handleRpc(hub, { method: "memory.write", params: { path: "user.md", content: "v1", baseUpdatedAt: r.updatedAt } }, ctx);
    await expect(handleRpc(hub, { method: "memory.write", params: { path: "user.md", content: "v2", baseUpdatedAt: r.updatedAt - 10_000 } }, ctx)).rejects.toThrow("刚被助理改过");
    cleanup(paths);
  });

  test("device.unpair drops the calling device; push.unregister drops its token", async () => {
    const { handleRpc } = await import("../src/rpc.ts");
    const { hub, paths } = makeHub();
    let dropped = "";
    hub.onUnpairDevice = (d) => (dropped = d);
    const ctx = { clientId: "app_1_dev-x", deviceId: "dev-x", channel: "app" as const, local: false };
    await handleRpc(hub, { method: "push.register", params: { token: "a".repeat(64) } }, ctx);
    await handleRpc(hub, { method: "push.unregister", params: { token: "a".repeat(64) } }, ctx);
    expect(JSON.parse(await Bun.file(paths.pushTokens).text())).toEqual([]);
    await handleRpc(hub, { method: "device.unpair", params: {} }, ctx);
    await tick(150);
    expect(dropped).toBe("dev-x");
    cleanup(paths);
  });
});

describe("Hub: runaway guard (no daily cap)", () => {
  test("a burst of schedule/probe pushes is held back after 5 in 10 minutes; same text isn't pushed twice", async () => {
    let n = 0;
    const { hub, pusher, paths } = makeHub({ script: async (_t, ctx) => ctx.emit({ type: "assistant_text", text: `晨报 ${++n}`, parentToolUseId: null }) });
    for (let i = 0; i < 7; i++) {
      (hub as any).onSchedule(hub.watches.add({ title: `定时 ${i}`, instruction: "写点什么", at: ["08:30"] }, "user"));
      await hub.idle();
    }
    expect(pusher.pushes).toHaveLength(5);
    expect(hub.chat.recent(30).filter((m) => m.proactive && m.channel === "schedule")).toHaveLength(7); // all still in the chat
    expect(hub.chat.recent(30).filter((m) => m.text.includes("异常频繁"))).toHaveLength(1); // told once
    // task results and notify_user are never held back by the guard
    expect(await hub.toolHandlers().notify_user({ text: "要紧事" })).toBe("已推送");
    cleanup(paths);
  });

  test("identical guarded text within an hour is pushed once", async () => {
    const { hub, pusher, paths } = makeHub({ script: async (_t, ctx) => ctx.emit({ type: "assistant_text", text: "一模一样", parentToolUseId: null }) });
    for (let i = 0; i < 2; i++) {
      (hub as any).onSchedule(hub.watches.add({ title: `x${i}`, instruction: "y", at: ["08:30"] }, "user"));
      await hub.idle();
    }
    expect(pusher.pushes).toHaveLength(1);
    cleanup(paths);
  });
});

describe("Hub: harness says which messages a turn answers", () => {
  test("a queued owner turn starts with exactly the uuids the harness names", async () => {
    const { hub, driver, paths } = makeHub({ script: async () => {} });
    hub.userMessage("hi", "app");
    await hub.idle();
    const s = driver.last!;
    // two owner messages in flight; the harness answers only the second first
    (hub as any).conversation.pending.set("u-a", { origin: "app", sentAt: Date.now() });
    (hub as any).conversation.pending.set("u-b", { origin: "wechat", wechat: { userId: "x", contextToken: "y" }, sentAt: Date.now() });
    s.opts.onEvent({ type: "answering", uuids: ["u-b"] });
    expect((hub as any).conversation.current.uuids).toEqual(["u-b"]);
    expect((hub as any).conversation.current.origin).toBe("wechat");
    cleanup(paths);
  });
});

describe("Hub: step-6 cleanups", () => {
  test("errors are worded by the SDK's own kind first", async () => {
    const { friendlyError } = await import("../src/copy.ts");
    expect(friendlyError("whatever", "billing_error")).toContain("额度");
    expect(friendlyError("whatever", "model_not_found")).toContain("换一个");
    expect(friendlyError("HTTP 429 Too Many Requests")).toContain("太忙");
  });

  test("the harness' own timers are disabled in favor of durable watches; env goes only to the harness", async () => {
    const { hub, driver, paths } = makeHub({ config: testConfig((c) => (c.env = { ANTHROPIC_BASE_URL: "https://example.invalid" })) });
    hub.userMessage("hi", "app");
    await hub.idle();
    expect(driver.last!.opts.env).toEqual({ ANTHROPIC_BASE_URL: "https://example.invalid" });
    expect(process.env.ANTHROPIC_BASE_URL).not.toBe("https://example.invalid");
    cleanup(paths);
  });
});

describe("Hub: images from the app", () => {
  test("uploaded images ride along with the message as image blocks", async () => {
    const { hub, driver, paths } = makeHub();
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==";
    const a = hub.media.save("image/png", png);
    const msg = hub.userMessage("这是什么", "app", undefined, undefined, [a])!;
    await hub.idle();
    expect(msg.attachments).toEqual([{ id: a.id, kind: "image", mediaType: "image/png" }]);
    expect(driver.last!.sentImages).toEqual([{ mediaType: "image/png", data: png }]);
    // an image alone is a valid message
    expect(hub.userMessage("", "app", undefined, undefined, [a])).not.toBeNull();
    expect(() => hub.media.save("image/tiff", png)).toThrow();
    expect(hub.media.read("../../etc/passwd")).toBeNull();
    cleanup(paths);
  });
});

describe("Hub: files to the owner (SendUserFile / Artifact)", () => {
  test("files go to the library and show as cards; temporary ones don't; odd images are converted", async () => {
    const { hub, pusher, paths } = makeHub();
    const h = hub.toolHandlers();
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==", "base64");
    writeFileSync(`${paths.home}/chart.png`, png);
    writeFileSync(`${paths.home}/report.pdf`, "%PDF-1.4 x");

    // kept: relative path, two files, one card each, both in the library
    expect(await h.SendUserFile({ files: ["chart.png", "report.pdf"], caption: "周报", status: "normal" })).toContain("产出物库");
    const card = hub.chat.since(0).at(-1)!;
    expect(card.text).toBe("周报");
    expect(card.attachments!.map((a) => a.kind)).toEqual(["artifact", "artifact"]);
    expect(card.attachments![1]!.mediaType).toBe("application/pdf");
    expect(hub.artifacts.list().map((a) => a.title).sort()).toEqual(["chart.png", "report.pdf"]);
    // same path again updates, not duplicates
    await h.SendUserFile({ files: ["report.pdf"], status: "normal" });
    expect(hub.artifacts.list()).toHaveLength(2);

    // temporary: in the conversation only; a TIFF becomes a JPEG
    Bun.spawnSync(["sips", "-s", "format", "tiff", `${paths.home}/chart.png`, "--out", `${paths.home}/x.tiff`]);
    await h.SendUserFile({ files: ["x.tiff"], status: "normal", temporary: true });
    const tmp = hub.chat.since(0).at(-1)!.attachments![0]!;
    expect(tmp).toMatchObject({ kind: "image", mediaType: "image/jpeg" });
    expect(hub.artifacts.list()).toHaveLength(2);
    // proactive reaches the phone
    await h.SendUserFile({ files: ["chart.png"], status: "proactive", temporary: true });
    await tick(20);
    expect(pusher.pushes.length).toBeGreaterThan(0);
    expect(await h.SendUserFile({ files: ["nope.txt"], status: "normal" })).toContain("没发出去");

    // Artifact: a multi-file page, published again = updated
    writeFileSync(`${paths.home}/page.html`, '<img src="img/c.png">');
    expect(await h.Artifact({ file_path: "page.html", title: "看板", files: { "img/c.png": "chart.png" } })).toContain("看板");
    const page = hub.artifacts.list().find((a) => a.title === "看板")!;
    expect(page.files.map((f) => f.path).sort()).toEqual(["img/c.png", "page.html"]);
    expect(await h.Artifact({ file_path: "page.html", files: { "../evil": "chart.png" } })).toContain("没发布成功");
    await h.Artifact({ file_path: "page.html" });
    expect(hub.artifacts.list().filter((a) => a.title === "看板")).toHaveLength(1);
    cleanup(paths);
  });
});

describe("Hub: files from the app", () => {
  test("chunked upload: in order, basename only, size cap; a sent file reaches the harness as a path", async () => {
    const { hub, driver, paths } = makeHub();
    const b64 = (s: string) => Buffer.from(s).toString("base64");
    const first = hub.media.uploadChunk({ name: "../../etc/报告.txt", offset: 0, data: b64("hello "), done: false }) as { uploadId: string };
    expect(first.uploadId).toMatch(/^up_/);
    // out of order is refused
    expect(() => hub.media.uploadChunk({ uploadId: first.uploadId, name: "报告.txt", offset: 0, data: b64("x"), done: false })).toThrow();
    const att = hub.media.uploadChunk({ uploadId: first.uploadId, name: "报告.txt", offset: 6, data: b64("world"), done: true }) as any;
    expect(att).toMatchObject({ kind: "file", name: "报告.txt", size: 11, mediaType: "text/plain" });
    expect(Buffer.from(hub.media.readChunk(att.id).data, "base64").toString()).toBe("hello world");
    expect(hub.media.filePath(att.id)!.includes("..")).toBe(false);
    // a stale / unknown upload id, a chunk that's too big, a non-zero first offset
    expect(() => hub.media.uploadChunk({ uploadId: first.uploadId, name: "a", offset: 11, data: "", done: true })).toThrow();
    expect(() => hub.media.uploadChunk({ name: "a", offset: 0, data: Buffer.alloc(300 * 1024).toString("base64"), done: true })).toThrow();
    expect(() => hub.media.uploadChunk({ name: "a", offset: 5, data: b64("x"), done: true })).toThrow();

    hub.userMessage("看看这个", "app", undefined, undefined, [hub.media.attachment(att.id)!]);
    await hub.idle();
    expect(driver.last!.sent.at(-1)).toBe(`看看这个\n[文件] ${hub.media.filePath(att.id)}`);
    expect(driver.last!.sentImages).toEqual([]);
    cleanup(paths);
  });
});
