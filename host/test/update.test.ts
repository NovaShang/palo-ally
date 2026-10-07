import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  type UpdateState,
  Updater,
  autoEnabled,
  bootCheck,
  canUpdate,
  confirmUpdate,
  detectInstall,
  parseLsRemote,
  pickUpdate,
  updateLine,
} from "../src/update.ts";
import { compareSemver, parseSemver, readHostVersion } from "../src/version.ts";

function git(dir: string, ...args: string[]): string {
  return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

// A stand-in for the public repo: host/src/cli.ts answers --version and selftest.
function release(dir: string, version: string, opts: { selftest?: string; reported?: string } = {}): void {
  mkdirSync(join(dir, "host", "src"), { recursive: true });
  writeFileSync(join(dir, "host", "package.json"), JSON.stringify({ name: "paloally", version, private: true }));
  writeFileSync(
    join(dir, "host", "src", "cli.ts"),
    `const c = process.argv[2];\nif (c === "--version") console.log(${JSON.stringify(opts.reported ?? version)});\nelse if (c === "selftest") console.log(${JSON.stringify(opts.selftest ?? "ok")});\n`,
  );
  git(dir, "add", "-A");
  git(dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", `v${version}`);
  git(dir, "tag", `v${version}`);
}

function setup(opts: { second?: { selftest?: string; reported?: string } } = {}) {
  const root = mkdtempSync(join(tmpdir(), "upd-"));
  const origin = join(root, "origin");
  mkdirSync(origin);
  git(origin, "init", "-q", "-b", "main");
  release(origin, "0.1.0");
  const app = join(root, "app");
  execFileSync("git", ["clone", "-q", `file://${origin}`, app]);
  git(app, "checkout", "-q", "--detach", "v0.1.0");
  release(origin, "0.1.1", opts.second);
  const state = join(root, "state");
  mkdirSync(state);
  const paths = { update: join(state, "update.json"), chat: join(state, "chat.jsonl"), audit: join(root, "audit") };
  const audits: { type: string; data: Record<string, unknown> }[] = [];
  let exits = 0;
  const flags = { clean: false, quiet: false, svc: true };
  const u = new Updater({
    statePath: paths.update,
    stagingRoot: join(root, "staging"),
    dir: app,
    config: () => ({ auto: true, channel: "release" }),
    cleanBreak: () => flags.clean,
    quiet: () => flags.quiet,
    underService: () => flags.svc,
    installDeps: async () => undefined,
    audit: (type, data) => audits.push({ type, data }),
    exit: () => void exits++,
  });
  return { root, origin, app, paths, u, audits, flags, exits: () => exits, state: (): UpdateState => JSON.parse(readFileSync(paths.update, "utf8")) };
}

describe("versions and tags", () => {
  test("semver parse and compare", () => {
    expect(parseSemver("v0.1.2")).toEqual([0, 1, 2]);
    expect(parseSemver("v0.2.0-beta")).toBeNull();
    expect(parseSemver("0.1.2")).toBeNull();
    expect(compareSemver([0, 1, 10], [0, 1, 9])).toBeGreaterThan(0);
  });

  test("ls-remote output", () => {
    const out = "abc\trefs/tags/v0.1.0\ndef\trefs/tags/v0.1.10\n123\trefs/tags/v0.2.0-rc1\n456\trefs/tags/build-7\n";
    expect(parseLsRemote(out)).toEqual(["v0.1.0", "v0.1.10"]);
  });

  test("picks the newest release above the current one, never a skipped one", () => {
    const tags = ["v0.1.0", "v0.1.2", "v0.1.10", "v0.1.3"];
    expect(pickUpdate({ tag: "v0.1.2" }, tags)).toBe("v0.1.10");
    expect(pickUpdate({ tag: "v0.1.10" }, tags)).toBeNull();
    expect(pickUpdate({ tag: "v0.1.2" }, tags, ["v0.1.10"])).toBe("v0.1.3");
    // a copy without tags (shallow clone of main) takes the newest release
    expect(pickUpdate({ tag: null }, tags)).toBe("v0.1.10");
  });

  test("version of a checkout: exact tag, ahead of a tag, no git", () => {
    const { app } = setup();
    expect(readHostVersion(app)).toMatchObject({ version: "0.1.0", tag: "v0.1.0", exact: true });
    writeFileSync(join(app, "x.txt"), "x");
    git(app, "add", "-A");
    git(app, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "dev");
    expect(readHostVersion(app)).toMatchObject({ version: "0.1.0+1", tag: "v0.1.0", exact: false });
    const copy = mkdtempSync(join(tmpdir(), "copy-"));
    mkdirSync(join(copy, "host"));
    writeFileSync(join(copy, "host", "package.json"), JSON.stringify({ version: "0.1.0" }));
    expect(readHostVersion(copy)).toMatchObject({ version: "0.1.0", tag: null, commit: null });
  });
});

describe("install kind", () => {
  test("install.sh's checkout of the public repo auto-updates; others are manual", () => {
    const home = mkdtempSync(join(tmpdir(), "home-"));
    const dir = join(home, ".paloally", "app");
    mkdirSync(dir, { recursive: true });
    const pub = detectInstall(dir, { isGit: true, origin: "https://github.com/NovaShang/palo-ally.git", home });
    expect(pub.kind).toBe("public");
    expect(detectInstall(dir, { isGit: true, origin: "git@github.com:NovaShang/palo-ally.git", home }).kind).toBe("public");
    expect(detectInstall(dir, { isGit: true, origin: "https://github.com/someone/fork.git", home })).toMatchObject({ kind: "manual", reason: "不是从公开仓库装的" });
    const dev = detectInstall(mkdtempSync(join(tmpdir(), "dev-")), { isGit: true, origin: "git@github.com:NovaShang/palo-ally.git", home });
    expect(dev).toMatchObject({ kind: "manual", reason: "开发目录" });
    expect(detectInstall(dir, { isGit: false, origin: null, home }).kind).toBe("manual");
    // config: unset follows the install kind; true opts a manual one in; false turns it off
    expect(autoEnabled({ channel: "release" }, pub)).toBe(true);
    expect(autoEnabled({ auto: false, channel: "release" }, pub)).toBe(false);
    expect(autoEnabled({ channel: "release" }, dev)).toBe(false);
    expect(autoEnabled({ auto: true, channel: "release" }, dev)).toBe(true);
    expect(canUpdate({ channel: "release" }, dev)).toBe(false);
  });
});

describe("Updater", () => {
  test("stages a new release, but switches only at a clean break", async () => {
    const s = setup();
    await s.u.tick();
    expect(s.state().staged).toMatchObject({ tag: "v0.1.1", version: "0.1.1" });
    expect(readHostVersion(s.app).version).toBe("0.1.0"); // mid-work: still the old code
    expect(s.exits()).toBe(0);

    s.flags.svc = false; // not under launchd/systemd: nobody would restart it
    s.flags.clean = true;
    await s.u.tick();
    expect(s.exits()).toBe(0);

    s.flags.svc = true;
    await s.u.tick();
    expect(readHostVersion(s.app).version).toBe("0.1.1");
    expect(s.exits()).toBe(1);
    expect(s.state().pending).toMatchObject({ from: { version: "0.1.0" }, to: { tag: "v0.1.1" }, attempts: 0 });
    expect(s.audits.map((a) => a.type)).toEqual(["host.update.staged", "host.update.apply"]);
  });

  test("a healthy start confirms the update and says so quietly", async () => {
    const s = setup();
    s.flags.clean = true;
    await s.u.tick();
    expect(bootCheck(s.paths, s.app)).toMatchObject({ rolledBack: false, pending: { attempts: 1 } });
    const notes: string[] = [];
    const audits: string[] = [];
    confirmUpdate(s.paths, { note: (t) => notes.push(t), audit: (t) => audits.push(t) });
    expect(notes).toEqual(["电脑上的 PaloAlly 已更新到 0.1.1"]);
    expect(audits).toEqual(["host.update"]);
    expect(s.state()).toMatchObject({ pending: null, last: { from: "0.1.0", to: "0.1.1", ok: true } });
  });

  test("a release that keeps dying is rolled back, reported, and not retried", async () => {
    const s = setup();
    s.flags.clean = true;
    await s.u.tick();
    for (let i = 0; i < 3; i++) expect(bootCheck(s.paths, s.app).rolledBack).toBe(false);
    expect(bootCheck(s.paths, s.app).rolledBack).toBe(true);
    expect(readHostVersion(s.app).version).toBe("0.1.0");
    const st = s.state();
    expect(st.pending).toBeNull();
    expect(st.skip).toEqual(["v0.1.1"]);
    expect(st.last).toMatchObject({ from: "0.1.0", to: "0.1.1", ok: false });
    const chat = readFileSync(s.paths.chat, "utf8");
    expect(chat).toContain("更新到 0.1.1 没成功，已退回 0.1.0");
    // the next check doesn't pick it again
    expect(await s.u.check()).toBeNull();
  });

  test("a release that fails its smoke run is never staged", async () => {
    const s = setup({ second: { reported: "9.9.9" } });
    s.flags.clean = true;
    await s.u.tick();
    const st = s.state();
    expect(st.staged ?? null).toBeNull();
    expect(st.lastError?.detail).toContain("9.9.9");
    expect(readHostVersion(s.app).version).toBe("0.1.0");
    expect(s.exits()).toBe(0);
  });

  test("local edits block the switch", async () => {
    const s = setup();
    await s.u.tick();
    writeFileSync(join(s.app, "host", "src", "cli.ts"), "// edited\n");
    expect(await s.u.apply()).toBe("dirty");
    expect(s.exits()).toBe(0);
  });

  test("by hand: manual installs refuse; --check only looks", async () => {
    const s = setup();
    const manual = new Updater({ ...(s.u as any).d, config: () => ({ channel: "release" }) });
    expect((await manual.updateNow()).status).toBe("manual");
    expect(await s.u.updateNow({ check: true })).toMatchObject({ status: "available", current: "0.1.0", latest: "0.1.1" });
    expect(readHostVersion(s.app).version).toBe("0.1.0");
    expect(await s.u.updateNow({ now: true })).toMatchObject({ status: "updating" });
    expect(readHostVersion(s.app).version).toBe("0.1.1");
    expect(await s.u.updateNow({ check: true })).toMatchObject({ status: "latest" });
  });
});

// Clones that don't know their release must never be "updated" backwards.
describe("never downgrade", () => {
  function commit(dir: string, name: string): void {
    writeFileSync(join(dir, `${name}.txt`), name);
    git(dir, "add", "-A");
    git(dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", name);
  }
  function updaterFor(app: string, root: string) {
    let exits = 0;
    const u = new Updater({
      statePath: join(root, "update.json"),
      stagingRoot: join(root, "staging"),
      dir: app,
      config: () => ({ auto: true, channel: "release" }),
      cleanBreak: () => true,
      quiet: () => true,
      underService: () => true,
      installDeps: async () => undefined,
      audit: () => undefined,
      exit: () => void exits++,
    });
    return { u, exits: () => exits, state: (): UpdateState => JSON.parse(readFileSync(join(root, "update.json"), "utf8")) };
  }

  test("a shallow clone of main with no tags learns its version instead of taking an older release", async () => {
    const s = setup();
    commit(s.origin, "after-0.1.1"); // main moves past the newest release
    const app = join(s.root, "shallow");
    execFileSync("git", ["clone", "-q", "--depth", "1", "--no-tags", `file://${s.origin}`, app]);
    expect(readHostVersion(app).tag).toBeNull();
    const t = updaterFor(app, s.root);
    await t.u.tick();
    expect(readHostVersion(app).version).toBe("0.1.1+1"); // tags fetched, HEAD untouched
    expect(t.state().staged ?? null).toBeNull();
    expect(t.state().versionUnknown).toBe(false);
    expect(t.exits()).toBe(0);
  });

  test("a checkout ahead of the newest release is up to date", async () => {
    const s = setup();
    commit(s.origin, "after-0.1.1");
    git(s.app, "fetch", "-q", "--tags", "origin");
    git(s.app, "checkout", "-q", "--detach", "origin/main");
    expect(readHostVersion(s.app).version).toBe("0.1.1+1");
    expect(await s.u.check()).toBeNull();
  });

  test("a release whose commit is already behind HEAD is not taken", async () => {
    const s = setup();
    // v0.1.2 was tagged on an older commit than v0.1.1's (odd, but possible)
    git(s.origin, "tag", "v0.1.2", "v0.1.0");
    git(s.app, "fetch", "-q", "--tags", "origin");
    git(s.app, "checkout", "-q", "--detach", "v0.1.1");
    expect(readHostVersion(s.app).version).toBe("0.1.1");
    expect(await s.u.check()).toBeNull();
  });

  test("when the version can't be known, nothing updates and status says so", async () => {
    const root = mkdtempSync(join(tmpdir(), "upd-"));
    const origin = join(root, "origin");
    mkdirSync(origin);
    git(origin, "init", "-q", "-b", "main");
    commit(origin, "untagged");
    const app = join(root, "app");
    execFileSync("git", ["clone", "-q", "--depth", "1", `file://${origin}`, app]);
    git(origin, "tag", "v0.1.0"); // a release appears, but nothing in this history says which one we are
    commit(origin, "later");
    git(origin, "tag", "-f", "v0.1.0", "HEAD");
    const t = updaterFor(app, root);
    await t.u.tick();
    expect(t.exits()).toBe(0);
    const st = await t.u.status();
    expect(st.versionUnknown).toBe(true);
    expect(updateLine(st)).toContain("版本未知，未自动更新");
    expect((await t.u.updateNow()).status).toBe("unknown");
  });
});

describe("status line", () => {
  const base = { commit: "abc1234", latest: null, staged: null, last: null, lastError: null };
  test("manual and automatic", () => {
    const now = Date.UTC(2026, 9, 6, 12);
    expect(updateLine({ ...base, version: "0.1.2+4", install: { kind: "manual", reason: "开发目录" }, auto: false, lastCheckAt: null }, now)).toBe(
      "0.1.2+4 · abc1234（手动管理：开发目录）",
    );
    expect(updateLine({ ...base, version: "0.1.2", install: { kind: "public", reason: "" }, auto: true, lastCheckAt: now - 3 * 3600_000 }, now)).toBe(
      "0.1.2（自动更新开 · 上次检查 3 小时前）",
    );
    expect(
      updateLine({ ...base, version: "0.1.2", install: { kind: "public", reason: "" }, auto: true, lastCheckAt: now - 60_000, staged: { tag: "v0.1.3", version: "0.1.3" } }, now),
    ).toBe("0.1.2（自动更新开 · 上次检查 1 分钟前 · 0.1.3 已下好，空闲时换上）");
  });
});
