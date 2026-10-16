// Files on the computer (docs/files-prd.md): list, read, search and resolve
// inside a scope only, symlinks followed and checked, `..` refused,
// PaloAlly's own state never readable, owner devices only.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { Audit } from "../src/audit.ts";
import { FileBrowser, MAX_READ_BYTES, cleanCandidate, parseScope } from "../src/files.ts";
import { parseAllyWire } from "../src/proto/ally.ts";
import { handleRpc } from "../src/rpc.ts";
import { Paths } from "../src/config.ts";
import { scaffoldHome } from "../src/home.ts";
import { makeHub } from "./helpers.ts";

const made: string[] = [];
afterAll(() => {
  for (const d of made.splice(0)) rmSync(d, { recursive: true, force: true });
});

/** A made-up computer: a home folder with a project, a secret beside it, and PaloAlly's folder. */
function world() {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "paloally-files-home-")));
  made.push(home);
  // PaloAlly's own folder, in a folder of its own (a Pal's project may be that one).
  const paths = new Paths(join(home, "apps", ".paloally"));
  scaffoldHome(paths);
  const project = join(home, "code", "site");
  mkdirSync(join(project, "src", "deep", "er"), { recursive: true });
  mkdirSync(join(project, ".git"), { recursive: true });
  mkdirSync(join(project, "node_modules", "left-pad"), { recursive: true });
  writeFileSync(join(project, "README.md"), "# Site\n");
  writeFileSync(join(project, "src", "app.ts"), "export const a = 1;\n");
  writeFileSync(join(project, "src", "deep", "er", "Widget.swift"), "struct Widget {}\n");
  writeFileSync(join(project, ".git", "HEAD"), "ref: refs/heads/main\n");
  writeFileSync(join(project, "node_modules", "left-pad", "index.js"), "module.exports = 1;\n");
  writeFileSync(join(project, ".DS_Store"), "x");
  writeFileSync(join(project, ".env"), "TOKEN=1\n");
  writeFileSync(join(home, "secret.txt"), "not yours\n");
  // Links: one inside the project, two pointing out of it.
  symlinkSync(join(project, "src", "app.ts"), join(project, "app-link.ts"));
  symlinkSync(join(home, "secret.txt"), join(project, "secret-link.txt"));
  symlinkSync(home, join(project, "home-link"));
  // PaloAlly's own identity next to the assistant's home.
  writeFileSync(join(paths.root, "identity.json"), "{\"key\":\"private\"}");
  writeFileSync(join(paths.home, "notes.md"), "# 笔记\n");
  mkdirSync(join(paths.artifacts, "brief"), { recursive: true });
  writeFileSync(join(paths.artifacts, "brief", "brief.md"), "# 晨报\n");
  const audit = new Audit(paths.audit);
  // pal_above: a Pal whose project folder holds PaloAlly's own folder.
  const cwds: Record<string, string> = { pal_site: project, pal_above: dirname(realpathSync(paths.root)) };
  const files = new FileBrowser({ paths, audit, palCwd: (id) => cwds[id], homeDir: () => home });
  return { paths, home, project, audit, files };
}

const site = { kind: "pal", id: "pal_site" } as const;

