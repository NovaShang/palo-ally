import { connect, constants, type ClientHttp2Session } from "node:http2";
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import type { Pusher } from "../router.ts";
import { readJson, writeJson } from "../util.ts";

// Host-direct APNs pusher (token auth, .p8 key). Normally pushes go through
// the relay (relayPush.ts), which holds the app key; this is the fallback for
// developer setups with apns.keyPath/keyId/teamId in config.json.

export interface ApnsConfig {
  keyPath?: string;
  keyId?: string;
  teamId?: string;
  bundleId: string;
  host?: string; // override (tests)
}

export function apnsJwt(key: string, keyId: string, teamId: string, iat = Math.floor(Date.now() / 1000)): string {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = enc({ alg: "ES256", kid: keyId });
  const body = enc({ iss: teamId, iat });
  const signer = createSign("SHA256");
  signer.update(`${head}.${body}`);
  // JOSE wants raw r||s, not DER.
  const sig = signer.sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${head}.${body}.${sig}`;
}

interface Token {
  token: string;
  env: string;
}

export class ApnsPusher implements Pusher {
  readonly name = "apns";
  private jwt: { value: string; at: number } | null = null;
  private sessions = new Map<string, ClientHttp2Session>();

  constructor(
    private cfg: ApnsConfig,
    private tokensPath: string,
    private enabled: boolean,
    /** This host's daemon id; sent as top-level `hostId` (next to `aps`). */
    private hostId?: string,
  ) {}

  available(): boolean {
    return this.enabled && !!this.cfg.keyPath && !!this.cfg.keyId && !!this.cfg.teamId && this.tokens().length > 0;
  }

  private tokens(): Token[] {
    return readJson<Token[]>(this.tokensPath, []);
  }

  private bearer(): string {
    // Apple wants the token refreshed at most hourly, at least every 60 min.
    if (!this.jwt || Date.now() - this.jwt.at > 50 * 60_000) {
      const key = readFileSync(this.cfg.keyPath!, "utf8");
      this.jwt = { value: apnsJwt(key, this.cfg.keyId!, this.cfg.teamId!), at: Date.now() };
    }
    return this.jwt.value;
  }

  private session(env: string): ClientHttp2Session {
    const host = this.cfg.host ?? (env === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com");
    let s = this.sessions.get(host);
    if (!s || s.closed || s.destroyed) {
      s = connect(host);
      s.on("error", () => this.sessions.delete(host));
      this.sessions.set(host, s);
    }
    return s;
  }

  async push(title: string, body: string, data: Record<string, unknown>): Promise<void> {
    const payload = JSON.stringify({
      aps: { alert: { title, body }, sound: "default", "thread-id": "paloally" },
      ...data,
      ...(this.hostId ? { hostId: this.hostId } : {}),
    });
    const dead: string[] = [];
    await Promise.all(
      this.tokens().map(
        (t) =>
          new Promise<void>((resolve) => {
            const req = this.session(t.env).request({
              [constants.HTTP2_HEADER_METHOD]: "POST",
              [constants.HTTP2_HEADER_PATH]: `/3/device/${t.token}`,
              authorization: `bearer ${this.bearer()}`,
              "apns-topic": this.cfg.bundleId,
              "apns-push-type": "alert",
              "apns-priority": "10",
            });
            let status = 0;
            req.on("response", (h) => (status = Number(h[constants.HTTP2_HEADER_STATUS])));
            req.on("data", () => {});
            req.on("end", () => {
              if (status === 410 || status === 400) dead.push(t.token); // unregistered / bad token
              resolve();
            });
            req.on("error", () => resolve());
            req.end(payload);
          }),
      ),
    );
    if (dead.length) writeJson(this.tokensPath, this.tokens().filter((t) => !dead.includes(t.token)));
  }

  close(): void {
    for (const s of this.sessions.values()) s.close();
  }
}
