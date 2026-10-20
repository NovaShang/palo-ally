import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { canonicalModel, settingsEffort } from "../src/ccEffort.ts";

function settings(dir: string, name: string, data: unknown) {
  mkdirSync(join(dir, ".claude"), { recursive: true });
  writeFileSync(join(dir, ".claude", name), JSON.stringify(data));
}

describe("the effort Claude Code's settings give a session", () => {
  test("model ids lose their [1m] and date", () => {
    expect(canonicalModel("claude-opus-5-5[1m]")).toBe("claude-opus-5-5");
    expect(canonicalModel("claude-sonnet-4-5-20250929")).toBe("claude-sonnet-4-5");
    expect(canonicalModel("Claude-Opus-5-5-1m")).toBe("claude-opus-5-5");
  });

  test("the model's own entry, then the general one; the folder's files before the user's; the env first", () => {
    const home = mkdtempSync(join(tmpdir(), "cce-home-"));
    const cwd = mkdtempSync(join(tmpdir(), "cce-cwd-"));
    const env = {};
    expect(settingsEffort("claude-opus-5-5", cwd, join(home, ".claude"), env)).toBeUndefined();
    settings(home, "settings.json", { effortLevel: "medium", modelSettings: { "claude-opus-5-5": { effortLevel: "high" } } });
    expect(settingsEffort("claude-opus-5-5[1m]", cwd, join(home, ".claude"), env)).toBe("high");
    expect(settingsEffort("claude-sonnet-4-5", cwd, join(home, ".claude"), env)).toBe("medium");
    settings(cwd, "settings.local.json", { effortLevel: "low" });
    expect(settingsEffort("claude-opus-5-5", cwd, join(home, ".claude"), env)).toBe("low");
    expect(settingsEffort("claude-opus-5-5", cwd, join(home, ".claude"), { CLAUDE_CODE_EFFORT_LEVEL: "max" })).toBe("max");
    settings(cwd, "settings.local.json", { effortLevel: "bogus" });
    expect(settingsEffort("claude-opus-5-5", cwd, join(home, ".claude"), env)).toBe("high");
  });
});
