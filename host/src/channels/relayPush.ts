import type { Pusher } from "../router.ts";
import { readJson, writeJson } from "../util.ts";
import type { RelayPushRequest, RelayPushResult, RelayState } from "./relay.ts";

// Pushes through the relay, which holds the app's APNs key: the key belongs
// to the developer, so other people's hosts could never push on their own.
// Tokens are the ones the app registered with this host (push.register).
//
// `fallback` is the host-direct ApnsPusher, used only when the owner has a
// key configured (developer setups) and the relay can't push right now —
// down, too old to know `push`, or not configured.

export interface RelayPushTransport {
  readonly state: RelayState;
  pushViaRelay(req: RelayPushRequest): Promise<RelayPushResult>;
}

interface Token {
  token: string;
  env: string;
}

// Reasons that mean "the relay couldn't do it" rather than "APNs said no".
const UNAVAILABLE = /^(NotConfigured|Network|RateLimited|NoPairedDevice)/;

export class RelayPusher implements Pusher {
  readonly name = "relay-apns";

  constructor(
    private relay: RelayPushTransport,
    private tokensPath: string,
    private fallback: Pusher | null = null,
    /** This host's daemon id; sent as top-level `hostId` (next to `aps`). */
    private hostId?: string,
  ) {}

  private tokens(): Token[] {
    return readJson<Token[]>(this.tokensPath, []);
  }

  available(): boolean {
    return this.tokens().length > 0 && (this.relay.state === "connected" || !!this.fallback?.available());
  }

  /** Resolves with how many devices the push reached; throws when none did. */
  async push(title: string, body: string, data: Record<string, unknown>): Promise<number | void> {
    const tokens = this.tokens();
    if (!tokens.length) return 0;
    const dead: string[] = [];
    const failures: string[] = [];
    let delivered = 0;
    let relayUnavailable = this.relay.state !== "connected";
    if (!relayUnavailable) {
      const results = await Promise.all(
        tokens.map((t) =>
          this.relay
            // The relay spreads `data` next to `aps` in the APNs payload.
            .pushViaRelay({ token: t.token, env: t.env === "production" ? "production" : "sandbox", title, body, data: clean({ ...data, hostId: this.hostId }) })
            .then((r) => ({ t, r }))
            .catch((e: unknown) => ({ t, r: { ok: false, status: 0, reason: `Network: ${String(e)}` } as RelayPushResult })),
        ),
      );
      for (const { t, r } of results) {
        if (r.ok) delivered++;
        else if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") dead.push(t.token);
        else failures.push(`${r.status} ${r.reason ?? ""}`.trim());
      }
      relayUnavailable = delivered === 0 && failures.length > 0 && failures.every((f) => UNAVAILABLE.test(f.replace(/^\d+ /, "")));
    }
    if (dead.length) writeJson(this.tokensPath, this.tokens().filter((t) => !dead.includes(t.token)));
    if (relayUnavailable && this.fallback?.available()) return this.fallback.push(title, body, data);
    if (delivered === 0 && failures.length) throw new Error(`relay push failed: ${failures.join("; ")}`);
    return delivered;
  }
}

// APNs custom data must be plain JSON; drop undefined fields.
function clean(data: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(data).filter(([, v]) => v !== undefined));
}
