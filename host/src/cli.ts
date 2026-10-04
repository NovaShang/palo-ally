import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { LocalClient } from "./channels/local.ts";
import { WechatILink } from "./channels/wechat.ts";
import { Paths, VERSION, defaultRoot, loadConfig, saveConfig } from "./config.ts";
import { startDaemon } from "./daemon.ts";
import { scaffoldHome } from "./home.ts";
import { CORE_SOFT_LIMIT } from "./memory.ts";
import { installService, serviceStatus, uninstallService } from "./service.ts";
import { runSetup } from "./setup.ts";
import type { ChatMessage, Task, Watch } from "./types.ts";

const paths = new Paths(defaultRoot());
const [cmd = "help", ...args] = process.argv.slice(2);

const HELP = `PaloAlly ${VERSION} — 把 Claude Code 变成常驻、会主动找你、记得你的私人助理

用法：paloally <命令>

  setup                  第一次使用：检查依赖、生成 home、配置、配对手机
  start                  前台运行助理（daemon）
  service install|uninstall|status   装成开机常驻服务（launchd / systemd）
  chat [消息]            在终端里跟助理说话（不带消息则进入对话）
  status                 助理现在在干嘛
  tasks [id]             任务列表 / 某个任务的详情
  approvals              待确认的操作
  approve <id> [--remember] / deny <id>
  rules [rm <id>]        自动批准规则
  watch [list|add|rm|on|off] 盯梢与定时
  artifacts              产物资料库
  memory [路径]          记忆文件
  settings [key value]   打扰频率、免打扰时段等
  kill / resume          急停 / 恢复
  restart [--now]        等手头的事办完再重启（--now 立刻重启，会打断正在办的事）
  audit [n]              审计日志
  metrics [天数]         Phase 0 验收数据（主动频率、任务、压缩、花费）
  pair                   配对手机 App
  devices [rm <id>]      已配对的设备
  wechat login|logout|status   微信入口
  doctor                 体检
`;

async function client(): Promise<LocalClient> {
  if (!existsSync(paths.socket)) {
    console.error("助理没在运行。先 `paloally start`（或 `paloally service install`）。");
    process.exit(1);
  }
  try {
    return await LocalClient.connect(paths.socket);
  } catch {
    console.error("连不上助理（socket 存在但没响应）。试试重启：paloally start");
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
  return new Date(ms).toLocaleString("zh-CN", { hour12: false });
}

function printMessage(m: ChatMessage): void {
  const who = m.role === "user" ? "你" : m.role === "assistant" ? "助理" : "·";
  console.log(`${who}${m.proactive ? "（主动）" : ""}：${m.text}`);
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
        process.stdout.write("助理：");
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

  console.log(`已连上 ${hello.hostName}。直接打字说话；/tasks /approvals /y <id> /n <id> /kill /resume /quit`);
  const sync = await c.call("sync", {});
  for (const m of (sync.messages as ChatMessage[]).slice(-10)) printMessage(m);
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: "" });
  rl.on("line", async (line) => {
    const t = line.trim();
    if (!t) return;
    try {
      if (t === "/quit" || t === "/exit") {
        rl.close();
        c.close();
        process.exit(0);
      } else if (t === "/tasks") {
        printTasks((await c.call("sync", {})).tasks);
      } else if (t === "/approvals") {
        printApprovals((await c.call("sync", {})).approvals);
      } else if (/^\/(y|n)\s+\S+/.test(t)) {
        const [, yn, id] = /^\/(y|n)\s+(\S+)/.exec(t)!;
        const r = await c.call("approval.answer", { id: await resolveApprovalId(c, id!), allow: yn === "y" });
        console.log(`· ${r.status}`);
      } else {
        await c.call("chat.send", { text: t });
      }
    } catch (e) {
      console.error(`· ${(e as Error).message}`);
    }
  });
  await new Promise(() => {});
}

async function resolveApprovalId(c: LocalClient, short: string): Promise<string> {
  const sync = await c.call("sync", {});
  const hit = sync.approvals.find((a: any) => a.id === short || a.id.endsWith(short));
  return hit?.id ?? short;
}

