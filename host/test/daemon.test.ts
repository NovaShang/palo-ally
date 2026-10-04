// Daemon + local unix socket + the real CLI binary, with a scripted harness.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { LocalClient } from "../src/channels/local.ts";
import { type Daemon, startDaemon } from "../src/daemon.ts";
import { FakeDriver } from "../src/harness/fake.ts";
import { launchdPlist, systemdUnit } from "../src/service.ts";
import { cleanup, testConfig, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const CLI = resolve(import.meta.dir, "../src/cli.ts");

describe("daemon over the local socket", () => {
  const paths = tmpPaths();
  let d: Daemon;
  const driver = new FakeDriver(async (t, ctx) => {
    if (t === "do a task") {
      ctx.emit({ type: "tool_use", id: "a1", name: "Agent", input: { description: "示例任务" }, parentToolUseId: null });
      await ctx.opts.tools.report_task({ id: "demo", summary: "开始了", status: "running", title: "示例任务" });
      return;
    }
    if (t === "risky") {
      await ctx.useTool("Bash", { command: "rm -rf ~/tmp/thing" }, { ask: true, defaultToNo: true });
      return;
    }
    ctx.emit({ type: "assistant_text", text: `回声：${t}`, parentToolUseId: null });
  });

  beforeAll(async () => {
    d = await startDaemon(paths, { driver, config: testConfig(), relay: false, probe: false });
  });
  afterAll(() => {
    d.stop();
    cleanup(paths);
  });

  const cli = async (...args: string[]) => {
    const p = Bun.spawn(["bun", CLI, ...args], { env: { ...process.env, PALOALLY_HOME: paths.root }, stdout: "pipe", stderr: "pipe" });
    const [out, err] = [await new Response(p.stdout).text(), await new Response(p.stderr).text()];
    await p.exited;
    return { out, err, code: p.exitCode };
  };

  test("RPC + events on the socket", async () => {
    const c = await LocalClient.connect(paths.socket);
    const events: string[] = [];
    c.onEvent = (e, data) => events.push(`${e}:${data?.text ?? ""}`);
    const hello = await c.call("hello", { client: "cli" });
    expect(hello.status.online).toBe(true);
    await c.call("chat.send", { text: "hi" });
    await waitFor(() => events.includes("chat.message:回声：hi"));
    const sync = await c.call("sync", { sinceSeq: 0 });
    expect(sync.messages.map((m: any) => m.channel)).toEqual(["cli", "cli"]);
    await expect(c.call("nope")).rejects.toThrow("unknown method");
    c.close();
  });

  test("CLI: chat one-shot, status, tasks, watch, settings, stop, audit", async () => {
    let r = await cli("chat", "你好呀");
    expect(r.out).toContain("回声：你好呀");

    r = await cli("chat", "do a task");
    r = await cli("tasks");
    expect(r.out).toContain("示例任务 — 开始了");

    r = await cli("watch", "add", "晨报", "整理今天日程", "--at", "08:30");
    expect(r.out).toContain("已添加");
    r = await cli("watch", "list");
    expect(r.out).toContain("晨报");
    expect(r.out).toContain("08:30");

    r = await cli("settings", "maxProactivePerDay", "3");
    expect(JSON.parse(r.out).maxProactivePerDay).toBe(3);
    r = await cli("settings", "quietHours", "22:00-07:30");
    expect(JSON.parse(r.out).quietHours).toEqual({ start: "22:00", end: "07:30" });

    r = await cli("status");
    expect(r.out).toContain("空闲");
    expect(r.out).toContain("远程：关闭");

    r = await cli("stop");
    expect(r.out).toContain("停下");

    r = await cli("audit", "50");
    expect(r.out).toContain("stop");

    r = await cli("metrics", "7");
    expect(r.out).toContain("任务：1 个");
    expect(r.out).toContain("对话：");

    r = await cli("memory");
    expect(r.out).toContain("user.md");
  }, 60_000);

  test("CLI: approve a pending careful action by short id", async () => {
    const c = await LocalClient.connect(paths.socket);
    await c.call("chat.send", { text: "risky" });
    await waitFor(() => d.hub.approvals.listPending().length === 1);
    const a = d.hub.approvals.listPending()[0]!;
    let r = await cli("approvals");
    expect(r.out).toContain(a.id.slice(-4));
    expect(r.out).toContain("请仔细看");
    r = await cli("deny", a.id.slice(-4));
    expect(r.out.trim()).toBe("denied");
    c.close();
  }, 30_000);

  test("large responses arrive intact (partial writes, multibyte text)", async () => {
    const big = "长消息，带中文和 emoji 🎉。".repeat(200);
    for (let i = 0; i < 120; i++) d.hub.chat.add({ role: "assistant", kind: "text", text: `${i}:${big}`, channel: "system" });
    const c = await LocalClient.connect(paths.socket);
    for (let round = 0; round < 3; round++) {
      const sync = await c.call("sync", { sinceSeq: 0 });
      const bigOnes = sync.messages.filter((m: any) => m.text.endsWith(big));
      expect(bigOnes.length).toBe(120);
    }
    c.close();
  }, 30_000);

  test("LineReader decodes characters split across chunks", async () => {
    const { LineReader } = await import("../src/channels/local.ts");
    const bytes = new TextEncoder().encode(JSON.stringify({ t: "你好🎉" }) + "\n");
    const r = new LineReader();
    const out: string[] = [];
    for (let i = 0; i < bytes.length; i++) out.push(...r.push(bytes.subarray(i, i + 1)));
    expect(out.map((l) => JSON.parse(l).t)).toEqual(["你好🎉"]);
  });

  test("CLI errors cleanly when the daemon is down", async () => {
    const other = tmpPaths();
    const p = Bun.spawn(["bun", CLI, "status"], { env: { ...process.env, PALOALLY_HOME: other.root }, stderr: "pipe" });
    const err = await new Response(p.stderr).text();
    await p.exited;
    expect(p.exitCode).toBe(1);
    expect(err).toContain("助理没在运行");
    cleanup(other);
  });

  test("socket path stays under the unix limit for deep roots", async () => {
    const { Paths } = await import("../src/config.ts");
    const deep = new Paths("/" + "x".repeat(120));
    expect(deep.socket.startsWith("/tmp/paloally-")).toBe(true);
    expect(new Paths("/a").socket).toBe("/a/run/host.sock");
  });

  test("service files", () => {
    const plist = launchdPlist(paths, "/opt/bun");
    expect(plist).toContain("<string>/opt/bun</string>");
    expect(plist).toContain("<key>KeepAlive</key><true/>");
    expect(plist).toContain(paths.root);
    expect(systemdUnit(paths, "/opt/bun")).toContain("Restart=always");
  });
});
