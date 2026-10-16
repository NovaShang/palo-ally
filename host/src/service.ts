import { execFileSync } from "node:child_process";
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { Paths } from "./config.ts";
import { t } from "./i18n/index.ts";
import { ensureDir } from "./util.ts";

const LABEL = "com.novashang.paloally";
const CLI = resolve(import.meta.dir, "cli.ts");

function plistPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${LABEL}.plist`);
}

function unitPath(): string {
  return join(homedir(), ".config", "systemd", "user", "paloally.service");
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

export function launchdPlist(paths: Paths, bun = process.execPath): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${esc(bun)}</string><string>${esc(CLI)}</string><string>start</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PALOALLY_HOME</key><string>${esc(paths.root)}</string>
    <key>PATH</key><string>${esc(process.env.PATH ?? "/usr/bin:/bin")}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${esc(join(paths.logs, "daemon.log"))}</string>
  <key>StandardErrorPath</key><string>${esc(join(paths.logs, "daemon.err.log"))}</string>
</dict>
</plist>
`;
}

export function systemdUnit(paths: Paths, bun = process.execPath): string {
  return `[Unit]
Description=PaloAlly personal assistant
After=network-online.target

[Service]
ExecStart=${bun} ${CLI} start
Environment=PALOALLY_HOME=${paths.root}
Environment=PATH=${process.env.PATH ?? "/usr/bin:/bin"}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
`;
}

export function installService(paths: Paths): string {
  ensureDir(paths.logs);
  if (process.platform === "darwin") {
    const p = plistPath();
    ensureDir(join(homedir(), "Library", "LaunchAgents"));
    try {
      execFileSync("launchctl", ["unload", p], { stdio: "ignore" });
    } catch {
      /* not loaded */
    }
    writeFileSync(p, launchdPlist(paths));
    execFileSync("launchctl", ["load", "-w", p]);
    return t("svc.installedLaunchd", { path: p, logs: paths.logs });
  }
  if (process.platform === "linux") {
    const p = unitPath();
    ensureDir(join(homedir(), ".config", "systemd", "user"));
    writeFileSync(p, systemdUnit(paths));
    execFileSync("systemctl", ["--user", "daemon-reload"]);
    execFileSync("systemctl", ["--user", "enable", "--now", "paloally.service"]);
    return t("svc.installedSystemd", { path: p });
  }
  throw new Error(t("svc.unsupportedPlatform", { platform: process.platform }));
}

export function uninstallService(): string {
  if (process.platform === "darwin") {
    const p = plistPath();
    if (!existsSync(p)) return t("svc.notInstalled");
    try {
      execFileSync("launchctl", ["unload", "-w", p], { stdio: "ignore" });
    } catch {
      /* ignore */
    }
    unlinkSync(p);
    return t("svc.removed");
  }
  if (process.platform === "linux") {
    try {
      execFileSync("systemctl", ["--user", "disable", "--now", "paloally.service"], { stdio: "ignore" });
    } catch {
      /* ignore */
    }
    if (existsSync(unitPath())) unlinkSync(unitPath());
    return t("svc.removed");
  }
  return t("svc.unsupportedHere");
}

export function serviceStatus(): string {
  if (process.platform === "darwin") {
    if (!existsSync(plistPath())) return t("svc.statusNotInstalled");
    try {
      const out = execFileSync("launchctl", ["list", LABEL], { encoding: "utf8" });
      const pid = /"PID"\s*=\s*(\d+)/.exec(out)?.[1];
      return pid ? t("svc.statusRunning", { pid }) : t("svc.statusStopped");
    } catch {
      return t("svc.statusNotLoaded");
    }
  }
  if (process.platform === "linux") {
    try {
      return execFileSync("systemctl", ["--user", "is-active", "paloally.service"], { encoding: "utf8" }).trim();
    } catch {
      return t("svc.statusDown");
    }
  }
  return t("svc.unsupportedHere");
}