function printTasks(tasks: Task[]): void {
  if (!tasks.length) return console.log("还没有任务。");
  const icon: Record<string, string> = { running: "⏳", done: "✅", failed: "⚠️", needs_input: "🙋", stopped: "⏹" };
  for (const t of tasks.slice(0, 30)) {
    console.log(`${icon[t.status] ?? "·"} ${t.id}  ${t.title}${t.summary ? ` — ${t.summary}` : ""}  (${fmtTime(t.updatedAt)})`);
  }
}

function printApprovals(list: any[]): void {
  const pending = list.filter((a) => a.status === "pending");
  if (!pending.length) return console.log("没有待确认的操作。");
  for (const a of pending) {
    console.log(`🔐 ${a.id.slice(-4)}  ${a.title}${a.irreversible ? "（不可撤销）" : ""}\n    ${a.detail}`);
  }
}

function printWatches(list: Watch[]): void {
  if (!list.length) return console.log("还没有盯梢。");
  for (const w of list) {
    const when = w.kind === "schedule" ? (w.at?.join(", ") ?? `每 ${w.intervalMinutes} 分钟`) : `每 ${w.intervalMinutes} 分钟检查`;
    console.log(`${w.enabled ? "●" : "○"} ${w.id}  ${w.title}  [${when}]  ${w.createdBy === "agent" ? "（助理登记）" : ""}\n    ${w.instruction}`);
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
      console.log(HELP);
      return;
    case "--version":
    case "version":
      console.log(VERSION);
      return;
    case "setup":
      await runSetup(paths, args);
      return;
    case "start": {
      if (existsSync(paths.socket)) {
        try {
          const c = await LocalClient.connect(paths.socket);
          c.close();
          console.error("助理已经在运行了。");
          process.exit(1);
        } catch {
          /* stale socket */
        }
      }
      // One bad promise must never take the assistant down.
      process.on("unhandledRejection", (e) => console.error("[daemon] unhandled rejection:", e));
      process.on("uncaughtException", (e) => console.error("[daemon] uncaught exception:", e));
      const d = await startDaemon(paths);
      console.log(`PaloAlly ${VERSION} 在运行。home: ${paths.home}`);
      if (d.relay) console.log(`远程 ID: ${d.relay.daemonId}（配对手机：paloally pair）`);
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
      c.close();
      const s = hello.status;
      console.log(`${hello.hostName} · ${s.killed ? "🛑 急停中" : s.busy ? "忙" : "空闲"} · 模型 ${s.model || "默认"}`);
      console.log(`进行中任务 ${sync.tasks.filter((t: Task) => t.status === "running").length} · 待确认 ${sync.approvals.filter((a: any) => a.status === "pending").length} · 盯梢 ${sync.watches.length}`);
      console.log(`远程：${relay.enabled ? `${relay.state}（${relay.streams} 个设备在线）${relay.lastError ? " " + relay.lastError : ""}` : "关闭"} · 微信：${wechat.status}`);
      console.log(`今日花费：主对话 $${usage.mainUsd.toFixed(3)} · 探针 $${usage.probeUsd.toFixed(4)}`);
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
    case "rules": {
      if (args[0] === "rm") return console.log((await call("approval.removeRule", { id: args[1] })).ok ? "已删除" : "没找到");
      const { rules } = await call("approval.rules");
      if (!rules.length) return console.log("没有自动批准规则。");
      for (const r of rules) console.log(`${r.id}  ${r.tool}  ${r.scope}`);
      return;
    }
    case "watch": {
      const sub = args[0] ?? "list";
      if (sub === "list") return printWatches((await call("sync", {})).watches);
      if (sub === "rm") return console.log((await call("watch.remove", { id: args[1] })).ok ? "已删除" : "没找到");
      if (sub === "on" || sub === "off") {
        await call("watch.update", { id: args[1], patch: { enabled: sub === "on" } });
        return console.log("好");
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
        return console.log(`已添加 ${r.watch.id}`);
      }
      console.log("用法：paloally watch [list|add <标题> <说明> [--every 分钟|--at HH:MM,...]|rm <id>|on <id>|off <id>]");
      return;
    }
    case "artifacts": {
      const { artifacts } = await call("artifact.list");
      if (!artifacts.length) return console.log("资料库是空的。");
      for (const a of artifacts) console.log(`${a.pinned ? "📌" : "  "} ${a.id}  ${a.title}  (${a.type}, ${fmtTime(a.updatedAt)})  ${paths.artifacts}/${a.id}/${a.mainFile}`);
      return;
    }
    case "memory": {
      if (args[0]) return console.log((await call("memory.read", { path: args[0] })).content);
      const { files, coreSize } = await call("memory.list");
      for (const f of files) console.log(`${f.scope === "core" ? "核心" : "记忆"}  ${f.path}  ${f.size}B  ${fmtTime(f.updatedAt)}`);
      if (coreSize > CORE_SOFT_LIMIT) console.log(`⚠️ 核心文件共 ${coreSize} 字节，偏大（建议 < ${CORE_SOFT_LIMIT}），啰嗦的内容挪进记忆。`);
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
        return console.log(JSON.stringify(r.settings, null, 2));
      }
      console.log(JSON.stringify((await call("sync", {})).settings, null, 2));
      return;
    }
    case "restart": {
      const now = flag("--now");
      if (!now) console.log("等手头的事办完再重启（最多等 30 分钟）…");
      const c = await client();
      const r = await c.call("restart", { now }).catch(() => ({ status: "restarting" }));
      c.close();
      console.log(r.status === "timeout" ? "等了 30 分钟还在忙，没重启。要强制重启：paloally restart --now" : "重启中。");
      return;
    }
    case "kill":
      await call("kill");
      console.log("🛑 已急停。所有操作停下并拒绝，直到 paloally resume。");
      return;
    case "resume":
      await call("resume");
      console.log("已恢复。");
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
      console.log(`\n用 PaloAlly App 扫描上面的二维码（${Math.round(r.ttl / 60)} 分钟内有效）。`);
      console.log(`或在 App 里粘贴：${r.link}`);
      console.log(`配对码：${r.code}`);
      return;
    }
    case "devices": {
      if (args[0] === "rm") return console.log((await call("devices.remove", { id: args[1] })).ok ? "已移除" : "没找到");
      const { devices } = await call("devices.list");
      if (!devices.length) return console.log("还没配对设备。paloally pair");
      for (const d of devices) console.log(`${d.deviceId}  ${d.label}  配对于 ${fmtTime(d.pairedAt)}  最近 ${fmtTime(d.lastSeen)}`);
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
      console.log(HELP);
      process.exit(1);
  }
}

async function wechatCmd(): Promise<void> {
  scaffoldHome(paths);
  const cfg = loadConfig(paths);
  const sub = args[0] ?? "status";
  const w = new WechatILink(paths.wechat, cfg.wechat.baseUrl);
  if (sub === "login") {
    const { qrcode, qrUrl } = await w.beginLogin();
    (await import("qrcode-terminal")).default.generate(qrUrl, { small: true });
    console.log("用微信扫码，并在手机上确认。");
    const ok = await w.waitLogin(qrcode, 5 * 60_000, (s) => console.log(`· ${s}`));
    if (!ok) return console.log("没有登录成功（二维码过期或超时）。");
    cfg.wechat.enabled = true;
    saveConfig(paths, cfg);
    console.log("微信已连上。重启助理生效（paloally service install 会自动重启）。给 bot 发第一条消息后，它就认你做主人。");
    return;
  }
  if (sub === "logout") {
    w.logout();
    cfg.wechat.enabled = false;
    saveConfig(paths, cfg);
    return console.log("已断开微信。");
  }
  console.log(cfg.wechat.enabled ? (w.loggedIn ? "已登录" : "已启用但未登录（paloally wechat login）") : "未启用");
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
