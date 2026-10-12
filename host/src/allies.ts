import { spawnSync } from "node:child_process";
import { randomBytes, randomInt } from "node:crypto";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import { type AllyConn, type AllyConnHandlers, type AllyTarget, type DialFn, type PairFn, PairError, dialAlly, pairAsClient } from "./channels/allyLink.ts";
import type { RelayState } from "./channels/relay.ts";
import type { ChatLog } from "./chat.ts";
import { type Paths, type Settings, VERSION } from "./config.ts";
import type { Turn } from "./conversation.ts";
import {
  allyByeNotice,
  allyDraftedText,
  allyKindWord,
  allyNotSeenText,
  allyPushTitle,
  allySentText,
  allyTrustWord,
  allyTurnHeader,
  allyTurnMessage,
  allyUndeliveredText,
} from "./copy.ts";
import { type Identity, b64, fingerprint, unb64 } from "./proto/e2e.ts";
import { ALLY_LIMITS, type AllyHello, type AllyMessage, type AllyReceipt, type AllyWire, allyInviteLink, allyTrust, allowedRelay, parseAllyInvite, parseAllyWire, validSlots } from "./proto/ally.ts";
import type { Router } from "./router.ts";
import type { AllyAuthor, AllyEntry, AllyInfo, AllyKind, AllySlot, AllyStatus, AllyTrust } from "./types.ts";
import { newId, readJson, readJsonl, truncate, writeJson, writeJsonl } from "./util.ts";

// Allies (docs/allies-prd.md): two PaloAlly hosts that know each other, so
// their assistants (and their owners) can pass messages and meeting times. An
// Ally reaches us as a client of our daemon (like a phone), but its stream
// only ever speaks the four ally.* messages: it is never attached as the
// owner's app and can't call any RPC method. What goes out is the owner's own
// words (ally.say), or the assistant's: sent at once to an Ally the owner set
// to 能对话, a draft card the owner sends for one set to 每句要你看 (§11.1).
// Incoming words are shown as they arrived and handed to the assistant as an
// outside message, never as an instruction, in a turn where it can only talk
// (Conversation's gate, allyGate.ts).

/** One Ally as stored in allies.json. */
export interface Ally {
  id: string;
  kind: AllyKind;
  ownerName: string;
  assistantName: string;
  daemonId: string;
  hostKey: string; // their Ed25519 public key, b64
  relay: string;
  myDeviceIdThere: string;
  theirDeviceIdHere: string;
  pairedAt: number;
  lastSeen: number;
  trust: AllyTrust; // how our assistant answers them (§11.1); "review" before §11
  theirTrust?: AllyTrust; // how theirs answers us, from their hello
  pending?: boolean; // pairing in progress: both legs not done yet
  removedAt?: number; // unpaired: identity cleared, the log kept
}

// A log line: the wire entry plus our own bookkeeping.
interface StoredEntry extends Omit<AllyEntry, "author"> {
  author?: AllyAuthor; // absent on entries from before §11: the assistant's words
  deliveredAt?: number;
  nudgedAt?: number; // 「还没看到」 said
}

// One thing waiting to go out (allies-outbox.json): a message, receipt or
// bye for an Ally, or a device revoke for our own relay.
interface OutItem {
  key: string; // entry id, "seen:<id>", "bye:<allyId>", "revoke:<deviceId>"
  allyId: string;
  msg?: AllyWire;
  revoke?: string;
  // where to reach them when the Ally record no longer says (a bye after removal)
  target?: { relay: string; daemonId: string; deviceId: string; hostKey: string };
  firstAt: number;
  attempts: number;
  nextAt: number;
}

/** What Allies needs from our own relay connection (RelayChannel). */
export interface AllyRelay {
  readonly state: RelayState;
  readonly relayUrl: string;
  readonly daemonId: string;
  readonly identity: Identity;
  /** Opens (or renews) the relay's pairing slot with this code. */
  openAllyWindow(code: string, ttlSec: number): Promise<{ code: string; ttl: number }>;
  /** The code of the pairing window opened last (phone or ally). */
  windowCode(): string | null;
  /** Asks the relay to forget a device; true once it confirmed. */
  revokeDevice(deviceId: string): Promise<boolean>;
}

export interface AlliesDeps {
  paths: Paths;
  bus: Bus;
  chat: ChatLog;
  router: Router;
  audit: Audit;
  settings: () => Settings;
  hostName: () => string;
  enqueue: (t: Turn) => void;
  findQueued: (pred: (t: Turn) => boolean) => Turn | undefined;
  // The Ally whose message the assistant is handling right now, if any.
  turnAlly?: () => string | undefined;
  dial?: DialFn;
  pair?: PairFn;
  now?: () => number;
  log?: (s: string) => void;
}

export const allyTiming = {
  inviteMs: 10 * 60_000, // the QR code
  windowSec: 300, // the relay's longest pairing window; renewed within the invite
  backWindowSec: 120, // leg 2: our window for the inviter to pair back
  acceptMs: 30_000, // both legs, from the scan
  pendingMs: 2 * 60_000, // a half-done pairing is dropped after this
  idleMs: 2 * 60_000, // an outbound connection with nothing to do
  receiptMs: 15_000, // waiting for 「已送到」 on an open connection
  retryMs: [30_000, 2 * 60_000, 10 * 60_000, 30 * 60_000], // then every 30 minutes
  giveUpMs: 3 * 24 * 3600_000,
  draftMs: 24 * 3600_000,
  notSeenMs: 4 * 3600_000, // 「还没看到」
  onlineMs: 5 * 60_000,
  announceEveryMs: 10 * 60_000,
  tickMs: 15_000,
};

interface Link {
  allyId: string;
  dir: "in" | "out"; // they connected to us / we to them
  conn: AllyConn;
  hello: boolean; // "in": the first message was ally.hello
  idle?: ReturnType<typeof setTimeout>;
}

const sixDigits = () => String(randomInt(0, 1_000_000)).padStart(6, "0");
// What the relay sees as an Ally's label, both ways: names travel only
// inside the E2E channel (ally.hello), never in the relay's clear text.
const RELAY_LABEL = "PaloAlly";
const newDeviceId = () => "al-" + newId() + newId();
const excerpt = (s: string) => truncate(s.replace(/\s+/g, " ").trim(), 40);
const RANK: Record<AllyStatus, number> = { draft: 0, queued: 1, sent: 2, delivered: 3, seen: 4, rejected: 5 };

