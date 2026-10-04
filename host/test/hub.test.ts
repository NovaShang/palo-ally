import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import type { WechatChannel, WechatReplyTarget } from "../src/hub.ts";
import type { FakeScript } from "../src/harness/fake.ts";
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

  test("turns are serialized: a second message waits for the first", async () => {
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

  test("roll: flush turn (hidden) then a fresh session", async () => {
    const { hub, driver, paths, events } = makeHub({
      config: testConfig((c) => {
        c.session.idleCloseMinutes = 1;
        c.session.rollAfterTokens = 500; // fake reports 1000 context tokens
      }),
      script: async (t, ctx) => ctx.emit({ type: "assistant_text", text: t.startsWith("[系统]") ? "[skip]" : "ok", parentToolUseId: null }),
    });
    hub.userMessage("hi", "app");
    await hub.idle();
    const before = events.filter((e) => e.event === "chat.message").length;
    hub.onIdle();
    await hub.idle();
    expect(driver.last!.sent.at(-1)).toContain("写进你的记忆");
    expect(events.filter((e) => e.event === "chat.message").length).toBe(before); // flush is invisible
    expect(readJson<any>(paths.runtime, {}).sessionId).toBeUndefined();
    hub.userMessage("again", "app");
    await hub.idle();
    expect(driver.last!.opts.resumeSessionId).toBeUndefined();
    const metrics = readJsonl<any>(paths.metrics);
    expect(metrics.some((m) => m.type === "roll")).toBe(true);
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
    expect(texts(hub.chat.recent(5)).some((t) => t.includes("出了点问题"))).toBe(true);
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

  test("quiet hours and the daily cap suppress pushes but keep the chat", async () => {
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
    hub.updateSettings({ quietHours: null, maxProactivePerDay: 1 });
    expect(await h.notify_user({ text: "a" })).toBe("已推送");
    expect(await h.notify_user({ text: "b" })).toContain("上限");
    expect(hub.chat.recent(10).filter((m) => m.proactive)).toHaveLength(4);
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

  test("task.stop and kill stop running tasks", async () => {
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

describe("Hub: safety", () => {
  test("irreversible action asks; WeChat '同意' answers it (first answer wins)", async () => {
    let ran = null as boolean | null;
    const script: FakeScript = async (_t, ctx) => {
      ran = await ctx.useTool("Bash", { command: "git push origin main" });
      ctx.emit({ type: "assistant_text", text: ran ? "推上去了" : "没推", parentToolUseId: null });
    };
    const wechat = new FakeWechat();
    const { hub, pusher, paths } = makeHub({ script, wechat });
    hub.userMessage("把代码推上去", "app");
    await tick(10);
    const pending = hub.approvals.listPending();
    expect(pending).toHaveLength(1);
    expect(pending[0]!.irreversible).toBe(true);
    const card = hub.chat.recent(5).find((m) => m.kind === "approval")!;
    expect(card.approvalId).toBe(pending[0]!.id);
    expect(pusher.pushes.some((p) => p.title === "需要你确认")).toBe(true);
    // WeChat only gets a hint, not the command
    expect(wechat.proactive[0]).toContain("有个操作等你确认");
    expect(wechat.proactive[0]).not.toContain("git push");

    hub.userMessage("同意", "wechat", { userId: "u", contextToken: "c" });
    await hub.idle();
    expect(ran).toBe(true);
    expect(hub.approvals.answer(pending[0]!.id, false, "app")!.status).toBe("allowed");
    const audit = hub.audit.tail(50);
    expect(audit.some((e) => e.type === "approval.decided" && e.by === "wechat")).toBe(true);
    expect(audit.some((e) => e.type === "tool" && String(e.input).includes("git push"))).toBe(true);
    cleanup(paths);
  });

  test("kill switch: interrupts, denies pending, refuses new work until resume", async () => {
    let result = null as boolean | null;
    const script: FakeScript = async (t, ctx) => {
      if (t === "push") result = await ctx.useTool("Bash", { command: "rm -rf /tmp/x" });
      else ctx.emit({ type: "assistant_text", text: "ok", parentToolUseId: null });
    };
    const { hub, driver, paths } = makeHub({ script });
    hub.userMessage("push", "app");
    await tick(10);
    expect(hub.approvals.listPending()).toHaveLength(1);
    hub.userMessage("/kill", "wechat", { userId: "u", contextToken: "c" });
    await hub.idle();
    expect(result).toBe(false);
    expect(hub.status().killed).toBe(true);
    expect(hub.approvals.preGate("Read", {}).decision).toBe("deny");
    hub.userMessage("在吗", "app");
    await hub.idle();
    expect(hub.chat.recent(1)[0]!.text).toContain("急停");
    expect(driver.last!.sent).toEqual(["push"]);
    // persisted across restart
    const { hub: again } = makeHub({ paths });
    expect(again.status().killed).toBe(true);
    hub.userMessage("/resume", "app");
    hub.userMessage("在吗", "app");
    await hub.idle();
    expect(hub.chat.recent(1)[0]!.text).toBe("ok");
    cleanup(paths);
  });

  test("approval command needs an id when several are pending", async () => {
    const script: FakeScript = async (_t, ctx) => {
      await Promise.all([ctx.useTool("Bash", { command: "rm a" }), ctx.useTool("Bash", { command: "rm b" })]);
    };
    const { hub, paths } = makeHub({ script });
    hub.userMessage("x", "app");
    await tick(10);
    hub.userMessage("同意", "app");
    expect(hub.chat.recent(1)[0]!.text).toContain("请带上编号");
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

  test("owner speaking during a proactive turn turns it visible", async () => {
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
    const texts = hub.chat.recent(10).filter((m) => m.role === "assistant").map((m) => m.text);
    expect(texts).toEqual(["晨报第一段", "晨报第二段", "回：在吗"]);
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
  test("read-only tools never ask; quiet hours don't apply while the owner is active", async () => {
    const { hub, pusher, paths } = makeHub({ config: testConfig((c) => (c.settings.quietHours = { start: "00:00", end: "23:59" })) });
    for (const t of ["Read", "Grep", "Glob", "WebSearch"]) expect(hub.approvals.preGate(t, {}).decision).toBe("allow");
    expect(hub.approvals.preGate("Bash", { command: "ls" }).decision).toBe("pass");
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
    expect(names.slice(0, 3)).toEqual(["kill", "resume", "status"]);
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
