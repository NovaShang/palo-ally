import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { autoMemoryDir } from "../src/harness/claude/memory.ts";
import { projectDirName, transcriptPath } from "../src/harness/claude/paths.ts";

// Claude Code names a folder's project dir from the resolved path (a home under
// /tmp writes under -private-tmp-… on a Mac); the host must look in the same place.
describe("Claude Code project dir", () => {
  test("a folder reached through a link maps to its resolved path", () => {
    const root = mkdtempSync(join(tmpdir(), "pa-cc-paths-"));
    try {
      const real = join(root, "real home");
      mkdirSync(real);
      const link = join(root, "link");
      symlinkSync(real, link);
      const resolved = realpathSync(real).replace(/[^A-Za-z0-9]/g, "-");
      expect(projectDirName(link)).toBe(resolved);
      expect(transcriptPath("/cc", link, "s1")).toBe(join("/cc", "projects", resolved, "s1.jsonl"));
      expect(transcriptPath("/cc", link, "s1")).toBe(transcriptPath("/cc", real, "s1"));
      expect(autoMemoryDir(link, "/cc")).toBe(join("/cc", "projects", resolved, "memory"));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a folder that is gone keeps its path as given", () => {
    expect(projectDirName("/no/such/folder.x")).toBe("-no-such-folder-x");
  });

  test.if(process.platform === "darwin")("/tmp on a Mac is /private/tmp", () => {
    expect(projectDirName("/tmp")).toBe("-private-tmp");
  });
});