export class Allies {
  private allies: Ally[];
  private logs = new Map<string, StoredEntry[]>();
  private outbox: OutItem[];
  private relay: AllyRelay | null = null;
  private links = new Set<Link>();
  private out = new Map<string, Link>(); // our connection to each Ally
  private dialing = new Map<string, Promise<Link>>();
  private flushing = new Set<string>();
  private again = new Set<string>();
  private revoking = new Set<string>();
  private receipts = new Map<string, { allyId: string; done: (state: string | null) => void }>();
  private inbound = new Map<string, number[]>(); // arrival times per Ally, last hour
  private contact = new Map<string, { okAt: number; failAt: number }>();
  private wasOnline = new Map<string, boolean>();
  private announced = new Map<string, number>();
  private inv: { code: string; expiresAt: number; timer?: ReturnType<typeof setTimeout> } | null = null;
  // our own accept, waiting for the inviter to pair back (leg 2)
  private back: { code: string; pub: string; until: number; allyId: string; done: () => void } | null = null;
  private pairing = new Map<string, { hello: () => void; fail: (e: Error) => void }>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private readonly dial: DialFn;
  private readonly pairFn: PairFn;
  private readonly now: () => number;
  private readonly logLine: (s: string) => void;

  constructor(private d: AlliesDeps) {
    this.allies = readJson<Ally[]>(d.paths.allies, []);
    // Allies from before §11 had no level: every reply a draft, as then.
    if (this.allies.some((a) => !allyTrust(a.trust))) {
      for (const a of this.allies) if (!allyTrust(a.trust)) a.trust = "review";
      this.saveAllies();
    }
    this.outbox = readJson<OutItem[]>(d.paths.alliesOutbox, []);
    this.dial = d.dial ?? dialAlly;
    this.pairFn = d.pair ?? pairAsClient;
    this.now = d.now ?? Date.now;
    this.logLine = d.log ?? ((s) => console.log(`[allies] ${s}`));
    // A pairing cut off by a restart can't finish.
    for (const a of this.allies.filter((x) => x.pending)) this.discardPending(a);
  }

  start(): void {
    this.timer = setInterval(() => this.tick(), allyTiming.tickMs);
    (this.timer as any).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    if (this.inv?.timer) clearTimeout(this.inv.timer);
    for (const l of [...this.links]) l.conn.close();
  }

  setRelay(relay: AllyRelay): void {
    this.relay = relay;
  }

  // ---------------- what the app and the assistant see ----------------

  list(): AllyInfo[] {
    return this.active().map((a) => this.info(a));
  }

  log(id: string, beforeTs?: unknown, limit?: unknown): AllyEntry[] {
    const a = this.get(id);
    if (!a || a.pending) throw new Error("没有这个 Ally");
    const before = typeof beforeTs === "number" ? beforeTs : Infinity;
    const n = Math.max(1, Math.min(typeof limit === "number" ? limit : 50, 200));
    return this.logOf(a.id)
      .filter((e) => e.ts < before)
      .slice(-n)
      .map(publicEntry);
  }

  /** ally_list for the assistant. */
  toolList(): string {
    return JSON.stringify(
      this.active().map((a) => ({ id: a.id, name: a.ownerName, assistantName: a.assistantName, kind: allyKindWord(a.kind), trust: allyTrustWord(a.trust), online: this.online(a) })),
    );
  }

  // ---------------- pairing ----------------

  // invite opens a pairing window on our relay and returns the link the app
  // shows as a QR code: 10 minutes, one use. The relay's window is at most
  // 300 s, so it's renewed with the same code until the invite runs out.
  async invite(): Promise<{ link: string; expiresAt: number }> {
    const relay = this.readyRelay();
    const now = this.now();
    const opened = await relay.openAllyWindow(sixDigits(), allyTiming.windowSec);
    this.closeInvite();
    this.inv = { code: opened.code, expiresAt: now + allyTiming.inviteMs };
    this.scheduleRenew(opened.ttl);
    this.d.audit.log("ally.invite", {});
    const link = allyInviteLink({ relay: relay.relayUrl, daemonId: relay.daemonId, code: opened.code, hostKey: relay.identity.pub, name: this.ownerName(), exp: this.inv.expiresAt });
    return { link, expiresAt: this.inv.expiresAt };
  }

  private scheduleRenew(ttlSec: number): void {
    const inv = this.inv;
    if (!inv) return;
    const at = Math.min(ttlSec * 1000 - 2_000, inv.expiresAt - this.now());
    if (at <= 0) return;
    inv.timer = setTimeout(() => void this.renewInvite(), at);
    (inv.timer as any).unref?.();
  }

  /** Renews the relay window under an open invite (exposed for tests). */
  async renewInvite(): Promise<void> {
    const inv = this.inv;
    const relay = this.relay;
    if (!inv || !relay) return;
    const left = inv.expiresAt - this.now();
    // Someone opened a phone pairing since: that window replaced ours.
    if (left <= 5_000 || relay.windowCode() !== inv.code) return;
    try {
      const opened = await relay.openAllyWindow(inv.code, Math.max(30, Math.min(allyTiming.windowSec, Math.ceil(left / 1000))));
      // A relay that can't keep the code: the QR code is dead from here.
      if (opened.code !== inv.code) return this.closeInvite();
      this.scheduleRenew(opened.ttl);
    } catch (e) {
      this.logLine(`invite renew failed: ${e}`);
    }
  }

  private closeInvite(): void {
    if (this.inv?.timer) clearTimeout(this.inv.timer);
    this.inv = null;
  }

  // onPairAttach answers the relay's pair.attach for device_kind "ally"
  // (RelayChannel). Leg 1: anyone holding our invite code, once. Leg 2 of
  // our own accept: only the inviter's host key. Names come in the hello.
  onPairAttach(pub: Uint8Array): { deviceId: string; label: string } | { error: string } {
    const now = this.now();
    const key = b64(pub);
    if (this.back && now < this.back.until) {
      const back = this.back;
      const a = this.get(back.allyId);
      if (key !== back.pub || !a) return { error: "unexpected ally key" };
      this.back = null;
      a.theirDeviceIdHere = newDeviceId();
      this.saveAllies();
      back.done();
      return { deviceId: a.theirDeviceIdHere, label: RELAY_LABEL };
    }
    if (this.inv && now < this.inv.expiresAt) {
      if (this.allies.some((a) => !a.removedAt && a.hostKey === key)) return { error: "already an ally" };
      this.closeInvite();
      const a: Ally = {
        id: newId("al_"),
        kind: "family",
        ownerName: "对方", // until its hello
        assistantName: "",
        daemonId: "",
        hostKey: key,
        relay: "",
        myDeviceIdThere: "",
        theirDeviceIdHere: newDeviceId(),
        pairedAt: now,
        lastSeen: now,
        trust: "review", // until the owner changes it in the app
        pending: true,
      };
      this.allies.push(a);
      this.saveAllies();
      this.d.audit.log("ally.pair.attach", { id: a.id });
      return { deviceId: a.theirDeviceIdHere, label: RELAY_LABEL };
    }
    return { error: "pairing not open" };
  }

