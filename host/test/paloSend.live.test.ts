// Live: a real Claude Code session (Haiku) started as a Pal, with only the
// host's palo_send tool (docs/pals-prd.md §16). It is asked to tell the
// assistant a word; the host's callback must receive it without the owner
// being asked. Costs a few cents. Run with:
//   PALOALLY_LIVE_PALO_SEND=1 bun test test/paloSend.live.test.ts
import { describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ClaudeCodeDriver } from "../src/harness/claude.ts";
import { PAL_PROMPT, PALO_NAME } from "../src/pals.ts";

const LIVE = process.env.PALOALLY_LIVE_PALO_SEND === "1";
const d = LIVE ? describe : describe.skip;

d("palo_send, live", () => {
  test(
    "a real Pal reaches the assistant through the host's tool, unasked",
    async () => {
      const cwd = realpathSync(mkdtempSync(join(tmpdir(), "paloally-palo-send-")));
      const got: string[] = [];
      const asked: string[] = [];
      const s = new ClaudeCodeDriver().startPal({
        cwd,
        model: "claude-haiku-4-5-20251001",
        permissionMode: "default",
        appendSystemPrompt: PAL_PROMPT(PALO_NAME),
        persistSession: false,
        canUseTool: async (r: { toolName: string }) => {
          asked.push(r.toolName);
          return { behavior: "deny", message: "not in this test" } as any;
        },
        onEvent: () => {},
        paloSend: async (text: string) => {
          got.push(text);
          return "已经送到「Palo」。";
        },
      } as any);
      await s.ready();
      s.send(`${PALO_NAME} asked you to report back. Tell ${PALO_NAME} the single word "apricot", then stop.`, randomUUID());
      const until = Date.now() + 120_000;
      while (!got.length && Date.now() < until) await new Promise((r) => setTimeout(r, 500));
      s.close();
      console.log("[live] palo_send got:", got, "asked:", asked);
      expect(got.join(" ")).toMatch(/apricot/i);
      expect(asked).not.toContain("mcp__paloally__palo_send");
    },
    180_000,
  );
});
