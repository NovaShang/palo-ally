import { afterAll } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { defaultConfig, Paths, type Config } from "../src/config.ts";
import { FakeDriver, type FakeScript } from "./fakeDriver.ts";
import { scaffoldHome } from "../src/home.ts";
import { Hub, type WechatChannel } from "../src/hub.ts";
import type { Pusher } from "../src/router.ts";

const created: string[] = [];

// Every temp root is removed when the test file finishes, even if a test failed
// before its own cleanup() call.
afterAll(() => {
  for (const r of created.splice(0)) rmSync(r, { recursive: true, force: true });
});

export function tmpPaths(): Paths {
  const root = mkdtempSync(join(tmpdir(), "paloally-test-"));
  created.push(root);
  const p = new Paths(root);
  scaffoldHome(p);
  return p;
}

export function cleanup(p: Paths): void {
  rmSync(p.root, { recursive: true, force: true });
}

export class RecordingPusher implements Pusher {
  readonly name = "rec";
  pushes: { title: string; body: string; data: Record<string, unknown> }[] = [];
  available() {
    return true;
  }
  async push(title: string, body: string, data: Record<string, unknown>) {
    this.pushes.push({ title, body, data });
  }
}

export function testConfig(over: (c: Config) => void = () => {}): Config {
  const c = defaultConfig();
  c.settings.timezone = "UTC";
  c.settings.quietHours = null;
  c.relay.enabled = false;
  c.session.idleCloseMinutes = 0;
  over(c);
  return c;
}

export function makeHub(opts: { script?: FakeScript; config?: Config; wechat?: WechatChannel; paths?: Paths } = {}) {
  const paths = opts.paths ?? tmpPaths();
  const driver = new FakeDriver(opts.script);
  const pusher = new RecordingPusher();
  const hub = new Hub({ paths, config: opts.config ?? testConfig(), driver, pushers: [pusher], wechat: opts.wechat, log: () => {} });
  const events: { event: string; data: any }[] = [];
  hub.bus.on((event, data) => events.push({ event, data }));
  return { hub, driver, pusher, paths, events };
}

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

// ---- fixtures shared with the iOS tests ----
// `bun run fixtures` (WRITE_FIXTURES=1) rewrites them; a normal test run only
// checks they are current, so a protocol change can't silently drift.

export const WRITE_FIXTURES = process.env.WRITE_FIXTURES === "1";

// shape keeps keys and value types, dropping values (ids and timestamps vary).
export function shape(v: unknown): unknown {
  if (Array.isArray(v)) return v.length ? [shape(v[0])] : [];
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(v as object).sort()) out[k] = shape((v as Record<string, unknown>)[k]);
    return out;
  }
  return v === null ? "null" : typeof v;
}

export function checkFixture(path: string, value: unknown, compare: (v: unknown) => unknown = (v) => v): void {
  if (WRITE_FIXTURES) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
    return;
  }
  if (!existsSync(path)) throw new Error(`fixture missing: ${path} — run \`bun run fixtures\``);
  const current = JSON.parse(readFileSync(path, "utf8"));
  if (JSON.stringify(compare(current)) !== JSON.stringify(compare(value))) {
    throw new Error(`fixture out of date: ${path} — run \`bun run fixtures\` and commit it`);
  }
}
