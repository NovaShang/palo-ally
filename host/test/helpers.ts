import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { defaultConfig, Paths, type Config } from "../src/config.ts";
import { FakeDriver, type FakeScript } from "../src/harness/fake.ts";
import { scaffoldHome } from "../src/home.ts";
import { Hub, type WechatChannel } from "../src/hub.ts";
import type { Pusher } from "../src/router.ts";

export function tmpPaths(): Paths {
  const root = mkdtempSync(join(tmpdir(), "paloally-test-"));
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
