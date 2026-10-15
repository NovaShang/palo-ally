import type {
  HarnessDriver,
  HarnessEvent,
  ImageInput,
  MainSession,
  MainSessionOptions,
  PermissionDecision,
  ProbeRequest,
  ProbeResult,
  SessionOptions,
} from "../src/harness/types.ts";

// A scripted turn: given the user text and the session's tools/permission
// hooks, emit events. Lets tests drive the Hub deterministically, including
// tool calls that ask the owner through the real approval relay.
export type FakeScript = (text: string, ctx: FakeCtx) => Promise<void>;

export interface FakeCtx {
  opts: MainSessionOptions; // a Pal's session has no tools / prompt (cast from SessionOptions)
  session: FakeMainSession;
  // resolves when the turn is interrupted (the stop button)
  interrupted: Promise<void>;
  emit(e: HarnessEvent): void;
  // simulate the harness calling a tool. The host's gate (Claude Code: a
  // PreToolUse hook) is consulted first, for every call. `ask` = the harness
  // then decided to ask the owner (with its own suggestions / defaultToNo);
  // otherwise it just runs (auto mode, an allow rule). `run` is the tool's
  // effect: called only if the call goes through.
  useTool(
    name: string,
    input: Record<string, unknown>,
    opts?: { id?: string; parent?: string | null; ask?: boolean; defaultToNo?: boolean; suggestions?: unknown[]; reason?: string; run?: () => unknown },
  ): Promise<boolean>;
}

let idCounter = 0;
export const fakeId = (p = "toolu_") => `${p}${++idCounter}`;

export class FakeMainSession implements MainSession {
  closed = false;
  private queue: { text: string; uuid: string }[] = [];
  private busy = false;
  sent: string[] = [];
  sentImages: ImageInput[] = [];
  private total: number;
  readonly sessionId: string;
  readonly pal: boolean;
  private interruptWaiters: (() => void)[] = [];
  proc?: import("node:child_process").ChildProcess; // a stand-in process (driver.spawnPals)
  // ready() rejects with this (Claude Code refused to start), and the process ends
  readonly failStart?: string;

