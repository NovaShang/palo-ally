import { execFileSync } from "node:child_process";
import { zh } from "./zh/index.ts";
import { en } from "./en/index.ts";

// The host's tiny i18n layer. Every sentence the owner reads (or the model
// reads on the owner's behalf) is a key in the zh dictionary; the en
// dictionary is typed `Record<MsgKey, string>`, so a missing English string
// fails `tsc`. Placeholders are `{name}`, filled from `params`.
//
// The language is one per host (the owner's): `setLang` is called by the hub
// at start and whenever settings.language changes. Until then it is zh.

export type Lang = "zh" | "en";
export const LANGS: readonly Lang[] = ["zh", "en"];
export type MsgKey = keyof typeof zh;
export type Params = Record<string, string | number>;

export const DICTIONARIES: Record<Lang, Record<MsgKey, string>> = { zh, en };

let current: Lang = "zh";
export const getLang = (): Lang => current;
export function setLang(l: Lang): void {
  current = l;
}

export function fill(s: string, params?: Params): string {
  if (!params) return s;
  return s.replace(/\{(\w+)\}/g, (m, k: string) => (k in params ? String(params[k]) : m));
}

export function tIn(lang: Lang, key: MsgKey, params?: Params): string {
  return fill(DICTIONARIES[lang][key] ?? zh[key], params);
}

export function t(key: MsgKey, params?: Params): string {
  return tIn(current, key, params);
}

// "zh", "zh-Hans-CN", "zh_TW" -> zh; anything else (en-US, fr, ...) -> en.
// null/empty -> null (nothing reported).
export function parseLocale(s: unknown): Lang | null {
  if (typeof s !== "string") return null;
  const v = s.trim().toLowerCase();
  if (!v) return null;
  return v.startsWith("zh") ? "zh" : "en";
}

// The macOS user's first preferred language (`defaults read -g AppleLanguages`).
// PALOALLY_LANG overrides it (tests, CI). Defaults to en when nothing is known.
let systemMemo: Lang | null = null;
export function systemLanguage(): Lang {
  if (!process.env.PALOALLY_LANG && systemMemo) return systemMemo;
  const l = detectSystemLanguage();
  if (!process.env.PALOALLY_LANG) systemMemo = l;
  return l;
}

function detectSystemLanguage(): Lang {
  const env = parseLocale(process.env.PALOALLY_LANG);
  if (env) return env;
  try {
    const out = execFileSync("defaults", ["read", "-g", "AppleLanguages"], { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] });
    const first = /"?([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*)"?\s*[,)]/.exec(out);
    const l = parseLocale(first?.[1]);
    if (l) return l;
  } catch {
    // not macOS, or no defaults: fall through
  }
  const l = parseLocale(process.env.LC_ALL || process.env.LANG);
  return l ?? "en";
}

export function isLang(v: unknown): v is Lang {
  return v === "zh" || v === "en";
}
