import { forkSession as sdkForkSession, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
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
import type { HarnessDriver } from "./harness/types.ts";
import type { MediaStore } from "./media.ts";
import { PalLauncher, type PalLaunch } from "./palLauncher.ts";
import { pagePalMessages, toPalMessages } from "./palHistory.ts";
import type { ForkSession } from "./rewind.ts";
import { RECENT_MAX, type RecentEntry, RecentSessions, type RecentSource, folderMatch, ownRoots, palNameFor, palTitle, recentWire, sdkRename, sdkSource } from "./palRecent.ts";
import { HeldElsewhere, type Holder, type PalRecord, PalSession } from "./palSession.ts";
import type { QuestionManager } from "./questions.ts";
import type { Router } from "./router.ts";
import type { Sessions } from "./sessions.ts";
import type { StallTarget } from "./stallWatch.ts";
import type { Attachment, ChatMessage, HelperProposal, Pal, PalAdoptProposal, RecentSession } from "./types.ts";
import { newId, readJson, writeJson, zonedParts } from "./util.ts";

// Pals (docs/pals-prd.md): Claude Code sessions the host runs itself. The
// owner adopts one of the computer's sessions (a background one is stopped
// first; one in a terminal is taken over once the owner quits it there), or
// the assistant opens a new one on the owner's 开吧. Each stays up with a
// fixed name the assistant reaches it by (SendMessage), comes back after a
// crash or a restart of the Mac, and goes back to the terminal on 交还终端.
// One transcript is never written by two processes.
// No practical limit on how many (§12; 50, against mistakes), but at most
// five awake: one idle 20 minutes is put to sleep (its process ends, its
// record stays), and past five awake the least recently used idle one goes
// first. Busy or waiting ones are never put to sleep (past five for a while,
// then). The owner's words, 叫醒, a card of its answered or the assistant's
// pal_send wake it: the same session resumes and the words go in, in order.
// Its name follows Claude Code's title for the session (§13): read back
// after each turn and before each start, and pals.rename retitles it there.
// The assistant reaches it by id or any of its names (pal_send).
// A conversation that ended on the computer lately can be taken over too
// (§10): listed by pals.recent, resumed directly by pals.adopt, or proposed
// by the assistant on a card the owner answers.

/** How many Pals at most (a safety limit, §12). */
export const MAX_PALS = 50;
/** How many awake (with a process) at once, before idle ones are put to sleep. */
export const MAX_AWAKE = 5;
/** The assistant's own session name: Pals see its SendMessages as from it, and answer it there. */
export const PALO_NAME = "Palo";
const PUSH_EVERY_MS = 10 * 60_000;

/** A folder as the owner says it: ~/… under the home folder. */
function tildePath(p: string): string {
  const home = homedir();
  return p === home ? "~" : p.startsWith(home + sep) ? `~/${p.slice(home.length + 1)}` : p;
}

// What a Pal is told about where it runs, on top of Claude Code's own prompt.
export const PAL_PROMPT = (paloName: string) =>
  `你现在由 PaloAlly 托管：主人在手机上的 PaloAlly App 里看这段对话、在这里打字，你要的确认和选项提问也都送到主人手机上。` +
  `名叫「${paloName}」的会话是主人的助理：它发来的消息按队友的请求对待；要回它，用 SendMessage 发给 ${paloName}。`;

interface PalFile {
  pals: PalRecord[];
  proposals: (HelperProposal & { createdAt: number; messageId?: string })[];
  // the assistant's cards proposing to take over an ended conversation (pal_adopt)
  adoptions: (PalAdoptProposal & { createdAt: number; messageId?: string })[];
  // Pals the owner took out of the list (交还终端 / 移出): listed again among the recent ones
  former: { sessionId: string; cwd: string; at: number }[];
}

/** A session to adopt: its id, the Pal's name and its folder. */
interface Adoptee {
  id: string;
  name: string;
  cwd: string;
}

export interface PalsDeps {
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
  /** The computer's ended conversations (the SDK's listSessions / getSessionInfo); also each Pal's title (§13). */
  recentSource?: RecentSource;
  /** Retitles a session that has no process (the SDK's renameSession). */
  renameSession?: (sessionId: string, title: string, dir: string) => Promise<void>;
  /** A Pal's permission mode; default: the owner's own default for Claude Code. */
  palMode?: () => string;
  /** A Pal's model; default: what its transcript last ran on (a new one: the owner's default). */
  palModel?: () => string | undefined;
  paloName?: () => string;
  registry?: () => RegistryEntry[];
  pidAlive?: (pid: number) => boolean;
  kill?: (pid: number, signal: NodeJS.Signals) => void;
  /** Copies a session up to one entry as a new one (default: the SDK's forkSession). */
  forkSession?: ForkSession;
  /** The owner's images and files (media.upload / uploadChunk), as Palo takes them. */
  media?: MediaStore;
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
  private dayTimer: ReturnType<typeof setInterval> | null = null;
  private sleepTimer: ReturnType<typeof setInterval> | null = null;
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
    this.data = { pals: list(saved.pals), proposals: list(saved.proposals), adoptions: list(saved.adoptions), former: list(saved.former) };
    this.source = d.recentSource ?? sdkSource(d.claudeDir);
    this.recentList = new RecentSessions({
      claudeDir: d.claudeDir,
      roots: () => ownRoots(d.paths.root),
      formerPals: () => this.data.former,
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
      onTurnEnd: (pal) => {
        this.checkBudget(pal);
        this.balanceSoon();
        void this.readTitle(pal);
      },
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
      now: () => this.now(),
      log: (s) => this.log(s),
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
    // Those stopped for today's spending wait for tomorrow; the rest (even
    // ones that couldn't start before) are tried again.
    let i = 0;
    const today = this.today();
    const back = [...this.pals.values()]
      .filter((p) => p.rec.status !== "asleep" && !(p.rec.stoppedFor === "budget" && p.rec.budgetDay === today))
      .sort((a, b) => b.rec.lastUsedAt - a.rec.lastUsedAt);
    for (const pal of back.slice(MAX_AWAKE)) pal.markAsleep();
    for (const pal of back.slice(0, MAX_AWAKE)) {
      pal.clearStop();
      pal.queueStart();
      const t = setTimeout(() => void this.bringBack(pal, "start"), i++ * this.timing.startStaggerMs);
      this.startTimers.push(t);
    }
    this.guardTimer = setInterval(() => this.guard(), this.timing.guardMs);
    (this.guardTimer as any).unref?.();
    this.dayTimer = setInterval(() => this.newDay(), 60_000);
    (this.dayTimer as any).unref?.();
    this.sleepTimer = setInterval(() => this.balance(), this.timing.sleepCheckMs);
    (this.sleepTimer as any).unref?.();
    this.emitSoon();
  }

  /** The host stops: every Pal's process ends (they come back at the next start). */
  stop(): void {
    this.started = false;
    this.offBus?.();
    for (const t of this.startTimers.splice(0)) clearTimeout(t);
    if (this.guardTimer) clearInterval(this.guardTimer);
    if (this.dayTimer) clearInterval(this.dayTimer);
    if (this.sleepTimer) clearInterval(this.sleepTimer);
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
      else pal.stopFor("failed", `没能接着跑：${msg}`);
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
   * Awake ones idle 20 minutes go to sleep; past five awake, the least
   * recently used idle ones too. Busy or waiting ones never: past five for a
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
    let over = awake.length - MAX_AWAKE;
    if (over <= 0) return;
    const idle = awake.filter((p) => p.idleSince() !== null).sort((a, b) => a.rec.lastUsedAt - b.rec.lastUsedAt);
    for (const p of idle) {
      if (over-- <= 0) break;
      void this.putToSleep(p, "more than five awake");
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
    if (!p) throw new Error("没有这个 Pal");
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
      pal.stopFor("elsewhere", "在别处打开了（终端或后台），这边先停下，免得两边一起写；那边退出后会自己接上");
    }
  }

  private onStopped(pal: PalSession): void {
    this.emitSoon();
    if (pal.rec.stoppedFor === "budget") return; // said already
    this.d.audit.log("pal.stopped", { pal: pal.id, name: pal.rec.name, why: pal.rec.stoppedFor, note: pal.rec.note });
  }

  // ---------------- adopting ----------------

  private oldest(): PalSession {
    return [...this.pals.values()].sort((a, b) => a.rec.lastUsedAt - b.rec.lastUsedAt)[0]!;
  }

  private room(): void {
    if (this.pals.size < MAX_PALS) return;
    throw new Error(`已经有 ${MAX_PALS} 个 Pal 了，先移出一个（最久没用的是「${this.oldest().rec.name}」）`);
  }

  // What the assistant's tools say when there's no room.
  private full(): string | null {
    if (this.pals.size < MAX_PALS) return null;
    return `已经有 ${MAX_PALS} 个 Pal 了（最多 ${MAX_PALS} 个）。先问主人要不要把最久没用的「${this.oldest().rec.name}」移出 Pals（主人在它的页面右上角点「移出 Pals」）。`;
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
    if (!want) throw new Error("名字不能是空的");
    if ([...want].length > 40) throw new Error("名字太长了（最多 40 个字）");
    if (want.toLowerCase() === this.paloName().toLowerCase()) throw new Error(`「${want}」是助理自己的名字`);
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
  }

  /**
   * pals.adopt: one of the computer's sessions becomes a Pal. A background
   * session is stopped first; a terminal session is waited for (the owner
   * quits it there) and taken over once its process is gone, unless `wait`
   * is false (then it's an error). A conversation that ended is resumed at once.
   */
  adopt(sessionId: string, by: string, o: { wait?: boolean } = {}): Promise<{ pal: Pal } | { waiting: "exit-in-terminal" }> {
    const sid = String(sessionId ?? "").trim();
    if (!sid) return Promise.reject(new Error("没有这个会话"));
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
      if (!short) throw new Error("它在后台跑着，但找不到它的编号，没法停下它");
      await this.d.cli.stop(short);
      this.d.audit.log("pal.stopped_bg", { session: sid, short, by });
      // Stopped means its process is gone, not just its entry in the lists.
      const end = this.now() + this.timing.stopWaitMs;
      const stillBg = async () => (holders = await this.holders(sid)).some((h) => h.bg) || bg.some((h) => this.alive(h.pid));
      while ((await stillBg()) && this.now() < end) await new Promise((r) => setTimeout(r, 200));
      if (await stillBg()) throw new Error("它停不下来，没有接管");
    }
    if (holders.length) {
      if (o.wait === false) throw new Error("它在终端里开着：先在终端里退出它（/exit），再接管");
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
    if (holders.length) throw new Error(`它刚在别处打开了（进程 ${holders.map((h) => h.pid).join("、")}），没有接管`);
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
          this.notice(`等了 ${Math.round(this.timing.adoptWaitMs / 60_000)} 分钟，「${session.name}」还没在终端里退出，先不接管了。要接管，退出它以后再点一次「接管」。`);
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
        this.notice(`接管「${session.name}」没成功：${why}`);
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
            throw new Error(`没能交还：${e instanceof Error ? e.message : e}`);
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
    void this.d.router.proactive(msg, { title: `${pal.rec.name} 在等你` }).catch(() => {});
  }

  // ---------------- spending (Pals the assistant opened) ----------------

  private today(): string {
    return zonedParts(this.now(), this.d.settings().timezone).dateKey;
  }

  spentToday(pal: PalSession): number {
    const tz = this.d.settings().timezone;
    return this.meter.spentOn(pal.rec.cwd, pal.rec.sessionId, this.today(), tz);
  }

  private checkBudget(pal: PalSession): void {
    const limit = pal.rec.dailyUsd;
    if (!limit || pal.rec.stoppedFor) return;
    const spent = this.spentToday(pal);
    if (spent <= limit) return;
    pal.rec.budgetDay = this.today();
    pal.stopFor("budget", `今天花了约 $${spent.toFixed(2)}，过了每天 $${limit} 的上限，明天接着跑；跟它说话也会让它接着跑`);
    this.d.audit.log("pal.budget", { pal: pal.id, name: pal.rec.name, spentUsd: Number(spent.toFixed(2)), dailyUsd: limit });
    const msg = this.d.chat.add({
      role: "assistant",
      kind: "notice",
      text: `「${pal.rec.name}」今天花了约 $${spent.toFixed(2)}，超过了每天 $${limit} 的上限，我先让它停下。明天它会接着跑；要它现在就接着做，在它的对话里跟它说一句就行。`,
      channel: "system",
      proactive: true,
    });
    void this.d.router.proactive(msg, { title: "Pal 停了" }).catch(() => {});
  }

  // A new day: Pals stopped for spending come back.
  private newDay(): void {
    const day = this.today();
    for (const pal of this.pals.values()) {
      if (pal.rec.stoppedFor !== "budget" || pal.rec.budgetDay === day) continue;
      pal.clearStop();
      void this.bringBack(pal, "new day");
    }
  }

  // ---------------- the assistant opens a Pal (docs/pals-prd.md §6) ----------------

  private checkProposal(p: { name: string; cwd: string; duty: string; dailyUsd: number }): void {
    if (!p.name.trim()) throw new Error("Pal 要有个名字");
    if ([...p.name].length > 30) throw new Error("Pal 的名字太长了");
    if (!p.duty.trim()) throw new Error("要写清楚它负责什么");
    if (!(p.dailyUsd > 0) || p.dailyUsd > 1000) throw new Error("每天的花费上限要大于 0");
    let dir = false;
    try {
      dir = statSync(p.cwd).isDirectory();
    } catch {
      dir = false;
    }
    if (!dir) throw new Error(`找不到目录 ${p.cwd}`);
    if (within(this.d.paths.root, p.cwd)) throw new Error("Pal 不能开在 PaloAlly 自己的目录里");
    const same = this.get(p.name);
    if (same && same.rec.name.toLowerCase() === p.name.trim().toLowerCase()) throw new Error(`已经有一个叫「${p.name}」的 Pal 了`);
    if (p.name.trim().toLowerCase() === this.paloName().toLowerCase()) throw new Error(`「${p.name}」是助理自己的名字`);
  }

  /** pal_propose: a card in the conversation; the Pal starts on the owner's 开吧. */
  propose(a: { name: string; dir: string; duty: string; dailyUsd: number }): string {
    const dir = String(a.dir ?? "").trim();
    if (!dir) return "没提：要给它一个项目目录";
    let cwd = resolve(expandHome(dir));
    try {
      cwd = realpathSync(cwd); // as Claude Code records it (/tmp → /private/tmp)
    } catch {
      /* checked below */
    }
    const p = { name: String(a.name ?? "").trim(), cwd, duty: String(a.duty ?? "").trim(), dailyUsd: Number(a.dailyUsd) };
    try {
      this.checkProposal(p);
    } catch (e) {
      return `没提：${e instanceof Error ? e.message : e}`;
    }
    const full = this.full();
    if (full) return full;
    const proposal: HelperProposal = { id: newId("hp_"), ...p, status: "pending" };
    const where = tildePath(p.cwd);
    const msg = this.d.chat.add({ role: "assistant", kind: "helper", text: `开一个 Pal「${p.name}」专门管 ${where}？`, channel: "system", proposal });
    this.data.proposals = [...this.data.proposals, { ...proposal, createdAt: this.now(), messageId: msg.id }].slice(-50);
    this.save();
    this.d.audit.log("pal.proposed", { id: proposal.id, name: p.name, cwd: p.cwd, dailyUsd: p.dailyUsd });
    return `已经给主人看了开 Pal 的卡片（${proposal.id}）。主人点「开吧」才会开，现在还没开，别说已经开了。`;
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
    if (!p) throw new Error("这个提议已经没有了");
    if (p.status !== "pending") {
      const pal = p.palId ? this.pals.get(p.palId) : undefined;
      return pal ? { pal: pal.toWire() } : {};
    }
    if (action === "discard") {
      this.settleProposal(p.id, { status: "discarded" });
      this.d.audit.log("pal.proposal_discarded", { id: p.id, by });
      return {};
    }
    if (action !== "create") throw new Error("看不懂这个操作");
    let pal: PalSession;
    try {
      this.room();
      this.checkProposal(p);
      pal = await this.create({ name: p.name, cwd: p.cwd, duty: p.duty, dailyUsd: p.dailyUsd });
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
  private async create(o: { name: string; cwd: string; duty: string; dailyUsd: number }): Promise<PalSession> {
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
      dailyUsd: o.dailyUsd,
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
    if (!key) return "没提：要给出这个对话的 sessionId（用 pals_recent 查）";
    const sid = await this.recentList.fullId(key);
    const pal = this.get(sid);
    if (pal && pal.rec.sessionId === sid) return `它已经是 Pal「${pal.rec.name}」了，不用再接管；给它派活用 pal_send 发给「${pal.rec.name}」。`;
    if (this.takenIds().has(sid))
      return "没提：这个对话现在还开着（在终端里或后台），不是已经退出的。要接管它，请主人在 Pals 列表里对它点「接管」。";
    const found = await this.recentList.find(sid);
    if (typeof found === "string") return `没提：${found}`;
    const open = this.data.adoptions.find((p) => p.sessionId === sid && p.status === "pending");
    if (open) return `已经有一张接管它的卡片在等主人点了（${open.id}），不用再提。`;
    const full = this.full();
    if (full) return full;
    const proposal: PalAdoptProposal = { id: newId("pa_"), sessionId: sid, cwd: found.cwd, title: found.title, status: "pending" };
    const where = tildePath(found.cwd);
    const msg = this.d.chat.add({ role: "assistant", kind: "pal_adopt", text: `接管「${found.title}」（${where}）？`, channel: "system", proposal });
    this.data.adoptions = [...this.data.adoptions, { ...proposal, createdAt: this.now(), messageId: msg.id }].slice(-50);
    this.save();
    this.d.audit.log("pal.adopt_proposed", { id: proposal.id, session: sid, cwd: found.cwd });
    return `已经给主人看了接管的卡片（${proposal.id}）：接管「${found.title}」（${where}）。主人点「接管」才会接，现在还没接，别说已经接了。`;
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
    if (action !== "create") throw new Error("看不懂这个操作");
    try {
      const r = await this.adopt(card.sessionId, by, { wait: false });
      if (!("pal" in r)) throw new Error("它在终端里开着：先在终端里退出它（/exit），再接管");
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
      ...(all.length ? {} : { note: a?.folder ? "这个目录里没有最近退出的对话" : "最近 30 天里没有退出了的对话" }),
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
    if (!name) return "没送：要给出 Pal 的名字（pals_list 里的 name）";
    if (!text) return "没送：要说的话是空的";
    const pal = this.get(name);
    if (!pal) return `没送：没有叫「${name}」的 Pal（用 pals_list 看名字）`;
    const wasAsleep = this.wakingFor(pal, "assistant");
    try {
      await pal.send(text, { from: this.assistantName(), peer: this.paloName() });
    } catch (e) {
      this.waking.delete(pal.id);
      return `没送到「${pal.rec.name}」：${e instanceof Error ? e.message : e}`;
    }
    this.balanceSoon();
    this.d.audit.log("pal.send", { pal: pal.id, name: pal.rec.name, chars: text.length, by: "assistant" });
    return `已经送到「${pal.rec.name}」${wasAsleep ? "（它刚才睡着，已经叫醒）" : ""}。它回你的话会作为消息回到你这里。`;
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
        openedBy: p.createdBy === "palo" ? "你" : "主人",
      })),
      otherSessions: others.map((s) => ({ name: s.name, kind: s.kind === "terminal" ? "终端" : "后台", status: s.status, dir: s.cwd, ...(s.lastLine ? { lastLine: s.lastLine } : {}) })),
    });
  }
}
