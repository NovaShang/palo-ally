import { t } from "../i18n/index.ts";
import type { AllyAuthor, AllyKind, AllySlot, AllyTrust } from "../types.ts";
import { b64url, unb64, unb64url } from "./e2e.ts";

// What two hosts say to each other on an Ally stream (docs/allies-prd.md
// §7.3, §7.6, §11.4): one JSON object per sealed unit. These four types are
// all an ally stream may carry. Anything else, every RPC method included, is
// refused and the stream closed: an Ally can never act as the owner's app.

export interface AllyHello {
  type: "ally.hello";
  name: string; // the sender's owner, as they're called
  assistantName: string;
  kind: AllyKind;
  version: string;
  // §11: how the sender's assistant answers the receiver (their `theirTrust`).
  // Absent from a pre-§11 host; a value we don't know is ignored.
  trust?: AllyTrust;
  // pairing leg 2 only: how to pair back into the sender
  pairCode?: string;
  hostKey?: string; // b64 raw Ed25519
  daemonId?: string;
  relay?: string;
}

export interface AllyMessage {
  type: "ally.message";
  id: string;
  text: string;
  urgent: boolean;
  slots?: AllySlot[];
  replyTo?: string;
  ts: number;
  // §11: the sender's owner in their own words, or their assistant. A
  // pre-§11 host doesn't say: read as "assistant" (all it passed).
  author: AllyAuthor;
}

export interface AllyReceipt {
  type: "ally.receipt";
  id: string;
  state: "delivered" | "seen" | "rejected";
}

export interface AllyBye {
  type: "ally.bye";
  reason?: string;
}

export type AllyWire = AllyHello | AllyMessage | AllyReceipt | AllyBye;

export const ALLY_LIMITS = {
  textBytes: 4096, // one message's words (UTF-8)
  unitBytes: 8192, // a whole message on the wire
  perHour: 30, // incoming messages per Ally
  slots: 5,
};

const ID = /^[\w-]{1,64}$/;
const DAEMON = /^[\w.-]{1,128}$/;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})$/;
const KINDS: readonly string[] = ["family", "mine"];
const TRUSTS: readonly unknown[] = ["converse", "review"];

/** A trust level from outside (an RPC parameter): the value, or null. */
export function allyTrust(v: unknown): AllyTrust | null {
  return TRUSTS.includes(v) ? (v as AllyTrust) : null;
}

const text = (v: unknown, max: number): string | null => (typeof v === "string" && v.length <= max ? v : null);

// validSlots checks meeting times: each {start, end} in ISO 8601 with a time
// zone, end after start, at most ALLY_LIMITS.slots. null if any is off.
export function validSlots(v: unknown): AllySlot[] | null {
  if (!Array.isArray(v) || !v.length || v.length > ALLY_LIMITS.slots) return null;
  const out: AllySlot[] = [];
  for (const s of v) {
    const start = text(s?.start, 40);
    const end = text(s?.end, 40);
    if (!start || !end || !ISO.test(start) || !ISO.test(end)) return null;
    if (!(Date.parse(end) > Date.parse(start))) return null;
    out.push({ start, end });
  }
  return out;
}

