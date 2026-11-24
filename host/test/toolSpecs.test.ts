// PaloAlly's own tools are defined once, harness-neutral (tools/paloally.ts);
// the Claude Code adapter offers them as one MCP server.
import { describe, expect, test } from "bun:test";
import { paloSendMcpServer, paloallyMcpServer } from "../src/harness/claude.ts";
import { DELIVERY_TOOLS, SESSION_ALLOWED_TOOLS } from "../src/harness/types.ts";
import { assistantToolSpecs, sessionToolSpecs } from "../src/tools/paloally.ts";

const handlers = new Proxy({}, { get: (_t, name) => async (a: unknown) => `${String(name)}:${JSON.stringify(a ?? null)}` }) as any;

describe("PaloAlly's tools", () => {
  test("the assistant's and a session's sets, by name; a session's are what it may call without asking", () => {
    const mine = assistantToolSpecs(handlers).map((s) => s.name);
    expect(mine).toEqual([
      "report_task", "register_watch", "list_watches", "remove_watch", "update_goal", "SendUserFile", "Artifact", "copy_to_clipboard", "ally_list", "ally_send", "pals_list",
      "pal_send", "pal_propose", "pals_recent", "pal_adopt", "pal_archive", "pal_rename", "pair_link", "notify_user", "add_pending", "resolve_pending", "backlog_add", "backlog_list", "backlog_start", "backlog_edit", "backlog_done",
    ]);
    for (const n of DELIVERY_TOOLS) expect(mine).toContain(n);
    const theirs = sessionToolSpecs(async (t) => `sent:${t}`, handlers).map((s) => s.name);
    expect(theirs.map((n) => `mcp__paloally__${n}`).sort()).toEqual([...SESSION_ALLOWED_TOOLS].sort());
    expect(sessionToolSpecs(async () => "")).toHaveLength(1); // without the delivery tools: palo_send alone
  });

  test("each runs its handler and says what it returned; the adapter builds its server from them", async () => {
    const palo = sessionToolSpecs(async (t) => `sent:${t}`, handlers);
    expect(await palo[0]!.run({ text: "hi" })).toBe("sent:hi");
    const ask = assistantToolSpecs(handlers).find((s) => s.name === "add_pending")!;
    expect(await ask.run({ title: "x" })).toBe('add_pending:{"title":"x"}');
    expect(Object.keys(ask.schema)).toEqual(expect.arrayContaining(["title", "context", "options"]));
    expect(paloallyMcpServer(handlers)).toMatchObject({ type: "sdk", name: "paloally" });
    expect(paloSendMcpServer(async () => "", handlers)).toMatchObject({ type: "sdk", name: "paloally" });
  });
});
