import { afterEach, describe, expect, test } from "bun:test";
import { ApprovalManager, isIrreversible, ruleMatches, scopeFor, validateRule } from "../src/approvals.ts";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import type { Approval } from "../src/types.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

describe("classification", () => {
  test("irreversible bash", () => {
    for (const cmd of ["rm -rf build", "git push origin main", "curl -X POST https://x", "curl -d a=1 x", "gh pr merge 3", "npm publish", "echo hi && rm a"]) {
      expect(isIrreversible("Bash", { command: cmd })).toBe(true);
    }
    for (const cmd of ["ls -la", "git status", "curl https://example.com", "cat rm.txt", "grep -r remove ."]) {
      expect(isIrreversible("Bash", { command: cmd })).toBe(false);
    }
  });

  test("irreversible MCP and browser", () => {
    expect(isIrreversible("mcp__gmail__send_email", {})).toBe(true);
    expect(isIrreversible("mcp__gmail__delete_message", {})).toBe(true);
    expect(isIrreversible("mcp__gmail__search_threads", {})).toBe(false);
    expect(isIrreversible("mcp__browser__browser_click", { element: "支付按钮" })).toBe(true);
    expect(isIrreversible("mcp__browser__browser_click", { element: "Next page link" })).toBe(false);
    expect(isIrreversible("mcp__browser__browser_navigate", { url: "https://a.com" })).toBe(false);
    expect(isIrreversible("mcp__paloally__remove_watch", {})).toBe(false); // our own tools are internal
  });

  test("scopes are narrow", () => {
    expect(scopeFor("Bash", { command: "git status" })).toBe("cmd:git status");
    expect(scopeFor("Bash", { command: "ls; rm x" })).toBeNull();
    expect(scopeFor("WebFetch", { url: "https://news.ycombinator.com/item?id=1" })).toBe("domain:news.ycombinator.com");
    expect(scopeFor("Write", { file_path: "/a/b/c.md" })).toBe("path:/a/b");
    expect(scopeFor("mcp__gmail__send_email", { to: "bob@x.com" })).toBe("recipient:bob@x.com");
    expect(scopeFor("mcp__browser__browser_click", { element: "x" }, "shop.com")).toBe("domain:shop.com");
    expect(scopeFor("mcp__foo__do_thing", {})).toBeNull();
  });

  test("rules refuse whole-class allow", () => {
    expect(validateRule("mcp__browser__browser_click", "*")).not.toBeNull();
    expect(validateRule("mcp__browser__browser_click", "")).not.toBeNull();
    expect(validateRule("*", "domain:a.com")).not.toBeNull();
    expect(validateRule("Bash", "cmd:*")).not.toBeNull();
    expect(validateRule("Write", "path:/")).not.toBeNull();
    expect(validateRule("WebFetch", "domain:a.com")).toBeNull();
  });

  test("rule matching", () => {
    const r = { id: "r", tool: "WebFetch", scope: "domain:example.com", createdAt: 0 };
    expect(ruleMatches(r, "WebFetch", "domain:example.com")).toBe(true);
    expect(ruleMatches(r, "WebFetch", "domain:api.example.com")).toBe(true);
    expect(ruleMatches(r, "WebFetch", "domain:badexample.com")).toBe(false);
    expect(ruleMatches(r, "Bash", "domain:example.com")).toBe(false);
    const p = { id: "p", tool: "Write", scope: "path:/a/b", createdAt: 0 };
    expect(ruleMatches(p, "Write", "path:/a/b/c")).toBe(true);
    expect(ruleMatches(p, "Write", "path:/a/bc")).toBe(false);
  });
});

