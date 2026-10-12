import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Courier, modeClass } from "../src/courier.ts";

// A stand-in for the Agent SDK's query(): a "model" that paraphrases what it
// was asked to send (as Haiku did in the spike) and tries to send twice.
function fakeQuery(log: { options: any[]; delivered: any[]; turns: string[] }, o: { fail?: boolean; noSend?: boolean } = {}) {
  return ((args: { prompt: AsyncIterable<any>; options: any }) => {
    log.options.push(args.options);
    let closed = false;
    const hook = args.options.hooks.PreToolUse[0].hooks[0];
    let total = 0;
    async function* run() {
      for await (const m of args.prompt) {
        if (closed) return;
        const text = String(m.message.content);
        log.turns.push(text);
        if (!o.noSend) {
          const first = await hook({ hook_event_name: "PreToolUse", tool_name: "SendMessage", tool_use_id: "t1", tool_input: { to: "the site session", message: "Reply with: done", content: "Reply with: done" } });
          const out = first.hookSpecificOutput;
          if (out.permissionDecision === "allow") log.delivered.push(out.updatedInput);
          // the model tries again; refused
          const second = await hook({ hook_event_name: "PreToolUse", tool_name: "SendMessage", tool_use_id: "t2", tool_input: { to: "x", message: "y" } });
          expect(second.hookSpecificOutput.permissionDecision).toBe("deny");
          yield {
            type: "user",
            message: {
              role: "user",
              content: [{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: o.fail ? '{"success":false,"message":"no such session"}' : '{"success":true,"message":"sent","msg_id":"abc-1"}' }] }],
            },
          };
        }
        total += 0.004;
        yield { type: "result", subtype: "success", total_cost_usd: total };
      }
    }
    const it = run();
    return Object.assign(it, {
      interrupt: async () => {},
      close: () => {
        closed = true;
      },
    });
  }) as any;
}

describe("the courier", () => {
  test("the exact recipient and words go into SendMessage, whatever the model wrote; one send per message", async () => {
    const log = { options: [] as any[], delivered: [] as any[], turns: [] as string[] };
    const courier = new Courier({ cwd: mkdtempSync(join(tmpdir(), "courier-")), query: fakeQuery(log), env: () => ({ PATH: "/usr/bin", CLAUDE_CODE_SESSION_ID: "mine", CLAUDECODE: "1" }) });
    const r = await courier.send({ to: "uds:/tmp/cc-socks/1.sock", label: "网站帮手", message: "主人：先别管登录页，把列表页做完", mode: "prompting" });
    expect(r).toEqual({ msgId: "abc-1", costUsd: 0.004 });
    expect(log.delivered).toEqual([{ to: "uds:/tmp/cc-socks/1.sock", message: "主人：先别管登录页，把列表页做完", content: "主人：先别管登录页，把列表页做完" }]);
    expect(log.turns[0]).toBe("TO: 网站帮手\nTEXT:\n主人：先别管登录页，把列表页做完");
    // the same session takes the next one
    await courier.send({ to: "uds:/tmp/cc-socks/1.sock", label: "网站帮手", message: "主人：好", mode: "prompting" });
    expect(log.options).toHaveLength(1);
    const opt = log.options[0];
    expect(opt).toMatchObject({ model: "haiku", thinking: { type: "disabled" }, tools: ["SendMessage", "ToolSearch"], extraArgs: { name: "PaloAlly" }, permissionMode: "default", settingSources: [] });
    // the host's own session: the global hooks skip it; no variables of a session it runs in
    expect(opt.env.PALOALLY_SESSION).toBe("1");
    expect(opt.env.CLAUDE_CODE_SESSION_ID).toBeUndefined();
    expect(opt.env.CLAUDECODE).toBeUndefined();
    expect(await opt.canUseTool("Bash", {})).toMatchObject({ behavior: "deny" });
    expect(await opt.canUseTool("SendMessage", { to: "a" })).toMatchObject({ behavior: "allow" });
    // a bypass-mode recipient gets a courier of that class
    await courier.send({ to: "x", label: "x", message: "主人：hi", mode: "bypass" });
    expect(log.options).toHaveLength(2);
    expect(log.options[1]).toMatchObject({ permissionMode: "bypassPermissions", allowDangerouslySkipPermissions: true });
    expect(courier.running).toBe(2);
    courier.close();
    expect(courier.running).toBe(0);
  });

  test("not delivered: the send fails with why", async () => {
    const log = { options: [] as any[], delivered: [] as any[], turns: [] as string[] };
    const failing = new Courier({ cwd: mkdtempSync(join(tmpdir(), "courier-")), query: fakeQuery(log, { fail: true }) });
    await expect(failing.send({ to: "x", label: "x", message: "主人：hi", mode: "prompting" })).rejects.toThrow("没送到");
    const idle = new Courier({ cwd: mkdtempSync(join(tmpdir(), "courier-")), query: fakeQuery(log, { noSend: true }) });
    await expect(idle.send({ to: "x", label: "x", message: "主人：hi", mode: "prompting" })).rejects.toThrow("没送到");
    failing.close();
    idle.close();
  });

  test("closes after 10 quiet minutes (here: a few ms) and starts again for the next message", async () => {
    const log = { options: [] as any[], delivered: [] as any[], turns: [] as string[] };
    const courier = new Courier({ cwd: mkdtempSync(join(tmpdir(), "courier-")), query: fakeQuery(log), idleMs: 20 });
    await courier.send({ to: "x", label: "x", message: "主人：1", mode: "prompting" });
    await new Promise((r) => setTimeout(r, 50));
    expect(courier.running).toBe(0);
    await courier.send({ to: "x", label: "x", message: "主人：2", mode: "prompting" });
    expect(log.options).toHaveLength(2);
    courier.close();
  });

  test("permission modes come in two classes", () => {
    expect(modeClass("bypassPermissions")).toBe("bypass");
    for (const m of ["default", "auto", "acceptEdits", "plan", undefined]) expect(modeClass(m)).toBe("prompting");
  });
});
