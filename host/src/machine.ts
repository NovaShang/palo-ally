import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { hostname } from "node:os";

// Which machine this host runs on, as the app can tell it too: a Mac app on
// the same computer lists this host first in its sidebar (docs/workbench-design/
// multi-host-sidebar.html). Never the raw hardware id: a hash of it, the
// same one the app makes from the same id (ios MachineIdentity.swift).

/** The hash both sides make: hex SHA-256 of a fixed prefix and the id, 32 characters. */
export function machineHash(raw: string): string {
  return createHash("sha256").update(`paloally-machine:${raw}`).digest("hex").slice(0, 32);
}

/** The Mac's hardware UUID (IOPlatformUUID), as `ioreg` prints it; undefined elsewhere or if it can't be read. */
export function platformUUID(ioreg: () => string = readIoreg): string | undefined {
  const m = /"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{36})"/.exec(ioreg());
  return m?.[1]?.toUpperCase();
}

function readIoreg(): string {
  if (process.platform !== "darwin") return "";
  const r = spawnSync("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], { encoding: "utf8", timeout: 5000 });
  return r.status === 0 ? r.stdout : "";
}

/** The computer's name as the app's fallback reads it: lowercased, without `.local`. */
export function normalizedHostName(name: string): string {
  return name.trim().toLowerCase().replace(/\.local$/, "");
}

/**
 * This machine's identity: the hardware UUID's hash on a Mac; elsewhere
 * /etc/machine-id's; failing both, the computer name's (`host:` in front,
 * so it never equals a UUID's).
 */
export function computeMachineId(read: { uuid?: () => string | undefined; linuxId?: () => string; name?: () => string } = {}): string {
  const uuid = (read.uuid ?? platformUUID)();
  if (uuid) return machineHash(uuid);
  const linux = (read.linuxId ?? readLinuxId)();
  if (linux) return machineHash(`linux:${linux}`);
  return machineHash(`host:${normalizedHostName((read.name ?? hostname)())}`);
}

function readLinuxId(): string {
  try {
    return readFileSync("/etc/machine-id", "utf8").trim();
  } catch {
    return "";
  }
}

let cached: string | undefined;
/** Computed once (ioreg takes a moment). */
export function machineId(): string {
  cached ??= computeMachineId();
  return cached;
}