describe("files", () => {
  test("list: a Pal's folder, folders first, heavy and machine-made entries hidden until asked", () => {
    const { files, project } = world();
    const r = files.list(site, "");
    expect(r.root).toBe(project);
    expect(r.path).toBe("");
    expect(r.entries.map((e) => [e.name, e.kind])).toEqual([
      ["src", "dir"], [".env", "file"], ["app-link.ts", "file"], ["README.md", "file"],
    ]);
    expect(r.entries.find((e) => e.name === "README.md")!.size).toBe(7);
    expect(r.truncated).toBe(false);
    const all = files.list(site, "", true).entries.map((e) => e.name);
    expect(all).toContain(".git");
    expect(all).toContain("node_modules");
    expect(all).toContain(".DS_Store");
    // links pointing out of the project aren't listed, even with showHidden
    expect(all).not.toContain("secret-link.txt");
    expect(all).not.toContain("home-link");
    expect(files.list(site, "src/deep").entries.map((e) => e.name)).toEqual(["er"]);
    // a hidden folder opened on purpose
    expect(files.list(site, ".git").entries.map((e) => e.name)).toEqual(["HEAD"]);
  });

  test("escapes are refused: .., absolute paths outside, links out, PaloAlly's own state", () => {
    const { files, home, paths } = world();
    for (const p of ["..", "../secret.txt", "src/../../secret.txt", join(home, "secret.txt"), "~/secret.txt", "secret-link.txt", "home-link/secret.txt", "/etc/passwd", "a\0b"]) {
      expect(() => files.read(site, p)).toThrow("找不到这个文件");
    }
    expect(() => files.list(site, "..")).toThrow("找不到这个文件");
    expect(() => files.list(site, "home-link")).toThrow("找不到这个文件");
    // a Pal whose project folder holds PaloAlly's own still can't see or read it
    const above = { kind: "pal", id: "pal_above" } as const;
    const realRoot = realpathSync(paths.root);
    expect(() => files.read(above, join(basename(realRoot), "identity.json"))).toThrow("找不到这个文件");
    expect(() => files.read(above, join(realRoot, "identity.json"))).toThrow("找不到这个文件");
    expect(() => files.list(above, basename(realRoot))).toThrow("找不到这个文件");
    expect(files.list(above, "", true).entries.map((e) => e.name)).not.toContain(basename(realRoot));
    expect(files.search(above, "identity").matches).toEqual([]);
    // the assistant's scope is its home, not PaloAlly's folder above it
    expect(() => files.read({ kind: "palo" }, "../identity.json")).toThrow("找不到这个文件");
    expect(() => files.read({ kind: "palo" }, join(paths.root, "identity.json"))).toThrow("找不到这个文件");
    // unknown scopes
    expect(() => files.list({ kind: "pal", id: "pal_nope" }, "")).toThrow("没有这个文件夹");
    expect(() => parseScope({ kind: "home" })).toThrow("没有这个文件夹");
    expect(() => parseScope({ kind: "pal" })).toThrow("没有这个文件夹");
    expect(parseScope({ kind: "palo", id: "x" })).toEqual({ kind: "palo" });
  });

  test("a link inside the project reads as its target", () => {
    const { files } = world();
    const r = files.read(site, "app-link.ts");
    expect(Buffer.from(r.data, "base64").toString()).toBe("export const a = 1;\n");
  });

  test("read: chunks like artifact.read, audited once, big files give their size only", () => {
    const { files, project, audit } = world();
    const whole = files.read(site, "README.md");
    expect(whole).toEqual({ data: Buffer.from("# Site\n").toString("base64"), size: 7, mime: expect.any(String), eof: true });
    const first = files.read(site, "README.md", 0, 3, "dev-phone");
    expect([Buffer.from(first.data, "base64").toString(), first.eof]).toEqual(["# S", false]);
    const rest = files.read(site, "README.md", 3, 100, "dev-phone");
    expect([Buffer.from(rest.data, "base64").toString(), rest.eof]).toEqual(["ite\n", true]);
    expect(() => files.read(site, "src")).toThrow("这是文件夹");
    writeFileSync(join(project, "big.bin"), Buffer.alloc(MAX_READ_BYTES + 1));
    expect(files.read(site, "big.bin")).toEqual({ data: "", size: MAX_READ_BYTES + 1, mime: expect.any(String), eof: true, tooLarge: true });
    const reads = audit.tail(20).filter((e) => e.type === "files.read");
    expect(reads.map((e) => [e.path, e.scope])).toEqual([["README.md", "pal:pal_site"], ["README.md", "pal:pal_site"], ["big.bin", "pal:pal_site"]]);
    expect(reads[1]!.by).toBe("dev-phone");
    expect(reads[2]!.tooLarge).toBe(true);
  });

  test("search: names, best first, never into .git or node_modules or links out", () => {
    const { files } = world();
    expect(files.search(site, "widget").matches).toEqual([{ path: "src/deep/er/Widget.swift", kind: "file" }]);
    expect(files.search(site, "app").matches.map((m) => m.path)).toEqual(["app-link.ts", "src/app.ts"]);
    expect(files.search(site, "deep/er").matches[0]).toEqual({ path: "src/deep/er", kind: "dir" });
    expect(files.search(site, "HEAD").matches).toEqual([]);
    expect(files.search(site, "index.js").matches).toEqual([]);
    expect(files.search(site, "secret").matches).toEqual([]);
    expect(files.search(site, "  ").matches).toEqual([]);
    expect(files.search(site, "s", 1).matches).toHaveLength(1);
  });

  test("resolve: relative to the Pal's folder, ~ and absolute inside it, bare names found deeper, the rest left out", () => {
    const { files, project, home } = world();
    const r = files.resolve(site, [
      "src/app.ts", "./README.md:3", join(project, "src", "app.ts"), "~/code/site/README.md", "Widget.swift", "er/Widget.swift",
      "src/nope.ts", "../secret.txt", join(home, "secret.txt"), "~/secret.txt", "src", "secret-link.txt", "src/app.ts",
    ]);
    expect(r.files.map((f) => [f.text, f.path])).toEqual([
      ["src/app.ts", "src/app.ts"],
      ["./README.md:3", "README.md"],
      [join(project, "src", "app.ts"), "src/app.ts"],
      ["~/code/site/README.md", "README.md"],
      ["Widget.swift", "src/deep/er/Widget.swift"],
      ["er/Widget.swift", "src/deep/er/Widget.swift"],
    ]);
    expect(r.files[0]!.size).toBe(20);
    // the assistant: its home, then its artifacts
    const palo = files.resolve({ kind: "palo" }, ["notes.md", "brief/brief.md", "brief.md"]);
    expect(palo.files.map((f) => f.path)).toEqual(["notes.md", "artifacts/brief/brief.md", "artifacts/brief/brief.md"]);
    expect(cleanCandidate("`src/app.ts:12:4`。")).toBe("src/app.ts");
    expect(cleanCandidate("/")).toBeNull();
  });

  test("the owner's folders: browse from home, add, list, use as a scope, remove; the disk, home and PaloAlly's own refused", () => {
    const { files, home, project, paths, audit } = world();
    const top = files.browse();
    expect(top.path).toBe(home);
    expect(top.entries.map((e) => e.name)).toEqual(["apps", "code"]);
    expect(files.browse(join(home, "code")).entries.map((e) => e.name)).toEqual(["site"]);
    expect(files.browse("~/code").parent).toBe(home);
    expect(() => files.browse(join(home, "secret.txt"))).toThrow("找不到这个文件");
    const f = files.addFolder("~/code/site", "dev-phone");
    expect(f).toMatchObject({ path: project, name: "site" });
    expect(files.addFolder(project).id).toBe(f.id);
    expect(files.folders()).toEqual([f]);
    const folder = { kind: "folder", id: f.id } as const;
    expect(files.list(folder, "src").entries.map((e) => e.name)).toEqual(["deep", "app.ts"]);
    expect(() => files.read(folder, "../../secret.txt")).toThrow("找不到这个文件");
    for (const bad of ["/", home, "~", paths.root, paths.home, join(home, "nope")]) expect(() => files.addFolder(bad)).toThrow();
    files.removeFolder(f.id);
    expect(files.folders()).toEqual([]);
    expect(() => files.list(folder, "")).toThrow("没有这个文件夹");
    expect(() => files.removeFolder(f.id)).toThrow("没有这个文件夹");
    expect(audit.tail(10).map((e) => e.type)).toEqual(["files.folder.added", "files.folder.removed"]);
  });

  test("over RPC: the owner's devices and the local CLI only; an Ally's host can't even ask", async () => {
    const { hub, paths } = makeHub();
    writeFileSync(join(paths.home, "notes.md"), "# 笔记\n");
    const as = (ctx: any) => (method: string, params: unknown) => handleRpc(hub, { method, params }, ctx) as Promise<any>;
    const phone = as({ clientId: "app_1_dev-phone", deviceId: "dev-phone", channel: "app", local: false });
    const cli = as({ clientId: "cli", channel: "cli", local: true });
    const stranger = as({ clientId: "x", channel: "app", local: false });
    expect((await phone("files.list", { scope: { kind: "palo" } })).entries.map((e: any) => e.name)).toContain("notes.md");
    expect((await cli("files.read", { scope: { kind: "palo" }, path: "notes.md" })).size).toBe(Buffer.byteLength("# 笔记\n"));
    expect((await phone("files.resolve", { scope: { kind: "palo" }, text: "notes.md" })).files[0].path).toBe("notes.md");
    for (const [m, p] of [
      ["files.list", { scope: { kind: "palo" } }],
      ["files.read", { scope: { kind: "palo" }, path: "notes.md" }],
      ["files.search", { scope: { kind: "palo" }, query: "notes" }],
      ["files.resolve", { scope: { kind: "palo" }, paths: ["notes.md"] }],
      ["files.folders.list", {}],
      ["files.folders.browse", {}],
      ["files.folders.add", { path: paths.home }],
      ["files.folders.remove", { id: "fld_x" }],
    ] as const) {
      await expect(stranger(m, p)).rejects.toThrow("只有主人自己的设备");
    }
    // An Ally's connection only carries the four ally.* messages: an RPC is dropped before it gets anywhere.
    expect(parseAllyWire(JSON.stringify({ id: 1, method: "files.read", params: { scope: { kind: "palo" }, path: "notes.md" } }))).toBeNull();
    expect(parseAllyWire(JSON.stringify({ type: "files.read", scope: { kind: "palo" }, path: "notes.md" }))).toBeNull();
    expect(hub.audit.tail(10).filter((e) => e.type === "files.read")).toHaveLength(1);
  });
});
