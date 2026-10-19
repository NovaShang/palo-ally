import { t } from "./i18n/index.ts";
import { forkSession as sdkForkSession, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { basename, join, resolve, sep } from "node:path";
import type { ApprovalManager } from "./approvals.ts";
import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { ClaudeCli } from "./ccCli.ts";
import { type RawSessionMessage, type RegistryEntry, readRegistry } from "./ccSessions.ts";
import { SpendMeter } from "./ccSpend.ts";
import type { ChatLog } from "./chat.ts";
import type { Paths, Settings } from "./config.ts";
import type { DeliveryToolHandlers, HarnessDriver, ModelOption } from "./harness/types.ts";
import type { MediaStore } from "./media.ts";
import type { ArtifactLibrary } from "./artifacts.ts";
import { makeDeliveryTools } from "./shellTools.ts";
import { PalLauncher, type PalLaunch } from "./palLauncher.ts";
import { pagePalMessages, toPalMessages } from "./palHistory.ts";
import type { ForkSession } from "./rewind.ts";
import { RECENT_MAX, type RecentEntry, RecentSessions, type RecentSource, folderMatch, ownRoots, palNameFor, palTitle, recentWire, sdkRename, sdkSource, shortName } from "./palRecent.ts";
import { HeldElsewhere, type Holder, type PalRecord, type PalTask, PalSession, peerWrap } from "./palSession.ts";
import type { QuestionManager } from "./questions.ts";
import type { Router } from "./router.ts";
import type { Sessions } from "./sessions.ts";
import type { StallTarget } from "./stallWatch.ts";
import type { Attachment, ChatMessage, EarlierItem, HelperProposal, Pal, PalAdoptProposal, RecentSession } from "./types.ts";
import { newId, readJson, writeJson, zonedParts } from "./util.ts";

// Pals (docs/pals-prd.md): Claude Code sessions the host runs itself. The
// owner adopts one of the computer's sessions (a background one is stopped
// first; one in a terminal is taken over once the owner quits it there), or
// the assistant opens a new one on the owner's 开吧. Each stays up with a
// fixed name the assistant reaches it by (SendMessage), comes back after a
// crash or a restart of the Mac, and goes back to the terminal on 交还终端.
// One transcript is never written by two processes.
// No practical limit on how many (§12; 50, against mistakes), but at most
// settings.maxAwake awake (8): one idle 20 minutes is put to sleep (its
// process ends, its record stays), and past that many awake the least
// recently used idle one goes first. Busy or waiting ones are never put to
// sleep (past the limit for a while, then). The owner's words, 叫醒, a card of its answered or the assistant's
// pal_send wake it: the same session resumes and the words go in, in order.
// Its name follows Claude Code's title for the session (§13): read back
// after each turn and before each start, and pals.rename retitles it there.
// The assistant reaches it by id or any of its names (pal_send).
// A conversation that ended on the computer lately can be taken over too
// (§10): listed by pals.recent, resumed directly by pals.adopt, or proposed
// by the assistant on a card the owner answers.

/** How many Pals at most (a safety limit, §12). */
export const MAX_PALS = 50;
/** How many awake (with a process) at once, before idle ones are put to sleep: settings.maxAwake, this by default. */
export const DEFAULT_MAX_AWAKE = 8;
/** The assistant's own session name: Pals see its SendMessages as from it, and answer it there. */
export const PALO_NAME = "Palo";
const PUSH_EVERY_MS = 10 * 60_000;

// A session's auto-name: Claude Code's summary of it when that isn't just its first words, else those.
function autoTitle(info: { summary?: string; firstPrompt?: string } | undefined): string {
  const one = (s?: string) => String(s ?? "").replace(/\s+/g, " ").trim();
  const first = one(info?.firstPrompt);
  const summary = one(info?.summary);
  const raw = summary && summary !== first ? summary : first;
  return raw ? shortName(raw) : "";
}

/** A folder as the owner says it: ~/… under the home folder. */
function tildePath(p: string): string {
  const home = homedir();
  return p === home ? "~" : p.startsWith(home + sep) ? `~/${p.slice(home.length + 1)}` : p;
}

function endedItem(e: EndedSession): EarlierItem {
  return { kind: "ended", key: `ended:${e.sessionId}`, sessionId: e.sessionId, name: e.name, cwd: e.cwd, at: e.at, ...(e.workspaceId ? { workspaceId: e.workspaceId } : {}) };
}

// What a Pal is told about where it runs, on top of Claude Code's own prompt.
export const PAL_PROMPT = (paloName: string) =>
  t("pals.prompt", { paloName });

interface PalFile {
  pals: PalRecord[];
  proposals: (HelperProposal & { createdAt: number; messageId?: string })[];
  // the assistant's cards proposing to take over an ended conversation (pal_adopt)
  adoptions: (PalAdoptProposal & { createdAt: number; messageId?: string })[];
  // Pals the owner took out of the list (交还终端 / 移出): listed again among the recent ones
  former: { sessionId: string; cwd: string; at: number }[];
  // Sessions the owner ended (pals.end): 以前的, resumable; the newest 200
  ended: EndedSession[];
}

interface EndedSession {
  sessionId: string;
  name: string;
  cwd: string;
  at: number;
  workspaceId?: string;
}

const ENDED_MAX = 200;
const FOLD_CHECK_MS = 60 * 60_000;

/** pals.detail (docs/workbench-rpc.md §2). */
export interface PalDetail {
  pal: Pal;
  contextTokens?: number;
  contextWindow: number;
  costTotalUsd: number;
  spentToday: number;
  model?: string;
  effort?: string;
  models: { id: string; name: string; efforts: string[] }[];
  tasks: PalTask[];
  lastCompactAt?: number;
}

class NoDesktop extends Error {}

/** macOS: `open <folder>` is Finder; `open -a Terminal <folder>` is a new Terminal window cd'd there. */
function defaultReveal(kind: "finder" | "terminal", cwd: string): Promise<void> {
  if (process.platform !== "darwin") return Promise.reject(new NoDesktop());
  const args = kind === "finder" ? [cwd] : ["-a", "Terminal", cwd];
  return new Promise((ok, fail) => execFile("open", args, (err) => (err ? fail(err) : ok())));
}

/** A session to adopt: its id, the Pal's name and its folder. */
interface Adoptee {
  id: string;
  name: string;
  cwd: string;
}

export interface PalsDeps {
  /** A Pal's turn went through (true) or failed for want of Claude Code's login (false). */
  onAuth?: (pal: { id: string; name: string }, ok: boolean) => void;
  paths: Paths;
  claudeDir: string;
  bus: Bus;
  chat: ChatLog;
  approvals: ApprovalManager;
  questions: QuestionManager;
  router: Router;
  audit: Audit;
  driver: HarnessDriver;
  sessions: Sessions;
  cli: ClaudeCli;
  settings: () => Settings;
  /** How Pals start (PaloAlly Helper, or directly). */
  launch?: () => Promise<PalLaunch>;
  usesHelper?: () => boolean;
  helperFailed?: (why: string) => void;
  helperApp?: () => string | undefined;
  launchMode?: () => "auto" | "helper" | "direct";
  readMessages?: (sessionId: string, dir: string) => Promise<RawSessionMessage[]>;
  /** A workspace exists (pals.create's workspaceId); without it no workspace does. */
  workspaceExists?: (id: string) => boolean;
  /** Sessions shown in a workspace's tiles: never the ones put to sleep to make room. */
  shownIds?: () => Set<string>;
  /** A new or resumed session joins a workspace (with a tile of its own). */
  workspaceJoin?: (workspaceId: string, palId: string) => void;
  /** A session is gone (ended, removed, handed back): out of its workspace. */
  palGone?: (palId: string) => void;
  /** The computer's ended conversations (the SDK's listSessions / getSessionInfo); also each Pal's title (§13). */
  recentSource?: RecentSource;
  /** Retitles a session that has no process (the SDK's renameSession). */
  renameSession?: (sessionId: string, title: string, dir: string) => Promise<void>;
  /** The models a session can run on (what Palo's model.get lists). */
  models?: () => Promise<ModelOption[]>;
  /** Opens a session's folder on this computer (default: macOS `open`). */
  reveal?: (kind: "finder" | "terminal", cwd: string) => Promise<void>;
  /** A Pal's permission mode; default: the owner's own default for Claude Code. */
  palMode?: () => string;
  /** A Pal's model; default: what its transcript last ran on (a new one: the owner's default). */
  palModel?: () => string | undefined;
  paloName?: () => string;
  /** A Pal's palo_send: the words (already wrapped as from that Pal) go into the assistant's session like any other inbound message (§16). */
  toAssistant?: (from: string, wrapped: string) => void;
  registry?: () => RegistryEntry[];
  pidAlive?: (pid: number) => boolean;
  kill?: (pid: number, signal: NodeJS.Signals) => void;
  /** Copies a session up to one entry as a new one (default: the SDK's forkSession). */
  forkSession?: ForkSession;
  /** The owner's images and files (media.upload / uploadChunk), as Palo takes them. */
  media?: MediaStore;
  /** The library its sessions publish into (Artifact, SendUserFile). */
  artifacts?: ArtifactLibrary;
  timing?: Partial<PalsTiming>;
  now?: () => number;
  log?: (s: string) => void;
}

export interface PalsTiming {
  readyMs: number; // Claude Code up after starting
  restartMs: number[]; // back off between restarts after a crash
  exitWaitMs: number; // a process asked to end, before it's killed
  exitPollMs: number; // how often a terminal session's process is checked while adopting
  adoptWaitMs: number; // how long an adoption waits for the owner to quit in the terminal
  stopWaitMs: number; // a background session stopping (claude stop) before giving up
  guardMs: number; // how often running Pals are checked for another process on their transcript
  startStaggerMs: number; // between Pals coming back at the host's start
  sleepIdleMs: number; // idle this long, an awake Pal is put to sleep
  sleepCheckMs: number; // how often that's looked at
}

const TIMING: PalsTiming = {
  readyMs: 45_000,
  restartMs: [2_000, 5_000, 15_000, 30_000, 60_000],
  exitWaitMs: 6_000,
  exitPollMs: 500,
  adoptWaitMs: 30 * 60_000,
  stopWaitMs: 15_000,
  guardMs: 5_000,
  startStaggerMs: 1_500,
  sleepIdleMs: 20 * 60_000,
  sleepCheckMs: 30_000,
};

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}

