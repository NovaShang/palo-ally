import { describe, expect, test } from "bun:test";
import { mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ArtifactLibrary, CHUNK } from "../src/artifacts.ts";
import { Bus } from "../src/bus.ts";
import { MemoryView, autoMemoryDir } from "../src/memory.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

describe("ArtifactLibrary", () => {
  test("lists pinned first then newest; infers metadata for unpublished folders", () => {
    const paths = tmpPaths();
    const events: any[] = [];
    const bus = new Bus();
    bus.on((e, d) => events.push([e, d]));
    const lib = new ArtifactLibrary(paths.artifacts, bus);
    mkdirSync(join(paths.artifacts, "loose"));
    writeFileSync(join(paths.artifacts, "loose", "notes.md"), "# hi");
    mkdirSync(join(paths.artifacts, "daily"));
    writeFileSync(join(paths.artifacts, "daily", "brief.md"), "# 晨报");
    writeFileSync(join(paths.artifacts, "daily", "chart.png"), Buffer.alloc(10));
    const old = (Date.now() - 86400_000) / 1000;
    utimesSync(join(paths.artifacts, "loose", "notes.md"), old, old);
    let list = lib.list();
    expect(list.map((a) => a.id)).toEqual(["daily", "loose"]);
    expect(list[1]).toMatchObject({ title: "loose", mainFile: "notes.md", type: "md", pinned: false });

    lib.publish("loose", "随手笔记", "notes.md", "markdown", true);
    list = lib.list();
    expect(list[0]!.id).toBe("loose"); // pinned wins
    expect(list[0]!.title).toBe("随手笔记");
    expect(events.some(([e, d]) => e === "artifact.updated" && d.id === "loose")).toBe(true);
    expect(() => lib.publish("../evil", "x", "a")).toThrow();
    cleanup(paths);
  });

  test("chunked reads, path traversal refused, change detection", () => {
    const paths = tmpPaths();
    const bus = new Bus();
    const lib = new ArtifactLibrary(paths.artifacts, bus);
    mkdirSync(join(paths.artifacts, "big"));
    const data = Buffer.alloc(CHUNK + 100, 7);
    writeFileSync(join(paths.artifacts, "big", "blob.pdf"), data);
    const a = lib.read("big", "blob.pdf");
    expect(a.mime).toBe("application/pdf");
    expect(a.eof).toBe(false);
    expect(Buffer.from(a.data, "base64").length).toBe(CHUNK);
    const b = lib.read("big", "blob.pdf", CHUNK);
    expect(b.eof).toBe(true);
    expect(Buffer.from(b.data, "base64").length).toBe(100);
    expect(() => lib.read("big", "../../config.json")).toThrow("越界");
    expect(() => lib.read("../state", "x")).toThrow();

    lib.watch(60_000);
    expect(lib.scan()).toHaveLength(0);
    const future = Date.now() / 1000 + 5;
    writeFileSync(join(paths.artifacts, "big", "blob.pdf"), "v2");
    utimesSync(join(paths.artifacts, "big", "blob.pdf"), future, future);
    expect(lib.scan().map((x) => x.id)).toEqual(["big"]);
    lib.stop();
    cleanup(paths);
  });
});

describe("MemoryView", () => {
  test("core + native auto memory, editable, sandboxed", () => {
    const paths = tmpPaths();
    const auto = join(paths.root, "fake-claude", "memory");
    const mem = new MemoryView(paths.home, auto);
    expect(mem.list().map((f) => f.path)).toEqual(["user.md", "soul.md"]);
    mem.write("memory/coffee.md", "喜欢燕麦拿铁");
    expect(mem.read("memory/coffee.md")).toBe("喜欢燕麦拿铁");
    expect(mem.list().find((f) => f.path === "memory/coffee.md")!.scope).toBe("auto");
    expect(() => mem.read("../config.json")).toThrow();
    expect(() => mem.write("memory/../../x.md", "")).toThrow();
    expect(() => mem.write("CLAUDE.md", "")).toThrow();
    expect(mem.coreSize()).toBeGreaterThan(0);
    cleanup(paths);
  });

  test("auto memory dir matches Claude Code's project encoding", () => {
    expect(autoMemoryDir("/Users/nova/.paloally/home", "/c")).toBe("/c/projects/-Users-nova--paloally-home/memory");
    expect(autoMemoryDir("/Users/nova/code/palo-ally", "/c")).toBe("/c/projects/-Users-nova-code-palo-ally/memory");
  });
});
