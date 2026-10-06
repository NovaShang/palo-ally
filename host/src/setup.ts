import { existsSync, statSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { LocalClient } from "./channels/local.ts";
import { loadHostIdentity } from "./channels/relay.ts";
import { type Config, type Paths, VERSION, loadConfig, saveConfig } from "./config.ts";
import { scaffoldHome } from "./home.ts";
import { CORE_FILES, CORE_SOFT_LIMIT } from "./memory.ts";
import { serviceStatus } from "./service.ts";

type Check = { name: string; ok: boolean; detail: string; fix?: string };

// checkHarness makes one tiny real call so onboarding proves the model works,
// whichever way the user authenticates (claude.ai login, API key, or a
// third-party Anthropic-compatible endpoint via ANTHROPIC_BASE_URL).
export async function checkHarness(cfg: Config, cwd: string): Promise<Check> {
  try {
    let text = "";
    let err = "";
    for await (const m of query({
      prompt: "只回复两个字母：ok",
      options: { cwd, model: cfg.probeModel, maxTurns: 1, tools: [], settingSources: [], persistSession: false, env: { ...process.env, ...cfg.env } },
    })) {
      const msg = m as any;
      if (msg.type === "result") {
        if (msg.subtype === "success") text = msg.result ?? "";
        else err = msg.errors?.join("; ") ?? msg.subtype;
      }
    }
    if (err) return { name: "模型连通", ok: false, detail: err, fix: authFix() };
    return { name: "模型连通", ok: /ok/i.test(text), detail: `探针模型 ${cfg.probeModel} 回复：${text.slice(0, 20)}` };
  } catch (e) {
    return { name: "模型连通", ok: false, detail: String(e instanceof Error ? e.message : e).slice(0, 300), fix: authFix() };
  }
}

function authFix(): string {
  return "三选一：① 运行 `claude` 并 /login（claude.ai 订阅）② export ANTHROPIC_API_KEY=… ③ 第三方模型：在 ~/.paloally/config.json 的 env 里设 ANTHROPIC_BASE_URL 和 ANTHROPIC_AUTH_TOKEN，并把 model/probeModel 改成对方的模型名";
}

export async function runDoctor(paths: Paths, opts: { live?: boolean } = { live: true }): Promise<boolean> {
  const checks: Check[] = [];
  const cfg = loadConfig(paths);
  checks.push({ name: "运行时", ok: typeof Bun !== "undefined", detail: `bun ${Bun.version} · paloally ${VERSION}` });
  checks.push({ name: "home 目录", ok: existsSync(paths.claudeMd), detail: paths.home, fix: "paloally setup" });
  const core = CORE_FILES.reduce((n, f) => n + (existsSync(`${paths.home}/${f}`) ? statSync(`${paths.home}/${f}`).size : 0), 0);
  checks.push({
    name: "核心记忆大小",
    ok: core <= CORE_SOFT_LIMIT,
    detail: `${core} 字节`,
    fix: `精简 user.md / soul.md 到 ${CORE_SOFT_LIMIT} 字节以内，零碎内容交给记忆`,
  });
  let running = false;
  if (existsSync(paths.socket)) {
    try {
      const c = await LocalClient.connect(paths.socket);
      const relay = await c.call("relay.status");
      const push = await c.call("push.status").catch(() => null);
      const probe = await c.call("probe.status").catch(() => null);
      c.close();
      running = true;
      if (relay.enabled)
        checks.push({ name: "远程连接", ok: relay.state === "connected", detail: `${relay.state} ${relay.lastError ?? ""}`.trim(), fix: "检查网络；或在 config.json 关闭 relay" });
      if (push?.health)
        checks.push({
          name: "推送",
          ok: push.health.ok,
          detail: `${push.health.ok ? "上次成功" : "上次失败"}：${push.health.detail}`,
          fix: "推送不通时提醒会改走微信，或只留在 App 对话里",
        });
      // Check watches exist but none ran within twice its interval: the goals
      // have gone quiet (budget used up, the probe failing, the timer stuck).
      if (probe?.checks)
        checks.push({
          name: "探针",
          ok: probe.stale === 0,
          detail: probe.stale
            ? `${probe.stale}/${probe.checks} 个盯梢超过两个周期没查了${probe.reasons.length ? `：${probe.reasons.join("；")}` : ""}`
            : `${probe.checks} 个盯梢按时在查${probe.failing ? `（${probe.failing} 个上次没查成：${probe.reasons.join("；")}）` : ""}`,
          fix: `今日探针花费 $${probe.spentUsd.toFixed(2)} / 预算 $${probe.budgetUsd}：预算用完就调高 config.json 的 budget.probeDailyUsd；其他原因看 ~/.paloally/logs/daemon.log 里的 probe 行`,
        });
    } catch {
      /* not running */
    }
  }
  checks.push({ name: "助理进程", ok: running, detail: running ? "在运行" : serviceStatus(), fix: "paloally service install（或 paloally start）" });
  if (opts.live) checks.push(await checkHarness(cfg, paths.home));

  for (const c of checks) {
    console.log(`${c.ok ? "✅" : "❌"} ${c.name}：${c.detail}${!c.ok && c.fix ? `\n   → ${c.fix}` : ""}`);
  }
  return checks.every((c) => c.ok);
}

export async function runSetup(paths: Paths, args: string[]): Promise<void> {
  const yes = args.includes("--yes") || !process.stdin.isTTY;
  console.log(`PaloAlly ${VERSION} 初始化\n`);
  const created = scaffoldHome(paths);
  for (const f of created) console.log(`· 生成 ${f}`);
  const cfg = loadConfig(paths);
  const rl = yes ? null : createInterface({ input: process.stdin, output: process.stdout });
  const ask = async (q: string, def: string) => {
    if (!rl) return def;
    const a = (await rl.question(`${q} [${def}] `)).trim();
    return a || def;
  };

  cfg.hostName = await ask("给这台机器起个名字", cfg.hostName);
  cfg.settings.timezone = await ask("你的时区", cfg.settings.timezone);
  const quiet = await ask("免打扰时段（off 关闭）", cfg.settings.quietHours ? `${cfg.settings.quietHours.start}-${cfg.settings.quietHours.end}` : "off");
  cfg.settings.quietHours = quiet === "off" ? null : { start: quiet.split("-")[0]!, end: quiet.split("-")[1]! };
  const third = await ask("用第三方模型（GLM / Kimi / DeepSeek 等 Anthropic 兼容接口）吗？y/n", cfg.env?.ANTHROPIC_BASE_URL ? "y" : "n");
  if (third === "y") {
    cfg.env = cfg.env ?? {};
    cfg.env.ANTHROPIC_BASE_URL = await ask("接口地址 ANTHROPIC_BASE_URL", cfg.env.ANTHROPIC_BASE_URL ?? "");
    cfg.env.ANTHROPIC_AUTH_TOKEN = await ask("密钥 ANTHROPIC_AUTH_TOKEN", cfg.env.ANTHROPIC_AUTH_TOKEN ?? "");
    cfg.model = (await ask("主对话模型名", cfg.model ?? "")) || undefined;
    cfg.probeModel = await ask("探针用的便宜模型名", cfg.probeModel);
  }
  saveConfig(paths, cfg);
  loadHostIdentity(paths.identity);
  rl?.close();

  console.log("\n检查模型能不能用（发一条很短的测试消息）…");
  const check = await checkHarness(cfg, paths.home);
  console.log(`${check.ok ? "✅" : "❌"} ${check.detail}${!check.ok && check.fix ? `\n   → ${check.fix}` : ""}`);

  console.log(`
下一步：
  1. paloally service install     # 装成常驻服务（或前台 paloally start）
  2. paloally pair                # 用手机 App 扫码配对
  3. paloally wechat login        # 可选：开微信入口
  4. 编辑 ${paths.userMd}（关于你，保持精简）
`);
}