  // accept takes a scanned invite: pair into the inviter's daemon (leg 1),
  // tell it over the new E2E channel how to pair back into ours (leg 2), and
  // return once both are done.
  async accept(link: string, kindIn: unknown, trustIn?: unknown): Promise<AllyInfo> {
    const relay = this.readyRelay();
    if (kindIn !== "family" && kindIn !== "mine") throw new Error("标签只能是「家人朋友」或「我的」");
    const kind: AllyKind = kindIn;
    const trust = trustIn === undefined || trustIn === null ? "review" : allyTrust(trustIn);
    if (!trust) throw new Error("档位只能是「能对话」或「每句要你看」");
    const inv = parseAllyInvite(link);
    const now = this.now();
    if (inv.exp && inv.exp < now) throw new Error("这个邀请过期了，请对方重新打开二维码");
    if (inv.daemonId === relay.daemonId) throw new Error("这是你自己的邀请");
    if (this.active().some((a) => a.daemonId === inv.daemonId)) throw new Error("你们已经是 Ally 了");
    if (this.back && now < this.back.until) throw new Error("正在加另一个 Ally，稍等一下再试");

    const a: Ally = {
      id: newId("al_"),
      kind,
      ownerName: inv.name || "对方",
      assistantName: "",
      daemonId: inv.daemonId,
      hostKey: b64(inv.hostKey),
      relay: inv.relay,
      myDeviceIdThere: "",
      theirDeviceIdHere: "",
      pairedAt: now,
      lastSeen: 0,
      trust,
      pending: true,
    };
    let backDone!: () => void;
    let helloDone!: () => void;
    let fail!: (e: Error) => void;
    const backP = new Promise<void>((r) => (backDone = r));
    const helloP = new Promise<void>((r) => (helloDone = r));
    const failP = new Promise<never>((_, rej) => (fail = rej));
    failP.catch(() => {});
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // Leg 2's window first: its code goes into our hello.
      const opened = await relay.openAllyWindow(sixDigits(), allyTiming.backWindowSec);
      this.allies.push(a);
      this.saveAllies();
      this.back = { code: opened.code, pub: a.hostKey, until: this.now() + opened.ttl * 1000, allyId: a.id, done: backDone };
      this.pairing.set(a.id, { hello: helloDone, fail });
      const ack = await this.pairFn(inv.relay, inv.daemonId, { code: inv.code, identity: relay.identity, label: RELAY_LABEL, kind: "ally" });
      if (ack.host_fingerprint !== fingerprint(inv.hostKey)) throw new Error("对方主机的指纹对不上，没有加");
      a.myDeviceIdThere = ack.device_id;
      this.saveAllies();
      const hello = this.hello(a, { pairCode: opened.code, hostKey: b64(relay.identity.pub), daemonId: relay.daemonId, relay: relay.relayUrl });
      await this.connectOut(a.id, this.target(a), hello);
      const timeout = new Promise<never>((_, rej) => (timer = setTimeout(() => rej(new Error("对方没回应，没加成")), allyTiming.acceptMs)));
      await Promise.race([Promise.all([backP, helloP]), failP, timeout]);
    } catch (e) {
      if (this.back?.allyId === a.id) this.back = null;
      this.pairing.delete(a.id);
      this.discardPending(a);
      this.d.audit.log("ally.accept.failed", { error: String(e) });
      throw new Error(acceptError(e));
    } finally {
      clearTimeout(timer);
    }
    this.pairing.delete(a.id);
    delete a.pending;
    a.lastSeen = this.now();
    this.saveAllies();
    this.d.audit.log("ally.paired", { id: a.id, kind: a.kind, trust: a.trust, as: "guest" });
    this.emitList();
    return this.info(a);
  }

  // Leg 2 on the inviter's side: the guest's hello carries a code for its own
  // relay. Its key came through the E2E channel we just verified against the
  // key it paired with, so nothing else needs checking by hand.
  private async pairBack(a: Ally, h: AllyHello, link: Link): Promise<void> {
    const relay = this.relay;
    try {
      if (!relay || !h.pairCode || !h.daemonId || !h.relay || h.hostKey !== a.hostKey || !allowedRelay(h.relay)) throw new Error("bad pairing hello");
      a.kind = h.kind;
      a.daemonId = h.daemonId;
      a.relay = h.relay;
      const ack = await this.pairFn(h.relay, h.daemonId, { code: h.pairCode, identity: relay.identity, label: RELAY_LABEL, kind: "ally" });
      if (ack.host_fingerprint !== fingerprint(unb64(a.hostKey))) throw new Error("host fingerprint mismatch");
      a.myDeviceIdThere = ack.device_id;
      delete a.pending;
      a.lastSeen = this.now();
      this.saveAllies();
      link.conn.send(this.hello(a));
      this.d.audit.log("ally.paired", { id: a.id, kind: a.kind, trust: a.trust, as: "host" });
      this.emitList();
    } catch (e) {
      this.logLine(`pairing back failed: ${e}`);
      link.conn.send({ type: "ally.bye", reason: "pairing failed" });
      setTimeout(() => this.discardPending(a), 200);
    }
  }

  // A pairing that didn't finish: as if it never happened, except that the
  // relay is told to forget whatever device it pinned for it.
  private discardPending(a: Ally): void {
    if (a.theirDeviceIdHere) this.queueRevoke(a.theirDeviceIdHere);
    for (const l of [...this.links]) if (l.allyId === a.id) l.conn.close();
    this.allies = this.allies.filter((x) => x !== a);
    this.saveAllies();
    rmSync(this.logPath(a.id), { force: true });
    this.logs.delete(a.id);
    this.pump();
  }

  // remove unpairs (the owner's 「解除」): tell them (ally.bye), have our relay
  // forget their device, and keep the log, marked removed.
  remove(id: string): boolean {
    const a = this.get(id);
    if (!a || a.removedAt || a.pending) return false;
    if (a.myDeviceIdThere) {
      const t = this.target(a);
      this.queue({ key: `bye:${a.id}`, allyId: a.id, msg: { type: "ally.bye" }, target: { ...t, hostKey: a.hostKey } });
    }
    this.forget(a, "owner");
    return true;
  }

  private forget(a: Ally, by: "owner" | "peer"): void {
    if (a.theirDeviceIdHere) this.queueRevoke(a.theirDeviceIdHere);
    // Words that hadn't gone out won't now.
    for (const e of this.logOf(a.id)) {
      if (e.dir === "out" && (e.status === "draft" || e.status === "queued" || e.status === "sent")) {
        e.status = "rejected";
        e.note = "已解除";
        this.emitEntry(e);
      }
    }
    this.saveLog(a.id);
    this.outbox = this.outbox.filter((i) => i.allyId !== a.id || i.key === `bye:${a.id}`);
    this.saveOutbox();
    Object.assign(a, { daemonId: "", hostKey: "", relay: "", myDeviceIdThere: "", theirDeviceIdHere: "", removedAt: this.now() });
    this.saveAllies();
    // Their connections end; ours stays only to carry the bye.
    for (const l of [...this.links]) if (l.allyId === a.id && (l.dir === "in" || by === "peer")) l.conn.close();
    this.d.audit.log("ally.removed", { id: a.id, by });
    this.emitList();
    this.pump();
  }

  // ---------------- what goes out ----------------

  // toolSend is ally_send. To an Ally the owner set to 能对话 it goes out now,
  // the assistant's words for them; otherwise it's a draft card the owner
  // sends (每句要你看). In a turn an Ally's message started, only the answer
  // to that Ally can go out directly: words for anyone else wait as a draft.
  toolSend(args: { to: string; text: string; urgent?: boolean; slots?: unknown; replyTo?: string }): string {
    const a = this.find(args.to);
    if (!a) {
      const names = this.active().map((x) => `${x.ownerName}（${x.id}）`).join("、");
      return names ? `没有「${args.to}」这个 Ally。现在的 Ally：${names}` : "还没有 Ally。主人可以在 App 的「它」里加。";
    }
    const text = String(args.text ?? "").trim();
    if (!text) return "没有要发的话";
    if (Buffer.byteLength(text) > ALLY_LIMITS.textBytes) return "太长了：一条不能超过 4 KB（大约 1300 个汉字），精简一下再拟。";
    let slots: AllySlot[] | undefined;
    if (Array.isArray(args.slots) && args.slots.length) {
      const v = validSlots(args.slots);
      if (!v) return "时段格式不对：每个是 {start, end}，ISO 8601 带时区（如 2026-10-17T14:00:00+08:00），结束晚于开始，最多 5 个。";
      slots = v;
    }
    const replyTo = typeof args.replyTo === "string" && /^[\w-]{1,64}$/.test(args.replyTo) ? args.replyTo : undefined;
    const turnAlly = this.d.turnAlly?.();
    const direct = a.trust === "converse" && (turnAlly === undefined || turnAlly === a.id);
    const e: StoredEntry = {
      id: newId("ae_"),
      allyId: a.id,
      dir: "out",
      ts: this.now(),
      text,
      urgent: !!args.urgent,
      ...(slots ? { slots } : {}),
      ...(replyTo ? { replyTo } : {}),
      status: direct ? "queued" : "draft",
      author: "assistant",
    };
    this.addEntry(a, e);
    this.d.chat.add({ role: "assistant", kind: "ally", text, channel: "system", allyId: a.id, allyName: a.ownerName, dir: "out", entryId: e.id, author: "assistant" });
    if (!direct) {
      this.d.audit.log("ally.draft", { id: e.id, allyId: a.id, chars: text.length, ...(turnAlly ? { inTurnOf: turnAlly } : {}) });
      return allyDraftedText(a.ownerName, e.id);
    }
    this.queueMessage(a, e);
    this.d.audit.log("ally.send", { id: e.id, allyId: a.id, chars: text.length, by: "assistant", ...(turnAlly ? { inTurnOf: turnAlly } : {}) });
    this.emitList();
    this.pump();
    return allySentText(a.ownerName, e.id);
  }

  // say is the owner's own words to an Ally (ally.say): sent as they are,
  // no card, through the outbox like everything else.
  say(id: string, textIn: unknown): AllyEntry {
    const a = this.get(id);
    if (!a || a.pending) throw new Error("没有这个 Ally");
    if (a.removedAt) throw new Error("已经不是 Ally 了");
    const text = typeof textIn === "string" ? textIn.trim() : "";
    if (!text) throw new Error("没有要发的话");
    if (Buffer.byteLength(text) > ALLY_LIMITS.textBytes) throw new Error("太长了，一条不能超过 4 KB");
    const e: StoredEntry = { id: newId("ae_"), allyId: a.id, dir: "out", ts: this.now(), text, urgent: false, status: "queued", author: "owner" };
    this.addEntry(a, e);
    // In the assistant's conversation too, as the owner's words to them.
    this.d.chat.add({ role: "user", kind: "ally", text, channel: "system", allyId: a.id, allyName: a.ownerName, dir: "out", entryId: e.id, author: "owner" });
    this.queueMessage(a, e);
    this.d.audit.log("ally.send", { id: e.id, allyId: a.id, chars: text.length, by: "owner" });
    this.emitList();
    this.pump();
    return publicEntry(e);
  }

  // setTrust is the owner choosing how their assistant answers this Ally
  // (ally.trust). Their host hears it in our next hello, sent now if it can.
  setTrust(id: string, trustIn: unknown): AllyInfo {
    const a = this.get(id);
    if (!a || a.pending || a.removedAt) throw new Error("没有这个 Ally");
    const trust = allyTrust(trustIn);
    if (!trust) throw new Error("档位只能是「能对话」或「每句要你看」");
    if (a.trust !== trust) {
      a.trust = trust;
      this.saveAllies();
      this.d.audit.log("ally.trust", { id: a.id, trust });
      this.emitList();
      void this.announce(a);
    }
    return this.info(a);
  }

  // announce tells an Ally what our hello says now (our level for them).
  private async announce(a: Ally): Promise<void> {
    const cur = this.out.get(a.id);
    if (cur?.conn.open) return cur.conn.send(this.hello(a));
    // A new connection opens with the hello.
    await this.connectOut(a.id, this.target(a)).catch(() => this.noteFail(a.id));
  }

  private queueMessage(a: Ally, e: StoredEntry): void {
    const msg: AllyMessage = {
      type: "ally.message",
      id: e.id,
      text: e.text,
      urgent: e.urgent,
      ...(e.slots ? { slots: e.slots } : {}),
      ...(e.replyTo ? { replyTo: e.replyTo } : {}),
      ts: this.now(),
      author: e.author ?? "assistant",
    };
    this.queue({ key: e.id, allyId: a.id, msg });
  }

  // decide is the owner on a draft card: 发送 / 改一下 / 不发.
  decide(id: string, action: unknown, textIn?: unknown): AllyEntry {
    const found = this.findEntry(id);
    if (!found || found.e.dir !== "out") throw new Error("没有这条草稿");
    const { a, e } = found;
    if (action !== "send" && action !== "edit" && action !== "discard") throw new Error("只能是发送、改一下或不发");
    if (e.status !== "draft") {
      // A retried 发送: it already went (or is going).
      if (action === "send" && e.status !== "rejected") return publicEntry(e);
      throw new Error("这条已经处理过了");
    }
    const text = typeof textIn === "string" ? textIn.trim() : undefined;
    if (text !== undefined && action !== "discard") {
      if (!text) throw new Error("没有要发的话");
      if (Buffer.byteLength(text) > ALLY_LIMITS.textBytes) throw new Error("太长了，一条不能超过 4 KB");
      e.text = text;
    }
    if (action === "edit" && text === undefined) throw new Error("改一下要带上新的文字");
    if (action === "discard") {
      e.status = "rejected";
      e.note = "没发";
    } else if (action === "send") {
      if (a.removedAt) throw new Error("已经不是 Ally 了");
      e.status = "queued";
      this.queueMessage(a, e);
    }
    this.saveLog(a.id);
    this.emitEntry(e);
    this.emitList();
    this.d.audit.log("ally.decide", { id: e.id, action });
    if (action === "send") this.pump();
    return publicEntry(e);
  }

  // ownerActive: the owner synced the app in the foreground or said
  // something. Everything shown to them since now counts as 「已看到」.
  ownerActive(): void {
    let any = false;
    for (const a of this.active()) {
      let changed = false;
      for (const e of this.logOf(a.id)) {
        if (e.dir !== "in" || e.status !== "delivered") continue;
        e.status = "seen";
        changed = true;
        this.emitEntry(e);
        this.queue({ key: `seen:${e.id}`, allyId: a.id, msg: { type: "ally.receipt", id: e.id, state: "seen" } });
      }
      if (changed) {
        this.saveLog(a.id);
        any = true;
      }
    }
    if (any) {
      this.emitList();
      this.pump();
    }
  }

  // ---------------- connections ----------------

  /** The pinned key of an Ally's device on our relay, for the E2E handshake. */
  inboundKey(deviceId: string): Uint8Array | null {
    const a = deviceId ? this.allies.find((x) => !x.removedAt && x.theirDeviceIdHere === deviceId) : undefined;
    return a ? unb64(a.hostKey) : null;
  }

  // attachInbound takes an Ally's stream into our daemon (RelayChannel, after
  // the handshake). Its units come back through the returned handlers.
  attachInbound(deviceId: string, conn: AllyConn): AllyConnHandlers {
    const a = this.allies.find((x) => !x.removedAt && x.theirDeviceIdHere === deviceId);
    if (!a) {
      conn.close();
      return { message: () => {}, closed: () => {} };
    }
    const link: Link = { allyId: a.id, dir: "in", conn, hello: false };
    this.links.add(link);
    return { message: (t) => this.receive(link, t), closed: () => this.dropLink(link) };
  }

  /** Our relay (re)connected: say hello to each Ally, so what they queued for us comes now. */
  onRelayConnected(): void {
    const now = this.now();
    // Revokes that waited for our relay go now.
    for (const i of this.outbox) if (i.revoke) i.nextAt = Math.min(i.nextAt, now);
    for (const a of this.active()) {
      if (now - (this.announced.get(a.id) ?? 0) < allyTiming.announceEveryMs) continue;
      this.announced.set(a.id, now);
      void this.connectOut(a.id, this.target(a)).catch(() => this.noteFail(a.id));
    }
    this.pump();
  }

  private receive(link: Link, raw: string): void {
    const a = this.get(link.allyId);
    const msg = parseAllyWire(raw);
    if (!a || a.removedAt || !msg) return this.refuse(link, a ? "not an ally message" : "unknown ally");
    if (link.dir === "in" && !link.hello && msg.type !== "ally.hello") return this.refuse(link, "hello first");
    if (a.pending && msg.type === "ally.message") return this.refuse(link, "still pairing");
    if (link.dir === "out") this.armIdle(link);
    this.noteOk(a.id);
    switch (msg.type) {
      case "ally.hello":
        return this.onHello(a, msg, link);
      case "ally.message":
        return this.onMessage(a, msg, link);
      case "ally.receipt":
        return this.onReceipt(a, msg);
      case "ally.bye":
        return this.onBye(a, link);
    }
  }

  // Anything but the four ally messages: refused, and the stream closed.
  private refuse(link: Link, why: string): void {
    this.d.audit.log("ally.refused", { allyId: link.allyId, dir: link.dir, why });
    link.conn.close();
    this.dropLink(link);
  }

  private onHello(a: Ally, h: AllyHello, link: Link): void {
    // A later hello on the same connection only brings news (names, their
    // level for us, §11): pairing and the outbox go by the first.
    const again = link.dir === "in" && link.hello;
    link.hello = true;
    if (h.name.trim()) a.ownerName = h.name.trim();
    if (h.assistantName.trim()) a.assistantName = h.assistantName.trim();
    if (h.trust) a.theirTrust = h.trust;
    this.saveAllies();
    if (again) {
      if (!a.pending) this.emitList();
      return;
    }
    if (a.pending) {
      if (link.dir === "in") void this.pairBack(a, h, link);
      else this.pairing.get(a.id)?.hello();
      return;
    }
    this.emitList();
    // They're up: what we queued for them goes now, not at the next retry.
    if (link.dir === "in") {
      for (const i of this.outbox) if (i.allyId === a.id && i.msg) i.nextAt = Math.min(i.nextAt, this.now());
      void this.flush(a.id);
    }
  }

  private onMessage(a: Ally, m: AllyMessage, link: Link): void {
    const now = this.now();
    const reply = (state: AllyReceipt["state"]) => link.conn.send({ type: "ally.receipt", id: m.id, state });
    // A resend of one we already have (our receipt got lost): just say so again.
    if (this.logOf(a.id).some((e) => e.dir === "in" && e.id === m.id)) return reply("delivered");
    const recent = (this.inbound.get(a.id) ?? []).filter((t) => now - t < 3600_000);
    if (!m.text.trim() || Buffer.byteLength(m.text) > ALLY_LIMITS.textBytes || recent.length >= ALLY_LIMITS.perHour) {
      this.d.audit.log("ally.in.rejected", { allyId: a.id, chars: m.text.length, lastHour: recent.length });
      return reply("rejected");
    }
    recent.push(now);
    this.inbound.set(a.id, recent);
    const e: StoredEntry = {
      id: m.id,
      allyId: a.id,
      dir: "in",
      ts: now,
      text: m.text,
      urgent: m.urgent,
      ...(m.slots ? { slots: m.slots } : {}),
      ...(m.replyTo ? { replyTo: m.replyTo } : {}),
      status: "delivered",
      author: m.author,
    };
    this.addEntry(a, e);
    reply("delivered");
    const msg = this.d.chat.add({ role: "system", kind: "ally", text: m.text, channel: "system", allyId: a.id, allyName: a.ownerName, dir: "in", entryId: e.id, author: m.author, proactive: true });
    if (m.urgent) void this.d.router.proactive(msg, { urgent: true, title: allyPushTitle(a.ownerName, m.author) });
    this.turnFor(a, e);
    this.d.audit.log("ally.in", { id: e.id, allyId: a.id, chars: m.text.length, urgent: m.urgent, author: m.author });
    this.emitList();
  }

  // The assistant hears about it in a turn of its own; a second message
  // before that turn starts joins it. The turn is gated (Conversation): it
  // can talk back, read the calendar and memory, nothing else.
  private turnFor(a: Ally, e: StoredEntry): void {
    const block = allyTurnMessage(e, randomBytes(4).toString("hex"), a.ownerName);
    const queued = this.d.findQueued((t) => t.allyId === a.id);
    if (queued) {
      queued.text += `\n\n${block}`;
      return;
    }
    this.d.enqueue({ text: `${allyTurnHeader(a, this.ownerSaidSince(a, e))}\n\n${block}`, origin: "system", proactive: true, label: allyPushTitle(a.ownerName), allyId: a.id });
  }

  // What the owner said to this Ally themselves (ally.say) since its
  // previous message: the assistant didn't see it go out. The last three.
  private ownerSaidSince(a: Ally, e: StoredEntry): string[] {
    const log = this.logOf(a.id);
    const prevIn = log.filter((x) => x.dir === "in" && x !== e).at(-1)?.ts ?? 0;
    return log
      .filter((x) => x.dir === "out" && x.author === "owner" && x.ts >= prevIn && x.status !== "rejected")
      .slice(-3)
      .map((x) => truncate(x.text.replace(/<<</g, "‹‹‹").replace(/>>>/g, "›››").replace(/\s+/g, " "), 200));
  }

  private onReceipt(a: Ally, r: AllyReceipt): void {
    const e = this.logOf(a.id).find((x) => x.dir === "out" && x.id === r.id);
    if (e) {
      let changed = false;
      if (r.state === "rejected" && RANK[e.status] < RANK.delivered) {
        e.status = "rejected";
        e.note = "对方没收";
        changed = true;
      } else if ((r.state === "delivered" || r.state === "seen") && e.status !== "rejected" && RANK[e.status] < RANK[r.state]) {
        e.status = r.state;
        e.deliveredAt ??= this.now();
        changed = true;
      }
      if (changed) {
        this.saveLog(a.id);
        this.emitEntry(e);
        this.emitList();
      }
    }
    // only this Ally's own items: another can't settle what we owe someone else
    this.outbox = this.outbox.filter((i) => i.key !== r.id || i.allyId !== a.id);
    this.saveOutbox();
    const w = this.receipts.get(r.id);
    if (w?.allyId === a.id) {
      this.receipts.delete(r.id);
      w.done(r.state);
    }
  }

  private onBye(a: Ally, link: Link): void {
    if (a.pending) {
      this.pairing.get(a.id)?.fail(new Error("对方没加成功"));
      if (link.dir === "in") this.discardPending(a);
      return;
    }
    this.forget(a, "peer");
    this.d.chat.add({ role: "system", kind: "notice", text: allyByeNotice(a.ownerName), channel: "system" });
  }

  // connectOut returns our connection to an Ally, dialing (and saying hello)
  // if there's none.
  private connectOut(allyId: string, target: AllyTarget, hello?: AllyHello): Promise<Link> {
    const cur = this.out.get(allyId);
    if (cur?.conn.open) return Promise.resolve(cur);
    const inFlight = this.dialing.get(allyId);
    if (inFlight) return inFlight;
    const relay = this.relay;
    if (!relay) return Promise.reject(new Error("relay not started"));
    const p = (async () => {
      const link = { allyId, dir: "out", hello: true } as Link;
      link.conn = await this.dial(target, relay.identity, { message: (t) => this.receive(link, t), closed: () => this.dropLink(link) });
      this.links.add(link);
      this.out.set(allyId, link);
      const a = this.get(allyId);
      const hi = hello ?? (a ? this.hello(a) : null);
      if (hi) link.conn.send(hi);
      this.noteOk(allyId);
      this.armIdle(link);
      return link;
    })();
    this.dialing.set(allyId, p);
    p.finally(() => this.dialing.delete(allyId)).catch(() => {});
    return p;
  }

  private armIdle(link: Link): void {
    if (link.idle) clearTimeout(link.idle);
    link.idle = setTimeout(() => {
      if (this.flushing.has(link.allyId)) return this.armIdle(link);
      link.conn.close();
      this.dropLink(link);
    }, allyTiming.idleMs);
    (link.idle as any).unref?.();
  }

  private dropLink(link: Link): void {
    if (!this.links.delete(link)) return;
    if (link.idle) clearTimeout(link.idle);
    if (this.out.get(link.allyId) === link) this.out.delete(link.allyId);
    if (link.dir === "out") {
      for (const [id, w] of this.receipts) {
        if (w.allyId !== link.allyId) continue;
        this.receipts.delete(id);
        w.done(null);
      }
      this.pairing.get(link.allyId)?.fail(new Error("对方断开了，没加成"));
    }
    this.onlineChanged(link.allyId);
  }

  // ---------------- the outbox ----------------

  private queue(item: Omit<OutItem, "firstAt" | "attempts" | "nextAt">): void {
    const now = this.now();
    this.outbox = this.outbox.filter((i) => i.key !== item.key);
    this.outbox.push({ ...item, firstAt: now, attempts: 0, nextAt: now });
    this.saveOutbox();
  }

  private queueRevoke(deviceId: string): void {
    this.queue({ key: `revoke:${deviceId}`, allyId: "", revoke: deviceId });
  }

  /** Sends whatever is due (exposed for tests; the timer calls it). */
  pump(): void {
    const now = this.now();
    for (const i of this.outbox) if (i.revoke && i.nextAt <= now) void this.sendRevoke(i);
    const due = new Set(this.outbox.filter((i) => i.msg && i.nextAt <= now).map((i) => i.allyId));
    for (const id of due) void this.flush(id);
  }

  private async sendRevoke(item: OutItem): Promise<void> {
    if (this.revoking.has(item.key)) return;
    this.revoking.add(item.key);
    try {
      const ok = this.relay?.state === "connected" ? await this.relay.revokeDevice(item.revoke!) : false;
      if (ok) this.dropItem(item);
      else this.failed(item);
    } finally {
      this.revoking.delete(item.key);
    }
  }

  private async flush(allyId: string): Promise<void> {
    if (this.flushing.has(allyId)) {
      this.again.add(allyId);
      return;
    }
    this.flushing.add(allyId);
    try {
      do {
        this.again.delete(allyId);
        const due = this.outbox.filter((i) => i.allyId === allyId && i.msg && i.nextAt <= this.now());
        if (!due.length) break;
        const a = this.get(allyId);
        const t = due[0]!.target;
        const target = t ? { ...t, hostKey: unb64(t.hostKey) } : a && !a.removedAt && !a.pending ? this.target(a) : null;
        if (!target) {
          for (const i of due) this.dropItem(i);
          continue;
        }
        let link: Link;
        try {
          link = await this.connectOut(allyId, target);
        } catch (e) {
          this.logLine(`can't reach ${allyId}: ${e instanceof Error ? e.message : e}`);
          this.noteFail(allyId);
          for (const i of due) this.failed(i);
          break;
        }
        for (const item of due) {
          if (!this.outbox.includes(item)) continue; // settled meanwhile
          if (!link.conn.open) {
            this.noteFail(allyId);
            this.failed(item);
            continue;
          }
          this.armIdle(link);
          if (item.msg!.type === "ally.message") {
            this.setStatus(allyId, item.key, "sent");
            const answer = new Promise<string | null>((done) => {
              const timer = setTimeout(() => {
                this.receipts.delete(item.key);
                done(null);
              }, allyTiming.receiptMs);
              this.receipts.set(item.key, { allyId, done: (s) => (clearTimeout(timer), done(s)) });
            });
            link.conn.send(item.msg);
            // a receipt settles the item itself (onReceipt)
            if ((await answer) === null) {
              this.noteFail(allyId);
              this.failed(item);
            }
          } else {
            link.conn.send(item.msg);
            this.dropItem(item);
            if (item.msg!.type === "ally.bye") setTimeout(() => link.conn.close(), 500);
          }
        }
      } while (this.again.has(allyId));
    } finally {
      this.flushing.delete(allyId);
    }
  }

  // failed reschedules an item: 30 s, 2 min, 10 min, then every 30 min, and
  // after 3 days gives up (telling the owner if it was their words).
  private failed(item: OutItem): void {
    if (!this.outbox.includes(item)) return;
    const now = this.now();
    item.attempts++;
    if (item.msg?.type === "ally.message") this.setStatus(item.allyId, item.key, "queued");
    if (now - item.firstAt >= allyTiming.giveUpMs) return this.giveUp(item);
    item.nextAt = now + allyTiming.retryMs[Math.min(item.attempts - 1, allyTiming.retryMs.length - 1)]!;
    this.saveOutbox();
  }

  private giveUp(item: OutItem): void {
    this.dropItem(item);
    this.d.audit.log("ally.giveup", { key: item.key, allyId: item.allyId });
    if (item.msg?.type !== "ally.message") return;
    const a = this.get(item.allyId);
    const e = this.logOf(item.allyId).find((x) => x.id === item.key);
    if (!a || !e) return;
    e.status = "rejected";
    e.note = "3 天没送到";
    this.saveLog(a.id);
    this.emitEntry(e);
    const msg = this.d.chat.add({ role: "assistant", kind: "text", text: allyUndeliveredText(a.ownerName, excerpt(e.text)), channel: "system", proactive: true });
    void this.d.router.proactive(msg);
  }

  private dropItem(item: OutItem): void {
    this.outbox = this.outbox.filter((i) => i !== item);
    this.saveOutbox();
  }

  private setStatus(allyId: string, id: string, status: AllyStatus): void {
    const e = this.logOf(allyId).find((x) => x.id === id && x.dir === "out");
    if (!e || e.status === status || RANK[e.status] >= RANK.delivered) return;
    e.status = status;
    this.saveLog(allyId);
    this.emitEntry(e);
  }

  // ---------------- housekeeping ----------------

  /** Expiries, 「还没看到」, half-done pairings, and the outbox (every 15 s). */
  tick(): void {
    const now = this.now();
    if (this.inv && now >= this.inv.expiresAt) this.closeInvite();
    if (this.back && now >= this.back.until + allyTiming.acceptMs) this.back = null;
    for (const a of this.allies.filter((x) => x.pending && now - x.pairedAt > allyTiming.pendingMs && !this.pairing.has(x.id))) this.discardPending(a);
    const quiet = this.d.router.isQuiet();
    for (const a of this.allies.filter((x) => !x.pending)) {
      let changed = false;
      for (const e of this.logOf(a.id)) {
        if (e.dir !== "out") continue;
        if (e.status === "draft" && now - e.ts >= allyTiming.draftMs) {
          e.status = "rejected";
          e.note = "草稿过期了";
          changed = true;
          this.emitEntry(e);
        } else if (e.status === "delivered" && !e.nudgedAt && e.deliveredAt && now - e.deliveredAt >= allyTiming.notSeenMs && !quiet && !a.removedAt) {
          // Told once, to the owner only: the other side isn't chased.
          e.nudgedAt = now;
          changed = true;
          const hours = Math.round((now - e.deliveredAt) / 3600_000);
          const msg = this.d.chat.add({ role: "assistant", kind: "text", text: allyNotSeenText(a.ownerName, hours, excerpt(e.text)), channel: "system", proactive: true });
          void this.d.router.proactive(msg);
        }
      }
      if (changed) this.saveLog(a.id);
    }
    for (const a of this.active()) this.onlineChanged(a.id);
    this.pump();
  }

  // ---------------- internals ----------------

  private active(): Ally[] {
    return this.allies.filter((a) => !a.removedAt && !a.pending);
  }

  private get(id: string): Ally | undefined {
    return this.allies.find((a) => a.id === id);
  }

  // find resolves ally_send's `to`: an id, or a name the owner would use.
  private find(to: string): Ally | undefined {
    const t = String(to ?? "").trim().toLowerCase();
    const list = this.active();
    return (
      list.find((a) => a.id === to) ??
      list.find((a) => a.ownerName.toLowerCase() === t || a.assistantName.toLowerCase() === t) ??
      (t ? list.find((a) => a.ownerName.toLowerCase().includes(t) || t.includes(a.ownerName.toLowerCase())) : undefined)
    );
  }

  private findEntry(id: string): { a: Ally; e: StoredEntry } | undefined {
    for (const a of this.allies) {
      if (a.pending) continue;
      const e = this.logOf(a.id).find((x) => x.id === id);
      if (e) return { a, e };
    }
    return undefined;
  }

  private target(a: Ally): AllyTarget {
    return { relay: a.relay, daemonId: a.daemonId, deviceId: a.myDeviceIdThere, hostKey: unb64(a.hostKey) };
  }

  private hello(a: Ally, extra: Partial<AllyHello> = {}): AllyHello {
    return { type: "ally.hello", name: this.ownerName(), assistantName: this.d.settings().assistantName || "Palo", kind: a.kind, version: VERSION, trust: a.trust, ...extra };
  }

  private ownerName(): string {
    return ownerDisplayName(this.d.paths.userMd, this.d.hostName());
  }

  private readyRelay(): AllyRelay {
    if (!this.relay) throw new Error("远程连接没开启，加不了 Ally");
    if (this.relay.state !== "connected") throw new Error("还没连上中转服务器，稍后再试");
    return this.relay;
  }

  private info(a: Ally): AllyInfo {
    const last = this.logOf(a.id).at(-1);
    return {
      id: a.id,
      kind: a.kind,
      ownerName: a.ownerName,
      assistantName: a.assistantName,
      online: this.online(a),
      lastSeen: a.lastSeen,
      ...(last ? { lastEntry: publicEntry(last) } : {}),
      trust: a.trust,
      ...(a.theirTrust ? { theirTrust: a.theirTrust } : {}),
    };
  }

  // online: a connection is up, or one worked in the last few minutes and
  // nothing failed since.
  private online(a: Ally): boolean {
    for (const l of this.links) if (l.allyId === a.id && l.conn.open) return true;
    const c = this.contact.get(a.id);
    return !!c && this.now() - c.okAt < allyTiming.onlineMs && c.failAt <= c.okAt;
  }

  private noteOk(allyId: string): void {
    const now = this.now();
    const c = this.contact.get(allyId) ?? { okAt: 0, failAt: 0 };
    c.okAt = now;
    this.contact.set(allyId, c);
    const a = this.get(allyId);
    if (a && !a.pending && now - a.lastSeen > 60_000) {
      a.lastSeen = now;
      this.saveAllies();
    }
    this.onlineChanged(allyId);
  }

  private noteFail(allyId: string): void {
    const c = this.contact.get(allyId) ?? { okAt: 0, failAt: 0 };
    c.failAt = this.now();
    this.contact.set(allyId, c);
    this.onlineChanged(allyId);
  }

  private onlineChanged(allyId: string): void {
    const a = this.get(allyId);
    if (!a || a.pending || a.removedAt) return;
    const now = this.online(a);
    if (this.wasOnline.get(allyId) === now) return;
    this.wasOnline.set(allyId, now);
    this.emitList();
  }

  private logPath(id: string): string {
    return join(this.d.paths.allyLogs, `${id}.jsonl`);
  }

  private logOf(id: string): StoredEntry[] {
    let l = this.logs.get(id);
    if (!l) {
      l = readJsonl<StoredEntry>(this.logPath(id));
      this.logs.set(id, l);
    }
    return l;
  }

  private addEntry(a: Ally, e: StoredEntry): void {
    this.logOf(a.id).push(e);
    this.saveLog(a.id);
    this.emitEntry(e);
  }

  private saveLog(id: string): void {
    writeJsonl(this.logPath(id), this.logOf(id));
  }

  private saveAllies(): void {
    writeJson(this.d.paths.allies, this.allies);
  }

  private saveOutbox(): void {
    writeJson(this.d.paths.alliesOutbox, this.outbox);
  }

  private emitList(): void {
    this.d.bus.emit("ally.updated", { allies: this.list() });
  }

  private emitEntry(e: StoredEntry): void {
    this.d.bus.emit("ally.entry", { entry: publicEntry(e) });
  }
}