const expandHome = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p);
const shq = (s: string) => (/^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`);

function within(root: string, p: string): boolean {
  if (!p) return false;
  const r = resolve(root);
  const x = resolve(p);
  return x === r || x.startsWith(r + sep);
}

/** Claude Code's own default permission mode for the owner's sessions. */
export function ownerMode(claudeDir: string): string {
  try {
    const s = JSON.parse(readFileSync(join(claudeDir, "settings.json"), "utf8"));
    const m = s?.permissions?.defaultMode;
    if (typeof m === "string" && m) return m;
  } catch {
    /* none */
  }
  return "default";
}

interface Waiting {
  sessionId: string;
  pids: number[];
  since: number;
  timer: ReturnType<typeof setTimeout> | null;
  session: Adoptee;
  by: string;
}

export class Pals {
  private data: PalFile;
  private pals = new Map<string, PalSession>();
  private waiting = new Map<string, Waiting>();
  private readonly timing: PalsTiming;
  private readonly meter: SpendMeter;
  private readonly launcher: PalLauncher;
  private readonly recentList: RecentSessions;
  private readonly source: RecentSource;
  private naming = new Map<string, Promise<void>>(); // titles being read back, by Pal
  private adopts = new Map<string, Promise<{ pal: Pal } | { waiting: "exit-in-terminal" }>>(); // in flight, by session id
  private lastPush = new Map<string, number>();
  private retried = new Map<string, number>(); // a Pal open elsewhere: when it was last tried again
  private sent = new Map<string, Map<string, { id: string; seq: number }>>(); // per Pal: clientMsgId → reply
  private lastEmitted = "";
  private emitTimer: ReturnType<typeof setTimeout> | null = null;
  private guardTimer: ReturnType<typeof setInterval> | null = null;
  private sleepTimer: ReturnType<typeof setInterval> | null = null;
  private foldTimer: ReturnType<typeof setInterval> | null = null;
  private balanceTimer: ReturnType<typeof setTimeout> | null = null;
  private waking = new Set<string>(); // asleep Pals being woken (said once)
  private startTimers: ReturnType<typeof setTimeout>[] = [];
  private offBus: (() => void) | null = null;
  private started = false;

  constructor(private d: PalsDeps) {
    this.timing = { ...TIMING, ...d.timing };
    this.meter = new SpendMeter(d.claudeDir);
    this.launcher = new PalLauncher({ root: d.paths.root, helperApp: d.helperApp, mode: d.launchMode, log: (s) => this.log(s) });
    const saved = readJson<Partial<PalFile>>(d.paths.pals, {});
    const list = <T>(v: T[] | undefined): T[] => (Array.isArray(v) ? v : []);
    this.data = { pals: list(saved.pals), proposals: list(saved.proposals), adoptions: list(saved.adoptions), former: list(saved.former), ended: list(saved.ended) };
    // Pals no longer have a daily spending limit (2026-10-19, the owner): an
    // old record's limit goes, and one stopped for it carries on.
    for (const rec of this.data.pals as (Omit<PalRecord, "stoppedFor"> & { dailyUsd?: number; budgetDay?: string; stoppedFor?: string })[]) {
      delete rec.dailyUsd;
      delete rec.budgetDay;
      if (rec.stoppedFor === "budget") {
        rec.stoppedFor = undefined;
        rec.note = undefined;
      }
    }
    this.source = d.recentSource ?? sdkSource(d.claudeDir);
    this.recentList = new RecentSessions({
      claudeDir: d.claudeDir,
      roots: () => ownRoots(d.paths.root),
      formerPals: () => [...this.data.former, ...this.data.ended],
      source: this.source,
      now: () => this.now(),
      log: (s) => this.log(s),
    });
    for (const rec of this.data.pals) this.pals.set(rec.id, this.session(rec));
  }

  private log(s: string): void {
    this.d.log?.(`pals: ${s}`);
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  private save(): void {
    writeJson(this.d.paths.pals, this.data);
  }

  private registry(): RegistryEntry[] {
    return this.d.registry?.() ?? readRegistry(join(this.d.claudeDir, "sessions"));
  }

  private alive(pid: number): boolean {
    return (this.d.pidAlive ?? pidAlive)(pid);
  }

  private session(rec: PalRecord): PalSession {
    return new PalSession(rec, {
      driver: this.d.driver,
      approvals: this.d.approvals,
      questions: this.d.questions,
      claudeDir: this.d.claudeDir,
      launch: () => (this.d.launch ?? (() => this.launcher.launch()))(),
      helperFailed: (why) => (this.d.helperFailed ?? ((w) => this.launcher.markBroken(w)))(why),
      holders: (sid, own) => this.holders(sid, own),
      emit: (event, data) => this.d.bus.emit(event, data),
      changed: () => this.emitSoon(),
      save: () => this.save(),
      mapOptions: () => this.mapOptions(rec),
      appendPrompt: () => PAL_PROMPT(this.paloName()),
      onWaiting: (pal, body, ids) => this.pushWaiting(pal, body, ids),
      toPalo: (pal, text) => this.toolPaloSend(pal, text),
      tools: (pal) => this.sessionTools(pal),
      onTurnEnd: (pal) => {
        this.balanceSoon();
        void this.readTitle(pal);
      },
      onAuth: (pal, ok) => this.d.onAuth?.({ id: pal.id, name: pal.rec.name }, ok),
      beforeStart: (pal) => this.readTitle(pal),
      onStopped: (pal) => this.onStopped(pal),
      onWoke: (pal) => {
        this.waking.delete(pal.id);
        this.balanceSoon();
      },
      pidAlive: (pid) => this.alive(pid),
      kill: this.d.kill ?? ((pid, sig) => process.kill(pid, sig)),
      forkSession: this.forkSession,
      ...(this.d.media ? { media: this.d.media } : {}),
      timing: this.timing,
      foldDays: () => this.d.settings().foldDays,
      now: () => this.now(),
      log: (s) => this.log(s),
    });
  }

  /** settings.maxAwake. */
  private maxAwake(): number {
    const n = this.d.settings().maxAwake;
    return Number.isFinite(n) && n >= 1 ? Math.floor(n) : DEFAULT_MAX_AWAKE;
  }

  /** What the owner calls it: 新会话 until it has a name of its own. */
  private shownName(pal: PalSession): string {
    return pal.rec.autoNamed ? t("pals.newSession") : pal.rec.name;
  }

  /** A session's tools that reach the owner: the assistant's handlers, scoped to it (its folder, its conversation, its name). */
  private sessionTools(pal: PalSession): DeliveryToolHandlers | undefined {
    const { media, artifacts } = this.d;
    if (!media || !artifacts) return undefined;
    return makeDeliveryTools({
      artifacts,
      chat: this.d.chat,
      router: this.d.router,
      audit: this.d.audit,
      media,
      pals: this,
      ownerChannel: () => "app",
      cwd: pal.rec.cwd,
      session: { id: pal.id, name: () => this.shownName(pal), card: (m, tool) => pal.card(m, tool), notice: (text) => pal.pushNotice(text) },
    });
  }

  private paloName(): string {
    return this.d.paloName?.() ?? PALO_NAME;
  }

  private assistantName(): string {
    return this.d.settings().assistantName || "Palo";
  }

  private mapOptions(rec: PalRecord) {
    const media = this.d.media;
    return {
      assistantName: this.assistantName(),
      paloName: this.paloName(),
      ...(rec.duty ? { duty: rec.duty } : {}),
      ...(media ? { recall: (uuid: string) => media.recall(uuid) } : {}),
    };
  }

  private get forkSession(): ForkSession {
    return this.d.forkSession ?? ((sid, o) => sdkForkSession(sid, o));
  }

  // ---------------- lifecycle ----------------

  /**
   * At the host's start: the Pals that were awake come back (a few seconds
   * apart; the five used most lately, if more were), those asleep stay
   * asleep, and the checks begin.
   */
  start(): void {
    if (this.started) return;
    this.started = true;
    this.offBus = this.d.bus.on((event) => {
      if (event === "sessions.updated") this.emitSoon();
    });
    // Every one that was up comes back (even ones that couldn't start before).
    let i = 0;
    const back = [...this.pals.values()]
      .filter((p) => p.rec.status !== "asleep")
      .sort((a, b) => b.rec.lastUsedAt - a.rec.lastUsedAt);
    const awakeMax = this.maxAwake();
    for (const pal of back.slice(awakeMax)) pal.markAsleep();
    for (const pal of back.slice(0, awakeMax)) {
      pal.clearStop();
      pal.queueStart();
      const t = setTimeout(() => void this.bringBack(pal, "start"), i++ * this.timing.startStaggerMs);
      this.startTimers.push(t);
    }
    this.guardTimer = setInterval(() => this.guard(), this.timing.guardMs);
    (this.guardTimer as any).unref?.();
    this.sleepTimer = setInterval(() => this.balance(), this.timing.sleepCheckMs);
    (this.sleepTimer as any).unref?.();
    // A session crossing foldDays changes `folded` with nobody touching it: say so.
    this.foldTimer = setInterval(() => this.emitSoon(), FOLD_CHECK_MS);
    (this.foldTimer as any).unref?.();
    this.emitSoon();
  }

  /** The host stops: every Pal's process ends (they come back at the next start). */
  stop(): void {
    this.started = false;
    this.offBus?.();
    for (const t of this.startTimers.splice(0)) clearTimeout(t);
    if (this.guardTimer) clearInterval(this.guardTimer);
    if (this.sleepTimer) clearInterval(this.sleepTimer);
    if (this.foldTimer) clearInterval(this.foldTimer);
    if (this.balanceTimer) clearTimeout(this.balanceTimer);
    this.balanceTimer = null;
    if (this.emitTimer) clearTimeout(this.emitTimer);
    for (const w of this.waiting.values()) if (w.timer) clearTimeout(w.timer);
    this.waiting.clear();
    for (const pal of this.pals.values()) void pal.shutdown();
  }

  /** Waits until every Pal's process is gone (tests, the CLI). */
  async stopAndWait(): Promise<void> {
    this.stop();
    await Promise.all([...this.pals.values()].map((p) => p.shutdown()));
  }

  private async bringBack(pal: PalSession, why: string): Promise<void> {
    if (!this.pals.has(pal.id)) return;
    try {
      await pal.start();
      this.d.audit.log("pal.resumed", { pal: pal.id, name: pal.rec.name, why });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.log(`couldn't bring back ${pal.rec.name}: ${msg}`);
      if (e instanceof HeldElsewhere) pal.stopFor("elsewhere", msg);
      else pal.stopFor("failed", t("pals.resumeFailed", { msg }));
    }
  }

  /** What the stall watchdog watches: the Pals that are awake. */
  stallTargets(): StallTarget[] {
    return [...this.pals.values()].filter((p) => p.awake).map((p) => p.stallTarget());
  }

  /** Nothing in flight in any Pal (safe to restart the host). */
  quiet(): boolean {
    return [...this.pals.values()].every((p) => {
      const s = p.status();
      return s === "idle" || s === "stopped" || s === "asleep";
    });
  }

  // ---------------- asleep and awake (§12) ----------------

  private balanceSoon(): void {
    if (this.balanceTimer || !this.started) return;
    this.balanceTimer = setTimeout(() => {
      this.balanceTimer = null;
      this.balance();
    }, 50);
    (this.balanceTimer as any).unref?.();
  }

  /**
   * Awake ones idle 20 minutes go to sleep; past settings.maxAwake awake,
   * the least recently used idle ones too, except those shown in a
   * workspace's tiles. Busy or waiting ones never: past the limit for a
   * while, then, until one of them is done.
   */
  private balance(): void {
    if (!this.started) return;
    const now = this.now();
    for (const p of this.pals.values()) {
      if (!p.awake) continue;
      const since = p.idleSince();
      if (since !== null && now - since >= this.timing.sleepIdleMs) void this.putToSleep(p, "idle");
    }
    const awake = [...this.pals.values()].filter((p) => p.awake);
    let over = awake.length - this.maxAwake();
    if (over <= 0) return;
    const shown = this.d.shownIds?.() ?? new Set<string>();
    const idle = awake.filter((p) => p.idleSince() !== null && !shown.has(p.id)).sort((a, b) => a.rec.lastUsedAt - b.rec.lastUsedAt);
    for (const p of idle) {
      if (over-- <= 0) break;
      void this.putToSleep(p, "more awake than allowed");
    }
  }

  private async putToSleep(pal: PalSession, why: string): Promise<void> {
    this.d.audit.log("pal.slept", { pal: pal.id, name: pal.rec.name, why });
    this.log(`${pal.rec.name} goes to sleep (${why})`);
    const done = pal.sleep();
    this.emitSoon();
    await done;
    this.emitSoon();
  }

  /**
   * pals.wake: the same session resumes (it's a moment), and it counts as
   * just used. One awake already is left as it is; one stopped (its spending
   * limit, couldn't start) carries on, as the owner's words would make it.
   */
  async wake(id: string, why: string): Promise<Pal> {
    const pal = this.mustGet(id);
    this.wakingFor(pal, why);
    if (pal.rec.stoppedFor) pal.clearStop();
    pal.rec.lastUsedAt = this.now();
    try {
      await pal.start();
    } catch (e) {
      this.waking.delete(pal.id);
      if (e instanceof HeldElsewhere) pal.markStopped("elsewhere", e.message);
      throw e;
    }
    this.save();
    this.emitSoon();
    this.balanceSoon();
    return pal.toWire();
  }

  // An asleep Pal is about to be woken: said once, however many words wait.
  private wakingFor(pal: PalSession, why: string): boolean {
    if (!pal.asleep) return false;
    if (this.waking.has(pal.id)) return true;
    this.waking.add(pal.id);
    this.d.audit.log("pal.woke", { pal: pal.id, name: pal.rec.name, why });
    this.log(`waking ${pal.rec.name} (${why})`);
    return true;
  }

  /**
   * Claude Code's login is back: each of these, awake and between turns, ends
   * its process (asleep), so the next word starts one that signs in afresh.
   */
  async restartIdle(ids: string[]): Promise<void> {
    for (const id of ids) {
      const pal = this.pals.get(id);
      if (!pal?.awake || pal.busy) continue;
      await this.putToSleep(pal, "login came back");
    }
  }

  /** A card of a Pal's was answered: one asleep is woken (in the background). */
  cardAnswered(palId: string): void {
    const pal = this.pals.get(palId);
    if (!pal?.asleep) return;
    void this.wake(pal.id, "card").catch((e) => this.log(`couldn't wake ${pal.rec.name}: ${e instanceof Error ? e.message : e}`));
  }

  // ---------------- the list ----------------

  list(): Pal[] {
    return [...this.pals.values()].map((p) => p.toWire()).sort((a, b) => b.updatedAt - a.updatedAt);
  }

  isPal(sessionId: string): boolean {
    return [...this.pals.values()].some((p) => p.rec.sessionId === sessionId || p.rec.formerSessions?.includes(sessionId));
  }

  /** pals.adopt is waiting for this session to quit in its terminal. */
  adopting(sessionId: string): boolean {
    return this.waiting.has(sessionId);
  }

  get helper(): boolean {
    return this.d.usesHelper?.() ?? this.launcher.usesHelper;
  }

  payload(others = this.d.sessions.list()) {
    return { pals: this.list(), others, hooks: this.d.sessions.hooksEnabled(), helper: this.helper };
  }

  /** pals.list: read the computer's sessions again first. */
  async listFresh() {
    return this.payload(await this.d.sessions.listFresh());
  }

  // ---------------- 最近的对话 (§10) ----------------

  /**
   * pals.recent: the conversations that ended on the computer in the last 30
   * days, newest first (at most 50): not what's running (`others`), not a
   * Pal, not PaloAlly's own. `folder` (a path, or a folder's name) narrows it.
   */
  async recent(o: { folder?: string; limit?: number } = {}): Promise<RecentSession[]> {
    return (await this.recentEntries(o)).map(recentWire);
  }

  private async recentEntries(o: { folder?: string; limit?: number } = {}): Promise<RecentEntry[]> {
    const all = await this.recentList.all();
    const taken = this.takenIds();
    const match = folderMatch(o.folder);
    const limit = Math.max(1, Math.min(Math.floor(Number(o.limit)) || RECENT_MAX, RECENT_MAX));
    return all.filter((e) => !taken.has(e.sessionId) && match(e.cwd)).slice(0, limit);
  }

  /** A conversation that ended (sessions.history, §14): its folder, when it's one pals.recent would list. */
  async endedCwd(sessionId: string): Promise<string | undefined> {
    const found = await this.recentList.find(sessionId);
    return typeof found === "string" ? undefined : found.cwd;
  }

  // Sessions that aren't ended ones: the Pals, those being adopted, and the
  // computer's running (or stopped background) sessions.
  private takenIds(): Set<string> {
    const ids = new Set<string>([...this.pals.values()].flatMap((p) => [p.rec.sessionId, ...(p.rec.formerSessions ?? [])]));
    for (const id of [...this.waiting.keys(), ...this.adopts.keys()]) ids.add(id);
    for (const s of this.d.sessions.list()) ids.add(s.id);
    try {
      for (const e of this.registry()) ids.add(e.sessionId);
    } catch {
      /* the next look */
    }
    return ids;
  }

  private emitSoon(): void {
    if (this.emitTimer) return;
    this.emitTimer = setTimeout(() => {
      this.emitTimer = null;
      this.emitNow();
    }, 30);
    (this.emitTimer as any).unref?.();
  }

  emitNow(): void {
    const p = this.payload();
    const key = JSON.stringify(p);
    if (key === this.lastEmitted) return;
    this.lastEmitted = key;
    this.d.bus.emit("pals.updated", p);
  }

  /** A Pal by id, or by its name or session id (the assistant's tools); then by a name it had before (§13). */
  get(key: string): PalSession | undefined {
    const k = key.trim();
    if (!k) return undefined;
    const all = [...this.pals.values()];
    const lower = k.toLowerCase();
    return (
      this.pals.get(k) ??
      all.find((p) => p.rec.sessionId === k) ??
      all.find((p) => p.rec.name === k) ??
      all.find((p) => p.rec.name.toLowerCase() === lower) ??
      [...all].reverse().find((p) => p.rec.formerNames?.some((n) => n.toLowerCase() === lower))
    );
  }

  private mustGet(id: string): PalSession {
    const p = this.pals.get(id) ?? this.get(id);
    if (!p) throw new Error(t("pals.noPal"));
    return p;
  }

  // ---------------- never two writers ----------------

  /** The live processes holding a session's transcript, other than `own`. */
  async holders(sessionId: string, own?: number): Promise<Holder[]> {
    const out = new Map<number, Holder>();
    for (const e of this.registry()) {
      if (e.sessionId !== sessionId || e.pid === own) continue;
      out.set(e.pid, { pid: e.pid, bg: e.kind === "bg" || e.kind === "background", ...(e.jobId ? { shortId: e.jobId } : {}) });
    }
    try {
      for (const a of await this.d.cli.agents()) {
        if (a.sessionId !== sessionId || !a.pid || a.pid === own || out.has(a.pid) || !this.alive(a.pid)) continue;
        out.set(a.pid, { pid: a.pid, bg: a.kind === "background" || a.kind === "bg", ...(a.id ? { shortId: a.id } : {}) });
      }
    } catch (e) {
      this.log(`claude agents failed: ${e instanceof Error ? e.message : e}`);
    }
    return [...out.values()];
  }

  // A running Pal whose transcript another process opened (the owner resumed
  // it in a terminal): the Pal steps aside at once. Once that process is gone,
  // the Pal comes back (it's always on).
  private guard(): void {
    let entries: RegistryEntry[];
    try {
      entries = this.registry();
    } catch {
      return;
    }
    const now = this.now();
    for (const pal of this.pals.values()) {
      const held = entries.filter((e) => e.sessionId === pal.rec.sessionId);
      if (pal.rec.stoppedFor === "elsewhere") {
        if (held.length || now - (this.retried.get(pal.id) ?? 0) < 30_000) continue;
        this.retried.set(pal.id, now);
        pal.clearStop();
        // One that was asleep (woken while open elsewhere) goes back to sleep.
        if (pal.rec.status === "asleep") this.emitSoon();
        else void this.bringBack(pal, "free again");
        continue;
      }
      const own = pal.pid;
      if (!pal.running || !own) continue;
      const other = held.find((e) => e.pid !== own);
      if (!other) continue;
      this.d.audit.log("pal.elsewhere", { pal: pal.id, name: pal.rec.name, pid: other.pid });
      pal.stopFor("elsewhere", t("pals.elsewhere"));
    }
  }

  private onStopped(pal: PalSession): void {
    this.emitSoon();
    this.d.audit.log("pal.stopped", { pal: pal.id, name: pal.rec.name, why: pal.rec.stoppedFor, note: pal.rec.note });
  }

  // ---------------- adopting ----------------

  private oldest(): PalSession {
    return [...this.pals.values()].sort((a, b) => a.rec.lastUsedAt - b.rec.lastUsedAt)[0]!;
  }

  private room(): void {
    if (this.pals.size < MAX_PALS) return;
    throw new Error(t("pals.tooManyErr", { max: MAX_PALS, oldest: this.oldest().rec.name }));
  }

  // What the assistant's tools say when there's no room.
  private full(): string | null {
    if (this.pals.size < MAX_PALS) return null;
    return t("pals.tooManyTool", { max: MAX_PALS, oldest: this.oldest().rec.name });
  }

  // `except`: the Pal being renamed (its own name isn't taken).
  private uniqueName(want: string, liveNames: string[] = [], except?: PalSession): string {
    const base = want.replace(/[\r\n\t]+/g, " ").trim().slice(0, 40) || "Pal";
    const others = [...this.pals.values()].filter((p) => p !== except).map((p) => p.rec.name.toLowerCase());
    const taken = new Set([...others, this.paloName().toLowerCase(), ...liveNames.map((n) => n.toLowerCase())]);
    if (!taken.has(base.toLowerCase())) return base;
    for (let i = 2; ; i++) if (!taken.has(`${base} ${i}`.toLowerCase())) return `${base} ${i}`;
  }

  // ---------------- its name (§13) ----------------

  /**
   * Its name, read back from Claude Code's title for the session: after a
   * turn (a /rename in it, or one on claude.ai) and right before it starts
   * (one in a terminal while it slept). A Pal always runs under its name, so
   * Claude Code always has it as the custom title; when the read doesn't
   * find one (it only looks at the transcript's head and tail), the name
   * stays, unless the process' own registry entry says it was renamed.
   * Unique among the Pals (「网站 2」).
   */
  readTitle(pal: PalSession): Promise<void> {
    const busy = this.naming.get(pal.id);
    if (busy) return busy;
    const p = this.doReadTitle(pal).finally(() => this.naming.delete(pal.id));
    this.naming.set(pal.id, p);
    return p;
  }

  private async doReadTitle(pal: PalSession): Promise<void> {
    let info: Awaited<ReturnType<RecentSource["info"]>>;
    try {
      info = await this.source.info(pal.rec.sessionId, pal.rec.cwd);
    } catch (e) {
      this.log(`couldn't read ${pal.rec.name}'s title: ${e instanceof Error ? e.message : e}`);
      return;
    }
    if (!this.pals.has(pal.id)) return;
    // Still under its placeholder name: named from what Claude Code made of its first words, once there are any.
    if (pal.rec.autoNamed) {
      const custom = String(info?.customTitle ?? "").trim();
      if (!custom || custom === pal.rec.name) {
        const auto = autoTitle(info);
        if (!auto) return;
        const unique = this.uniqueName(auto, [], pal);
        // Claude Code's own title follows, so a terminal and /resume say the same (and the next start doesn't read the placeholder back).
        if (!(await pal.renameLive(unique)) && existsSync(pal.transcript)) {
          await (this.d.renameSession ?? sdkRename(this.d.claudeDir))(pal.rec.sessionId, unique, pal.rec.cwd).catch((e) => this.log(`couldn't retitle ${pal.rec.name}: ${e instanceof Error ? e.message : e}`));
        }
        if (this.pals.has(pal.id)) this.setName(pal, unique, "auto");
        return;
      }
    }
    let want = info?.customTitle?.trim() ? palTitle(info, pal.rec.cwd) : "";
    if (!want && pal.running && pal.pid) {
      // Renamed in the process (/rename): its entry in Claude Code's registry says so.
      const entry = this.registry().find((e) => e.pid === pal.pid && e.sessionId === pal.rec.sessionId);
      if (entry?.nameSource === "user" && entry.name && entry.name !== pal.spawnedAs) want = entry.name;
    }
    if (!want) return;
    this.setName(pal, this.uniqueName(want, [], pal), "claude");
  }

  private setName(pal: PalSession, name: string, by: string): boolean {
    const from = pal.rec.name;
    if (name === from) return false;
    pal.rec.formerNames = [...(pal.rec.formerNames ?? []).filter((n) => n !== name && n !== from), from].slice(-5);
    pal.rec.name = name;
    delete pal.rec.autoNamed;
    this.save();
    this.d.audit.log("pal.renamed", { pal: pal.id, from, to: name, by });
    this.log(`${from} is called ${name} now (${by})`);
    this.emitSoon();
    return true;
  }

  /**
   * pals.rename: the owner names it. Claude Code's own title changes too
   * (in its process when it's running, as /rename would; in its transcript
   * when it isn't), so a terminal, /resume and claude.ai say the same. A name
   * another Pal has gets a number. It isn't restarted: other sessions reach it
   * under the new name once it starts again (the assistant, by pal_send, at once).
   */
  async rename(id: string, name: string, by: string): Promise<Pal> {
    const pal = this.mustGet(id);
    const want = String(name ?? "").replace(/\s+/g, " ").trim();
    if (!want) throw new Error(t("pals.nameEmpty"));
    if ([...want].length > 40) throw new Error(t("pals.nameLong"));
    if (want.toLowerCase() === this.paloName().toLowerCase()) throw new Error(t("pals.nameIsAssistant", { name: want }));
    delete pal.rec.autoNamed;
    const unique = this.uniqueName(want, [], pal);
    if (!(await pal.renameLive(unique))) {
      // No process: into its transcript, where Claude Code reads it (none yet: it starts under it).
      if (existsSync(pal.transcript)) await (this.d.renameSession ?? sdkRename(this.d.claudeDir))(pal.rec.sessionId, unique, pal.rec.cwd);
    }
    this.setName(pal, unique, by);
    this.emitNow();
    return pal.toWire();
  }

  private add(rec: PalRecord): PalSession {
    this.data.pals = [...this.data.pals.filter((r) => r.id !== rec.id), rec];
    this.save();
    const pal = this.session(rec);
    this.pals.set(rec.id, pal);
    return pal;
  }

  // `out`: the owner took it out of the list; it's among the recent ones again.
  private drop(pal: PalSession, out = false): void {
    this.pals.delete(pal.id);
    this.data.pals = this.data.pals.filter((r) => r.id !== pal.id);
    this.sent.delete(pal.id);
    this.lastPush.delete(pal.id);
    if (out) {
      // Gone back and not spoken to since: the old session is the one there is.
      const sessionId = pal.pendingRewind()?.from ?? pal.rec.sessionId;
      const { cwd } = pal.rec;
      this.data.former = [...this.data.former.filter((f) => f.sessionId !== sessionId), { sessionId, cwd, at: this.now() }].slice(-20);
      this.recentList.invalidate();
    }
    this.save();
    this.d.palGone?.(pal.id);
  }

  /** The workbench says which workspace a session is in (written on its record; nothing is emitted). */
  setWorkspace(id: string, workspaceId: string | undefined): void {
    const pal = this.pals.get(id);
    if (!pal || pal.rec.workspaceId === workspaceId) return;
    if (workspaceId) pal.rec.workspaceId = workspaceId;
    else delete pal.rec.workspaceId;
    this.save();
  }

  /**
   * pals.adopt: one of the computer's sessions becomes a Pal. A background
   * session is stopped first; a terminal session is waited for (the owner
   * quits it there) and taken over once its process is gone, unless `wait`
   * is false (then it's an error). A conversation that ended is resumed at once.
   */
  adopt(sessionId: string, by: string, o: { wait?: boolean } = {}): Promise<{ pal: Pal } | { waiting: "exit-in-terminal" }> {
    const sid = String(sessionId ?? "").trim();
    if (!sid) return Promise.reject(new Error(t("pals.noSession")));
    const have = this.get(sid);
    if (have && have.rec.sessionId === sid) return Promise.resolve({ pal: have.toWire() });
    if (this.waiting.has(sid)) return Promise.resolve({ waiting: "exit-in-terminal" });
    // Asked twice at once (two devices, a card and the list): one adoption.
    const inFlight = this.adopts.get(sid);
    if (inFlight) return inFlight;
    const p = this.doAdopt(sid, by, o).finally(() => this.adopts.delete(sid));
    this.adopts.set(sid, p);
    return p;
  }

  private async doAdopt(sid: string, by: string, o: { wait?: boolean }): Promise<{ pal: Pal } | { waiting: "exit-in-terminal" }> {
    this.room();
    await this.d.sessions.watch.refresh({ agents: true });
    const rec = this.d.sessions.watch.get(sid);
    // Not one of the computer's sessions now: a conversation that ended (§10).
    if (!rec?.cwd) return { pal: (await this.adoptEnded(sid, by)).toWire() };
    const wire = this.d.sessions.watch.toWire(rec);
    const session: Adoptee = { id: wire.id, name: wire.name, cwd: wire.cwd };
    let holders = await this.holders(sid);
    const bg = holders.filter((h) => h.bg);
    if (bg.length) {
      const short = bg.find((h) => h.shortId)?.shortId ?? rec.shortId;
      if (!short) throw new Error(t("pals.noBgId"));
      await this.d.cli.stop(short);
      this.d.audit.log("pal.stopped_bg", { session: sid, short, by });
      // Stopped means its process is gone, not just its entry in the lists.
      const end = this.now() + this.timing.stopWaitMs;
      const stillBg = async () => (holders = await this.holders(sid)).some((h) => h.bg) || bg.some((h) => this.alive(h.pid));
      while ((await stillBg()) && this.now() < end) await new Promise((r) => setTimeout(r, 200));
      if (await stillBg()) throw new Error(t("pals.wontStop"));
    }
    if (holders.length) {
      if (o.wait === false) throw new Error(t("pals.inTerminal"));
      this.waitForExit(sid, holders, session, by);
      return { waiting: "exit-in-terminal" };
    }
    return { pal: (await this.finishAdopt(session, by)).toWire() };
  }

  // A conversation that ended: no process to stop, it's resumed at once. Never
  // two writers: nothing may hold its transcript now (the Pal looks once more
  // right before it starts, and steps aside if anything opens it later).
  private async adoptEnded(sid: string, by: string): Promise<PalSession> {
    const found = await this.recentList.find(sid);
    if (typeof found === "string") throw new Error(found);
    const holders = await this.holders(sid);
    if (holders.length) throw new Error(t("pals.heldJustNow", { pids: holders.map((h) => h.pid).join("、") }));
    return this.finishAdopt({ id: sid, name: palNameFor(found), cwd: found.cwd }, by, true);
  }

  private async finishAdopt(s: Adoptee, by: string, ended = false): Promise<PalSession> {
    this.room();
    const live = this.d.sessions.list().filter((x) => x.id !== s.id && x.status !== "stopped").map((x) => x.name);
    const now = this.now();
    const model = this.d.palModel?.();
    const rec: PalRecord = {
      id: newId("pal_"),
      sessionId: s.id,
      name: this.uniqueName(s.name || basename(s.cwd), live),
      cwd: s.cwd,
      createdBy: "owner",
      createdAt: now,
      lastUsedAt: now,
      permissionMode: this.d.palMode?.() ?? ownerMode(this.d.claudeDir),
      ...(model ? { model } : {}),
    };
    const pal = this.add(rec);
    try {
      await pal.start();
    } catch (e) {
      await pal.shutdown();
      this.drop(pal);
      this.emitSoon();
      throw e;
    }
    this.d.audit.log("pal.adopted", { pal: rec.id, session: s.id, name: rec.name, cwd: rec.cwd, by, ...(ended ? { ended: true } : {}) });
    this.emitNow();
    this.balanceSoon();
    return pal;
  }

  /**
   * pals.adopt {cancel: true}: the owner no longer waits for a terminal
   * session to be quit; the host stops waiting too, and quitting it later
   * adopts nothing. `cancelled` says whether it was waiting; one that became a
   * Pal already comes back as that Pal.
   */
  cancelAdopt(sessionId: string, by: string): { cancelled: boolean; pal?: Pal } {
    const sid = String(sessionId ?? "").trim();
    const w = this.waiting.get(sid);
    if (!w) {
      const pal = sid ? this.get(sid) : undefined;
      return pal && pal.rec.sessionId === sid ? { cancelled: false, pal: pal.toWire() } : { cancelled: false };
    }
    if (w.timer) clearTimeout(w.timer);
    this.waiting.delete(sid);
    this.d.audit.log("pal.adopt_cancelled", { session: sid, name: w.session.name, by });
    this.emitNow();
    return { cancelled: true };
  }

  // A terminal session: once its process is gone (the owner typed /exit),
  // it's taken over by itself, within a second or so.
  private waitForExit(sessionId: string, holders: Holder[], session: Adoptee, by: string): void {
    const w: Waiting = { sessionId, pids: holders.map((h) => h.pid), since: this.now(), timer: null, session, by };
    this.waiting.set(sessionId, w);
    this.d.audit.log("pal.adopt_waiting", { session: sessionId, name: session.name, pids: w.pids, by });
    const tick = async () => {
      w.timer = null;
      if (this.waiting.get(sessionId) !== w) return;
      if (w.pids.some((p) => this.alive(p))) {
        if (this.now() - w.since > this.timing.adoptWaitMs) {
          this.waiting.delete(sessionId);
          this.emitSoon();
          this.notice(t("pals.adoptWaited", { min: Math.round(this.timing.adoptWaitMs / 60_000), name: session.name }));
          return;
        }
        w.timer = setTimeout(() => void tick(), this.timing.exitPollMs);
        return;
      }
      const again = await this.holders(sessionId);
      // Cancelled while the processes were being looked up.
      if (this.waiting.get(sessionId) !== w) return;
      if (again.length) {
        w.pids = again.map((h) => h.pid);
        w.timer = setTimeout(() => void tick(), this.timing.exitPollMs);
        return;
      }
      this.waiting.delete(sessionId);
      try {
        await this.finishAdopt(session, by);
      } catch (e) {
        const why = e instanceof Error ? e.message : String(e);
        this.d.audit.log("pal.adopt_failed", { session: sessionId, why });
        this.notice(t("pals.adoptFailed", { name: session.name, why }));
      }
      this.emitSoon();
    };
    w.timer = setTimeout(() => void tick(), this.timing.exitPollMs);
    this.emitSoon();
  }

  private notice(text: string): void {
    this.d.chat.add({ role: "system", kind: "notice", text, channel: "system" });
  }

  // ---------------- 交还终端 / 移出 ----------------

  /** pals.release: the host's process ends; the owner picks it up in a terminal. */
  async release(id: string, by: string): Promise<{ resumeCommand: string }> {
    const pal = this.mustGet(id);
    // Gone back (回到这里重来) and not spoken to since, its fork has no
    // transcript yet, and the old session would bring back all it left
    // behind (a terminal resumes a session whole). The conversation as it
    // stands is copied into a session of its own first (the SDK's
    // forkSession, as a rewind past a compaction is), and that's the one
    // the terminal resumes. Gone back to its very first message, nothing is
    // kept: a fresh `claude` in its folder. Copied before its process ends,
    // so a copy that fails leaves it as it was.
    const pending = pal.pendingRewind();
    let sid: string | null = pal.rec.sessionId;
    if (pending) {
      sid = pending.at
        ? (await this.forkSession(pending.from, { dir: pal.rec.cwd, upToMessageId: pending.at, title: pal.rec.name }).catch((e) => {
            throw new Error(t("pals.handBackFailed", { why: e instanceof Error ? e.message : String(e) }));
          })).sessionId
        : null;
    }
    await pal.shutdown();
    // (Spoken to meanwhile after all: its own session has it now.)
    if (pending && !pal.pendingRewind()) sid = pal.rec.sessionId;
    this.drop(pal, true);
    this.d.audit.log("pal.released", { pal: pal.id, session: sid ?? "", name: pal.rec.name, by, ...(pending ? { rewound: pending.from } : {}) });
    this.emitNow();
    return { resumeCommand: sid ? `cd ${shq(pal.rec.cwd)} && claude --resume ${sid}` : `cd ${shq(pal.rec.cwd)} && claude` };
  }

  /** pals.remove: out of the Pals; its transcript stays where Claude Code keeps it. */
  async remove(id: string, by: string): Promise<void> {
    const pal = this.mustGet(id);
    await pal.shutdown();
    this.drop(pal, true);
    this.d.audit.log("pal.removed", { pal: pal.id, session: pal.rec.sessionId, name: pal.rec.name, by });
    this.emitNow();
  }

  // ---------------- the owner's sessions: new, seen, ended, earlier ----------------

  /**
   * pals.create: a new session in any folder, the owner's own. It needs no
   * duty and has no daily limit (as in a terminal). Without a name it is
   * called session-<short id> inside and 新会话 to the owner, and is named
   * from its first words after its first turn. `text` is its first message;
   * it comes back at once, the process still starting.
   */
  createSession(o: { cwd: string; name?: string; text?: string; workspaceId?: string }, by: string): Pal {
    const dir = String(o?.cwd ?? "").trim();
    if (!dir) throw new Error(t("pals.newFolderNeeded"));
    let cwd = resolve(expandHome(dir));
    try {
      cwd = realpathSync(cwd); // as Claude Code records it (/tmp → /private/tmp)
    } catch {
      /* checked next */
    }
    let isDir = false;
    try {
      isDir = statSync(cwd).isDirectory();
    } catch {
      isDir = false;
    }
    if (!isDir) throw new Error(t("pals.dirNotFound", { cwd }));
    if (ownRoots(this.d.paths.root).some((r) => within(r, cwd))) throw new Error(t("pals.ownDir"));
    const given = String(o.name ?? "").replace(/\s+/g, " ").trim();
    if (given && [...given].length > 40) throw new Error(t("pals.nameLong"));
    if (given && given.toLowerCase() === this.paloName().toLowerCase()) throw new Error(t("pals.nameIsAssistant", { name: given }));
    const workspaceId = typeof o.workspaceId === "string" && o.workspaceId ? o.workspaceId : undefined;
    if (workspaceId && !this.d.workspaceExists?.(workspaceId)) throw new Error(t("pals.noWorkspace"));
    this.room();
    const now = this.now();
    const model = this.d.palModel?.();
    const id = newId("pal_");
    const rec: PalRecord = {
      id,
      sessionId: crypto.randomUUID(),
      name: given ? this.uniqueName(given) : `session-${id.slice(4, 10)}`,
      cwd,
      createdBy: "owner",
      createdAt: now,
      lastUsedAt: now,
      permissionMode: this.d.palMode?.() ?? ownerMode(this.d.claudeDir),
      ...(given ? {} : { autoNamed: true }),
      ...(workspaceId ? { workspaceId } : {}),
      ...(model ? { model } : {}),
    };
    const pal = this.add(rec);
    if (workspaceId) this.d.workspaceJoin?.(workspaceId, id);
    const text = String(o.text ?? "").trim();
    const failed = (e: unknown) => {
      const msg = e instanceof Error ? e.message : String(e);
      this.log(`couldn't start ${rec.name}: ${msg}`);
      pal.stopFor("failed", t("pals.resumeFailed", { msg }));
    };
    // (Starting is under way when this returns: it shows as starting.)
    const up = pal.start();
    if (text) void pal.send(text).then(() => this.balanceSoon(), failed);
    else void up.then(() => this.balanceSoon(), failed);
    this.d.audit.log("pal.created", { pal: rec.id, session: rec.sessionId, name: rec.name, cwd, by, owner: true });
    this.emitNow();
    return pal.toWire();
  }

  /** pals.seen: the owner looked. Idempotent; the other devices hear it in pals.updated. */
  seen(id: string): Pal {
    const pal = this.mustGet(id);
    if (pal.markSeen(this.now())) this.emitNow();
    return pal.toWire();
  }

  /** pals.detail: what the capsule's details show. */
  async detail(id: string): Promise<PalDetail> {
    const pal = this.mustGet(id);
    const models = ((await this.d.models?.().catch(() => [])) ?? []).map((m) => ({ id: m.value, name: m.displayName, efforts: m.efforts }));
    const info = pal.detailInfo();
    return { pal: pal.toWire(), ...info, spentToday: this.spentToday(pal), models };
  }

  /**
   * pals.setModel: model and/or effort for its next turns. A running session
   * switches live; a sleeping one only has its record changed (it isn't
   * woken) and starts on them.
   */
  async setModel(id: string, o: { model?: unknown; effort?: unknown }): Promise<{ pal: Pal }> {
    const pal = this.mustGet(id);
    const model = typeof o.model === "string" && o.model ? o.model : undefined;
    const effort = typeof o.effort === "string" && o.effort ? o.effort : undefined;
    if (!model && !effort) throw new Error(t("pals.setModelNothing"));
    if (pal.rec.stoppedFor) throw new Error(t("pals.stoppedNoModel"));
    if (effort && !["low", "medium", "high", "xhigh", "max"].includes(effort)) throw new Error(t("pals.effortBad"));
    const models = (await this.d.models?.().catch(() => [])) ?? [];
    if (model && models.length && !models.some((m) => m.value === model)) throw new Error(t("pals.modelUnknown", { model }));
    if (model && !models.length && !/^[\w.\-:[\]]{1,80}$/.test(model)) throw new Error(t("pals.modelUnknown", { model }));
    if (effort) {
      // the model it will run on: the one asked for, else the one it has (a full id matches its alias's entry by prefix)
      const on = model ?? pal.rec.model;
      const entry = models.find((m) => m.value === on);
      if (entry && !entry.efforts.includes(effort)) throw new Error(t("pals.effortUnsupported"));
    }
    await pal.setModel({ ...(model ? { model } : {}), ...(effort ? { effort } : {}) });
    this.d.audit.log("pal.model", { pal: pal.id, model: model ?? null, effort: effort ?? null });
    this.emitNow();
    return { pal: pal.toWire() };
  }

  /** pals.compact: the harness' /compact in the session (woken first if asleep). */
  async compact(id: string): Promise<Record<string, never>> {
    const pal = this.mustGet(id);
    await pal.compact();
    this.emitNow();
    return {};
  }

  /** pals.stopTask: a subagent or background task. */
  async stopTask(id: string, taskId: string): Promise<Record<string, never>> {
    await this.mustGet(id).stopTask(String(taskId ?? ""));
    this.emitNow();
    return {};
  }

  /** pals.reveal: its folder in Finder, or a plain shell in Terminal there (never the session itself). */
  async reveal(id: string, kind: unknown): Promise<Record<string, never>> {
    const pal = this.mustGet(id);
    if (kind !== "finder" && kind !== "terminal") throw new Error(t("pals.revealKind"));
    let isDir = false;
    try {
      isDir = statSync(pal.rec.cwd).isDirectory();
    } catch {
      isDir = false;
    }
    if (!isDir) throw new Error(t("pals.folderGone", { cwd: pal.rec.cwd }));
    try {
      await (this.d.reveal ?? defaultReveal)(kind, pal.rec.cwd);
    } catch (e) {
      throw e instanceof NoDesktop ? new Error(t("pals.revealNoDesktop")) : new Error(t("pals.revealFailed", { msg: e instanceof Error ? e.message : String(e) }));
    }
    return {};
  }

  /** pals.end: its process ends and it leaves the list for 以前的, where it can be picked up again. */
  async end(id: string, by: string): Promise<{ earlier: EarlierItem }> {
    const pal = this.mustGet(id);
    await pal.shutdown();
    // Gone back and not spoken to since: the old session is the one there is.
    const sessionId = pal.pendingRewind()?.from ?? pal.rec.sessionId;
    const item: EndedSession = { sessionId, name: pal.rec.name, cwd: pal.rec.cwd, at: this.now(), ...(pal.rec.workspaceId ? { workspaceId: pal.rec.workspaceId } : {}) };
    this.drop(pal);
    this.data.ended = [...this.data.ended.filter((e) => e.sessionId !== sessionId), item].slice(-ENDED_MAX);
    this.save();
    this.recentList.invalidate();
    this.d.audit.log("pal.ended", { pal: pal.id, session: sessionId, name: pal.rec.name, by });
    this.emitNow();
    return { earlier: endedItem(item) };
  }

  /**
   * pals.earlier: 以前的. The sessions the owner ended, those folded for lack
   * of use, and the conversations that ended on the computer lately, newest
   * first, one line per session (folded over ended over recent).
   */
  async earlier(o: { limit?: number; folder?: string } = {}): Promise<{ items: EarlierItem[] }> {
    const limit = Math.max(1, Math.min(Math.floor(Number(o.limit)) || 50, 200));
    const match = folderMatch(o.folder);
    const items: EarlierItem[] = [];
    const seen = new Set<string>();
    const push = (i: EarlierItem) => {
      if (seen.has(i.sessionId) || !match(i.cwd)) return;
      seen.add(i.sessionId);
      items.push(i);
    };
    for (const p of this.pals.values()) {
      if (!p.folded()) continue;
      push({ kind: "folded", key: `folded:${p.id}`, id: p.id, sessionId: p.rec.sessionId, name: p.rec.name, cwd: p.rec.cwd, at: p.rec.lastUsedAt });
    }
    for (const e of this.data.ended) if (!this.isPal(e.sessionId)) push(endedItem(e));
    for (const e of await this.recentEntries({ limit: RECENT_MAX }).catch(() => [])) push({ kind: "recent", key: `recent:${e.sessionId}`, sessionId: e.sessionId, name: e.title, cwd: e.cwd, at: e.lastModified });
    return { items: items.sort((a, b) => b.at - a.at).slice(0, limit) };
  }

  /**
   * pals.resume: picks up an item of 以前的: a folded session wakes (it is
   * still a session), an ended or recent one is resumed as a new session of
   * the same name and folder.
   */
  async resume(o: { key?: string; kind?: string; sessionId?: string }, by: string): Promise<{ pal: Pal }> {
    let key = String(o?.key ?? "").trim();
    if (!key && o?.kind && o?.sessionId) key = `${o.kind}:${o.sessionId}`;
    const i = key.indexOf(":");
    const kind = i < 0 ? "" : key.slice(0, i);
    const ref = i < 0 ? "" : key.slice(i + 1);
    if (!ref || !["folded", "ended", "recent"].includes(kind)) throw new Error(t("pals.badEarlierKey"));
    if (kind === "folded") {
      if (!this.pals.has(ref)) throw new Error(t("pals.earlierGone"));
      return { pal: await this.wake(ref, by) };
    }
    const have = this.get(ref);
    if (have && have.rec.sessionId === ref) return { pal: have.toWire() };
    if (kind === "recent") {
      const r = await this.adopt(ref, by, { wait: false });
      if (!("pal" in r)) throw new Error(t("pals.inTerminal"));
      this.forgetEnded(ref);
      return { pal: r.pal };
    }
    const e = this.data.ended.find((x) => x.sessionId === ref);
    if (!e) throw new Error(t("pals.earlierGone"));
    this.room();
    const holders = await this.holders(ref);
    if (holders.length) throw new Error(t("pals.heldJustNow", { pids: holders.map((h) => h.pid).join("、") }));
    let isDir = false;
    try {
      isDir = statSync(e.cwd).isDirectory();
    } catch {
      isDir = false;
    }
    if (!isDir) throw new Error(t("pals.folderGone", { cwd: e.cwd }));
    const pal = await this.finishAdopt({ id: ref, name: e.name, cwd: e.cwd }, by, true);
    // Back in the workspace it was ended from, if that is still there.
    if (e.workspaceId && this.d.workspaceExists?.(e.workspaceId)) {
      this.d.workspaceJoin?.(e.workspaceId, pal.id);
      this.emitNow();
    }
    this.forgetEnded(ref);
    return { pal: pal.toWire() };
  }

  private forgetEnded(sessionId: string): void {
    if (!this.data.ended.some((e) => e.sessionId === sessionId)) return;
    this.data.ended = this.data.ended.filter((e) => e.sessionId !== sessionId);
    this.save();
    this.emitSoon();
  }

  /** pals.folders: where a new session can start, the most recently used first (not PaloAlly's own). */
  async folders(o: { limit?: number } = {}): Promise<{ folders: { path: string; name: string; lastUsedAt: number }[] }> {
    const limit = Math.max(1, Math.min(Math.floor(Number(o.limit)) || 20, 50));
    const own = ownRoots(this.d.paths.root);
    const best = new Map<string, number>();
    const note = (path: string, at: number) => {
      if (!path || own.some((r) => within(r, path))) return;
      if (at > (best.get(path) ?? -1)) best.set(path, at);
    };
    for (const p of this.pals.values()) note(p.rec.cwd, p.rec.lastUsedAt);
    for (const e of this.data.ended) note(e.cwd, e.at);
    for (const e of await this.recentList.all().catch(() => [])) note(e.cwd, e.lastModified);
    const folders = [...best].sort((a, b) => b[1] - a[1]).slice(0, limit).map(([path, lastUsedAt]) => ({ path, name: basename(path) || path, lastUsedAt }));
    return { folders };
  }

  // ---------------- talking to a Pal ----------------

  /**
   * pals.send: the owner's words, as typed. One asleep is woken first (what
   * comes meanwhile goes in after, in order). A retried send (same
   * clientMsgId) goes in once.
   */
  async send(id: string, text: string, clientMsgId?: string, attachments: Attachment[] = []): Promise<{ id: string; seq: number }> {
    const pal = this.mustGet(id);
    const cid = clientMsgId ? String(clientMsgId).slice(0, 100) : undefined;
    const seen = cid ? this.sent.get(pal.id)?.get(cid) : undefined;
    if (seen) return seen;
    const wasStopped = pal.rec.stoppedFor;
    this.wakingFor(pal, "owner");
    const msg = await pal.send(String(text ?? ""), { ...(cid ? { clientMsgId: cid } : {}), ...(attachments.length ? { attachments } : {}) }).catch((e) => {
      this.waking.delete(pal.id);
      throw e;
    });
    this.balanceSoon();
    if (wasStopped) this.d.audit.log("pal.resumed", { pal: pal.id, name: pal.rec.name, why: "owner" });
    const out = { id: msg.id, seq: msg.seq };
    if (cid) {
      let m = this.sent.get(pal.id);
      if (!m) this.sent.set(pal.id, (m = new Map()));
      m.set(cid, out);
      if (m.size > 200) m.delete(m.keys().next().value!);
    }
    this.d.audit.log("pal.send", { pal: pal.id, name: pal.rec.name, chars: msg.text.length, ...(attachments.length ? { attachments: attachments.length } : {}) });
    return out;
  }

  // ---------------- 回到这里重来 (docs/rewind-prd.md) ----------------

  /** pals.rewind {check}: whether its files can go back to how they were before that message. */
  canRestoreFiles(id: string, messageId: string): { canRestoreFiles: boolean } {
    return { canRestoreFiles: this.mustGet(id).canRestoreFiles(String(messageId ?? "")) };
  }

  /**
   * pals.rewind: its conversation goes back to just before one of the
   * owner's messages (a new session forked from the old one, which keeps
   * everything), and its files too when asked. The app drops that message
   * and the ones after it (`chat.rewound`) and gets its words back.
   */
  async rewind(id: string, messageId: string, o: { restoreFiles?: boolean; by: string }): Promise<{ text: string; filesRestored: boolean }> {
    const pal = this.mustGet(id);
    const r = await pal.rewind(String(messageId ?? ""), !!o.restoreFiles);
    this.d.bus.emit("chat.rewound", { id: messageId, ids: r.dropped, pal: pal.id });
    this.d.audit.log("pal.rewind", { pal: pal.id, name: pal.rec.name, messageId, from: r.from, to: pal.rec.sessionId, at: r.at, dropped: r.dropped.length, files: r.filesRestored, ...(r.copied ? { copied: true } : {}), by: o.by });
    this.log(`${pal.rec.name} went back to before ${messageId} (${r.dropped.length} message(s) out${r.filesRestored ? ", files restored" : ""})`);
    this.emitNow();
    this.balanceSoon();
    return { text: r.text, filesRestored: r.filesRestored };
  }

  /** pals.stop: ends the current turn. */
  async stopTurn(id: string, by: string): Promise<void> {
    const pal = this.mustGet(id);
    await pal.interrupt(by);
    this.d.audit.log("pal.stop", { pal: pal.id, name: pal.rec.name, by });
  }

  /**
   * pals.history: its conversation from its transcript, a page at a time; the
   * newest page also has the reply being written right now (`streaming`,
   * whose later chat.delta events append to it).
   */
  async history(id: string, before?: string | number, limit = 50): Promise<{ messages: ChatMessage[]; streaming?: { id: string; text: string } }> {
    const pal = this.mustGet(id);
    const read = this.d.readMessages ?? ((sid: string, dir: string) => getSessionMessages(sid, { dir }) as Promise<RawSessionMessage[]>);
    let raw: RawSessionMessage[] = [];
    // Gone back to an earlier message and not spoken to since: the old
    // session's conversation up to where it was cut (docs/rewind-prd.md §4.3).
    const pending = pal.pendingRewind();
    try {
      raw = pending ? pal.conversationEntries().chain : await read(pal.rec.sessionId, pal.rec.cwd);
    } catch {
      raw = []; // a new Pal's transcript isn't there before its first message
    }
    const all = toPalMessages(raw, { pal: pal.id, ...this.mapOptions(pal.rec) });
    const messages = pagePalMessages(all, before, Math.max(1, Math.min(Number(limit) || 50, 200)));
    const streaming = before === undefined ? pal.streaming() : null;
    return { messages, ...(streaming ? { streaming } : {}) };
  }

  // 「X 在等你」: at most once per Pal every 10 minutes.
  private pushWaiting(pal: PalSession, body: string, ids: { approvalId?: string; questionId?: string }): void {
    const now = this.now();
    if (now - (this.lastPush.get(pal.id) ?? 0) < PUSH_EVERY_MS) return;
    this.lastPush.set(pal.id, now);
    const msg: ChatMessage = {
      seq: 0,
      id: newId("m_"),
      role: "assistant",
      kind: ids.questionId ? "question" : "approval",
      text: body,
      channel: "system",
      ts: now,
      pal: pal.id,
      ...(ids.approvalId ? { approvalId: ids.approvalId } : {}),
      ...(ids.questionId ? { questionId: ids.questionId } : {}),
    };
    void this.d.router.proactive(msg, { title: t("pals.waitingTitle", { name: this.shownName(pal) }) }).catch(() => {});
  }

  // ---------------- spending (shown in a Pal's details; no limit) ----------------

  private today(): string {
    return zonedParts(this.now(), this.d.settings().timezone).dateKey;
  }

  spentToday(pal: PalSession): number {
    const tz = this.d.settings().timezone;
    return this.meter.spentOn(pal.rec.cwd, pal.rec.sessionId, this.today(), tz);
  }

  // ---------------- the assistant opens a Pal (docs/pals-prd.md §6) ----------------

  private checkProposal(p: { name: string; cwd: string; duty: string }): void {
    if (!p.name.trim()) throw new Error(t("pals.needName"));
    if ([...p.name].length > 30) throw new Error(t("pals.palNameLong"));
    if (!p.duty.trim()) throw new Error(t("pals.needDuty"));
    let dir = false;
    try {
      dir = statSync(p.cwd).isDirectory();
    } catch {
      dir = false;
    }
    if (!dir) throw new Error(t("pals.dirNotFound", { cwd: p.cwd }));
    if (within(this.d.paths.root, p.cwd)) throw new Error(t("pals.ownDir"));
    const same = this.get(p.name);
    if (same && same.rec.name.toLowerCase() === p.name.trim().toLowerCase()) throw new Error(t("pals.nameTaken", { name: p.name }));
    if (p.name.trim().toLowerCase() === this.paloName().toLowerCase()) throw new Error(t("pals.nameIsAssistant", { name: p.name }));
  }

  /** pal_propose: a card in the conversation; the Pal starts on the owner's 开吧. */
  propose(a: { name: string; dir: string; duty: string }): string {
    const dir = String(a.dir ?? "").trim();
    if (!dir) return t("pals.noDir");
    let cwd = resolve(expandHome(dir));
    try {
      cwd = realpathSync(cwd); // as Claude Code records it (/tmp → /private/tmp)
    } catch {
      /* checked below */
    }
    const p = { name: String(a.name ?? "").trim(), cwd, duty: String(a.duty ?? "").trim() };
    try {
      this.checkProposal(p);
    } catch (e) {
      return t("pals.notProposed", { why: e instanceof Error ? e.message : String(e) });
    }
    const full = this.full();
    if (full) return full;
    const proposal: HelperProposal = { id: newId("hp_"), ...p, status: "pending" };
    const where = tildePath(p.cwd);
    const msg = this.d.chat.add({ role: "assistant", kind: "helper", text: t("pals.proposalText", { name: p.name, where }), channel: "system", proposal });
    this.data.proposals = [...this.data.proposals, { ...proposal, createdAt: this.now(), messageId: msg.id }].slice(-50);
    this.save();
    this.d.audit.log("pal.proposed", { id: proposal.id, name: p.name, cwd: p.cwd });
    return t("pals.proposalShown", { id: proposal.id });
  }

  private settleProposal(id: string, patch: Partial<HelperProposal>): void {
    const p = this.data.proposals.find((x) => x.id === id);
    if (!p) return;
    Object.assign(p, patch);
    for (const k of Object.keys(patch) as (keyof HelperProposal)[]) if (patch[k] === undefined) delete (p as any)[k];
    this.save();
    if (!p.messageId) return;
    const { createdAt: _c, messageId: _m, ...proposal } = p;
    this.d.chat.update(p.messageId, { proposal });
  }

  /** helper.decide: 开吧 opens the Pal (and returns it), 不用 drops the proposal. A pal_adopt card: 接管 / 不用. */
  async decide(proposalId: string, action: string, by: string): Promise<{ pal?: Pal }> {
    const card = this.data.adoptions.find((x) => x.id === proposalId);
    if (card) return this.decideAdopt(card, action, by);
    const p = this.data.proposals.find((x) => x.id === proposalId);
    if (!p) throw new Error(t("pals.proposalGone"));
    if (p.status !== "pending") {
      const pal = p.palId ? this.pals.get(p.palId) : undefined;
      return pal ? { pal: pal.toWire() } : {};
    }
    if (action === "discard") {
      this.settleProposal(p.id, { status: "discarded" });
      this.d.audit.log("pal.proposal_discarded", { id: p.id, by });
      return {};
    }
    if (action !== "create") throw new Error(t("pals.unknownAction"));
    let pal: PalSession;
    try {
      this.room();
      this.checkProposal(p);
      pal = await this.create({ name: p.name, cwd: p.cwd, duty: p.duty });
    } catch (e) {
      // Still on offer; the card says why it didn't start.
      const why = e instanceof Error ? e.message : String(e);
      this.settleProposal(p.id, { note: why });
      this.d.audit.log("pal.create_failed", { id: p.id, why, by });
      throw e;
    }
    this.settleProposal(p.id, { status: "created", sessionId: pal.rec.sessionId, palId: pal.id, note: undefined });
    this.d.audit.log("pal.created", { id: p.id, pal: pal.id, session: pal.rec.sessionId, name: pal.rec.name, by });
    return { pal: pal.toWire() };
  }

  // A new session in its folder, the assistant's handover as its first message.
  private async create(o: { name: string; cwd: string; duty: string }): Promise<PalSession> {
    const now = this.now();
    const model = this.d.palModel?.();
    const rec: PalRecord = {
      id: newId("pal_"),
      sessionId: crypto.randomUUID(),
      name: o.name.trim(),
      cwd: o.cwd,
      createdBy: "palo",
      createdAt: now,
      lastUsedAt: now,
      permissionMode: this.d.palMode?.() ?? ownerMode(this.d.claudeDir),
      duty: o.duty,
      ...(model ? { model } : {}),
    };
    const pal = this.add(rec);
    try {
      await pal.start();
      await pal.send(o.duty, { from: this.assistantName() });
    } catch (e) {
      await pal.shutdown();
      this.drop(pal);
      this.emitSoon();
      throw e;
    }
    this.emitNow();
    this.balanceSoon();
    return pal;
  }

  // ---------------- the assistant proposes taking over an ended one (§10) ----------------

  /** pal_adopt: a card 「接管『标题』（目录）」; the conversation is taken over on the owner's 接管. */
  async proposeAdopt(a: { sessionId: string }): Promise<string> {
    const key = String(a?.sessionId ?? "").trim();
    if (!key) return t("pals.needSessionId");
    const sid = await this.recentList.fullId(key);
    const pal = this.get(sid);
    if (pal && pal.rec.sessionId === sid) return t("pals.alreadyPal", { name: pal.rec.name });
    if (this.takenIds().has(sid))
      return t("pals.stillOpen");
    const found = await this.recentList.find(sid);
    if (typeof found === "string") return t("pals.notProposed", { why: found });
    const open = this.data.adoptions.find((p) => p.sessionId === sid && p.status === "pending");
    if (open) return t("pals.cardWaiting", { id: open.id });
    const full = this.full();
    if (full) return full;
    const proposal: PalAdoptProposal = { id: newId("pa_"), sessionId: sid, cwd: found.cwd, title: found.title, status: "pending" };
    const where = tildePath(found.cwd);
    const msg = this.d.chat.add({ role: "assistant", kind: "pal_adopt", text: t("pals.adoptText", { title: found.title, where }), channel: "system", proposal });
    this.data.adoptions = [...this.data.adoptions, { ...proposal, createdAt: this.now(), messageId: msg.id }].slice(-50);
    this.save();
    this.d.audit.log("pal.adopt_proposed", { id: proposal.id, session: sid, cwd: found.cwd });
    return t("pals.adoptShown", { id: proposal.id, title: found.title, where });
  }

  private settleAdopt(id: string, patch: Partial<PalAdoptProposal>): void {
    const p = this.data.adoptions.find((x) => x.id === id);
    if (!p) return;
    Object.assign(p, patch);
    for (const k of Object.keys(patch) as (keyof PalAdoptProposal)[]) if (patch[k] === undefined) delete (p as any)[k];
    this.save();
    if (!p.messageId) return;
    const { createdAt: _c, messageId: _m, ...proposal } = p;
    this.d.chat.update(p.messageId, { proposal });
  }

  // 接管 takes it over (and returns the Pal); 不用 drops the card. One that
  // couldn't be taken over says why on the card (failed, with a note) and
  // can be tapped again; one taken over gives its Pal again.
  private async decideAdopt(card: PalFile["adoptions"][number], action: string, by: string): Promise<{ pal?: Pal }> {
    if (card.status === "adopted" || card.status === "discarded") {
      const pal = card.palId ? this.pals.get(card.palId) : undefined;
      return pal ? { pal: pal.toWire() } : {};
    }
    if (action === "discard") {
      this.settleAdopt(card.id, { status: "discarded", note: undefined });
      this.d.audit.log("pal.adopt_discarded", { id: card.id, session: card.sessionId, by });
      return {};
    }
    if (action !== "create") throw new Error(t("pals.unknownAction"));
    try {
      const r = await this.adopt(card.sessionId, by, { wait: false });
      if (!("pal" in r)) throw new Error(t("pals.inTerminal"));
      this.settleAdopt(card.id, { status: "adopted", palId: r.pal.id, note: undefined });
      this.d.audit.log("pal.adopt_accepted", { id: card.id, pal: r.pal.id, session: card.sessionId, by });
      return { pal: r.pal };
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      this.settleAdopt(card.id, { status: "failed", note: why });
      this.d.audit.log("pal.adopt_failed", { id: card.id, session: card.sessionId, why, by });
      return {};
    }
  }

  // ---------------- the assistant's tools ----------------

  /** pals_recent: the ended conversations, for the assistant to pick from (or ask the owner). */
  async toolRecent(a: { folder?: string } = {}): Promise<string> {
    const all = await this.recentEntries({ folder: a?.folder });
    const tz = this.d.settings().timezone;
    const when = (ms: number) => {
      const p = zonedParts(ms, tz);
      return `${p.dateKey} ${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
    };
    const shown = all.slice(0, 30);
    return JSON.stringify({
      sessions: shown.map((e) => ({ sessionId: e.sessionId, dir: tildePath(e.cwd), title: e.title, lastActive: when(e.lastModified) })),
      ...(all.length > shown.length ? { more: all.length - shown.length } : {}),
      ...(all.length ? {} : { note: a?.folder ? t("pals.noRecentHere") : t("pals.noRecent") }),
    });
  }

  /**
   * pal_send: the assistant's words to a Pal by name, asleep or awake (one
   * asleep is woken first). They go in as the handover does, shown as the
   * assistant's (「Palo 说」), and the Pal reads them as a SendMessage from
   * the assistant's session, which it answers there.
   */
  async toolSend(a: { name: string; text: string }): Promise<string> {
    const name = String(a?.name ?? "").trim();
    const text = String(a?.text ?? "").trim();
    if (!name) return t("pals.sendNeedName");
    if (!text) return t("pals.sendNeedText");
    const pal = this.get(name);
    if (!pal) return t("pals.sendNoPal", { name });
    const wasAsleep = this.wakingFor(pal, "assistant");
    try {
      await pal.send(text, { from: this.assistantName(), peer: this.paloName() });
    } catch (e) {
      this.waking.delete(pal.id);
      return t("pals.sendFailed", { name: pal.rec.name, why: e instanceof Error ? e.message : String(e) });
    }
    this.balanceSoon();
    this.d.audit.log("pal.send", { pal: pal.id, name: pal.rec.name, chars: text.length, by: "assistant" });
    return t("pals.sendOk", { name: pal.rec.name, woke: wasAsleep ? t("pals.sendWoke") : "" });
  }

  /**
   * palo_send, a Pal's words to the assistant (§16): the host puts them into
   * the assistant's session as a message from that Pal, the way a SendMessage
   * reads, so it never depends on Claude Code's session registry (a restart
   * leaves it stale). They queue like any inbound message: behind a running turn.
   */
  toolPaloSend(pal: PalSession, text: string): string {
    const body = String(text ?? "").trim();
    const to = this.assistantName();
    if (!body) return t("pals.paloSendEmpty");
    if (!this.d.toAssistant) return t("pals.paloSendFailed", { name: to, why: t("pals.paloSendNoLink") });
    try {
      this.d.toAssistant(pal.rec.name, peerWrap(pal.rec.name, body));
    } catch (e) {
      return t("pals.paloSendFailed", { name: to, why: e instanceof Error ? e.message : String(e) });
    }
    this.d.audit.log("pal.palo_send", { pal: pal.id, name: pal.rec.name, chars: body.length });
    return t("pals.paloSendOk", { name: to });
  }

  async toolList(): Promise<string> {
    const others = await this.d.sessions.listFresh().catch(() => this.d.sessions.list());
    return JSON.stringify({
      pals: this.list().map((p) => ({
        id: p.id, // pal_send takes it, or the name
        name: p.name, // its name now (it can change: the owner or Claude Code renames it)
        dir: p.cwd,
        status: p.status,
        ...(p.lastLine ? { lastLine: p.lastLine } : {}),
        ...(p.note ? { note: p.note } : {}),
        openedBy: p.createdBy === "palo" ? t("pals.openedByPalo") : t("pals.openedByOwner"),
      })),
      otherSessions: others.map((s) => ({ name: s.name, kind: s.kind === "terminal" ? t("pals.kindTerminal") : t("pals.kindBackground"), status: s.status, dir: s.cwd, ...(s.lastLine ? { lastLine: s.lastLine } : {}) })),
    });
  }
}
