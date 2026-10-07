import { execFile, execFileSync } from "node:child_process";
import { existsSync, realpathSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { Audit } from "./audit.ts";
import { Bus } from "./bus.ts";
import { ChatLog } from "./chat.ts";
import { readJson, writeJson } from "./util.ts";
import { APP_DIR, type HostVersion, compareSemver, parseSemver, readHostVersion } from "./version.ts";

// Host auto-update. Installs made by install.sh (a git checkout of the public
// repo in ~/.paloally/app) follow official releases: every few hours the host
// looks for a newer v* tag, stages it (fetch, install deps, smoke-run it), and
// switches to it at a clean break, never mid-work. The service manager starts
// the new code; if it can't come up, the next start rolls back to the old
// commit and says so. Dev checkouts and copies are "managed manually".

export const CHECK_EVERY_MS = 6 * 3600_000;
export const FIRST_CHECK_MS = 2 * 60_000;
export const HEALTHY_AFTER_MS = 60_000;
export const MAX_BOOT_ATTEMPTS = 3;
const PUBLIC_REPO = /github\.com[:/]novashang\/palo-ally(\.git)?\/?$/i;
const SERVICE_LABEL = "com.novashang.paloally";

export type Run = (cmd: string, args: string[], opts?: { cwd?: string; timeoutMs?: number }) => Promise<string>;

const execFileP = promisify(execFile);
export const defaultRun: Run = async (cmd, args, opts = {}) => {
  const { stdout } = await execFileP(cmd, args, { cwd: opts.cwd, timeout: opts.timeoutMs ?? 180_000, maxBuffer: 16 * 1024 * 1024 });
  return String(stdout).trim();
};

export interface UpdateConfig {
  auto?: boolean; // undefined: on for install.sh installs, off for dev checkouts
  channel: "release";
}

interface Ref { ref: string; version: string; tag: string | null }
export interface Pending { from: Ref; to: { tag: string; version: string }; at: number; attempts: number }

export interface UpdateState {
  lastCheckAt?: number;
  latest?: { tag: string; version: string } | null;
  staged?: { tag: string; version: string; at: number } | null;
  pending?: Pending | null;
  last?: { from: string; to: string; ok: boolean; at: number; reason?: string; durationMs?: number } | null;
  skip?: string[]; // releases that failed to start here; not retried
  lastError?: { at: number; detail: string } | null;
  versionUnknown?: boolean; // couldn't tell which release this is: no auto-update
}

export interface InstallInfo {
  kind: "public" | "manual";
  reason: string; // why manual, in Chinese
}

// ---------------------------------------------------------------- pure parts

/** Release tags from `git ls-remote --tags --refs`. */
export function parseLsRemote(out: string): string[] {
  const tags: string[] = [];
  for (const line of out.split("\n")) {
    const m = /refs\/tags\/(\S+)$/.exec(line.trim());
    if (m && parseSemver(m[1]!)) tags.push(m[1]!);
  }
  return tags;
}

/** The newest release newer than `current`, skipping ones that failed here. */
export function pickUpdate(current: Pick<HostVersion, "tag">, tags: string[], skip: string[] = []): string | null {
  const base = current.tag ? parseSemver(current.tag) : null;
  let best: string | null = null;
  for (const t of tags) {
    const v = parseSemver(t);
    if (!v || skip.includes(t)) continue;
    if (base && compareSemver(v, base) <= 0) continue;
    if (!best || compareSemver(v, parseSemver(best)!) > 0) best = t;
  }
  return best;
}

function samePath(a: string, b: string): boolean {
  try {
    return realpathSync(a) === realpathSync(b);
  } catch {
    return false;
  }
}

/** Public install (auto-updates) or managed by hand (dev checkout, copy). */
export function detectInstall(dir: string, opts: { isGit: boolean; origin: string | null; home?: string; appDirEnv?: string }): InstallInfo {
  if (!opts.isGit) return { kind: "manual", reason: "不是 git 安装（手动部署）" };
  const home = opts.home ?? homedir();
  const installDir = opts.appDirEnv || join(home, ".paloally", "app");
  if (!samePath(dir, installDir)) return { kind: "manual", reason: "开发目录" };
  if (!opts.origin || !PUBLIC_REPO.test(opts.origin)) return { kind: "manual", reason: "不是从公开仓库装的" };
  return { kind: "public", reason: "" };
}

export function autoEnabled(cfg: UpdateConfig, install: InstallInfo): boolean {
  return cfg.auto === true || (cfg.auto !== false && install.kind === "public");
}

/** May this host update itself at all (also by hand, through `paloally update`)? */
export function canUpdate(cfg: UpdateConfig, install: InstallInfo): boolean {
  return install.kind === "public" || cfg.auto === true;
}

/** Running under launchd / systemd, which brings the process back after exit. */
export function underService(): boolean {
  return process.env.XPC_SERVICE_NAME === SERVICE_LABEL || !!process.env.INVOCATION_ID;
}

function ago(ms: number, now: number): string {
  const min = Math.max(0, Math.round((now - ms) / 60_000));
  if (min < 60) return `${min} 分钟前`;
  const h = Math.round(min / 60);
  return h < 48 ? `${h} 小时前` : `${Math.round(h / 24)} 天前`;
}

export interface UpdateStatus {
  version: string;
  commit: string | null;
  install: InstallInfo;
  auto: boolean;
  lastCheckAt: number | null;
  latest: { tag: string; version: string } | null;
  staged: { tag: string; version: string } | null;
  last: UpdateState["last"] | null;
  lastError: UpdateState["lastError"] | null;
  versionUnknown?: boolean;
}

/** The `paloally status` line: 「0.1.2（自动更新开 · 上次检查 3 小时前）」. */
export function updateLine(s: UpdateStatus, now = Date.now()): string {
  if (s.install.kind === "manual" && !s.auto) {
    return `${s.version}${s.commit ? ` · ${s.commit}` : ""}（手动管理：${s.install.reason}）`;
  }
  if (s.versionUnknown) return `${s.version}${s.commit ? ` · ${s.commit}` : ""}（版本未知，未自动更新）`;
  const bits = [s.auto ? "自动更新开" : "自动更新关"];
  bits.push(s.lastCheckAt ? `上次检查 ${ago(s.lastCheckAt, now)}` : "还没检查过");
  if (s.staged) bits.push(`${s.staged.version} 已下好，空闲时换上`);
  else if (s.latest && s.latest.version !== s.version) bits.push(`有新版本 ${s.latest.version}`);
  if (s.last && !s.last.ok) bits.push(`上次更新到 ${s.last.to} 没成功`);
  else if (s.lastError) bits.push(`上次检查出错：${s.lastError.detail}`);
  return `${s.version}（${bits.join(" · ")}）`;
}

// ---------------------------------------------------------------- boot side

// Runs at `paloally start`, before the daemon. A pending update counts boot
// attempts; if the new code keeps dying, roll back to the commit it came from.

function gitSync(dir: string, args: string[]): void {
  execFileSync("git", ["-C", dir, ...args], { stdio: "ignore", timeout: 120_000 });
}

function installSync(dir: string): void {
  execFileSync(process.execPath, ["install", "--production"], { cwd: join(dir, "host"), stdio: "ignore", timeout: 300_000 });
}

export interface BootPaths {
  update: string; // state/update.json
  chat: string;
  audit: string;
}

/** Restores the previous code after a failed update and says why in the conversation. */
export function rollbackSync(paths: BootPaths, reason: string, dir = APP_DIR): void {
  const st = readJson<UpdateState>(paths.update, {});
  const p = st.pending;
  if (!p) return;
  try {
    gitSync(dir, ["checkout", "--force", "--detach", p.from.ref]);
    installSync(dir);
  } catch (e) {
    reason += `（退回时也出错：${e instanceof Error ? e.message.split("\n")[0] : String(e)}）`;
  }
  st.pending = null;
  st.staged = null;
  st.skip = [...new Set([...(st.skip ?? []), p.to.tag])];
  st.last = { from: p.from.version, to: p.to.version, ok: false, at: Date.now(), reason };
  writeJson(paths.update, st);
  new Audit(paths.audit).log("host.update.failed", { from: p.from.version, to: p.to.version, reason });
  new ChatLog(paths.chat, new Bus()).add({
    role: "system",
    kind: "notice",
    text: `电脑上的 PaloAlly 更新到 ${p.to.version} 没成功，已退回 ${p.from.version}：${reason}`,
    channel: "system",
  });
}

/** Called first thing at start. Returns the update to confirm once the daemon is healthy. */
export function bootCheck(paths: BootPaths, dir = APP_DIR): { pending: Pending | null; rolledBack: boolean } {
  const st = readJson<UpdateState>(paths.update, {});
  if (!st.pending) return { pending: null, rolledBack: false };
  st.pending.attempts = (st.pending.attempts ?? 0) + 1;
  writeJson(paths.update, st);
  if (st.pending.attempts > MAX_BOOT_ATTEMPTS) {
    rollbackSync(paths, `新版本连续 ${MAX_BOOT_ATTEMPTS} 次没能启动`, dir);
    return { pending: null, rolledBack: true };
  }
  return { pending: st.pending, rolledBack: false };
}

/** The new code has been up for a while: the update stuck. */
export function confirmUpdate(paths: BootPaths, deps: { note: (text: string) => void; audit: (type: string, data: Record<string, unknown>) => void }): void {
  const st = readJson<UpdateState>(paths.update, {});
  const p = st.pending;
  if (!p) return;
  const durationMs = Date.now() - p.at;
  st.pending = null;
  st.staged = null;
  st.last = { from: p.from.version, to: p.to.version, ok: true, at: Date.now(), durationMs };
  writeJson(paths.update, st);
  deps.audit("host.update", { from: p.from.version, to: p.to.version, durationMs });
  deps.note(`电脑上的 PaloAlly 已更新到 ${p.to.version}`);
}

// ---------------------------------------------------------------- the updater

export interface UpdaterDeps {
  statePath: string; // state/update.json
  stagingRoot: string; // where releases are staged and smoke-tested
  dir?: string; // the app checkout (default: the running code's repo)
  config: () => UpdateConfig;
  /** A clean break (turn over, nothing in flight, owner quiet). */
  cleanBreak: () => boolean;
  /** Nothing in flight at all (what `paloally restart` waits for). */
  quiet: () => boolean;
  underService?: () => boolean;
  run?: Run;
  /** Install dependencies in a host/ dir; defaults to `bun install --production`. */
  installDeps?: (hostDir: string) => Promise<void>;
  audit: (type: string, data: Record<string, unknown>) => void;
  /** Leave so the service manager starts the new code. */
  exit: () => void;
  log?: (s: string) => void;
  now?: () => number;
}

export type UpdateResult = {
  status: "manual" | "unknown" | "latest" | "available" | "staged" | "updating" | "dirty" | "failed" | "waiting";
  current: string;
  latest?: string;
  detail?: string;
};

export class Updater {
  private timer: ReturnType<typeof setInterval> | null = null;
  private first: ReturnType<typeof setTimeout> | null = null;
  private installInfo: InstallInfo | null = null;
  private busy = false;
  private applySoon = false; // asked by hand: apply when quiet, without the owner-quiet wait
  private readonly dir: string;
  private readonly run: Run;

  constructor(private d: UpdaterDeps) {
    this.dir = d.dir ?? APP_DIR;
    this.run = d.run ?? defaultRun;
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  private state(): UpdateState {
    return readJson<UpdateState>(this.d.statePath, {});
  }

  private save(patch: Partial<UpdateState>): void {
    writeJson(this.d.statePath, { ...this.state(), ...patch });
  }

  private git(args: string[], timeoutMs?: number): Promise<string> {
    return this.run("git", ["-C", this.dir, ...args], { timeoutMs });
  }

  current(): HostVersion {
    return readHostVersion(this.dir);
  }

  /** The staged release, if it's still newer than the code in the checkout. */
  private staged(): { tag: string; version: string } | null {
    const st = this.state().staged;
    if (!st) return null;
    return pickUpdate(this.current(), [st.tag]) ? st : null;
  }

  async install(): Promise<InstallInfo> {
    if (this.installInfo) return this.installInfo;
    const isGit = (await this.git(["rev-parse", "--is-inside-work-tree"]).catch(() => "")) === "true";
    const origin = isGit ? await this.git(["remote", "get-url", "origin"]).catch(() => null) : null;
    this.installInfo = detectInstall(this.dir, { isGit, origin, appDirEnv: process.env.PALOALLY_APP_DIR });
    return this.installInfo;
  }

  async status(): Promise<UpdateStatus> {
    const install = await this.install();
    const st = this.state();
    const cur = this.current();
    return {
      version: cur.version,
      commit: cur.commit,
      install,
      auto: autoEnabled(this.d.config(), install),
      lastCheckAt: st.lastCheckAt ?? null,
      latest: st.latest ?? null,
      staged: this.staged(),
      last: st.last ?? null,
      lastError: st.lastError ?? null,
      versionUnknown: !!st.versionUnknown,
    };
  }

  start(): void {
    this.stop();
    this.first = setTimeout(() => void this.tick(), FIRST_CHECK_MS);
    (this.first as any).unref?.();
    this.timer = setInterval(() => void this.tick(), 60_000);
    (this.timer as any).unref?.();
  }

  stop(): void {
    if (this.first) clearTimeout(this.first);
    if (this.timer) clearInterval(this.timer);
    this.first = this.timer = null;
  }

  /**
   * Which release this checkout is, fetching tags (and, if need be, the full
   * history) when a shallow clone doesn't know. A copy of main with no tags
   * must never look "older than every release" and get downgraded.
   */
  private async knownVersion(): Promise<HostVersion> {
    let cur = this.current();
    if (cur.tag || !cur.commit) return cur;
    const shallow = await this.shallow();
    await this.git(["fetch", "--tags", ...(shallow ? ["--depth", "200"] : []), "origin"], 120_000).catch(() => undefined);
    cur = this.current();
    if (cur.tag || !(await this.shallow())) return cur;
    await this.git(["fetch", "--unshallow", "--tags", "origin"], 300_000).catch(() => undefined);
    return this.current();
  }

  /** Shallow clones (install.sh's) fetch shallow; a full clone stays full. */
  private async shallow(): Promise<boolean> {
    return (await this.git(["rev-parse", "--is-shallow-repository"]).catch(() => "")) === "true";
  }

  private async fetchTag(tag: string): Promise<void> {
    const depth = (await this.shallow()) ? ["--depth", "1"] : [];
    await this.git(["fetch", ...depth, "origin", `refs/tags/${tag}:refs/tags/${tag}`], 120_000);
  }

  /** The release's commit is HEAD or behind it: this code already has it. */
  private async alreadyHas(tag: string): Promise<boolean> {
    try {
      await this.fetchTag(tag);
      await this.git(["merge-base", "--is-ancestor", tag, "HEAD"]);
      return true;
    } catch {
      return false;
    }
  }

  /** Looks for a newer release (network). Null when there's none, or when unsure. */
  async check(): Promise<string | null> {
    const out = await this.git(["ls-remote", "--tags", "--refs", "origin", "v*"], 30_000);
    const tags = parseLsRemote(out);
    const newest = pickUpdate({ tag: null }, tags);
    const latest = newest ? { tag: newest, version: newest.slice(1) } : null;
    const cur = await this.knownVersion();
    if (!cur.tag) {
      this.save({ lastCheckAt: this.now(), latest, versionUnknown: true, lastError: null });
      return null;
    }
    let next = pickUpdate(cur, tags, this.state().skip ?? []);
    if (next && (await this.alreadyHas(next))) next = null; // ahead of it already (a dev or main checkout)
    this.save({ lastCheckAt: this.now(), latest, versionUnknown: false, lastError: null });
    return next;
  }

  private async installDeps(hostDir: string): Promise<void> {
    if (this.d.installDeps) return this.d.installDeps(hostDir);
    await this.run(process.execPath, ["install", "--production"], { cwd: hostDir, timeoutMs: 300_000 });
  }

  /** Fetches a release next to the running code, installs its deps and smoke-runs it. */
  async stage(tag: string): Promise<void> {
    const version = tag.slice(1);
    const dir = join(this.d.stagingRoot, `staging-${tag}`);
    await this.fetchTag(tag);
    await this.git(["worktree", "remove", "--force", dir]).catch(() => undefined);
    rmSync(dir, { recursive: true, force: true });
    await this.git(["worktree", "prune"]).catch(() => undefined);
    await this.git(["worktree", "add", "--detach", dir, tag]);
    try {
      await this.installDeps(join(dir, "host"));
      const cli = join(dir, "host", "src", "cli.ts");
      const got = await this.run(process.execPath, [cli, "--version"], { timeoutMs: 60_000 });
      if (got.trim() !== version) throw new Error(`新版本报的版本号是「${got.trim()}」，不是 ${version}`);
      const self = await this.run(process.execPath, [cli, "selftest"], { timeoutMs: 60_000 });
      if (!/\bok\b/.test(self)) throw new Error(`新版本自检没通过：${self.slice(0, 200)}`);
    } finally {
      await this.git(["worktree", "remove", "--force", dir]).catch(() => undefined);
      rmSync(dir, { recursive: true, force: true });
    }
    this.save({ staged: { tag, version, at: this.now() } });
    this.d.audit("host.update.staged", { to: version });
    this.d.log?.(`[update] staged ${tag}`);
  }

  /** Switches the checkout to the staged release and leaves for the service to restart it. */
  async apply(): Promise<UpdateResult["status"]> {
    const staged = this.staged();
    if (!staged) return "latest";
    const cur = this.current();
    const dirty = await this.git(["status", "--porcelain", "--untracked-files=no"]).catch(() => "?");
    if (dirty) {
      this.save({ lastError: { at: this.now(), detail: "本地改过代码，没自动更新" } });
      return "dirty";
    }
    const ref = await this.git(["rev-parse", "HEAD"]);
    const to = staged;
    this.save({ pending: { from: { ref, version: cur.version, tag: cur.tag }, to: { tag: to.tag, version: to.version }, at: this.now(), attempts: 0 } });
    try {
      await this.git(["checkout", "--force", "--detach", to.tag]);
      await this.installDeps(join(this.dir, "host"));
    } catch (e) {
      const reason = e instanceof Error ? e.message.split("\n")[0]! : String(e);
      await this.git(["checkout", "--force", "--detach", ref]).catch(() => undefined);
      await this.installDeps(join(this.dir, "host")).catch(() => undefined);
      const skip = [...new Set([...(this.state().skip ?? []), to.tag])];
      this.save({ pending: null, staged: null, skip, last: { from: cur.version, to: to.version, ok: false, at: this.now(), reason } });
      this.d.audit("host.update.failed", { from: cur.version, to: to.version, reason });
      return "failed";
    }
    this.d.audit("host.update.apply", { from: cur.version, to: to.version });
    this.d.log?.(`[update] switched to ${to.tag}; restarting`);
    this.d.exit();
    return "updating";
  }

  /** Every minute: check every few hours, stage, and switch at a clean break. */
  async tick(): Promise<void> {
    if (this.busy) return;
    const install = await this.install();
    const cfg = this.d.config();
    if (!autoEnabled(cfg, install) && !this.applySoon) return;
    this.busy = true;
    try {
      const st = this.state();
      if (!this.staged() && autoEnabled(cfg, install) && this.now() - (st.lastCheckAt ?? 0) >= CHECK_EVERY_MS) {
        const next = await this.check();
        if (next) await this.stage(next);
      }
      const svc = (this.d.underService ?? underService)();
      const ready = this.applySoon ? this.d.quiet() : this.d.cleanBreak();
      if (this.staged() && svc && ready) {
        this.applySoon = false;
        await this.apply();
      }
    } catch (e) {
      const detail = e instanceof Error ? e.message.split("\n")[0]! : String(e);
      this.save({ lastError: { at: this.now(), detail } });
      this.d.audit("host.update.error", { detail });
      this.d.log?.(`[update] ${detail}`);
    } finally {
      this.busy = false;
    }
  }

  /**
   * By hand (`paloally update`, the app's 立即更新): check now, stage, and
   * switch — right away with `now`, else as soon as nothing is in flight.
   */
  async updateNow(opts: { check?: boolean; now?: boolean; wait?: boolean } = {}): Promise<UpdateResult> {
    const install = await this.install();
    const cur = this.current();
    if (!canUpdate(this.d.config(), install)) return { status: "manual", current: cur.version, detail: `这台电脑上的 PaloAlly 是手动管理的（${install.reason}），用 git 自己更新` };
    let next: string | null;
    try {
      next = await this.check();
    } catch (e) {
      return { status: "failed", current: cur.version, detail: `查不到新版本：${e instanceof Error ? e.message.split("\n")[0] : String(e)}` };
    }
    const latest = this.state().latest?.version;
    if (this.state().versionUnknown) return { status: "unknown", current: this.current().version, latest, detail: "看不出这台电脑上是哪个版本，没有自动更新" };
    if (!next && !this.staged()) return { status: "latest", current: this.current().version, latest, detail: "已经是最新版" };
    if (opts.check) return { status: "available", current: cur.version, latest: (next ?? this.staged()?.tag)?.slice(1), detail: "有新版本" };
    try {
      if (next && this.staged()?.tag !== next) await this.stage(next);
    } catch (e) {
      return { status: "failed", current: cur.version, latest, detail: `新版本没准备好：${e instanceof Error ? e.message.split("\n")[0] : String(e)}` };
    }
    if (opts.now) return { status: await this.apply(), current: cur.version, latest };
    if (opts.wait) {
      const deadline = this.now() + 30 * 60_000;
      while (Date.now() < deadline) {
        if (this.d.quiet()) return { status: await this.apply(), current: cur.version, latest };
        await new Promise((r) => setTimeout(r, 2000));
      }
      return { status: "waiting", current: cur.version, latest, detail: "等了 30 分钟还在忙，空闲后会自动换上" };
    }
    this.applySoon = true;
    void this.tick();
    return { status: "staged", current: cur.version, latest, detail: "新版本已下好，手头的事一完就换上" };
  }
}

/** Removes leftovers of an interrupted staging (startup housekeeping). */
export function cleanStaging(stagingRoot: string): void {
  if (existsSync(stagingRoot)) rmSync(stagingRoot, { recursive: true, force: true });
}
