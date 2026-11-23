// A session's harness process: starting it, knowing whether it's up,
// bringing it back when it ends by itself, putting it to sleep and ending it
// (docs/harness-adapter-design.md §1.1 rows 2, 17, 18; step 12). The
// assistant and every agent have one; what differs is said by flags:
//
//  - startMode "lazy-sync" (the assistant): ensure() starts the process
//    synchronously and words go in at once (the SDK holds them until it's up);
//    "awaited" (an agent): start() resolves once the harness says it's ready,
//    with a timeout and one more try when PaloAlly Helper failed.
//  - restart "on-demand" (the assistant): a process that died is started again
//    by the next words; "backoff" (an agent): it comes back by itself after
//    each delay in turn and stays stopped after five ends in ten minutes.
//  - exclusive (an agent): never two writers on one transcript; a process of
//    its own the host lost track of is stopped, anyone else's means it waits.
//  - canSleep (an agent): sleep() ends its process and marks it asleep.
//
// What the process is started with, and what the session does when it comes
// up or goes down, are the session's (open, onUp, onDown).
import { t as tr } from "../i18n/index.ts";
import { firstLine } from "../ccSessions.ts";
import type { MainSession, Spawner } from "../harness/types.ts";
import { type PalLaunch, isHelperFailure, makeSpawner } from "../palLauncher.ts";
import { sleep } from "../util.ts";

export interface ProcessFlags {
  startMode: "lazy-sync" | "awaited";
  restart: "on-demand" | "backoff";
  exclusive: boolean;
  canSleep: boolean;
}

/** Another process holding a session's transcript. */
export interface Holder {
  pid: number;
  bg: boolean; // Claude Code's background service runs it
  shortId?: string;
}

export class HeldElsewhere extends Error {}

/** What of the process is kept with the session's record. */
export interface ProcessRecord {
  pid?: number; // the harness' pid while the host runs it (an orphan after the host died)
  stoppedFor?: "failed" | "elsewhere";
  note?: string; // why it's stopped
  status?: "asleep"; // put to sleep: no process until it's woken; absent = awake
}

/** What the host hands the session to start its process with. */
export interface OpenContext {
  /** Starts the harness through the launcher, its pid kept (awaited mode). */
  spawn?: Spawner;
  /** The environment it starts from (the launcher's). */
  baseEnv?: Record<string, string>;
  /** The process ended by itself. */
  onExit: (err?: string) => void;
  stderr: (s: string) => void;
}

export interface ProcessHostDeps {
  /** Its name, for the log. */
  name: () => string;
  save: () => void;
  changed: () => void;
  log: (s: string) => void;
  now: () => number;
  /** Starts the process (the session's options); `how` goes in the log line ("resumed", "forked"). */
  open: (ctx: OpenContext) => { proc: MainSession; how?: string };
  /** It came up (awaited mode); `woke`: it was asleep. */
  onUp?: (o: { woke: boolean }) => void;
  /** It went down (ended by itself, or being ended): what was going on with it ends. */
  onDown?: (why: string, o: { closing: boolean }) => void;
  /** It stopped by itself for good (couldn't start again, or opened elsewhere). */
  onStopped?: () => void;
  // lazy-sync mode (awaited: the host starts its process itself, so it has the pid)
  /** Its process' pid, as far as the host can tell. */
  pid?: () => number | undefined;
  /** Ends a process that froze, whatever it takes. */
  killFrozen?: (pid: number | undefined) => Promise<void>;
  // awaited mode
  /** Live processes holding its session, other than `own` (exclusive). */
  holders?: (own?: number) => Promise<Holder[]>;
  /** What it says when another process holds its session. */
  heldMessage?: (pids: number[]) => string;
  /** Right before its process starts. */
  beforeStart?: () => Promise<void>;
  launch?: () => Promise<PalLaunch>;
  helperFailed?: (why: string) => void;
  /** A refusal to start, in plain words. */
  startError: (why: string) => string;
  pidAlive?: (pid: number) => boolean;
  kill?: (pid: number, signal: NodeJS.Signals) => void;
  timing?: { readyMs: number; restartMs: number[]; exitWaitMs: number };
}

