import { existsSync } from "node:fs";
import { getLang, isLang, setLang, systemLanguage, t } from "./i18n/index.ts";
import { dateLocale } from "./util.ts";
import { createInterface } from "node:readline";
import { LocalClient } from "./channels/local.ts";
import { WechatILink } from "./channels/wechat.ts";
import { Paths, VERSION, defaultRoot, loadConfig, saveConfig } from "./config.ts";
import { startDaemon } from "./daemon.ts";
import { scaffoldHome } from "./home.ts";
import { scheduleText } from "./watches.ts";
import { powerLine } from "./power.ts";
import { CORE_SOFT_LIMIT } from "./memory.ts";
import { installService, serviceStatus, uninstallService } from "./service.ts";
import { HEALTHY_AFTER_MS, Updater, bootCheck, cleanStaging, confirmUpdate, rollbackSync, updateLine } from "./update.ts";
import { runSetup } from "./setup.ts";
import type { ChatMessage, Task, Watch } from "./types.ts";

const paths = new Paths(defaultRoot());
const [cmd = "help", ...args] = process.argv.slice(2);

// This process is not the daemon: it picks its own language, the owner's
// setting if there is one, else the computer's.
function readLanguage(): "zh" | "en" {
  try {
    const l = loadConfig(paths).settings.language;
    if (isLang(l)) return l;
  } catch {
    /* no readable config yet: the computer's language */
  }
  return systemLanguage();
}
setLang(readLanguage());

const helpText = (): string => t("cli.help", { version: VERSION });

async function client(): Promise<LocalClient> {
  if (!existsSync(paths.socket)) {
    console.error(t("cli.notRunning"));
    process.exit(1);
  }
  try {
    return await LocalClient.connect(paths.socket);
  } catch {
    console.error(t("cli.noResponse"));
    process.exit(1);
  }
}

async function call<T = any>(method: string, params: unknown = {}): Promise<T> {
  const c = await client();
  try {
    return await c.call<T>(method, params);
  } finally {
    c.close();
  }
}

function fmtTime(ms?: number): string {
  if (!ms) return "-";
  return new Date(ms).toLocaleString(dateLocale(), { hour12: false });
}

function printMessage(m: ChatMessage): void {
  const who = m.role === "user" ? t("cli.who.user") : m.role === "assistant" ? t("cli.who.assistant") : "·";
  console.log(t("cli.msgLine", { who, proactive: m.proactive ? t("cli.proactive") : "", text: m.text }));
}

async function chat(): Promise<void> {
  const c = await client();
  const hello = await c.call("hello", { client: "cli", version: VERSION });
  const one = args.join(" ").trim();
  let streaming: string | null = null;
  let waitingReply = false;
  let acked = false;
  let sawBusy = false;
  let sawIdle = false;
  let done: (() => void) | null = null;

  c.onEvent = (event, data) => {
    if (event === "chat.delta") {
      if (streaming !== data.id) {
        streaming = data.id;
        process.stdout.write(t("cli.assistantPrefix"));
      }
      process.stdout.write(data.text);
    } else if (event === "chat.message") {
      const m = data as ChatMessage;
      if (m.role === "user" && m.channel === "cli") return;
      if (streaming && m.id === streaming) {
        process.stdout.write("\n");
        streaming = null;
      } else {
        printMessage(m);
      }
    } else if (event === "status") {
      sawIdle = !data.busy && sawBusy;
      if (data.busy) sawBusy = true;
      if (waitingReply && sawIdle && acked) {
        waitingReply = false;
        done?.();
      }
    }
  };

  if (one) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    await new Promise<void>((resolve) => {
      done = resolve;
      waitingReply = true;
      c.call("chat.send", { text: one })
        .then(() => {
          acked = true;
          // the turn may already be over (or it was a command with no turn)
          if (!sawBusy || sawIdle) setTimeout(() => (waitingReply && (sawIdle || !sawBusy) ? resolve() : undefined), 300);
        })
        .catch((e) => {
          console.error(e.message);
          resolve();
        });
      timer = setTimeout(resolve, 10 * 60_000);
    });
    clearTimeout(timer);
    c.close();
    process.exit(0);
  }

  console.log(t("cli.connected", { host: hello.hostName }));
  const sync = await c.call("sync", {});
  for (const m of (sync.messages as ChatMessage[]).slice(-10)) printMessage(m);
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: "" });
  rl.on("line", async (line) => {
    const text = line.trim();
    if (!text) return;
    try {
      if (text === "/quit" || text === "/exit") {
        rl.close();
        c.close();
        process.exit(0);
      } else if (text === "/tasks") {
        printTasks((await c.call("sync", {})).tasks);
      } else if (text === "/approvals") {
        printApprovals((await c.call("sync", {})).approvals);
      } else if (/^\/(y|n)\s+\S+/.test(text)) {
        const [, yn, id] = /^\/(y|n)\s+(\S+)/.exec(text)!;
        const r = await c.call("approval.answer", { id: await resolveApprovalId(c, id!), allow: yn === "y" });
        console.log(`· ${r.status}`);
      } else {
        await c.call("chat.send", { text });
      }
    } catch (e) {
      console.error(`· ${(e as Error).message}`);
    }
  });
  await new Promise(() => {});
}

