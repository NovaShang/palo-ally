import { chmodSync } from "node:fs";
import { ApnsPusher } from "./channels/apns.ts";
import { LocalServer } from "./channels/local.ts";
import { RelayChannel, loadHostIdentity } from "./channels/relay.ts";
import { WechatILink } from "./channels/wechat.ts";
import { type Config, Paths, loadConfig } from "./config.ts";
import { ClaudeCodeDriver } from "./harness/claude.ts";
import type { HarnessDriver } from "./harness/types.ts";
import { scaffoldHome } from "./home.ts";
import { Hub } from "./hub.ts";
import type { AdminHandler } from "./rpc.ts";

export interface Daemon {
  hub: Hub;
  local: LocalServer;
  relay: RelayChannel | null;
  wechat: WechatILink | null;
  stop(): void;
}

export async function startDaemon(
  paths: Paths,
  opts: { driver?: HarnessDriver; config?: Config; relay?: boolean; probe?: boolean } = {},
): Promise<Daemon> {
  scaffoldHome(paths);
  // Older installs wrote these world-readable; they hold tokens and the host key.
  for (const f of [paths.config, paths.identity, paths.wechat, paths.devices, paths.pushTokens]) {
    try {
      chmodSync(f, 0o600);
    } catch {
      /* not there yet */
    }
  }
  try {
    chmodSync(paths.root, 0o700);
  } catch {
    /* ignore */
  }
  const config = opts.config ?? loadConfig(paths);
  Object.assign(process.env, config.env ?? {});
  const driver = opts.driver ?? new ClaudeCodeDriver();

  const wechat = config.wechat.enabled ? new WechatILink(paths.wechat, config.wechat.baseUrl) : null;
  const apns = new ApnsPusher(config.apns, paths.pushTokens, config.apns.enabled);
  const hub = new Hub({ paths, config, driver, pushers: [apns], wechat });

  if (wechat) {
    wechat.onMessage = (text, target) => {
      hub.audit.log("wechat.in", { chars: text.length });
      hub.userMessage(text, "wechat", target);
    };
    if (wechat.loggedIn) void wechat.start();
  }

  let relay: RelayChannel | null = null;
  if (opts.relay ?? config.relay.enabled) {
    const { id, daemonId } = loadHostIdentity(paths.identity);
    relay = new RelayChannel(hub, config.relay.url, id, daemonId, paths.devices);
    const r = relay;
    hub.onUnpairDevice = (deviceId) => r.removeDevice(deviceId);
    void relay.start();
  }

  const admin: AdminHandler = async (method, p) => {
    switch (method) {
      case "pair.open":
        if (!relay) throw new Error("远程连接没开启（config.relay.enabled=false）");
        return relay.openPairing(Number(p.ttl ?? 120));
      case "devices.list":
        return { devices: relay?.devices() ?? [] };
      case "devices.remove":
        return { ok: relay?.removeDevice(String(p.id)) ?? false };
      case "relay.status":
        return relay
          ? { enabled: true, state: relay.state, daemonId: relay.daemonId, lastError: relay.lastError, streams: relay.connectedStreams() }
          : { enabled: false };
      case "wechat.status":
        return { status: wechat?.status() ?? "off", enabled: !!wechat };
      case "probe.tick":
        return hub.probe.tick();
      case "usage":
        return hub.usage();
      case "subscribe":
        return { ok: true };
      case "restart":
        if (p.now) {
          setTimeout(() => process.exit(0), 200);
          return { status: "restarting" };
        }
        return { status: await hub.restartWhenIdle(Number(p.maxWaitMs ?? 30 * 60_000)) };
      default:
        throw new Error(`unknown method: ${method}`);
    }
  };

  const local = new LocalServer(hub, paths.socket, admin);
  local.start();
  hub.start({ probe: opts.probe });

  return {
    hub,
    local,
    relay,
    wechat,
    stop() {
      wechat?.stop();
      relay?.stop();
      apns.close();
      local.stop();
      hub.stop();
    },
  };
}
