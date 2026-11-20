import { networkInterfaces } from "node:os";
import type { ServerWebSocket } from "bun";
import type { RelayChannel } from "./relay.ts";

// The app's way straight to this computer, without the relay: when it can
// reach it (the same Mac, the same local network, Tailscale), it opens a
// WebSocket here at `/v1/tunnel?<the query it gives the relay>` instead.
// Each WebSocket is one stream, its binary messages the units it would send
// through the relay, handled by RelayChannel as a relay stream is. Nothing
// is trusted for being local: the E2E handshake against the paired devices'
// keys decides, as it does through the relay (an unpaired device is closed).

/** Where the app may reach this computer directly (`hello`'s `direct`). */
export interface DirectEndpoints {
  port: number;
  /** 127.0.0.1, then each local network IPv4, then Tailscale's (100.64.0.0/10). */
  addrs: string[];
}

/** Tailscale gives each device an address in the CGNAT range 100.64.0.0/10. */
export function isTailscaleV4(addr: string): boolean {
  const m = /^100\.(\d+)\./.exec(addr);
  return !!m && Number(m[1]) >= 64 && Number(m[1]) <= 127;
}

/** This computer's IPv4 addresses the app could reach, best first. */
export function directAddrs(ifaces = networkInterfaces()): string[] {
  const lan: string[] = [];
  const tailscale: string[] = [];
  for (const list of Object.values(ifaces)) {
    for (const a of list ?? []) {
      if (a.family !== "IPv4" || a.internal) continue;
      if (a.address.startsWith("169.254.")) continue; // link-local: no DHCP, not a network
      (isTailscaleV4(a.address) ? tailscale : lan).push(a.address);
    }
  }
  return [...new Set(["127.0.0.1", ...lan, ...tailscale])];
}

interface Conn {
  tag: string;
  stream?: { unit(u: Uint8Array): void; closed(): void };
}

export class LocalTunnel {
  private server: ReturnType<typeof Bun.serve<Conn>> | null = null;
  private n = 0;
  port = 0;

  constructor(
    private relay: RelayChannel,
    private log: (s: string) => void = (s) => console.log(`[direct] ${s}`),
  ) {}

  /** Listens on all interfaces at `port`, or the next free one (up to 20 on). */
  start(port: number, hostname = "0.0.0.0"): number {
    let lastError: unknown = null;
    for (let p = port; p < port + 20; p++) {
      try {
        this.server = this.serve(p, hostname);
        this.port = this.server.port ?? p;
        this.log(`listening on ${hostname}:${this.port}`);
        return this.port;
      } catch (e) {
        lastError = e;
      }
    }
    throw new Error(`no free port from ${port}: ${lastError}`);
  }

  stop(): void {
    this.server?.stop(true);
    this.server = null;
  }

  endpoints(): DirectEndpoints | null {
    return this.server ? { port: this.port, addrs: directAddrs() } : null;
  }

  private serve(port: number, hostname: string) {
    const relay = this.relay;
    return Bun.serve<Conn>({
      port,
      hostname,
      fetch: (req, server) => {
        const url = new URL(req.url);
        if (url.pathname !== "/v1/tunnel") return new Response("not found", { status: 404 });
        // The checks the relay makes before it opens a tunnel, as far as they
        // are cheap: this computer, and a device it knows. The device proves
        // it holds the key in the E2E handshake.
        const daemonId = url.searchParams.get("daemon_id");
        const deviceId = url.searchParams.get("device_id") ?? "";
        if (daemonId !== relay.daemonId) return new Response("unknown daemon", { status: 404 });
        if (!deviceId) return new Response("missing device", { status: 400 });
        if (server.upgrade(req, { data: { tag: `l${++this.n}` } })) return undefined;
        return new Response("websocket only", { status: 426 });
      },
      websocket: {
        // A file chunk or an upload is at most a few MB once sealed.
        maxPayloadLength: 64 * 1024 * 1024,
        open: (ws: ServerWebSocket<Conn>) => {
          ws.data.stream = relay.openDirectStream({
            tag: ws.data.tag,
            send: (unit) => {
              try {
                ws.sendBinary(unit);
              } catch {
                /* closed */
              }
            },
            close: () => {
              ws.close();
              ws.data.stream?.closed();
            },
          });
        },
        message: (ws: ServerWebSocket<Conn>, msg) => {
          if (typeof msg === "string") return; // units are binary
          ws.data.stream?.unit(new Uint8Array(msg));
        },
        close: (ws: ServerWebSocket<Conn>) => {
          ws.data.stream?.closed();
        },
      },
    });
  }
}
