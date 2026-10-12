import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync, lstatSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HOOK_EVENTS, HookInstaller, HookServer, TRUST_LINE, isPaloAllyHook } from "../src/ccHooks.ts";
import { tmpPaths } from "./helpers.ts";

function setup() {
  const paths = tmpPaths();
  const claudeDir = mkdtempSync(join(tmpdir(), "paloally-cc-"));
  const inst = new HookInstaller({ paths, claudeDir });
  return { paths, claudeDir, inst, file: join(claudeDir, "settings.json") };
}

// A settings file with the owner's own hooks and other settings, 4-space indented.
const OWNER = {
  permissions: { allow: ["Bash(npm test:*)"], defaultMode: "default" },
  hooks: {
    Stop: [{ hooks: [{ type: "command", command: "afplay /System/Library/Sounds/Glass.aiff" }] }],
    PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "~/bin/check.sh", timeout: 10 }] }],
  },
  model: "opus",
};

// Runs the installed hook like Claude Code does: through a shell, the payload on stdin.
function runHook(paths: { bin: string }, payload: any, env: Record<string, string> = {}): Promise<{ out: string; ms: number; code: number | null }> {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const p = spawn("/bin/sh", ["-c", `'${join(paths.bin, "cc-hook")}' ${payload.hook_event_name} # PaloAlly`], { env: { ...process.env, PALOALLY_SESSION: "", ...env } });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.on("close", (code) => resolve({ out, ms: performance.now() - t0, code }));
    p.stdin.end(JSON.stringify(payload));
  });
}

const perm = { session_id: "s-1", cwd: "/tmp/x", hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "npm run build" } };

describe("global hook install", () => {
  test("install appends PaloAlly's entries after the owner's; uninstall gives back the same file, byte for byte", async () => {
    const { inst, file, paths } = setup();
    const original = JSON.stringify(OWNER, null, 4) + "\n";
    writeFileSync(file, original);
    expect(inst.installed()).toBe(false);
    inst.install();
    expect(inst.installed()).toBe(true);
    const s = JSON.parse(readFileSync(file, "utf8"));
    // the owner's hooks are untouched and first
    expect(s.hooks.Stop[0]).toEqual(OWNER.hooks.Stop[0]);
    expect(s.hooks.PreToolUse).toEqual(OWNER.hooks.PreToolUse);
    expect(s.permissions).toEqual(OWNER.permissions);
    for (const [ev, timeout] of Object.entries(HOOK_EVENTS)) {
      const ours = s.hooks[ev].at(-1).hooks[0];
      expect(isPaloAllyHook(ours)).toBe(true);
      expect(ours.timeout).toBe(timeout);
      expect(ours.command).toBe(`'${join(paths.bin, "cc-hook")}' ${ev} # PaloAlly`);
    }
    expect(s.hooks.PermissionRequest[0].hooks[0].timeout).toBe(300);
    expect(readFileSync(paths.ccSettingsBackup, "utf8")).toBe(original);
    // same indentation as before
    expect(readFileSync(file, "utf8")).toContain('\n    "permissions"');
    // turning it on twice changes nothing
    const once = readFileSync(file, "utf8");
    inst.install();
    expect(readFileSync(file, "utf8")).toBe(once);
    expect(readFileSync(paths.ccSettingsBackup, "utf8")).toBe(original);
    // a host start with nothing to change leaves the file alone
    const { mtimeMs } = (await import("node:fs")).statSync(file);
    inst.refresh();
    expect((await import("node:fs")).statSync(file).mtimeMs).toBe(mtimeMs);
    // entries an older version wrote are brought up to date
    const old = JSON.parse(readFileSync(file, "utf8"));
    old.hooks.Stop.at(-1).hooks[0].command = `'${join(paths.bin, "cc-hook")}' # PaloAlly`;
    writeFileSync(file, JSON.stringify(old, null, 4) + "\n");
    inst.refresh();
    expect(readFileSync(file, "utf8")).toBe(once);
    inst.uninstall();
    expect(readFileSync(file, "utf8")).toBe(original);
    expect(inst.installed()).toBe(false);
  });

  test("a change the owner made meanwhile is kept; only PaloAlly's entries go", () => {
    const { inst, file } = setup();
    writeFileSync(file, JSON.stringify(OWNER, null, 2) + "\n");
    inst.install();
    const s = JSON.parse(readFileSync(file, "utf8"));
    s.theme = "dark";
    s.hooks.Stop.push({ hooks: [{ type: "command", command: "say done" }] });
    // the owner put a hook of their own into PaloAlly's group
    s.hooks.Notification.at(-1).hooks.push({ type: "command", command: "say ding" });
    writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
    inst.uninstall();
    const after = JSON.parse(readFileSync(file, "utf8"));
    expect(after).toEqual({
      ...OWNER,
      theme: "dark",
      hooks: {
        ...OWNER.hooks,
        Stop: [...OWNER.hooks.Stop, { hooks: [{ type: "command", command: "say done" }] }],
        Notification: [{ hooks: [{ type: "command", command: "say ding" }] }],
      },
    });
  });

  test("no settings file, or one without hooks: removing leaves it as it was", () => {
    const a = setup();
    a.inst.install();
    expect(a.inst.installed()).toBe(true);
    a.inst.uninstall();
    expect(existsSync(a.file)).toBe(false);

    const b = setup();
    const original = `{\n  "model": "sonnet"\n}`; // no final newline
    writeFileSync(b.file, original);
    b.inst.install();
    b.inst.uninstall();
    expect(readFileSync(b.file, "utf8")).toBe(original);
  });

  test("a settings file that is a symlink is written through; a broken one is left alone", () => {
    const { inst, file, claudeDir } = setup();
    const real = join(claudeDir, "dotfiles-settings.json");
    writeFileSync(real, JSON.stringify(OWNER, null, 2) + "\n");
    symlinkSync(real, file);
    inst.install();
    expect(lstatSync(file).isSymbolicLink()).toBe(true);
    expect(JSON.parse(readFileSync(real, "utf8")).hooks.PermissionRequest).toHaveLength(1);
    inst.uninstall();
    expect(JSON.parse(readFileSync(real, "utf8"))).toEqual(OWNER);

    const b = setup();
    writeFileSync(b.file, "{ not json");
    expect(() => b.inst.install()).toThrow("不是合法的 JSON");
    expect(readFileSync(b.file, "utf8")).toBe("{ not json");
  });
});