async function resolveApprovalId(c: LocalClient, short: string): Promise<string> {
  if (!short.trim()) throw new Error(t("cli.needApprovalId"));
  const sync = await c.call("sync", {});
  const hit = sync.approvals.find((a: any) => a.id === short || a.id.endsWith(short));
  return hit?.id ?? short;
}

function printTasks(tasks: Task[]): void {
  if (!tasks.length) return console.log(t("cli.noTasks"));
  const icon: Record<string, string> = { running: "⏳", done: "✅", failed: "⚠️", needs_input: "🙋", stopped: "⏹" };
  for (const t of tasks.slice(0, 30)) {
    console.log(`${icon[t.status] ?? "·"} ${t.id}  ${t.title}${t.summary ? ` — ${t.summary}` : ""}  (${fmtTime(t.updatedAt)})`);
  }
}

function printApprovals(list: any[]): void {
  const pending = list.filter((a) => a.status === "pending");
  if (!pending.length) return console.log(t("cli.noApprovals"));
  for (const a of pending) {
    console.log(`🔐 ${a.id.slice(-4)}  ${a.title}${a.careful ? t("cli.careful") : ""}\n    ${a.detail}`);
  }
}

function printWatches(list: Watch[]): void {
  if (!list.length) return console.log(t("cli.noWatches"));
  for (const w of list) {
    const when = scheduleText(w);
    console.log(`${w.enabled ? "●" : "○"} ${w.id}  ${w.title}  [${when}]  ${w.createdBy === "agent" ? t("cli.byAssistant") : ""}\n    ${w.instruction}`);
  }
}

function flag(name: string): boolean {
  return args.includes(name);
}

