// Files on the computer (docs/files-prd.md): list, read, search and resolve
// inside a scope only, symlinks followed and checked, `..` refused,
// PaloAlly's own state never readable, owner devices only.
import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { Audit } from "../src/audit.ts";
import { FileBrowser, MAX_READ_BYTES, MAX_WRITE_BYTES, cleanCandidate, parseScope } from "../src/files.ts";
import { FileWatches, type FileChanged } from "../src/fileWatch.ts";
import { Bus } from "../src/bus.ts";
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
  test("the owner's home: listed and searched, its dot files only when asked for, PaloAlly's own state never", () => {
    const { files, home } = world();
    mkdirSync(join(home, ".ssh"), { recursive: true });
    writeFileSync(join(home, ".ssh", "id_ed25519"), "private key\n");
    writeFileSync(join(home, ".zshrc"), "export A=1\n");
    const homeScope = { kind: "home" } as const;
    const top = files.list(homeScope);
    expect(top.root).toBe(home);
    const names = top.entries.map((e) => e.name);
    expect(names).toContain("code");
    expect(names).toContain("secret.txt");
    expect(names).not.toContain(".ssh");
    expect(names).not.toContain(".zshrc");
    expect(files.list(homeScope, "", true).entries.map((e) => e.name)).toContain(".ssh");
    // a search never walks into dot folders
    expect(files.search(homeScope, "id_ed25519").matches).toEqual([]);
    expect(files.search(homeScope, "Widget").matches.map((m) => m.path)).toContain("code/site/src/deep/er/Widget.swift");
    // PaloAlly's own state stays out, though it is under the home
    expect(() => files.read(homeScope, "apps/.paloally/identity.json")).toThrow();
    expect(parseScope({ kind: "home" })).toEqual({ kind: "home" });
  });

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
    expect(parseScope({ kind: "root", id: "x" })).toEqual({ kind: "root" });
    expect(() => parseScope({ kind: "pal" })).toThrow("没有这个文件夹");
    expect(parseScope({ kind: "palo", id: "x" })).toEqual({ kind: "palo" });
  });

  test("root: any file on the disk by its absolute path (a preview tab's)", () => {
    const { files, home, project, audit } = world();
    const root = { kind: "root" } as const;
    expect(Buffer.from(files.read(root, join(home, "secret.txt")).data, "base64").toString()).toBe("not yours\n");
    expect(Buffer.from(files.read(root, join(project, "README.md")).data, "base64").toString()).toBe("# Site\n");
    expect(Buffer.from(files.read(root, "~/code/site/README.md").data, "base64").toString()).toBe("# Site\n");
    expect(() => files.read(root, join(project, "nope.md"))).toThrow("找不到这个文件");
    expect(() => files.read(root, project)).toThrow("这是文件夹");
    expect(() => files.read(root, "/a\0b")).toThrow("找不到这个文件");
    expect(audit.tail(5).filter((e) => e.type === "files.read").map((e) => [e.scope, e.path])).toContainEqual(["root", realpathSync(join(project, "README.md"))]);
  });

  test("a link inside the project reads as its target", () => {
    const { files } = world();
    const r = files.read(site, "app-link.ts");
    expect(Buffer.from(r.data, "base64").toString()).toBe("export const a = 1;\n");
  });

  test("read: chunks like artifact.read, audited once, big files give their size only", () => {
    const { files, project, audit } = world();
    const whole = files.read(site, "README.md");
    expect(whole).toEqual({ data: Buffer.from("# Site\n").toString("base64"), size: 7, mime: expect.any(String), eof: true, version: expect.stringMatching(/^\d+:7$/) });
    const first = files.read(site, "README.md", 0, 3, "dev-phone");
    expect([Buffer.from(first.data, "base64").toString(), first.eof]).toEqual(["# S", false]);
    const rest = files.read(site, "README.md", 3, 100, "dev-phone");
    expect([Buffer.from(rest.data, "base64").toString(), rest.eof]).toEqual(["ite\n", true]);
    expect(() => files.read(site, "src")).toThrow("这是文件夹");
    writeFileSync(join(project, "big.bin"), Buffer.alloc(MAX_READ_BYTES + 1));
    expect(files.read(site, "big.bin")).toEqual({ data: "", size: MAX_READ_BYTES + 1, mime: expect.any(String), eof: true, tooLarge: true, version: expect.any(String) });
    const reads = audit.tail(20).filter((e) => e.type === "files.read");
    expect(reads.map((e) => [e.path, e.scope])).toEqual([["README.md", "pal:pal_site"], ["README.md", "pal:pal_site"], ["big.bin", "pal:pal_site"]]);
    expect(reads[1]!.by).toBe("dev-phone");
    expect(reads[2]!.tooLarge).toBe(true);
  });

  test("write: over the version read, replaced whole (mode kept, a link stays a link), audited", () => {
    const { files, project, audit } = world();
    const file = join(project, "README.md");
    chmodSync(file, 0o640);
    const base = files.read(site, "README.md").version;
    const r = files.write(site, "README.md", "# Site\n\n改过了\n", base, "dev-mac");
    expect(r.conflict).toBeUndefined();
    expect(readFileSync(file, "utf8")).toBe("# Site\n\n改过了\n");
    expect(statSync(file).mode & 0o777).toBe(0o640);
    expect(r.version).toBe(files.read(site, "README.md").version);
    expect(r.size).toBe(Buffer.byteLength("# Site\n\n改过了\n"));
    // no temp file left beside it
    expect(readdirSync(project).filter((n) => n.includes(".paloally-"))).toEqual([]);
    // written again over the new version
    expect(files.write(site, "README.md", "# Site 2\n", r.version).conflict).toBeUndefined();
    // a link inside the project: its target is written, the link stays
    const linkBase = files.read(site, "app-link.ts").version;
    files.write(site, "app-link.ts", "export const a = 2;\n", linkBase);
    expect(lstatSync(join(project, "app-link.ts")).isSymbolicLink()).toBe(true);
    expect(readlinkSync(join(project, "app-link.ts"))).toBe(join(project, "src", "app.ts"));
    expect(readFileSync(join(project, "src", "app.ts"), "utf8")).toBe("export const a = 2;\n");
    const writes = audit.tail(20).filter((e) => e.type === "files.write");
    expect(writes.map((e) => [e.path, e.bytes])).toEqual([["README.md", Buffer.byteLength("# Site\n\n改过了\n")], ["README.md", 9], ["src/app.ts", 20]]);
    expect(writes[0]!.by).toBe("dev-mac");
  });

  test("write: changed on the computer since it was read is a conflict, nothing written; forcing takes the version now", () => {
    const { files, project, audit } = world();
    const file = join(project, "README.md");
    const base = files.read(site, "README.md").version;
    writeFileSync(file, "# Site, edited on the computer\n");
    utimesSync(file, new Date(), new Date(Date.now() + 5_000));
    const r = files.write(site, "README.md", "# mine\n", base);
    expect(r.conflict).toBe(true);
    expect(r.version).not.toBe(base);
    expect(readFileSync(file, "utf8")).toBe("# Site, edited on the computer\n");
    expect(audit.tail(20).filter((e) => e.type === "files.write")).toEqual([]);
    // 「用我的覆盖」: over the version on disk now
    expect(files.write(site, "README.md", "# mine\n", r.version).conflict).toBeUndefined();
    expect(readFileSync(file, "utf8")).toBe("# mine\n");
    // an empty or made-up version never writes
    expect(files.write(site, "README.md", "# x\n", "").conflict).toBe(true);
  });

  test("write: over 1 MB, folders, missing files, outside the scope and PaloAlly's own state refused", () => {
    const { files, project, paths } = world();
    const base = files.read(site, "README.md").version;
    expect(() => files.write(site, "README.md", "x".repeat(MAX_WRITE_BYTES + 1), base)).toThrow("超过 1 MB");
    // a multi-byte character counts by its bytes
    expect(() => files.write(site, "README.md", "改".repeat(Math.ceil(MAX_WRITE_BYTES / 3) + 1), base)).toThrow("超过 1 MB");
    expect(readFileSync(join(project, "README.md"), "utf8")).toBe("# Site\n");
    expect(() => files.write(site, "src", "x", base)).toThrow("这是文件夹");
    expect(() => files.write(site, "nope.md", "x", base)).toThrow();
    expect(() => files.write(site, "secret-link.txt", "x", base)).toThrow();
    expect(() => files.write(site, "../secret.txt", "x", base)).toThrow();
    const identity = join(paths.root, "identity.json");
    const st = statSync(identity);
    expect(() => files.write({ kind: "root" }, identity, "{}", `${Math.round(st.mtimeMs)}:${st.size}`)).toThrow();
    expect(readFileSync(identity, "utf8")).toBe("{\"key\":\"private\"}");
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
    expect(r.files[0]!.abs).toBe(join(project, "src", "app.ts"));
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
      ["files.write", { scope: { kind: "palo" }, path: "notes.md", content: "x", baseVersion: "1:1" }],
      ["files.search", { scope: { kind: "palo" }, query: "notes" }],
      ["files.resolve", { scope: { kind: "palo" }, paths: ["notes.md"] }],
      ["files.folders.list", {}],
      ["files.folders.browse", {}],
      ["files.folders.add", { path: paths.home }],
      ["files.folders.remove", { id: "fld_x" }],
      ["files.watch", { scope: { kind: "palo" }, path: "notes.md" }],
      ["files.unwatch", { scope: { kind: "palo" }, path: "notes.md" }],
    ] as const) {
      await expect(stranger(m, p)).rejects.toThrow("只有主人自己的设备");
    }
    // An Ally's connection only carries the four ally.* messages: an RPC is dropped before it gets anywhere.
    expect(parseAllyWire(JSON.stringify({ id: 1, method: "files.read", params: { scope: { kind: "palo" }, path: "notes.md" } }))).toBeNull();
    expect(parseAllyWire(JSON.stringify({ type: "files.read", scope: { kind: "palo" }, path: "notes.md" }))).toBeNull();
    expect(hub.audit.tail(10).filter((e) => e.type === "files.read")).toHaveLength(1);
    // the owner's device saves from the editor; a stranger's attempt left nothing
    expect(readFileSync(join(paths.home, "notes.md"), "utf8")).toBe("# 笔记\n");
    const base = (await phone("files.read", { scope: { kind: "palo" }, path: "notes.md" })).version;
    const saved = await phone("files.write", { scope: { kind: "palo" }, path: "notes.md", content: "# 笔记\n改了\n", baseVersion: base });
    expect(saved.conflict).toBeUndefined();
    expect(readFileSync(join(paths.home, "notes.md"), "utf8")).toBe("# 笔记\n改了\n");
    expect((await phone("files.write", { scope: { kind: "palo" }, path: "notes.md", content: "again", baseVersion: base })).conflict).toBe(true);
    expect(hub.audit.tail(20).filter((e) => e.type === "files.write").map((e) => e.by)).toEqual(["dev-phone"]);
  });

  test("files.watch: a preview follows its file (edits, atomic saves, deletion), a lease nobody renews lapses", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "paloally-watch-")));
    made.push(dir);
    const file = join(dir, "notes.md");
    writeFileSync(file, "# one\n");
    const audit = new Audit(join(dir, "audit.jsonl"));
    const files = new FileBrowser({ paths: new Paths(join(dir, ".paloally")), audit, palCwd: () => undefined });
    const bus = new Bus();
    const seen: FileChanged[] = [];
    bus.on((event, data) => {
      if (event === "files.changed") seen.push(data as FileChanged);
    });
    let now = 1_000;
    // The sweep alone (no folder watch), driven by hand.
    const w = new FileWatches({ files, bus, now: () => now, folderWatch: false, pollMs: 60_000 });
    const scope = { kind: "root" } as const;
    const first = w.watch(scope, file);
    expect(first).toMatchObject({ size: 6, lease: 90_000 });
    expect(w.check()).toEqual([]);
    // An edit in place (same size, newer mtime).
    writeFileSync(file, "# two\n");
    utimesSync(file, new Date(), new Date(Date.now() + 5_000));
    expect(w.check()).toEqual([{ scope, path: file, size: 6, mtime: expect.any(Number) }]);
    expect(w.check()).toEqual([]);
    // Saved the way editors do: a new file renamed over the old one.
    writeFileSync(join(dir, ".notes.md.tmp"), "# three, longer\n");
    renameSync(join(dir, ".notes.md.tmp"), file);
    expect(w.check().map((c) => c.size)).toEqual([16]);
    // Gone, then back.
    rmSync(file);
    expect(w.check()).toEqual([{ scope, path: file, size: 0, mtime: 0, gone: true }]);
    expect(w.check()).toEqual([]);
    writeFileSync(file, "# back\n");
    expect(w.check().map((c) => c.gone ?? false)).toEqual([false]);
    expect(seen).toHaveLength(4);
    // Renewed, it stays; not renewed, it lapses.
    now += 60_000;
    w.watch(scope, file);
    now += 60_000;
    expect(w.count).toBe(1);
    w.check();
    expect(w.count).toBe(1);
    now += 31_000;
    w.check();
    expect(w.count).toBe(0);
    // Unwatched: no more news. A missing file can't be watched.
    w.watch(scope, file);
    w.unwatch(scope, file);
    expect(w.count).toBe(0);
    expect(() => w.watch(scope, join(dir, "nope.md"))).toThrow();
    // Reads aren't audited by watching.
    expect(audit.tail(10)).toEqual([]);
    w.stop();
  });

  test("files.watch: the folder watch reports a save within a moment, once", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "paloally-watch-")));
    made.push(dir);
    const file = join(dir, "page.html");
    writeFileSync(file, "<p>one</p>");
    const files = new FileBrowser({ paths: new Paths(join(dir, ".paloally")), audit: new Audit(join(dir, "audit.jsonl")), palCwd: () => undefined });
    const bus = new Bus();
    const seen: FileChanged[] = [];
    bus.on((event, data) => {
      if (event === "files.changed") seen.push(data as FileChanged);
    });
    const w = new FileWatches({ files, bus, pollMs: 60_000, settleMs: 50 });
    w.watch({ kind: "root" }, file);
    await new Promise((r) => setTimeout(r, 50));
    // Three quick writes: one change, after they settle.
    writeFileSync(file, "<p>two</p>");
    writeFileSync(file, "<p>three</p>");
    writeFileSync(file, "<p>four!</p>");
    const until = Date.now() + 3_000;
    while (!seen.length && Date.now() < until) await new Promise((r) => setTimeout(r, 20));
    await new Promise((r) => setTimeout(r, 200));
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ scope: { kind: "root" }, path: file, size: 12 });
    w.stop();
  });
});
