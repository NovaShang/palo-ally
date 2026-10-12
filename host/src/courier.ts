import { query as sdkQuery, type HookInput, type Query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { cleanSessionEnv } from "./ccCli.ts";
import { COURIER_NAME } from "./ccHooks.ts";
import { OWN_SESSION_ENV } from "./harness/claude.ts";
import { VERSION } from "./config.ts";
import { ensureDir } from "./util.ts";

// The courier (docs/sessions-prd.md §6.4): words from the app (or from the
// assistant) reach a Claude Code session through Claude Code's own
// SendMessage, sent by a very small session of the host's named "PaloAlly"
// — Haiku, no thinking, only SendMessage and ToolSearch. The model only
// presses send: a PreToolUse hook puts the exact recipient and the exact
// words into the call, so nothing it writes can change them. It stays up for
// the next message and closes after 10 quiet minutes. A session holds a
// message from a sender whose permission mode is of the other class (bypass
// vs prompting), so there is one courier per class, started when needed.

export type ModeClass = "prompting" | "bypass";

export function modeClass(mode: string | undefined): ModeClass {
  return mode === "bypassPermissions" ? "bypass" : "prompting";
}

const SYSTEM = `You deliver one message per user turn. Each turn reads:
TO: <session>
TEXT:
<the text>
Call SendMessage exactly once with to=<session> and message=<the text>, unchanged. (Load SendMessage with ToolSearch first if you have to.) Then reply with just: ok. Never do anything else.`;

const SEND_TIMEOUT_MS = 60_000;
export const COURIER_IDLE_MS = 10 * 60_000;

class Queue<T> implements AsyncIterable<T> {
  private items: T[] = [];
  private waiters: ((r: IteratorResult<T>) => void)[] = [];
  private done = false;
  push(item: T): void {
    const w = this.waiters.shift();
    if (w) w({ value: item, done: false });
    else this.items.push(item);
  }
  end(): void {
    this.done = true;
    for (const w of this.waiters.splice(0)) w({ value: undefined as never, done: true });
  }
  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        const item = this.items.shift();
        if (item !== undefined) return Promise.resolve({ value: item, done: false });
        if (this.done) return Promise.resolve({ value: undefined as never, done: true });
        return new Promise((resolve) => this.waiters.push(resolve));
      },
    };
  }
}

interface Pending {
  to: string;
  message: string;
  used: boolean; // the hook already put this message into a SendMessage call
  sendId?: string; // that call's tool_use id
  delivered: boolean;
  msgId?: string;
  error?: string;
  resolve: (r: { msgId?: string; costUsd: number }) => void;
  reject: (e: Error) => void;
}

export interface CourierDeps {
  cwd: string; // its own folder (PaloAlly's, never a project)
  env?: () => Record<string, string | undefined>;
  query?: typeof sdkQuery; // tests pass a fake
  model?: string;
  idleMs?: number;
  log?: (s: string) => void;
}

class CourierSession {
  private input = new Queue<SDKUserMessage>();
  private q: Query;
  private current: Pending | null = null;
  private lastCost = 0;
  closed = false;

  constructor(
    private d: CourierDeps,
    readonly mode: ModeClass,
  ) {
    ensureDir(d.cwd);
    const query = d.query ?? sdkQuery;
    this.q = query({
      prompt: this.input,
      options: {
        cwd: d.cwd,
        model: d.model ?? "haiku",
        thinking: { type: "disabled" },
        systemPrompt: SYSTEM,
        settingSources: [],
        tools: ["SendMessage", "ToolSearch"],
        persistSession: false,
        // Its name is how sessions know it (the line its SessionStart hook adds).
        extraArgs: { name: COURIER_NAME },
        // Nothing should be sent to the courier; it would only cost a turn.
        settings: { crossSessionInbound: "refuse" } as any,
        permissionMode: this.mode === "bypass" ? "bypassPermissions" : "default",
        ...(this.mode === "bypass" ? { allowDangerouslySkipPermissions: true } : {}),
        canUseTool: async (tool, input) =>
          tool === "SendMessage" || tool === "ToolSearch"
            ? { behavior: "allow", updatedInput: input }
            : { behavior: "deny", message: "Only SendMessage." },
        hooks: { PreToolUse: [{ matcher: "SendMessage", hooks: [async (input) => this.rewrite(input)] }] },
        env: { ...cleanSessionEnv((d.env ?? (() => process.env))()), ...OWN_SESSION_ENV, CLAUDE_AGENT_SDK_CLIENT_APP: `paloally-courier/${VERSION}` },
      },
    });
    void this.pump();
  }

