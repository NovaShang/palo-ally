import { execFileSync } from "node:child_process";
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { Paths } from "./config.ts";
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
    return `已装成常驻服务（launchd：${p}）。崩溃会自动重启，开机自动运行。日志在 ${paths.logs}`;
  }
  if (process.platform === "linux") {
    const p = unitPath();
    ensureDir(join(homedir(), ".config", "systemd", "user"));
    writeFileSync(p, systemdUnit(paths));
    execFileSync("systemctl", ["--user", "daemon-reload"]);
    execFileSync("systemctl", ["--user", "enable", "--now", "paloally.service"]);
    return `已装成常驻服务（systemd --user：${p}）。若要在未登录时也运行：sudo loginctl enable-linger $USER`;
  }
  throw new Error(`暂不支持 ${process.platform}`);
}

export function uninstallService(): string {
  if (process.platform === "darwin") {
    const p = plistPath();
    if (!existsSync(p)) return "没有安装服务。";
    try {
      execFileSync("launchctl", ["unload", "-w", p], { stdio: "ignore" });
    } catch {
      /* ignore */
    }
    unlinkSync(p);
    return "已卸载服务。";
  }
  if (process.platform === "linux") {
    try {
      execFileSync("systemctl", ["--user", "disable", "--now", "paloally.service"], { stdio: "ignore" });
    } catch {
      /* ignore */
    }
    if (existsSync(unitPath())) unlinkSync(unitPath());
    return "已卸载服务。";
  }
  return "暂不支持此平台。";
}

export function serviceStatus(): string {
  if (process.platform === "darwin") {
    if (!existsSync(plistPath())) return "未安装服务（paloally service install）";
    try {
      const out = execFileSync("launchctl", ["list", LABEL], { encoding: "utf8" });
      const pid = /"PID"\s*=\s*(\d+)/.exec(out)?.[1];
      return pid ? `服务运行中（pid ${pid}）` : "服务已安装但没在运行";
    } catch {
      return "服务已安装但没加载";
    }
  }
  if (process.platform === "linux") {
    try {
      return execFileSync("systemctl", ["--user", "is-active", "paloally.service"], { encoding: "utf8" }).trim();
    } catch {
      return "未运行";
    }
  }
  return "暂不支持此平台。";
}