const MAX_FAILURES = 5; // restarts within FAILURE_WINDOW_MS before it stays stopped
const FAILURE_WINDOW_MS = 10 * 60_000;

export class ProcessHost {
  private p: MainSession | null = null;
  private isUp = false; // the process answered and is ours to talk to
  private startingP: Promise<void> | null = null;
  private restartTimer: ReturnType<typeof setTimeout> | null = null;
  private isQueued = false; // the host will start it in a moment (its own start)
  private isClosing = false;
  private exited: Promise<void> = Promise.resolve();
  private stderrTail = "";
  private failures: number[] = [];
  private sleepingP: Promise<void> | null = null; // being put to sleep: its process is ending
  private upAtMs = 0;

  constructor(
    readonly flags: ProcessFlags,
    private rec: ProcessRecord,
    private d: ProcessHostDeps,
  ) {}

  /** The process, if there is one (closed or not). */
  get proc(): MainSession | null {
    return this.p;
  }

  /** Up and ours to talk to. */
  get up(): boolean {
    return this.isUp;
  }

  get starting(): Promise<void> | null {
    return this.startingP;
  }

  /** A restart after it ended by itself is on its way. */
  get restarting(): boolean {
    return !!this.restartTimer;
  }

  get queued(): boolean {
    return this.isQueued;
  }

  /** Being ended (or ended) on purpose. */
  get closing(): boolean {
    return this.isClosing;
  }

  get sleeping(): Promise<void> | null {
    return this.sleepingP;
  }

  get upAt(): number {
    return this.upAtMs;
  }

  /** The harness' pid while it runs. */
  get pid(): number | undefined {
    if (this.flags.startMode === "lazy-sync") return this.d.pid?.();
    return this.isUp || this.startingP ? this.rec.pid : undefined;
  }

  /** A process that hasn't ended. */
  get alive(): boolean {
    return !!this.p && !this.p.closed;
  }

  get running(): boolean {
    return this.flags.startMode === "lazy-sync" ? this.alive : this.isUp && this.alive;
  }

  /** Its process froze: ended, killed if it must be. Nothing of it writes the transcript once this resolves. */
  async endFrozen(): Promise<void> {
    if (this.flags.startMode === "awaited") return this.shutdown();
    const pid = this.pid;
    const p = this.p;
    this.p = null;
    p?.close();
    await this.d.killFrozen?.(pid);
  }

  // ---------------- lazy-sync: started by the words that need it ----------------

  /** The process, started now if there's none (the words go in at once: the harness holds them until it's up). */
  ensure(): MainSession {
    if (this.p && !this.p.closed) return this.p;
    this.p = this.d.open({ onExit: () => {}, stderr: () => {} }).proc;
    return this.p;
  }

  /** Ends the process now; the next words start another (on-demand). */
  close(): void {
    this.p?.close();
    this.p = null;
  }

  // ---------------- awaited: start, ready, holders, backoff ----------------

  /** The host starts it shortly (at its own start, a few seconds apart): it shows as starting. */
  queueStart(): void {
    this.isQueued = true;
  }

  /** Starts (or resumes) its process; resolves once the harness is up. */
  start(): Promise<void> {
    // Being put to sleep: once its process is gone, it's woken.
    if (this.sleepingP) return this.sleepingP.then(() => this.start());
    this.isQueued = false;
    if (this.running) return Promise.resolve();
    if (this.startingP) return this.startingP;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = null;
    this.isClosing = false;
    this.startingP = this.doStart().finally(() => {
      this.startingP = null;
      this.d.changed();
    });
    this.d.changed();
    return this.startingP;
  }