describe("the hook script", () => {
  test("host down: no socket, a stale socket, or a host that never answers — exits within 0.5 s with no output", async () => {
    const { inst, paths } = setup();
    inst.writeScripts();
    // no socket at all: it doesn't even start bun
    let r = await runHook(paths, perm);
    expect(r.out).toBe("");
    expect(r.code).toBe(0);
    expect(r.ms).toBeLessThan(500);
    // a socket file nobody listens on
    mkdirSync(paths.run, { recursive: true });
    const stale = createServer();
    await new Promise<void>((res) => stale.listen(paths.hookSocket, () => res()));
    await new Promise<void>((res) => stale.close(() => res()));
    expect(existsSync(paths.hookSocket)).toBe(true); // left behind, as after a crash
    await runHook(paths, { ...perm, hook_event_name: "Stop" }); // bun's first start, off the clock
    r = await runHook(paths, perm);
    expect(r.out).toBe("");
    expect(r.ms).toBeLessThan(500);
    // a host that accepts but hangs
    const { unlinkSync } = await import("node:fs");
    unlinkSync(paths.hookSocket);
    const hung = createServer(() => {});
    await new Promise<void>((res) => hung.listen(paths.hookSocket, () => res()));
    r = await runHook(paths, perm);
    hung.close();
    expect(r.out).toBe("");
    expect(r.code).toBe(0);
    expect(r.ms).toBeLessThan(500);
  });

  test("PaloAlly's own sessions skip it; SessionStart says how to take PaloAlly's messages even with no host", async () => {
    const { inst, paths } = setup();
    inst.writeScripts();
    let r = await runHook(paths, perm, { PALOALLY_SESSION: "1" });
    expect(r.out).toBe("");
    expect(r.ms).toBeLessThan(500);
    r = await runHook(paths, { session_id: "s-1", hook_event_name: "SessionStart", source: "startup" });
    expect(JSON.parse(r.out)).toEqual({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: TRUST_LINE } });
    r = await runHook(paths, { session_id: "s-1", hook_event_name: "SessionStart" }, { PALOALLY_SESSION: "1" });
    expect(r.out).toBe("");
  });

  test("with the host there: the decision comes back as Claude Code's JSON; a hook killed meanwhile aborts the wait", async () => {
    const { inst, paths } = setup();
    inst.writeScripts();
    const seen: { event: string; payload: any }[] = [];
    let aborted = false;
    const server = new HookServer(paths.hookSocket, async (event, payload, ctx) => {
      seen.push({ event, payload });
      if (payload.tool_input?.command === "wait") {
        await new Promise<void>((res) => ctx.signal.addEventListener("abort", () => res()));
        aborted = true;
        return null;
      }
      if (event === "PermissionRequest") return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } };
      return null;
    });
    server.start();
    try {
      let r = await runHook(paths, perm);
      expect(JSON.parse(r.out)).toEqual({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });
      r = await runHook(paths, { session_id: "s-1", hook_event_name: "Stop", last_assistant_message: "好了" });
      expect(r.out).toBe("");
      expect(seen.map((s) => s.event)).toEqual(["PermissionRequest", "Stop"]);
      expect(seen[1]!.payload.last_assistant_message).toBe("好了");
      // Claude Code kills the hook when the prompt is answered in the terminal.
      const p = spawn("/bin/sh", ["-c", `exec '${join(paths.bin, "cc-hook")}' PermissionRequest`], { env: { ...process.env, PALOALLY_SESSION: "" } });
      p.stdin.end(JSON.stringify({ ...perm, tool_input: { command: "wait" } }));
      await new Promise((r) => setTimeout(r, 300));
      p.kill("SIGTERM");
      for (let i = 0; i < 50 && !aborted; i++) await new Promise((r) => setTimeout(r, 20));
      expect(aborted).toBe(true);
    } finally {
      server.stop();
    }
  });
});
