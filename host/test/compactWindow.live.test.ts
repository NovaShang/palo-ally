// Live, no model call: Claude Code is started with the assistant's session
// options and asked for its context usage; the autocompact threshold must be
// the configured window minus 33k. Run with:
//   PALOALLY_LIVE_COMPACT_WINDOW=1 bun test test/compactWindow.live.test.ts
import { describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { sessionOptions } from "../src/harness/claude.ts";

const d = process.env.PALOALLY_LIVE_COMPACT_WINDOW === "1" ? describe : describe.skip;

d("autocompact window, live", () => {
  test(
    "the main session options give Claude Code a 200k window and a 167k threshold",
    async () => {
      const cwd = realpathSync(mkdtempSync(join(tmpdir(), "paloally-window-")));
      const opts = sessionOptions({ cwd, permissionMode: "default", appendSystemPrompt: "", tools: {} as any, mcpServers: {}, compactWindowTokens: 200_000, canUseTool: async () => ({ behavior: "deny", message: "" }), onEvent: () => {} } as any);
      let end!: () => void;
      const open = new Promise<void>((r) => (end = r));
      const q = query({ prompt: (async function* () { await open; })(), options: opts }); // stays open, sends nothing
      await q.initializationResult();
      const usage: any = await q.getContextUsage();
      end();
      q.close();
      expect(usage.maxTokens).toBe(200_000);
      expect(usage.autoCompactThreshold).toBe(167_000);
    },
    60_000,
  );
});
