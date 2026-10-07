import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// The host's version comes from where its code came from: the release tag the
// checkout sits on (v0.1.2 → "0.1.2"), or the nearest tag plus how far past it
// a dev checkout is ("0.1.2+4"). A copy with no git (git archive deploys) falls
// back to package.json. PALOALLY_VERSION overrides all of it (fixtures, tests).

/** The repository root this code runs from (…/palo-ally). */
export const APP_DIR = resolve(import.meta.dir, "../..");

export interface HostVersion {
  version: string; // shown to people: "0.1.2", "0.1.2+4"
  tag: string | null; // the release tag at or below this code, e.g. "v0.1.2"
  exact: boolean; // the checkout is exactly on that tag
  commit: string | null; // short commit, when it's a git checkout
}

const TAG_RE = /^v(\d+)\.(\d+)\.(\d+)$/;

export function parseSemver(tag: string): [number, number, number] | null {
  const m = TAG_RE.exec(tag.trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

export function compareSemver(a: [number, number, number], b: [number, number, number]): number {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i]! - b[i]!;
  return 0;
}

function git(dir: string, args: string[]): string | null {
  try {
    return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 }).trim();
  } catch {
    return null;
  }
}

function packageVersion(dir: string): string {
  try {
    return String(JSON.parse(readFileSync(resolve(dir, "host/package.json"), "utf8")).version ?? "0.0.0");
  } catch {
    return "0.0.0";
  }
}

/** Reads the version of the code in `dir` (no caching). */
export function readHostVersion(dir = APP_DIR): HostVersion {
  const env = process.env.PALOALLY_VERSION;
  if (env) return { version: env, tag: null, exact: true, commit: null };
  const commit = git(dir, ["rev-parse", "--short", "HEAD"]);
  if (!commit) return { version: packageVersion(dir), tag: null, exact: false, commit: null };
  const described = git(dir, ["describe", "--tags", "--match", "v*", "--long"]); // v0.1.2-4-g02df428
  const m = described ? /^(v\d+\.\d+\.\d+)-(\d+)-g[0-9a-f]+$/.exec(described) : null;
  if (!m || !parseSemver(m[1]!)) return { version: `${packageVersion(dir)}-dev`, tag: null, exact: false, commit };
  const tag = m[1]!;
  const ahead = Number(m[2]);
  return { version: ahead ? `${tag.slice(1)}+${ahead}` : tag.slice(1), tag, exact: ahead === 0, commit };
}

let cached: HostVersion | null = null;
/** The running code's version, read once. */
export function hostVersion(): HostVersion {
  return (cached ??= readHostVersion());
}
