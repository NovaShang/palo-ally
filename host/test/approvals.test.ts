import { describe, expect, test } from "bun:test";
import { ApprovalManager, describeSuggestion } from "../src/approvals.ts";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import type { PermissionRequest } from "../src/harness/types.ts";
import type { Approval } from "../src/types.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

// The approval manager only relays the harness' own permission prompts.

function mk(timeoutMinutes = 30) {
  const paths = tmpPaths();
  const created: Approval[] = [];
  const m = new ApprovalManager(`${paths.state}/a.json`, new Bus(), new Audit(paths.audit), {
    taskForToolUse: () => "t_1",
    onCreated: (a) => created.push(a),
    timeoutMinutes: () => timeoutMinutes,
  });
  return { m, created, paths };
}

const req = (toolName: string, input: Record<string, unknown>, extra: Partial<PermissionRequest> = {}): PermissionRequest => ({
  toolName,
  input,
  toolUseId: "tu",
  signal: new AbortController().signal,
  ...extra,
});

const bashRule = [{ type: "addRules", behavior: "allow", destination: "localSettings", rules: [{ toolName: "Bash", ruleContent: "git status:*" }] }];

describe("ApprovalManager (relay only)", () => {
  test("first answer wins; remember hands the harness' own rule back", async () => {
    const { m, paths } = mk();
    const p = m.request(req("Bash", { command: "git status" }, { suggestions: bashRule }));
    const a = m.listPending()[0]!;
    expect(a.taskId).toBe("t_1");
    expect(a.title).toBe("在电脑上运行一条命令");
    expect(a.suggestedScope).toBe("cmd:git status");
    expect(a.careful).toBe(false);
    m.answer(a.id, true, "app", true);
    m.answer(a.id, false, "wechat"); // late answer ignored
    const d = await p;
    expect(d.behavior).toBe("allow");
    expect(d.behavior === "allow" && d.updatedPermissions).toEqual(bashRule);
    expect(m.list()[0]!.decidedBy).toBe("app");
    cleanup(paths);
  });

  test("allow without remember returns no rule", async () => {
    const { m, paths } = mk();
    const p = m.request(req("Bash", { command: "ls" }, { suggestions: bashRule }));
    m.answer(m.listPending()[0]!.id, true, "cli");
    const d = await p;
    expect(d.behavior === "allow" && d.updatedPermissions).toBeUndefined();
    cleanup(paths);
  });

  test("the harness' defaultToNo marks it careful and never offers remember", async () => {
    const { m, paths } = mk();
    void m.request(req("Bash", { command: "git push" }, { defaultToNo: true, suggestions: bashRule, reason: "会推送到远端" }));
    const a = m.listPending()[0]!;
    expect(a.careful).toBe(true);
    expect(a.reason).toBe("会推送到远端"); // the harness' own words, shown on the card
    expect(a.suggestedScope).toBeUndefined();
    void m.request(req("Bash", { command: "x" }, { suppressAlwaysAllowRule: true, suggestions: bashRule }));
    expect(m.listPending()[1]!.suggestedScope).toBeUndefined();
    m.denyAll("test");
    cleanup(paths);
  });

  test("deny, timeout, abort", async () => {
    const { m, paths } = mk(0.0005); // ~30ms
    const p1 = m.request(req("Write", { file_path: "/x/y" }));
    m.answer(m.listPending()[0]!.id, false, "cli");
    expect((await p1).behavior).toBe("deny");
    expect((await m.request(req("Write", { file_path: "/x/z" }))).behavior).toBe("deny");
    expect(m.list().find((a) => a.detail === "/x/z")!.status).toBe("expired");
    const ac = new AbortController();
    const p3 = m.request({ ...req("Write", { file_path: "/q" }), signal: ac.signal });
    ac.abort();
    expect((await p3).behavior).toBe("deny");
    cleanup(paths);
  });

  test("own tools never ask; prompts from a dead process load as expired", async () => {
    const { m, created, paths } = mk();
    expect((await m.request(req("mcp__paloally__report_task", {}))).behavior).toBe("allow");
    expect(created).toHaveLength(0);
    void m.request(req("Write", { file_path: "/a" }));
    const again = new ApprovalManager(`${paths.state}/a.json`, new Bus(), new Audit(paths.audit), {
      taskForToolUse: () => undefined,
      onCreated: () => {},
      timeoutMinutes: () => 30,
    });
    expect(again.list()[0]!.status).toBe("expired");
    cleanup(paths);
  });

  test("full command and Chinese titles on cards", async () => {
    const { m, paths } = mk();
    const long = "echo " + "x".repeat(1200) + " && rm -rf /tmp/thing";
    void m.request(req("Bash", { command: long }));
    void m.request(req("mcp__claude_ai_Gmail__send_message", { to: "a@b.c" }));
    void m.request(req("mcp__claude-in-chrome__navigate", { url: "https://example.com/x" }));
    const [a, b, c] = m.listPending();
    expect(a!.detail).toContain("rm -rf /tmp/thing");
    expect(b!.title).toBe("替你发出一条消息");
    expect(c!.title).toBe("浏览器打开 example.com");
    m.denyAll("t");
    cleanup(paths);
  });
});

describe("describeSuggestion", () => {
  test("maps harness rules to the app's scope words", () => {
    const rule = (toolName: string, ruleContent?: string) => [{ type: "addRules", behavior: "allow", rules: [{ toolName, ruleContent }] }];
    expect(describeSuggestion(rule("Bash", "npm test:*"))).toBe("cmd:npm test");
    expect(describeSuggestion(rule("WebFetch", "domain:docs.x.com"))).toBe("domain:docs.x.com");
    expect(describeSuggestion(rule("Edit", "/Users/n/proj/**"))).toBe("path:/Users/n/proj");
    expect(describeSuggestion(rule("mcp__gh__list_issues"))).toBe("tool:mcp__gh__list_issues");
    expect(describeSuggestion([{ type: "addDirectories", directories: ["/tmp/x"] }])).toBe("path:/tmp/x");
    expect(describeSuggestion([{ type: "setMode", mode: "acceptEdits" }])).toBeNull();
    expect(describeSuggestion(undefined)).toBeNull();
  });
});