// The wire entry, without our bookkeeping. Entries from before §11 were all
// the assistants' words.
function publicEntry(e: StoredEntry): AllyEntry {
  const { deliveredAt: _d, nudgedAt: _n, ...rest } = e;
  return { ...rest, author: e.author ?? "assistant" };
}

// Plain words for a failed accept.
function acceptError(e: unknown): string {
  if (e instanceof PairError) {
    if (e.status === 401) return "邀请码不对，或者已经用过了，请对方重新打开二维码";
    if (e.status === 400) return "邀请已经失效了，请对方重新打开二维码";
    if (e.status === 503) return "对方的电脑现在不在线";
    if (e.status === 429) return "试得太多了，等一分钟再试";
    if (e.status === 502) return "对方没接受，邀请可能已经用过了";
    return "对方的电脑没回应，再试一次";
  }
  const m = e instanceof Error ? e.message : String(e);
  return /[一-鿿]/.test(m) ? m : "没加成，再试一次";
}

let accountName: string | null = null;

// ownerDisplayName is how the owner is called on the other side: the
// 「称呼」/「名字」 line in user.md, else the computer account's full name,
// else the computer's name.
export function ownerDisplayName(userMd: string, fallback: string): string {
  try {
    const m = /^[-*\s]*(?:称呼|名字|姓名)\s*[:：]\s*(.+?)\s*$/m.exec(readFileSync(userMd, "utf8"));
    if (m?.[1]) return m[1].slice(0, 30);
  } catch {
    /* no user.md */
  }
  if (accountName === null) {
    accountName = "";
    if (process.platform === "darwin") {
      const r = spawnSync("id", ["-F"], { encoding: "utf8", timeout: 2_000 });
      if (r.status === 0) accountName = r.stdout.trim().slice(0, 30);
    }
  }
  return accountName || fallback;
}
