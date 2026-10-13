// Live: the Ally turn's gate (docs/allies-prd.md §11.5) against real Claude
// Code in auto mode, with a model that has auto mode (default: sonnet; Haiku
// doesn't, and Claude Code then quietly runs in "default"). Costs real tokens
// (about $0.15). Run with:
//   PALOALLY_LIVE_ALLY_GATE=1 bun test test/allyGate.live.test.ts
// PALOALLY_LIVE_MODEL picks the model; PALOALLY_LIVE_TRACE=1 prints events.
//
// Benign on purpose: no adversarial words. The gate is turned on for an
// ordinary request (the host's own turn state, as an Ally's message sets it),
// and the same request then runs with the gate off. Then one real Ally
// question at 能对话, over an in-memory relay to a scripted host.
//
// Kept apart from the owner's own setup: a temp root, its own session name
// (never the assistant's "Palo"), PALOALLY_SESSION=1 (the host sets it, so
// PaloAlly's global hooks stay out), no MCP servers but the host's own (no
// connectors, no calendar), no browser. What Claude Code wrote for the temp
// folder under ~/.claude is removed at the end.
import { afterAll, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync, realpathSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { isCalendarReadTool } from "../src/allyGate.ts";
import { ClaudeCodeDriver } from "../src/harness/claude.ts";
import type { HarnessEvent, MainSession, MainSessionOptions, Spawner } from "../src/harness/types.ts";
import { AllyNet, befriend } from "./allyNet.ts";
import { waitFor } from "./relayClient.ts";

const LIVE = process.env.PALOALLY_LIVE_ALLY_GATE === "1";
const MODEL = process.env.PALOALLY_LIVE_MODEL ?? "sonnet";
const TRACE = process.env.PALOALLY_LIVE_TRACE === "1";
const d = LIVE ? describe : describe.skip;
const T = 240_000;
const ASK = "运行 echo hello 看看输出";

// The real driver, with the session under its own name and only the host's
// own MCP server (--strict-mcp-config drops the owner's servers and claude.ai
// connectors).
class IsolatedDriver extends ClaudeCodeDriver {
  readonly peer = `palo-live-gate-${randomBytes(3).toString("hex")}`;
  envs: Record<string, string | undefined>[] = [];
  procs: ChildProcess[] = [];

  override startMain(opts: MainSessionOptions): MainSession {
    const spawner: Spawner = (req) => {
      this.envs.push(req.env);
      const p = spawn(req.command, [...req.args, "--strict-mcp-config"], { cwd: req.cwd, env: req.env as NodeJS.ProcessEnv, stdio: ["pipe", "pipe", "pipe"] });
      p.stderr?.on("data", (b) => TRACE && process.stderr.write(`[cc] ${b}`));
      req.signal?.addEventListener("abort", () => p.exitCode === null && p.signalCode === null && p.kill("SIGTERM"));
      this.procs.push(p);
      return p as unknown as ReturnType<Spawner>;
    };
    return super.startMain({ ...opts, name: this.peer, env: { ...opts.env, ENABLE_CLAUDEAI_MCP_SERVERS: "false" }, spawn: spawner });
  }
}

// ~/.claude/projects/<folder> as Claude Code names it (it may use the real path).
function projectDirs(cwd: string): string[] {
  const names = new Set([resolve(cwd), realpathSync(cwd)].map((p) => p.replace(/[^A-Za-z0-9]/g, "-")));
  return [...names].map((n) => join(homedir(), ".claude", "projects", n));
}

d(`live: the Ally turn's gate in auto mode (${MODEL})`, () => {
  const driver = new IsolatedDriver();
  const net = new AllyNet();
  const a = net.add("家人A", {
    harness: driver,
    config: (c) => {
      c.model = MODEL;
      c.permissionMode = "auto";
      c.browser.enabled = false;
      c.settings.approvalTimeoutMinutes = 5;
    },
  });
  const b = net.add("家人B");
  const hub = a.hub;
  const home = a.ctx.paths.home;
  const dirs = projectDirs(home);
  const sessionIds = new Set<string>();

  const events: HarnessEvent[] = [];
  const orig = hub.onHarnessEvent.bind(hub);
  hub.onHarnessEvent = (e) => {
    if (e.type !== "text_delta") events.push(e);
    if (e.type === "init") sessionIds.add(e.sessionId);
    if (TRACE && e.type !== "text_delta") console.log(`[trace] ${JSON.stringify(e).slice(0, 300)}`);
    orig(e);
  };
  // Anything the harness would ask the owner about: refused at once, and counted.
  const asked: string[] = [];
  hub.bus.on((event, data: any) => {
    if (event === "approval.updated" && data.status === "pending") {
      asked.push(data.tool);
      setTimeout(() => hub.approvals.answer(data.id, false, "test"), 10);
    }
  });

  const audits = (type: string) => hub.audit.tail(500).filter((e) => e.type === type) as any[];
  const mainTools = (from: number) => events.slice(from).filter((e): e is Extract<HarnessEvent, { type: "tool_use" }> => e.type === "tool_use" && !e.parentToolUseId);
  const resultsOf = (from: number, ids: string[]) =>
    events.slice(from).filter((e): e is Extract<HarnessEvent, { type: "tool_result" }> => e.type === "tool_result" && ids.includes(e.toolUseId));

  afterAll(async () => {
    for (const h of net.hosts.values()) h.hub.stop();
    // Claude Code writes a last few lines to the transcript as it exits: let it finish first.
    await Promise.all(
      driver.procs.map((p) =>
        p.exitCode !== null || p.signalCode !== null
          ? null
          : new Promise((done) => {
              p.once("exit", done);
              setTimeout(() => (p.kill("SIGKILL"), done(null)), 10_000);
            }),
      ),
    );
    const removed: string[] = [];
    for (const dir of dirs) if (existsSync(dir)) (rmSync(dir, { recursive: true, force: true }), removed.push(dir));
    // per-session leftovers, by this run's session ids only
    for (const sub of ["file-history", "session-env", "todos", "debug"]) {
      const base = join(homedir(), ".claude", sub);
      if (!existsSync(base)) continue;
      for (const name of readdirSync(base)) {
        if ([...sessionIds].some((sid) => name.startsWith(sid))) (rmSync(join(base, name), { recursive: true, force: true }), removed.push(join(base, name)));
      }
    }
    console.log(`[live] removed: ${JSON.stringify(removed)}`);
    console.log(`[live] usage: ${JSON.stringify(hub.usage())}`);
  });

  test(
    "gate on: the model tries Bash, auto mode would run it, and the PreToolUse hook denies it first",
    async () => {
      const from = events.length;
      // The host's own turn state for an Ally's message, on an ordinary request.
      hub.conversation.enqueue({ text: ASK, origin: "app", proactive: false, allyId: "al_live_gate" });
      await hub.idle();

      const init = events.find((e) => e.type === "init") as Extract<HarnessEvent, { type: "init" }>;
      console.log(`[live] init: model=${init.model} permissionMode=${init.permissionMode} peer=${driver.peer} PALOALLY_SESSION=${driver.envs[0]?.PALOALLY_SESSION}`);
      expect(init.permissionMode).toBe("auto");
      expect(hub.conversation.permissionMode).toBe("auto");
      expect(audits("harness.mode_mismatch")).toEqual([]);
      expect(driver.envs[0]?.PALOALLY_SESSION).toBe("1");

      const bash = mainTools(from).filter((t) => t.name === "Bash");
      expect(bash.length).toBeGreaterThan(0);
      const denied = audits("ally.tool.denied").filter((x) => x.tool === "Bash");
      console.log(`[live] denied: ${JSON.stringify(denied)}`);
      expect(denied.length).toBe(bash.length);
      expect(denied.every((x) => x.via === "hook" && x.allyId === "al_live_gate")).toBe(true);
      const results = resultsOf(from, bash.map((t) => t.id));
      expect(results.length).toBe(bash.length);
      expect(results.every((r) => r.isError && r.content.includes("没有执行 Bash"))).toBe(true);
      expect(asked).toEqual([]); // denied before Claude Code's own permission step
      expect(audits("ally.turn.end").at(-1)).toMatchObject({ allyId: "al_live_gate", why: "done" });
    },
    T,
  );

  test(
    "gate off: the same request runs, approved without asking anyone",
    async () => {
      const from = events.length;
      const deniedBefore = audits("ally.tool.denied").length;
      hub.userMessage(ASK, "app");
      await hub.idle();
      const bash = mainTools(from).filter((t) => t.name === "Bash");
      expect(bash.length).toBeGreaterThan(0);
      const results = resultsOf(from, bash.map((t) => t.id));
      console.log(`[live] ran: ${JSON.stringify(results.map((r) => ({ isError: r.isError, content: r.content.slice(0, 80) })))}`);
      expect(results.some((r) => !r.isError && /hello/.test(r.content))).toBe(true);
      expect(audits("ally.tool.denied").length).toBe(deniedBefore);
      expect(asked).toEqual([]);
    },
    T,
  );

  test(
    "能对话: an Ally's question is answered to the Ally with ally_send, straight out",
    async () => {
      const init = events.find((e) => e.type === "init") as Extract<HarnessEvent, { type: "init" }>;
      expect(init.tools.filter(isCalendarReadTool)).toEqual([]); // no calendar to look at
      await befriend(a, b);
      const toB = hub.allies.list()[0]!;
      hub.allies.setTrust(toB.id, "converse");
      const from = events.length;
      const chatBefore = hub.chat.lastSeq;
      const toA = b.hub.allies.list()[0]!;
      b.hub.allies.say(toA.id, "周六下午有空吗？");
      await waitFor(() => audits("ally.turn.end").some((x) => x.allyId === toB.id), 180_000);
      await hub.idle();

      const tools = mainTools(from).map((t) => t.name);
      const toOwner = hub.chat
        .since(chatBefore)
        .filter((m) => m.role === "assistant" && m.kind === "text")
        .map((m) => m.text);
      const out = hub.allies.log(toB.id).filter((e) => e.dir === "out");
      console.log(`[live] converse: tools=${JSON.stringify(tools)} out=${JSON.stringify(out.map((e) => ({ status: e.status, author: e.author, text: e.text })))} toOwner=${JSON.stringify(toOwner)}`);
      expect(tools).toContain("mcp__paloally__ally_send");
      expect(out.length).toBeGreaterThan(0);
      expect(out.every((e) => e.author === "assistant" && e.status !== "draft")).toBe(true);
      await waitFor(() => b.hub.allies.log(toA.id).some((e) => e.dir === "in"));
      expect(audits("ally.tool.denied").filter((x) => x.allyId === toB.id)).toEqual([]);
    },
    T,
  );
});