// parseAllyWire reads one unit's plaintext. null for anything that isn't one
// of the four messages, well formed (unknown extra fields are ignored).
export function parseAllyWire(raw: string): AllyWire | null {
  if (Buffer.byteLength(raw) > ALLY_LIMITS.unitBytes) return null;
  let m: any;
  try {
    m = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!m || typeof m !== "object" || Array.isArray(m)) return null;
  switch (m.type) {
    case "ally.hello": {
      const name = text(m.name, 60);
      const assistantName = text(m.assistantName, 40);
      const version = text(m.version, 40);
      if (name === null || assistantName === null || version === null || !KINDS.includes(m.kind)) return null;
      const hello: AllyHello = { type: "ally.hello", name, assistantName, kind: m.kind, version };
      if (TRUSTS.includes(m.trust)) hello.trust = m.trust;
      if (m.pairCode !== undefined) {
        if (typeof m.pairCode !== "string" || !/^\d{6}$/.test(m.pairCode)) return null;
        hello.pairCode = m.pairCode;
      }
      if (m.hostKey !== undefined) {
        if (typeof m.hostKey !== "string" || m.hostKey.length > 64 || unb64(m.hostKey).length !== 32) return null;
        hello.hostKey = m.hostKey;
      }
      if (m.daemonId !== undefined) {
        if (typeof m.daemonId !== "string" || !DAEMON.test(m.daemonId)) return null;
        hello.daemonId = m.daemonId;
      }
      if (m.relay !== undefined) {
        if (typeof m.relay !== "string" || !allowedRelay(m.relay)) return null;
        hello.relay = m.relay;
      }
      return hello;
    }
    case "ally.message": {
      const t = text(m.text, ALLY_LIMITS.unitBytes);
      if (typeof m.id !== "string" || !ID.test(m.id) || t === null || typeof m.ts !== "number") return null;
      // Only "owner" means the owner; anything else is their assistant's.
      const msg: AllyMessage = { type: "ally.message", id: m.id, text: t, urgent: m.urgent === true, ts: m.ts, author: m.author === "owner" ? "owner" : "assistant" };
      if (m.slots !== undefined) {
        const slots = validSlots(m.slots);
        if (!slots) return null;
        msg.slots = slots;
      }
      if (m.replyTo !== undefined) {
        if (typeof m.replyTo !== "string" || !ID.test(m.replyTo)) return null;
        msg.replyTo = m.replyTo;
      }
      return msg;
    }
    case "ally.receipt":
      if (typeof m.id !== "string" || !ID.test(m.id) || !["delivered", "seen", "rejected"].includes(m.state)) return null;
      return { type: "ally.receipt", id: m.id, state: m.state };
    case "ally.bye": {
      if (m.reason !== undefined && text(m.reason, 200) === null) return null;
      return m.reason !== undefined ? { type: "ally.bye", reason: m.reason } : { type: "ally.bye" };
    }
    default:
      return null;
  }
}

// A relay an Ally may point us at: https, or plain http on this machine (a
// local relay in development). The link and the hello come from outside.
export function allowedRelay(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  if (url.length > 300 || u.username || u.password) return false;
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(u.hostname);
}

// ---- the invite link (the QR code) ----

export interface AllyInvite {
  relay: string;
  daemonId: string;
  code: string;
  hostKey: Uint8Array;
  name: string;
  exp: number; // ms
}

export function allyInviteLink(i: AllyInvite): string {
  const q = new URLSearchParams({ relay: i.relay, daemon: i.daemonId, code: i.code, hostkey: b64url(i.hostKey), name: i.name, exp: String(i.exp) });
  return `paloally://ally?${q}`;
}

// parseAllyInvite reads a scanned link, or says in plain words what's wrong.
export function parseAllyInvite(link: string): AllyInvite {
  let u: URL;
  try {
    u = new URL(link.trim());
  } catch {
    throw new Error(t("ally.notInvite"));
  }
  if (u.protocol !== "paloally:" || u.hostname !== "ally") throw new Error(t("ally.notInvite"));
  const q = u.searchParams;
  const relay = q.get("relay") ?? "";
  const daemonId = q.get("daemon") ?? "";
  const code = q.get("code") ?? "";
  let hostKey = new Uint8Array(0);
  try {
    hostKey = unb64url(q.get("hostkey") ?? "");
  } catch {
    /* checked below */
  }
  if (!allowedRelay(relay) || !DAEMON.test(daemonId) || !/^\d{6}$/.test(code) || hostKey.length !== 32) throw new Error(t("ally.incomplete"));
  const exp = Number(q.get("exp") ?? 0);
  return { relay, daemonId, code, hostKey, name: (q.get("name") ?? "").trim().slice(0, 60), exp: Number.isFinite(exp) ? exp : 0 };
}