async function main(): Promise<void> {
  switch (cmd) {
    case "help":
    case "--help":
    case "-h":
      console.log(helpText());
      return;
    case "--version":
    case "version":
      console.log(VERSION);
      return;
    case "selftest": {
      // The updater smoke-runs a staged release with this: every module loads.
      await import("./daemon.ts");
      await import("./hub.ts");
      await import("./setup.ts");
      console.log("ok");
      return;
    }
    case "update":
      return updateCmd();
    case "setup":
      await runSetup(paths, args);
      return;
    case "start": {
      if (existsSync(paths.socket)) {
        try {
          const c = await LocalClient.connect(paths.socket);
          c.close();
          console.error(t("cli.alreadyRunning"));
          process.exit(1);
        } catch {
          /* stale socket */
        }
      }
      // One bad promise must never take the assistant down.
      process.on("unhandledRejection", (e) => console.error("[daemon] unhandled rejection:", e));
      process.on("uncaughtException", (e) => console.error("[daemon] uncaught exception:", e));
      // A just-applied update: count the attempt, roll back if it keeps dying.
      const bootPaths = { update: paths.update, chat: paths.chat, audit: paths.audit };
      const boot = bootCheck(bootPaths);
      if (boot.rolledBack) {
        console.error(t("cli.updateRolledBack"));
        process.exit(1);
      }
      cleanStaging(paths.updateStaging);
      let d: Awaited<ReturnType<typeof startDaemon>>;
      try {
        d = await startDaemon(paths);
      } catch (e) {
        if (boot.pending) {
          rollbackSync(bootPaths, t("cli.updateBootError", { detail: e instanceof Error ? e.message.split("\n")[0]! : String(e) }));
          console.error(t("cli.updateBootErrorRolledBack"));
          process.exit(1);
        }
        throw e;
      }
      if (boot.pending) {
        const t = setTimeout(() => {
          confirmUpdate(bootPaths, {
            note: (text) => d.hub.chat.add({ role: "system", kind: "notice", text, channel: "system" }),
            audit: (type, data) => d.hub.audit.log(type, data),
          });
        }, HEALTHY_AFTER_MS);
        (t as any).unref?.();
      }
      console.log(t("cli.running", { version: VERSION, home: paths.home }));
      if (d.relay) console.log(t("cli.remoteId", { id: d.relay.daemonId }));
      const shutdown = () => {
        d.stop();
        process.exit(0);
      };
      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);
      return;
    }
    case "chat":
      return chat();
    case "status": {
      const c = await client();
      const hello = await c.call("hello", { client: "cli", version: VERSION });
      const relay = await c.call("relay.status");
      const wechat = await c.call("wechat.status");
      const usage = await c.call("usage");
      const sync = await c.call("sync", {});
      const push = await c.call("push.status").catch(() => null);
      const probe = await c.call("probe.status").catch(() => null);
      const power = await c.call("power.status").catch(() => null);
      const update = await c.call("update.status").catch(() => null);
      c.close();
      const s = hello.status;
      console.log(t("cli.statusHead", { host: hello.hostName, busy: s.busy ? t("cli.busy") : t("cli.idle"), model: s.model || t("cli.modelDefault") }));
      if (update) console.log(t("cli.versionLine", { line: updateLine(update) }));
      console.log(
        t("cli.statusCounts", {
          running: sync.tasks.filter((x: Task) => x.status === "running").length,
          pending: sync.approvals.filter((a: any) => a.status === "pending").length,
          watches: sync.watches.length,
        }),
      );
      const remote = relay.enabled ? `${t("cli.remoteOn", { state: relay.state, streams: relay.streams })}${relay.lastError ? " " + relay.lastError : ""}` : t("cli.remoteOff");
      console.log(t("cli.remoteLine", { remote, wechat: wechat.status }));
      if (push) console.log(t("cli.pushLine", { line: pushLine(push) }));
      if (probe) console.log(t("cli.probeLine", { line: probeLine(probe) }));
      const pl = power ? powerLine(power) : null;
      if (pl) console.log(t("cli.powerLine", { line: pl }));
      console.log(t("cli.todayCost", { main: `$${usage.mainUsd.toFixed(3)}`, probe: `$${usage.probeUsd.toFixed(4)}` }));
      return;
    }
    case "tasks": {
      if (args[0]) {
        const r = await call("task.get", { id: args[0] });
        console.log(`${r.task.title} [${r.task.status}] ${r.task.summary}`);
        for (const a of r.activity) console.log(`  ${fmtTime(a.ts)} ${a.kind}${a.tool ? ` ${a.tool}` : ""}: ${a.text}`);
        return;
      }
      printTasks((await call("sync", {})).tasks);
      return;
    }
    case "approvals":
      printApprovals((await call("sync", {})).approvals);
      return;
    case "approve":
    case "deny": {
      const c = await client();
      const id = await resolveApprovalId(c, args[0] ?? "");
      const r = await c.call("approval.answer", { id, allow: cmd === "approve", remember: flag("--remember") });
      c.close();
      console.log(r.status);
      return;
    }
    case "watch": {
      const sub = args[0] ?? "list";
      if (sub === "list") return printWatches((await call("sync", {})).watches);
      if (sub === "rm") return console.log((await call("watch.remove", { id: args[1] })).ok ? t("cli.removed") : t("cli.notFound"));
      if (sub === "on" || sub === "off") {
        await call("watch.update", { id: args[1], patch: { enabled: sub === "on" } });
        return console.log(t("cli.ok"));
      }
      if (sub === "add") {
        // paloally watch add "标题" "说明" [--every 60] [--at 08:30,22:30]
        const title = args[1];
        const instruction = args[2];
        const every = args.indexOf("--every");
        const at = args.indexOf("--at");
        const r = await call("watch.add", {
          title,
          instruction,
          kind: at >= 0 ? "schedule" : "check",
          intervalMinutes: every >= 0 ? Number(args[every + 1]) : undefined,
          at: at >= 0 ? args[at + 1]!.split(",") : undefined,
        });
        return console.log(t("cli.watchAdded", { id: r.watch.id }));
      }
      console.log(t("cli.watchUsage"));
      return;
    }
    case "artifacts": {
      const { artifacts } = await call("artifact.list");
      if (!artifacts.length) return console.log(t("cli.noArtifacts"));
      for (const a of artifacts) console.log(`${a.pinned ? "📌" : "  "} ${a.id}  ${a.title}  (${a.type}, ${fmtTime(a.updatedAt)})  ${paths.artifacts}/${a.id}/${a.mainFile}`);
      return;
    }
    case "memory": {
      if (args[0]) return console.log((await call("memory.read", { path: args[0] })).content);
      const { files, coreSize } = await call("memory.list");
      for (const f of files) console.log(`${f.scope === "core" ? t("cli.memCore") : t("cli.memNote")}  ${f.path}  ${f.size}B  ${fmtTime(f.updatedAt)}`);
      if (coreSize > CORE_SOFT_LIMIT) console.log(t("cli.coreBig", { size: coreSize, limit: CORE_SOFT_LIMIT }));
      return;
    }
    case "settings": {
      if (args.length >= 2) {
        const [key, ...rest] = args;
        const raw = rest.join(" ");
        let value: unknown = raw;
        if (key === "quietHours") value = raw === "off" ? null : { start: raw.split("-")[0], end: raw.split("-")[1] };
        else if (/^\d+(\.\d+)?$/.test(raw)) value = Number(raw);
        const r = await call("settings.update", { patch: { [key!]: value } });
        if (key === "language" && isLang(r.settings.language)) {
          setLang(r.settings.language);
          return console.log(t("cli.languageSet"));
        }
        return console.log(JSON.stringify(r.settings, null, 2));
      }
      console.log(JSON.stringify((await call("sync", {})).settings, null, 2));
      return;
    }
    // `auth expire`: acts as if Claude Code's login ran out (to try signing in again from the phone).
    case "auth": {
      if (args[0] !== "expire") throw new Error("usage: paloally auth expire");
      console.log(JSON.stringify(await call("auth.expire", {})));
      return;
    }
    case "restart": {
      const now = flag("--now");
      if (!now) console.log(t("cli.restartWait"));
      const c = await client();
      const r = await c.call("restart", { now }).catch(() => ({ status: "restarting" }));
      c.close();
      console.log(r.status === "timeout" ? t("cli.restartTimeout") : t("cli.restarting"));
      return;
    }
    case "sessions": {
      // The computer's Claude Code sessions; `sessions hooks on|off` is the app's 会话 switch.
      if (args[0] === "hooks") {
        const enabled = args[1] === "on" ? true : args[1] === "off" ? false : undefined;
        const r = await call("sessions.hooks", enabled === undefined ? {} : { enabled });
        console.log(r.enabled ? t("cli.hooksOn") : t("cli.hooksOff"));
        return;
      }
      const r = await call("pals.list");
      const kind: Record<string, string> = { terminal: t("cli.kind.terminal"), background: t("cli.kind.background") };
      const status: Record<string, string> = { busy: t("cli.st.busy"), idle: t("cli.st.idle"), waiting: t("cli.st.waiting"), stopped: t("cli.st.stopped"), starting: t("cli.st.starting") };
      if (r.pals.length) console.log(t("cli.palsHead", { note: r.helper ? "" : t("cli.palsNoHelper") }));
      for (const p of r.pals)
        console.log(`${status[p.status] ?? p.status} ${p.name}  ${p.cwd}${p.pending ? t("cli.palWaiting", { n: p.pending }) : ""}${p.note ? `\n    ${p.note}` : ""}${p.lastLine ? `\n    ${p.lastLine}` : ""}`);
      if (!r.others.length) console.log(r.pals.length ? t("cli.othersNoneMore") : t("cli.othersNone"));
      else console.log(t("cli.othersHead"));
      for (const x of r.others)
        console.log(`${status[x.status] ?? x.status} ${x.name}（${kind[x.kind] ?? x.kind}）  ${x.cwd}${x.waitingFor ? `\n    ${t("cli.waitingFor", { what: x.waitingFor })}` : ""}${x.lastLine ? `\n    ${x.lastLine}` : ""}`);
      console.log(t("cli.hooksState", { state: r.hooks ? t("cli.on") : t("cli.off") }));
      return;
    }
    case "stop":
      await call("stop");
      console.log(t("cli.stopped"));
      return;
    case "audit": {
      const { entries } = await call("audit.tail", { limit: Number(args[0] ?? 30) });
      for (const e of entries) {
        const { ts, type, ...rest } = e;
        console.log(`${fmtTime(ts)} ${type} ${JSON.stringify(rest)}`);
      }
      return;
    }
    case "pair": {
      const r = await call("pair.open", { ttl: 180 });
      const qrcode = (await import("qrcode-terminal")).default;
      qrcode.generate(r.link, { small: true });
      console.log(t("cli.pairScan", { min: Math.round(r.ttl / 60) }));
      // On its own line, so a terminal makes it clickable and it copies whole.
      console.log(t("cli.pairLink", { link: r.link }));
      console.log(t("cli.pairCode", { code: r.code }));
      return;
    }
    case "devices": {
      if (args[0] === "rm") return console.log((await call("devices.remove", { id: args[1] })).ok ? t("cli.deviceRemoved") : t("cli.notFound"));
      const { devices } = await call("devices.list");
      if (!devices.length) return console.log(t("cli.noDevices"));
      for (const d of devices) console.log(t("cli.deviceLine", { id: d.deviceId, label: d.label, paired: fmtTime(d.pairedAt), seen: fmtTime(d.lastSeen) }));
      return;
    }
    case "wechat":
      return wechatCmd();
    case "service": {
      const sub = args[0] ?? "status";
      if (sub === "install") return console.log(installService(paths));
      if (sub === "uninstall") return console.log(uninstallService());
      return console.log(serviceStatus());
    }
    case "metrics": {
      const { phase0Report } = await import("./metrics.ts");
      console.log(phase0Report(paths, Number(args[0] ?? 7), loadConfig(paths).settings.timezone));
      return;
    }
    case "doctor":
      return doctor();
    default:
      console.log(helpText());
      process.exit(1);
  }
}

