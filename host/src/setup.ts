import { existsSync, statSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { LocalClient } from "./channels/local.ts";
import { loadHostIdentity } from "./channels/relay.ts";
import { type Config, type Paths, VERSION, loadConfig, saveConfig } from "./config.ts";
import { scaffoldHome } from "./home.ts";
import { CORE_FILES, CORE_SOFT_LIMIT } from "./memory.ts";
import { serviceStatus } from "./service.ts";
import { getLang, t } from "./i18n/index.ts";

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
    if (err) return { name: t("setup.model"), ok: false, detail: err, fix: authFix() };
    return { name: t("setup.model"), ok: /ok/i.test(text), detail: t("setup.modelReply", { model: cfg.probeModel, text: text.slice(0, 20) }) };
  } catch (e) {
    return { name: t("setup.model"), ok: false, detail: String(e instanceof Error ? e.message : e).slice(0, 300), fix: authFix() };
  }
}

function authFix(): string {
  return t("setup.authFix");
}

export async function runDoctor(paths: Paths, opts: { live?: boolean } = { live: true }): Promise<boolean> {
  const checks: Check[] = [];
  const cfg = loadConfig(paths);
  checks.push({ name: t("setup.runtime"), ok: typeof Bun !== "undefined", detail: `bun ${Bun.version} · paloally ${VERSION}` });
  checks.push({ name: t("setup.home"), ok: existsSync(paths.claudeMd), detail: paths.home, fix: "paloally setup" });
  const core = CORE_FILES.reduce((n, f) => n + (existsSync(`${paths.home}/${f}`) ? statSync(`${paths.home}/${f}`).size : 0), 0);
  checks.push({
    name: t("setup.coreSize"),
    ok: core <= CORE_SOFT_LIMIT,
    detail: t("setup.bytes", { n: core }),
    fix: t("setup.coreFix", { limit: CORE_SOFT_LIMIT }),
  });
  let running = false;
  const sep = getLang() === "zh" ? "；" : "; ";
  if (existsSync(paths.socket)) {
    try {
      const c = await LocalClient.connect(paths.socket);
      const relay = await c.call("relay.status");
      const push = await c.call("push.status").catch(() => null);
      const probe = await c.call("probe.status").catch(() => null);
      c.close();
      running = true;
      if (relay.enabled)
        checks.push({ name: t("setup.remote"), ok: relay.state === "connected", detail: `${relay.state} ${relay.lastError ?? ""}`.trim(), fix: t("setup.remoteFix") });
      if (push?.health)
        checks.push({
          name: t("setup.push"),
          ok: push.health.ok,
          detail: t(push.health.ok ? "setup.pushOk" : "setup.pushFail", { detail: push.health.detail }),
          fix: t("setup.pushFix"),
        });
      // Check watches exist but none ran within twice its interval: the goals
      // have gone quiet (budget used up, the probe failing, the timer stuck).
      if (probe?.checks)
        checks.push({
          name: t("setup.probe"),
          ok: probe.stale === 0,
          detail: probe.stale
            ? t("setup.probeStale", { stale: probe.stale, checks: probe.checks, reasons: probe.reasons.length ? t("setup.probeReasons", { reasons: probe.reasons.join(sep) }) : "" })
            : t("setup.probeOk", { checks: probe.checks, failing: probe.failing ? t("setup.probeFailing", { n: probe.failing, reasons: probe.reasons.join(sep) }) : "" }),
          fix: t("setup.probeFix", { spent: `$${probe.spentUsd.toFixed(2)}`, budget: `$${probe.budgetUsd}` }),
        });
    } catch {
      /* not running */
    }
  }
  checks.push({ name: t("setup.process"), ok: running, detail: running ? t("setup.processRunning") : serviceStatus(), fix: t("setup.processFix") });
  if (opts.live) checks.push(await checkHarness(cfg, paths.home));

  for (const c of checks) {
    console.log(t("setup.checkLine", { icon: c.ok ? "✅" : "❌", name: c.name, detail: c.detail }) + (!c.ok && c.fix ? t("setup.fixLine", { fix: c.fix }) : ""));
  }
  return checks.every((c) => c.ok);
}

export async function runSetup(paths: Paths, args: string[]): Promise<void> {
  const yes = args.includes("--yes") || !process.stdin.isTTY;
  console.log(t("setup.title", { version: VERSION }));
  const created = scaffoldHome(paths);
  for (const f of created) console.log(t("setup.created", { file: f }));
  const cfg = loadConfig(paths);
  const rl = yes ? null : createInterface({ input: process.stdin, output: process.stdout });
  const ask = async (q: string, def: string) => {
    if (!rl) return def;
    const a = (await rl.question(`${q} [${def}] `)).trim();
    return a || def;
  };

  cfg.hostName = await ask(t("setup.askName"), cfg.hostName);
  cfg.settings.timezone = await ask(t("setup.askTz"), cfg.settings.timezone);
  const quiet = await ask(t("setup.askQuiet"), cfg.settings.quietHours ? `${cfg.settings.quietHours.start}-${cfg.settings.quietHours.end}` : "off");
  cfg.settings.quietHours = quiet === "off" ? null : { start: quiet.split("-")[0]!, end: quiet.split("-")[1]! };
  const third = await ask(t("setup.askThird"), cfg.env?.ANTHROPIC_BASE_URL ? "y" : "n");
  if (third === "y") {
    cfg.env = cfg.env ?? {};
    cfg.env.ANTHROPIC_BASE_URL = await ask(t("setup.askUrl"), cfg.env.ANTHROPIC_BASE_URL ?? "");
    cfg.env.ANTHROPIC_AUTH_TOKEN = await ask(t("setup.askToken"), cfg.env.ANTHROPIC_AUTH_TOKEN ?? "");
    cfg.model = (await ask(t("setup.askModel"), cfg.model ?? "")) || undefined;
    cfg.probeModel = await ask(t("setup.askProbe"), cfg.probeModel);
  }
  saveConfig(paths, cfg);
  loadHostIdentity(paths.identity);
  rl?.close();

  console.log(t("setup.checking"));
  const check = await checkHarness(cfg, paths.home);
  console.log(`${check.ok ? "✅" : "❌"} ${check.detail}${!check.ok && check.fix ? t("setup.fixLine", { fix: check.fix }) : ""}`);

  console.log(t("setup.next", { userMd: paths.userMd }));
}
