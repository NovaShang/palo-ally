import { existsSync, unlinkSync, chmodSync } from "node:fs";
import type { Socket } from "bun";
import type { Hub } from "../hub.ts";
import { serveRpc, type AdminHandler } from "../rpc.ts";
import { newId } from "../util.ts";

// LocalServer: the owner's own machine talks to the daemon over a unix socket
// (mode 0600), newline-delimited JSON. Same RPC as the app, plus admin methods.
export class LocalServer {
  private server: ReturnType<typeof Bun.listen> | null = null;

  constructor(private hub: Hub, private path: string, private admin: AdminHandler) {}

  start(): void {
    if (existsSync(this.path)) unlinkSync(this.path);
    const hub = this.hub;
    const admin = this.admin;
    type Data = { id: string; buf: string; attached: boolean };
    this.server = Bun.listen<Data>({
      unix: this.path,
      socket: {
        open(sock) {
          sock.data = { id: newId("cli_"), buf: "", attached: false };
        },
        data(sock, chunk) {
          sock.data.buf += chunk.toString();
          let i: number;
          while ((i = sock.data.buf.indexOf("\n")) >= 0) {
            const line = sock.data.buf.slice(0, i);
            sock.data.buf = sock.data.buf.slice(i + 1);
            if (!line.trim()) continue;
            let req: any;
            try {
              req = JSON.parse(line);
            } catch {
              write(sock, { error: { message: "bad json" } });
              continue;
            }
            // Event subscription starts on the first "hello"/"subscribe".
            if ((req.method === "hello" || req.method === "subscribe") && !sock.data.attached) {
              sock.data.attached = true;
              hub.attach({ id: sock.data.id, kind: "cli", send: (m) => write(sock, m) });
            }
            void serveRpc(hub, req, { clientId: sock.data.id, channel: "cli", local: true }, admin).then((res) => write(sock, res));
          }
        },
        close(sock) {
          hub.detach(sock.data.id);
        },
        error(sock) {
          hub.detach(sock.data.id);
        },
      },
    });
    chmodSync(this.path, 0o600);
  }

  stop(): void {
    this.server?.stop(true);
    if (existsSync(this.path)) unlinkSync(this.path);
  }
}

function write(sock: Socket<any>, msg: unknown): void {
  try {
    sock.write(JSON.stringify(msg) + "\n");
  } catch {
    /* socket gone */
  }
}

// LocalClient: used by CLI subcommands.
export class LocalClient {
  private sock: Socket<undefined> | null = null;
  private buf = "";
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  onEvent: (event: string, data: any) => void = () => {};

  static async connect(path: string): Promise<LocalClient> {
    const c = new LocalClient();
    c.sock = await Bun.connect({
      unix: path,
      socket: {
        data: (_s, chunk) => c.onData(chunk.toString()),
        close: () => {
          for (const p of c.pending.values()) p.reject(new Error("连接断开"));
          c.pending.clear();
        },
      },
    });
    return c;
  }

  private onData(s: string): void {
    this.buf += s;
    let i: number;
    while ((i = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (!line.trim()) continue;
      const msg = JSON.parse(line);
      if (msg.event) this.onEvent(msg.event, msg.data);
      else if (msg.id !== undefined) {
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message));
        else p.resolve(msg.result);
      }
    }
  }

  call<T = any>(method: string, params: unknown = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.sock!.write(JSON.stringify({ id, method, params }) + "\n");
    });
  }

  close(): void {
    this.sock?.end();
  }
}
