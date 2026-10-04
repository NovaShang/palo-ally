import { existsSync, unlinkSync, chmodSync } from "node:fs";
import type { Socket } from "bun";
import type { Hub } from "../hub.ts";
import { serveRpc, type AdminHandler } from "../rpc.ts";
import { newId } from "../util.ts";

// Bun's socket.write() writes what the kernel accepts and returns the count;
// the rest is ours to resend on "drain". LineWriter keeps that queue.
export class LineWriter {
  private queue: Uint8Array[] = [];
  private enc = new TextEncoder();
  constructor(private sock: { write(b: Uint8Array): number }) {}

  send(msg: unknown): void {
    this.queue.push(this.enc.encode(JSON.stringify(msg) + "\n"));
    if (this.queue.length === 1) this.flush();
  }

  flush(): void {
    while (this.queue.length) {
      const head = this.queue[0]!;
      let n: number;
      try {
        n = this.sock.write(head);
      } catch {
        this.queue = [];
        return;
      }
      if (n < 0) n = 0;
      if (n < head.length) {
        this.queue[0] = head.subarray(n);
        return; // wait for drain
      }
      this.queue.shift();
    }
  }
}

// LineReader splits a byte stream into lines, decoding UTF-8 across chunk
// boundaries (a multibyte character can straddle two chunks).
export class LineReader {
  private dec = new TextDecoder();
  private buf = "";
  push(chunk: Uint8Array): string[] {
    this.buf += this.dec.decode(chunk, { stream: true });
    const lines: string[] = [];
    let i: number;
    while ((i = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (line.trim()) lines.push(line);
    }
    return lines;
  }
}

// LocalServer: the owner's own machine talks to the daemon over a unix socket
// (mode 0600), newline-delimited JSON. Same RPC as the app, plus admin methods.
export class LocalServer {
  private server: ReturnType<typeof Bun.listen> | null = null;

  constructor(private hub: Hub, private path: string, private admin: AdminHandler) {}

  start(): void {
    if (existsSync(this.path)) unlinkSync(this.path);
    const hub = this.hub;
    const admin = this.admin;
    type Data = { id: string; reader: LineReader; writer: LineWriter; attached: boolean };
    this.server = Bun.listen<Data>({
      unix: this.path,
      socket: {
        open(sock) {
          sock.data = { id: newId("cli_"), reader: new LineReader(), writer: new LineWriter(sock), attached: false };
        },
        drain(sock) {
          sock.data.writer.flush();
        },
        data(sock, chunk) {
          const write = (m: unknown) => sock.data.writer.send(m);
          for (const line of sock.data.reader.push(chunk)) {
            let req: any;
            try {
              req = JSON.parse(line);
            } catch {
              write({ error: { message: "bad json" } });
              continue;
            }
            // Event subscription starts on the first "hello"/"subscribe".
            if ((req.method === "hello" || req.method === "subscribe") && !sock.data.attached) {
              sock.data.attached = true;
              hub.attach({ id: sock.data.id, kind: "cli", send: write });
            }
            void serveRpc(hub, req, { clientId: sock.data.id, channel: "cli", local: true }, admin).then(write);
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

// LocalClient: used by CLI subcommands.
export class LocalClient {
  private sock: Socket<undefined> | null = null;
  private reader = new LineReader();
  private writer: LineWriter | null = null;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  onEvent: (event: string, data: any) => void = () => {};

  static async connect(path: string): Promise<LocalClient> {
    const c = new LocalClient();
    c.sock = await Bun.connect({
      unix: path,
      socket: {
        data: (_s, chunk) => c.onData(chunk),
        drain: () => c.writer?.flush(),
        close: () => {
          for (const p of c.pending.values()) p.reject(new Error("连接断开"));
          c.pending.clear();
        },
      },
    });
    c.writer = new LineWriter(c.sock);
    return c;
  }

  private onData(chunk: Uint8Array): void {
    for (const line of this.reader.push(chunk)) {
      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
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
      this.writer!.send({ id, method, params });
    });
  }

  close(): void {
    this.sock?.end();
  }
}