describe("ApprovalManager", () => {
  const paths = tmpPaths();
  afterEach(() => {});
  let killed = false;
  const created: Approval[] = [];
  const mk = (timeoutMinutes = 30) =>
    new ApprovalManager(`${paths.state}/a-${Math.random()}.json`, `${paths.state}/r-${Math.random()}.json`, new Bus(), new Audit(paths.audit), {
      isKilled: () => killed,
      taskForToolUse: () => "t_1",
      onCreated: (a) => created.push(a),
      timeoutMinutes: () => timeoutMinutes,
      sensitiveDomains: () => ["bank.com"],
    });
  const req = (toolName: string, input: Record<string, unknown>) => ({ toolName, input, toolUseId: "tu", signal: new AbortController().signal });

  test("first answer wins and remember adds a narrow rule", async () => {
    const m = mk();
    const p = m.request(req("WebFetch", { url: "https://docs.x.com/a" }));
    const a = m.listPending()[0]!;
    expect(a.taskId).toBe("t_1");
    expect(a.suggestedScope).toBe("domain:docs.x.com");
    m.answer(a.id, true, "app", true);
    m.answer(a.id, false, "wechat"); // late answer is ignored
    expect((await p).behavior).toBe("allow");
    expect(m.list()[0]!.status).toBe("allowed");
    expect(m.list()[0]!.decidedBy).toBe("app");
    // the rule now auto-approves the same domain without a card
    const before = created.length;
    expect((await m.request(req("WebFetch", { url: "https://docs.x.com/b" }))).behavior).toBe("allow");
    expect(created.length).toBe(before);
  });

  test("irreversible actions never get auto rules", async () => {
    const m = mk();
    const p = m.request(req("Bash", { command: "git push" }));
    const a = m.listPending()[0]!;
    expect(a.irreversible).toBe(true);
    expect(a.suggestedScope).toBeUndefined();
    m.answer(a.id, true, "app", true);
    await p;
    expect(m.listRules()).toHaveLength(0);
    // and the gate forces a prompt
    expect(m.preGate("Bash", { command: "git push" }).decision).toBe("ask");
    // the shell's own tools never prompt
    expect(m.preGate("mcp__paloally__report_task", {}).decision).toBe("allow");
    expect(m.preGate("mcp__browser__browser_snapshot", {}).decision).toBe("allow");
    expect(m.preGate("mcp__browser__browser_click", { element: "next" }).decision).toBe("pass");
    expect((await m.request(req("mcp__paloally__register_watch", {}))).behavior).toBe("allow");
  });

  test("deny, timeout, kill", async () => {
    const m = mk(0.0005); // ~30ms
    const p1 = m.request(req("Write", { file_path: "/x/y" }));
    m.answer(m.listPending()[0]!.id, false, "cli");
    expect((await p1).behavior).toBe("deny");
    const p2 = m.request(req("Write", { file_path: "/x/z" }));
    expect((await p2).behavior).toBe("deny");
    expect(m.list().find((a) => a.detail === "/x/z")!.status).toBe("expired");
    killed = true;
    expect((await m.request(req("Read", {}))).behavior).toBe("deny");
    expect(m.preGate("Read", {}).decision).toBe("deny");
    killed = false;
  });

  test("sensitive domains are refused outright", async () => {
    const m = mk();
    expect(m.preGate("mcp__browser__browser_navigate", { url: "https://login.bank.com" }).decision).toBe("deny");
    expect((await m.request(req("WebFetch", { url: "https://bank.com" }))).behavior).toBe("deny");
  });

  test("abort signal expires the card", async () => {
    const m = mk();
    const ac = new AbortController();
    const p = m.request({ toolName: "Write", input: { file_path: "/q" }, toolUseId: "x", signal: ac.signal });
    ac.abort();
    expect((await p).behavior).toBe("deny");
  });

  test("pending approvals from a dead process load as expired", () => {
    const ap = `${paths.state}/persist.json`;
    const rp = `${paths.state}/persist-rules.json`;
    const hooks = { isKilled: () => false, taskForToolUse: () => undefined, onCreated: () => {}, timeoutMinutes: () => 30, sensitiveDomains: () => [] };
    const m1 = new ApprovalManager(ap, rp, new Bus(), new Audit(paths.audit), hooks);
    void m1.request(req("Write", { file_path: "/a" }));
    const m2 = new ApprovalManager(ap, rp, new Bus(), new Audit(paths.audit), hooks);
    expect(m2.list()[0]!.status).toBe("expired");
  });

  test("cleanup", () => cleanup(paths));
});