// paloally update [--check] [--now]: through the running assistant when there is
// one (it switches once idle), else directly on the checkout.
async function updateCmd(): Promise<void> {
  const check = flag("--check");
  const now = flag("--now");
  if (existsSync(paths.socket)) {
    try {
      const c = await LocalClient.connect(paths.socket);
      if (!check) console.log(now ? t("cli.updating") : t("cli.updateChecking"));
      const r = await c.call<any>("host.update", { check, now, wait: !now });
      c.close();
      return printUpdate(r);
    } catch {
      /* not running: update the files directly */
    }
  }
  const cfg = loadConfig(paths);
  const u = new Updater({
    statePath: paths.update,
    stagingRoot: paths.updateStaging,
    config: () => cfg.update,
    cleanBreak: () => true,
    quiet: () => true,
    underService: () => false,
    audit: () => undefined,
    exit: () => undefined,
  });
  const r = await u.updateNow({ check, now: true });
  printUpdate(r.status === "updating" ? { ...r, detail: t("cli.updateFilesSwapped") } : r);
}

function printUpdate(r: { status: string; current: string; latest?: string; detail?: string }): void {
  const head =
    r.status === "updating" ? t("cli.upd.updating", { latest: r.latest ?? t("cli.upd.newVersion") })
    : r.status === "latest" ? t("cli.upd.latest", { current: r.current })
    : r.status === "available" ? t("cli.upd.available", { latest: r.latest ?? "", current: r.current })
    : r.status === "dirty" ? t("cli.upd.dirty")
    : `${r.detail ?? r.status}`;
  console.log(head);
  if (r.detail && !head.includes(r.detail) && r.status !== "available" && r.status !== "latest") console.log(r.detail);
}