  private async doStart(retry = false): Promise<void> {
    const { rec } = this;
    if (this.flags.exclusive && this.d.holders) {
      // Never two writers: a process of ours the host lost track of (it died
      // and left the harness running) is stopped; anyone else's means wait.
      let holders = await this.d.holders();
      const orphans = holders.filter((h) => h.pid === rec.pid);
      for (const o of orphans) {
        this.d.log(`pal ${this.d.name()}: stopping its old process ${o.pid}`);
        await this.killPid(o.pid);
      }
      if (orphans.length) holders = await this.d.holders();
      if (holders.length) throw new HeldElsewhere(this.d.heldMessage?.(holders.map((h) => h.pid)) ?? "held elsewhere");
    }
    if (this.isClosing) throw new Error(tr("pals.closed"));
    // Renamed while it had no process (in a terminal, say): it starts under that name.
    await this.d.beforeStart?.().catch(() => {});

    const launch: { helper: string | null; env?: Record<string, string> } = this.d.launch ? await this.d.launch() : { helper: null };
    let exitDone!: () => void;
    const exited = new Promise<void>((r) => (exitDone = r));
    this.exited = Promise.resolve(); // nothing to wait for until a process is started
    this.stderrTail = "";
    rec.pid = undefined;
    const spawner = makeSpawner(launch.helper, {
      onPid: (pid) => {
        rec.pid = pid;
        this.d.save();
      },
      onExit: () => exitDone(),
      stderr: (s) => (this.stderrTail = (this.stderrTail + s).slice(-2000)),
    });
    const spawn: typeof spawner = (req) => {
      this.exited = exited;
      return spawner(req);
    };
    let proc!: MainSession;
    const opened = this.d.open({
      spawn,
      baseEnv: launch.env,
      onExit: (err) => this.onExit(proc, err),
      stderr: (s) => (this.stderrTail = (this.stderrTail + s).slice(-2000)),
    });
    proc = opened.proc;
    this.p = proc;
    this.isUp = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        proc.ready(),
        new Promise<never>((_, rej) => (timer = setTimeout(() => rej(new Error(tr("pals.startTimeout"))), this.timing.readyMs))),
      ]);
    } catch (e) {
      clearTimeout(timer);
      this.p = null;
      proc.close();
      await this.waitExit();
      const why = `${e instanceof Error ? e.message : e}\n${this.stderrTail}`;
      if (launch.helper && !retry && isHelperFailure(why)) {
        this.d.helperFailed?.(firstLine(why.slice(why.indexOf("PaloAlly Helper:"))));
        return this.doStart(true);
      }
      throw new Error(this.d.startError(why));
    }
    clearTimeout(timer);
    if (this.isClosing || proc !== this.p) {
      proc.close();
      throw new Error(tr("pals.closed"));
    }
    this.isUp = true;
    this.upAtMs = this.d.now();
    const woke = rec.status === "asleep";
    if (woke) {
      delete rec.status;
      this.d.save();
    }
    this.d.onUp?.({ woke });
    this.d.log(
      `pal ${this.d.name()}: up (pid ${rec.pid ?? "?"}, ${launch.helper ? "through PaloAlly Helper" : "direct"}${opened.how ? `, ${opened.how}` : ""}${woke ? ", woken" : ""})`,
    );
  }

  private get timing(): { readyMs: number; restartMs: number[]; exitWaitMs: number } {
    return this.d.timing ?? { readyMs: 45_000, restartMs: [2_000], exitWaitMs: 6_000 };
  }

  private async waitExit(): Promise<void> {
    await Promise.race([this.exited, sleep(this.timing.exitWaitMs)]);
    const pid = this.rec.pid;
    if (pid && this.d.pidAlive?.(pid)) await this.killPid(pid);
  }

  /** Ends a process by its pid: asked first, then killed. */
  async killPid(pid: number): Promise<void> {
    const kill = this.d.kill ?? ((p: number, s: NodeJS.Signals) => process.kill(p, s));
    const alive = this.d.pidAlive ?? (() => false);
    try {
      kill(pid, "SIGTERM");
    } catch {
      return;
    }
    for (let i = 0; i < 30 && alive(pid); i++) await sleep(100);
    if (alive(pid)) {
      try {
        kill(pid, "SIGKILL");
      } catch {
        /* gone */
      }
      for (let i = 0; i < 20 && alive(pid); i++) await sleep(100);
    }
  }

  // Its process ended without being asked to: back it comes (backoff),
  // unless it keeps failing.
  private onExit(proc: MainSession, err?: string): void {
    if (proc !== this.p || this.isClosing || !this.isUp) return;
    this.d.log(`pal ${this.d.name()}: its process ended (${err ?? "no error"})`);
    this.down(tr("pals.diedUnexpected"));
    if (this.flags.restart !== "backoff") return this.d.changed();
    const now = this.d.now();
    this.failures = [...this.failures.filter((t) => now - t < FAILURE_WINDOW_MS), now];
    if (this.failures.length > MAX_FAILURES) {
      this.stopFor("failed", tr("pals.failedRepeatedly", { n: MAX_FAILURES, why: this.d.startError(err ?? this.stderrTail) }));
      return;
    }
    const delays = this.timing.restartMs;
    const delay = delays[Math.min(this.failures.length - 1, delays.length - 1)] ?? 2_000;
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start().catch((e) => {
        if (e instanceof HeldElsewhere) this.stopFor("elsewhere", e.message);
        else this.onExitRetry(e);
      });
    }, delay);
    this.d.changed();
  }

  private onExitRetry(e: unknown): void {
    // Counted like an exit: try again later, give up after a few.
    const now = this.d.now();
    this.failures = [...this.failures.filter((t) => now - t < FAILURE_WINDOW_MS), now];
    if (this.failures.length > MAX_FAILURES) return this.stopFor("failed", this.d.startError(e instanceof Error ? e.message : String(e)));
    const delays = this.timing.restartMs;
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start().catch((err) => (err instanceof HeldElsewhere ? this.stopFor("elsewhere", err.message) : this.onExitRetry(err)));
    }, delays[Math.min(this.failures.length - 1, delays.length - 1)] ?? 2_000);
    this.d.changed();
  }

  // Not running any more: the session closes what was going on.
  private down(why: string): void {
    this.isUp = false;
    this.p = null;
    this.d.onDown?.(why, { closing: this.isClosing });
  }

  /** Stopped for good, with a reason the list shows; the owner's words bring it back. */
  stopFor(why: NonNullable<ProcessRecord["stoppedFor"]>, note: string): void {
    this.rec.stoppedFor = why;
    this.rec.note = note;
    this.d.save();
    void this.shutdown().then(() => {
      this.d.changed();
      this.d.onStopped?.();
    });
  }

  /** Stopped without a process to end (it never came up). */
  markStopped(why: NonNullable<ProcessRecord["stoppedFor"]>, note: string): void {
    this.rec.stoppedFor = why;
    this.rec.note = note;
    this.d.save();
    this.d.changed();
  }

  /** Clears a stop (the owner spoke to it, or a new day for its spending). */
  clearStop(): void {
    if (!this.rec.stoppedFor) return;
    this.rec.stoppedFor = undefined;
    this.rec.note = undefined;
    this.failures = [];
    this.d.save();
  }

  /** Puts it to sleep: its process ends cleanly, its record stays, marked asleep; the next start wakes it. */
  sleep(): Promise<void> {
    if (!this.flags.canSleep) return Promise.reject(new Error("this session doesn't sleep"));
    if (this.sleepingP) return this.sleepingP;
    this.rec.status = "asleep";
    this.d.save();
    this.sleepingP = this.shutdown().finally(() => {
      this.sleepingP = null;
      this.d.changed();
    });
    this.d.changed();
    return this.sleepingP;
  }

  /** Marked asleep without a process to end (the host's start, past five awake). */
  markAsleep(): void {
    this.rec.status = "asleep";
    this.d.save();
  }

  /** Ends its process and waits until it's really gone (nothing writes its transcript after this). */
  async shutdown(): Promise<void> {
    this.isClosing = true;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = null;
    const starting = this.startingP;
    const proc = this.p;
    this.down(tr("pals.shutDown"));
    proc?.close();
    if (starting) await starting.catch(() => {});
    await this.waitExit();
    this.rec.pid = undefined;
    this.d.save();
  }
}
