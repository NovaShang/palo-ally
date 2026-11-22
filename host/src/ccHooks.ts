import { chmodSync, existsSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";
import { LineReader } from "./channels/local.ts";
import { ensureDir } from "./util.ts";
import { HOOK_ACK_MS, HOOK_EVENTS, HookInstaller, type HookInstallerOptions, hookCommand, isPaloAllyHook } from "./harness/claude/hooks.ts";

// PaloAlly's global Claude Code hooks (docs/sessions-prd.md §6.3): writing
// them into Claude Code's settings and the hook script are Claude Code's own
// (harness/claude/hooks.ts, kept here for the modules and tests that import
// them from here); the host's end of the hook socket is here.
export { HOOK_ACK_MS, HOOK_EVENTS, HookInstaller, hookCommand, isPaloAllyHook };
export type { HookInstallerOptions };

// ---------------- the host's end of the hook socket ----------------

export interface HookContext {
  /** Aborted when the hook went away first (Claude Code killed it: answered in the terminal, or the session ended). */
  signal: AbortSignal;
  env: { jobDir?: string };
}

export type HookHandler = (event: string, payload: Record<string, any>, ctx: HookContext) => Promise<unknown> | unknown;

// HookServer: one connection per hook run. It reads the hook's one line,
// says it's there at once (the hook gives up after HOOK_ACK_MS otherwise),
// then answers with the handler's output (null = print nothing).
export class HookServer {
  private server: ReturnType<typeof Bun.listen> | null = null;

  constructor(
    private path: string,
    private handler: HookHandler,
    private log: (s: string) => void = () => {},
  ) {}

  start(): void {
    ensureDir(dirname(this.path));
    if (existsSync(this.path)) unlinkSync(this.path);
    const handler = this.handler;
    const log = this.log;
    type Data = { reader: LineReader; started: boolean; abort: AbortController; closed: boolean };
    this.server = Bun.listen<Data>({
      unix: this.path,
      socket: {
        open(sock) {
          sock.data = { reader: new LineReader(), started: false, abort: new AbortController(), closed: false };
        },
        data(sock, chunk) {
          if (sock.data.started) return;
          const line = sock.data.reader.push(chunk)[0];
          if (line === undefined) return;
          sock.data.started = true;
          let msg: any;
          try {
            msg = JSON.parse(line);
          } catch {
            sock.end();
            return;
          }
          sock.write(JSON.stringify({ ack: true }) + "\n");
          const payload = msg?.payload && typeof msg.payload === "object" ? msg.payload : {};
          const event = String(msg?.event || payload.hook_event_name || "");
          Promise.resolve()
            .then(() => handler(event, payload, { signal: sock.data.abort.signal, env: msg?.env ?? {} }))
            .catch((e) => {
              log(`hook ${event} failed: ${e instanceof Error ? e.message : e}`);
              return null;
            })
            .then((output) => {
              if (sock.data.closed) return;
              sock.write(JSON.stringify({ output: output ?? null }) + "\n");
              sock.end();
            });
        },
        close(sock) {
          sock.data.closed = true;
          sock.data.abort.abort("closed");
        },
        error(sock) {
          sock.data.closed = true;
          sock.data.abort.abort("closed");
        },
      },
    });
    chmodSync(this.path, 0o600);
  }

  stop(): void {
    this.server?.stop(true);
    this.server = null;
    try {
      if (existsSync(this.path)) unlinkSync(this.path);
    } catch {
      /* ignore */
    }
  }
}