async function wechatCmd(): Promise<void> {
  scaffoldHome(paths);
  const cfg = loadConfig(paths);
  const sub = args[0] ?? "status";
  const w = new WechatILink(paths.wechat, cfg.wechat.baseUrl);
  if (sub === "login") {
    const { qrcode, qrUrl } = await w.beginLogin();
    (await import("qrcode-terminal")).default.generate(qrUrl, { small: true });
    console.log(t("cli.wechatScan"));
    const ok = await w.waitLogin(qrcode, 5 * 60_000, (s) => console.log(`· ${s}`));
    if (!ok) return console.log(t("cli.wechatFailed"));
    cfg.wechat.enabled = true;
    saveConfig(paths, cfg);
    console.log(t("cli.wechatConnected"));
    return;
  }
  if (sub === "logout") {
    w.logout();
    cfg.wechat.enabled = false;
    saveConfig(paths, cfg);
    return console.log(t("cli.wechatOut"));
  }
  console.log(cfg.wechat.enabled ? (w.loggedIn ? t("cli.wechatLoggedIn") : t("cli.wechatNotLoggedIn")) : t("cli.wechatOff"));
}

function pushLine(p: { health: { at: number; ok: boolean; detail: string } | null; devices: number }): string {
  const devices = p.devices ? t("cli.push.devices", { n: p.devices }) : t("cli.push.noDevices");
  if (!p.health) return t("cli.push.never", { devices });
  const when = new Date(p.health.at).toLocaleString(dateLocale(), { hour12: false });
  return t("cli.push.last", { devices, result: p.health.ok ? t("cli.push.ok") : t("cli.push.fail"), when, detail: p.health.detail });
}

function probeLine(p: { checks: number; lastRunAt?: number; failing: number; stale: number; reasons: string[]; budgetUsd: number; spentUsd: number }): string {
  if (!p.checks) return t("cli.probe.none");
  const ago = p.lastRunAt ? t("cli.probe.ago", { min: Math.max(0, Math.round((Date.now() - p.lastRunAt) / 60_000)) }) : t("cli.probe.never");
  const trouble = p.failing ? t("cli.probe.trouble", { n: p.failing, reasons: p.reasons.join(getLang() === "zh" ? "；" : "; ") }) : t("cli.probe.noTrouble");
  return t("cli.probe.line", { checks: p.checks, ago, trouble, spent: `$${p.spentUsd.toFixed(2)}`, budget: `$${p.budgetUsd}` });
}

async function doctor(): Promise<void> {
  const { runDoctor } = await import("./setup.ts");
  const ok = await runDoctor(paths);
  process.exit(ok ? 0 : 1);
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