  // The exact recipient and words go into the call; a second call in the same turn is refused.
  private async rewrite(input: HookInput): Promise<any> {
    const cur = this.current;
    const toolInput = ((input as any).tool_input ?? {}) as Record<string, unknown>;
    if (!cur || cur.used) {
      return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Already sent." } };
    }
    cur.used = true;
    cur.sendId = (input as any).tool_use_id;
    const updated: Record<string, unknown> = { ...toolInput, to: cur.to, message: cur.message };
    if ("content" in updated) updated.content = cur.message;
    if ("recipient" in updated) updated.recipient = cur.to;
    return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: updated } };
  }

  private async pump(): Promise<void> {
    try {
      for await (const msg of this.q) {
        const m = msg as any;
        const cur = this.current;
        if (m.type === "user" && cur && Array.isArray(m.message?.content)) {
          for (const b of m.message.content) {
            if (b?.type !== "tool_result" || (cur.sendId && b.tool_use_id !== cur.sendId)) continue;
            const text = typeof b.content === "string" ? b.content : Array.isArray(b.content) ? b.content.map((x: any) => x?.text ?? "").join("") : "";
            if (/"success"\s*:\s*true/.test(text) && !b.is_error) {
              cur.delivered = true;
              cur.msgId = /"msg_id"\s*:\s*"([^"]+)"/.exec(text)?.[1];
            } else if (cur.used) {
              cur.error = text.slice(0, 300) || "没送到";
            }
          }
        } else if (m.type === "result") {
          const total = typeof m.total_cost_usd === "number" ? m.total_cost_usd : this.lastCost;
          const cost = Math.max(0, total - this.lastCost);
          this.lastCost = total;
          if (cur) {
            this.current = null;
            if (cur.delivered) cur.resolve({ msgId: cur.msgId, costUsd: cost });
            else cur.reject(new Error(cur.error ? `没送到：${cur.error}` : "没送到"));
          }
        }
      }
    } catch (e) {
      this.d.log?.(`courier: ${e instanceof Error ? e.message : e}`);
    } finally {
      this.closed = true;
      const cur = this.current;
      this.current = null;
      cur?.reject(new Error("没送到：跑腿的会话停了"));
    }
  }

  send(to: string, label: string, message: string): Promise<{ msgId?: string; costUsd: number }> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.current === pending) {
          this.current = null;
          void this.q.interrupt().catch(() => {});
          reject(new Error("没送到：等太久了"));
        }
      }, SEND_TIMEOUT_MS);
      const pending: Pending = {
        to,
        message,
        used: false,
        delivered: false,
        resolve: (r) => {
          clearTimeout(timer);
          resolve(r);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      };
      this.current = pending;
      this.input.push({
        type: "user",
        message: { role: "user", content: `TO: ${label}\nTEXT:\n${message}` },
        parent_tool_use_id: null,
      } as SDKUserMessage);
    });
  }

  close(): void {
    this.input.end();
    try {
      this.q.close();
    } catch {
      /* already gone */
    }
    this.closed = true;
  }
}

export class Courier {
  private sessions = new Map<ModeClass, CourierSession>();
  private chain: Promise<unknown> = Promise.resolve();
  private idleTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private d: CourierDeps) {}

  /**
   * Sends `message` to session `to` (its address: "uds:<socket>" or its name)
   * exactly as given. `label` is how the model sees the recipient. One at a
   * time; resolves once Claude Code says it was delivered.
   */
  send(o: { to: string; label: string; message: string; mode: ModeClass }): Promise<{ msgId?: string; costUsd: number }> {
    const run = async () => {
      let s = this.sessions.get(o.mode);
      if (!s || s.closed) {
        s = new CourierSession(this.d, o.mode);
        this.sessions.set(o.mode, s);
      }
      try {
        return await s.send(o.to, o.label, o.message);
      } finally {
        this.armIdle();
      }
    };
    const p = this.chain.then(run, run);
    this.chain = p.catch(() => {});
    return p;
  }

  private armIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.close(), this.d.idleMs ?? COURIER_IDLE_MS);
    (this.idleTimer as any).unref?.();
  }

  get running(): number {
    return [...this.sessions.values()].filter((s) => !s.closed).length;
  }

  close(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}