  constructor(readonly opts: MainSessionOptions, private script: FakeScript, private driver: FakeDriver, pal = false) {
    this.sessionId = opts.resumeSessionId ?? opts.sessionId ?? `sess-${++idCounter}`;
    this.pal = pal;
    // Resumed, Claude Code goes on from the session's running total.
    this.total = opts.resumeSessionId ? (driver.totals.get(opts.resumeSessionId) ?? 0) : 0;
    this.failStart = pal ? driver.failPalStart?.(opts) : undefined;
    if (this.failStart) {
      const why = this.failStart;
      queueMicrotask(() => {
        this.closed = true;
        opts.onEvent({ type: "error", message: why });
        opts.onExit?.(why);
      });
      return;
    }
    if (pal) {
      // A real process stands in for Claude Code, started through the
      // host's spawner (so its pid is known, as through PaloAlly Helper).
      if (driver.spawnPals && opts.spawn) {
        this.proc = opts.spawn({ command: "/bin/sleep", args: ["600"], cwd: opts.cwd, env: { PATH: process.env.PATH } }) as any;
        this.proc!.on("exit", () => {
          if (!this.closed) this.crash("Claude Code process exited");
        });
      }
      return; // a Pal says nothing until it's spoken to
    }
    queueMicrotask(() => {
      const permissionMode = driver.permissionModeFor?.(opts.permissionMode) ?? opts.permissionMode;
      opts.onEvent({ type: "init", sessionId: this.sessionId, model: opts.model ?? "fake-model", tools: [], terminalCommands: ["doctor"], permissionMode });
      opts.onEvent({
        type: "commands",
        commands: [
          { name: "compact", description: "Clear conversation history but keep a summary" },
          { name: "status", description: "harness status" },
          { name: "doctor", description: "terminal only" },
          { name: "pdf", description: "PDF skill", argumentHint: "<file>" },
        ],
      });
      opts.onEvent({
        type: "models",
        models: [
          { value: "default", displayName: "Default (recommended)", description: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"] },
          { value: "haiku", displayName: "Haiku", description: "fast", efforts: [] },
        ],
      });
    });
  }

  async ready(): Promise<void> {
    if (this.failStart) throw new Error(this.failStart);
  }

  /** The process dies by itself (not through close()). */
  crash(why = "Claude Code process exited with code 1"): void {
    if (this.closed) return;
    this.closed = true;
    this.queue = [];
    if (this.proc && this.proc.exitCode === null) this.proc.kill("SIGKILL");
    this.opts.onEvent({ type: "error", message: why });
    this.opts.onExit?.(why);
  }

  send(text: string, uuid: string, images: ImageInput[] = []): void {
    if (this.closed) throw new Error("closed");
    this.sent.push(text);
    this.sentImages.push(...images);
    this.queue.push({ text, uuid });
    void this.drain();
  }

  private async drain(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    while (this.queue.length && !this.closed) {
      const { text, uuid } = this.queue.shift()!;
      if (this.pal) this.opts.onEvent({ type: "init", sessionId: this.sessionId, model: this.opts.model ?? "fake-model", tools: [] });
      const ctx: FakeCtx = {
        opts: this.opts,
        session: this,
        interrupted: new Promise<void>((r) => this.interruptWaiters.push(r)),
        emit: (e) => this.opts.onEvent(e),
        useTool: async (name, input, o = {}) => {
          const id = o.id ?? fakeId();
          this.opts.onEvent({ type: "tool_use", id, name, input, parentToolUseId: o.parent ?? null });
          const agentId = o.parent ? `agent-${o.parent}` : undefined;
          let allowed = true;
          let content = "ok";
          const gated = this.opts.toolGate?.({ toolName: name, input, agentId, via: "hook" }) ?? null;
          if (gated) {
            allowed = false;
            content = gated;
            this.driver.gateDenials.push({ tool: name, message: gated });
          } else if (o.ask) {
            const d = await this.opts.canUseTool({
              toolName: name,
              input,
              toolUseId: id,
              agentId,
              signal: new AbortController().signal,
              defaultToNo: o.defaultToNo,
              suggestions: o.suggestions,
              reason: o.reason,
            });
            allowed = d.behavior === "allow";
            if (d.behavior === "deny") content = d.message;
            this.driver.decisions.push({ tool: name, decision: d });
            if (d.behavior === "allow" && d.updatedPermissions) this.driver.appliedPermissions.push(...d.updatedPermissions);
          }
          if (allowed) {
            this.driver.ran.push(name);
            await o.run?.();
          }
          this.opts.onEvent({
            type: "tool_result",
            toolUseId: id,
            content: allowed ? content : content === "ok" ? "denied" : content,
            isError: !allowed,
            parentToolUseId: o.parent ?? null,
          });
          return allowed;
        },
      };
      try {
        await this.script(text, ctx);
      } catch (e) {
        this.opts.onEvent({ type: "error", message: String(e) });
      }
      if (this.closed) break;
      this.total += this.driver.turnCost;
      this.driver.totals.set(this.sessionId, this.total);
      this.opts.onEvent({
        type: "result",
        isError: false,
        text: "",
        costUsd: this.driver.turnCost,
        totalCostUsd: this.total,
        contextTokens: this.driver.contextTokens,
        sessionId: this.sessionId,
        consumedUuids: [uuid],
      });
    }
    this.busy = false;
  }

  async interrupt(): Promise<void> {
    this.queue = [];
    for (const w of this.interruptWaiters.splice(0)) w();
  }

  async setModel(model?: string): Promise<void> {
    this.driver.liveSwitches.push(`model:${model}`);
  }

  async setEffort(effort?: string): Promise<void> {
    this.driver.liveSwitches.push(`effort:${effort}`);
  }

  async stopTask(_taskId: string): Promise<void> {
    this.driver.stoppedTasks.push(_taskId);
  }

  close(): void {
    this.closed = true;
    if (this.proc && this.proc.exitCode === null) this.proc.kill("SIGTERM");
  }
}

export class FakeDriver implements HarnessDriver {
  readonly name = "fake";
  sessions: FakeMainSession[] = [];
  pals: FakeMainSession[] = []; // every Pal process started, in order
  // How a Pal's turn goes (default: echo, like the main one).
  palScript: FakeScript = defaultScript;
  // A Pal process that refuses to start: return why (e.g. it's held elsewhere).
  failPalStart?: (opts: SessionOptions) => string | undefined;
  // Start a stand-in process for each Pal through the host's spawner.
  spawnPals = false;
  probes: ProbeRequest[] = [];
  stoppedTasks: string[] = [];
  liveSwitches: string[] = [];
  appliedPermissions: unknown[] = []; // rules the owner chose to remember (harness-side)
  decisions: { tool: string; decision: PermissionDecision }[] = []; // every canUseTool answer, in order
  gateDenials: { tool: string; message: string }[] = []; // calls the host's gate (the PreToolUse hook) refused
  ran: string[] = []; // tools that went through and ran, in order
  turnCost = 0.001;
  totals = new Map<string, number>(); // each session's running total of cost, as a resume goes on from it
  contextTokens = 1000; // what each turn's result reports
  probeResponder: (req: ProbeRequest) => ProbeResult = () => ({ output: { results: [] }, costUsd: 0.0001 });
  // the permission mode a session reports running in (default: the one asked for)
  permissionModeFor?: (requested: string) => string;

  constructor(public script: FakeScript = defaultScript) {}

  startMain(opts: MainSessionOptions): MainSession {
    const s = new FakeMainSession(opts, (t, c) => this.script(t, c), this);
    this.sessions.push(s);
    return s;
  }

  startPal(opts: SessionOptions): MainSession {
    const s = new FakeMainSession(opts as MainSessionOptions, (t, c) => this.palScript(t, c), this, true);
    this.pals.push(s);
    return s;
  }

  async runProbe(req: ProbeRequest): Promise<ProbeResult> {
    this.probes.push(req);
    return this.probeResponder(req);
  }

  get last(): FakeMainSession | undefined {
    return this.sessions[this.sessions.length - 1];
  }
}

// default: echo, streaming in two deltas.
export const defaultScript: FakeScript = async (text, ctx) => {
  const reply = `收到：${text}`;
  ctx.emit({ type: "text_delta", text: reply.slice(0, 3) });
  ctx.emit({ type: "text_delta", text: reply.slice(3) });
  ctx.emit({ type: "assistant_text", text: reply, parentToolUseId: null });
};
