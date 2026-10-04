import type {
  HarnessDriver,
  HarnessEvent,
  MainSession,
  MainSessionOptions,
  ProbeRequest,
  ProbeResult,
} from "./types.ts";

// A scripted turn: given the user text and the session's tools/permission
// hooks, emit events. Lets tests drive the Hub deterministically, including
// tool calls that go through the real approval gate.
export type FakeScript = (text: string, ctx: FakeCtx) => Promise<void>;

export interface FakeCtx {
  opts: MainSessionOptions;
  emit(e: HarnessEvent): void;
  // simulate the harness calling a tool. `ask` = the harness decided to ask
  // the owner (with its own suggestions / defaultToNo); otherwise it just runs.
  useTool(
    name: string,
    input: Record<string, unknown>,
    opts?: { id?: string; parent?: string | null; ask?: boolean; defaultToNo?: boolean; suggestions?: unknown[] },
  ): Promise<boolean>;
}

let idCounter = 0;
export const fakeId = (p = "toolu_") => `${p}${++idCounter}`;

export class FakeMainSession implements MainSession {
  closed = false;
  private queue: { text: string; uuid: string }[] = [];
  private busy = false;
  sent: string[] = [];
  private total = 0;
  readonly sessionId: string;

  constructor(readonly opts: MainSessionOptions, private script: FakeScript, private driver: FakeDriver) {
    this.sessionId = opts.resumeSessionId ?? `sess-${++idCounter}`;
    queueMicrotask(() => {
      opts.onEvent({ type: "init", sessionId: this.sessionId, model: opts.model ?? "fake-model", tools: [], terminalCommands: ["doctor"] });
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

  send(text: string, uuid: string): void {
    this.sent.push(text);
    this.queue.push({ text, uuid });
    void this.drain();
  }

  private async drain(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    while (this.queue.length && !this.closed) {
      const { text, uuid } = this.queue.shift()!;
      const ctx: FakeCtx = {
        opts: this.opts,
        emit: (e) => this.opts.onEvent(e),
        useTool: async (name, input, o = {}) => {
          const id = o.id ?? fakeId();
          this.opts.onEvent({ type: "tool_use", id, name, input, parentToolUseId: o.parent ?? null });
          let allowed = true;
          if (o.ask) {
            const d = await this.opts.canUseTool({
              toolName: name,
              input,
              toolUseId: id,
              signal: new AbortController().signal,
              defaultToNo: o.defaultToNo,
              suggestions: o.suggestions,
            });
            allowed = d.behavior === "allow";
            if (d.behavior === "allow" && d.updatedPermissions) this.driver.appliedPermissions.push(...d.updatedPermissions);
          }
          this.opts.onEvent({
            type: "tool_result",
            toolUseId: id,
            content: allowed ? "ok" : "denied",
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
      this.total += this.driver.turnCost;
      this.opts.onEvent({
        type: "result",
        isError: false,
        text: "",
        costUsd: this.driver.turnCost,
        totalCostUsd: this.total,
        contextTokens: 1000,
        sessionId: this.sessionId,
        consumedUuids: [uuid],
      });
    }
    this.busy = false;
  }

  async interrupt(): Promise<void> {
    this.queue = [];
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
  }
}

export class FakeDriver implements HarnessDriver {
  readonly name = "fake";
  sessions: FakeMainSession[] = [];
  probes: ProbeRequest[] = [];
  stoppedTasks: string[] = [];
  liveSwitches: string[] = [];
  appliedPermissions: unknown[] = []; // rules the owner chose to remember (harness-side)
  turnCost = 0.001;
  probeResponder: (req: ProbeRequest) => ProbeResult = () => ({ output: { results: [] }, costUsd: 0.0001 });

  constructor(public script: FakeScript = defaultScript) {}

  startMain(opts: MainSessionOptions): MainSession {
    const s = new FakeMainSession(opts, (t, c) => this.script(t, c), this);
    this.sessions.push(s);
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
