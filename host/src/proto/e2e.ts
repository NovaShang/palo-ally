import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { ed25519, x25519 } from "@noble/curves/ed25519.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { randomBytes } from "node:crypto";

// E2E layer for one relay stream (docs/design.md §5.2). Each WebSocket
// message is one unit: 0x01 = plaintext JSON handshake, 0x02 = sealed.

export const UNIT_HANDSHAKE = 0x01;
export const UNIT_SEALED = 0x02;
const enc = new TextEncoder();
const dec = new TextDecoder();

export const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64");
export const unb64 = (s: string) => new Uint8Array(Buffer.from(s, "base64"));
export const b64url = (b: Uint8Array) => Buffer.from(b).toString("base64url");
export const unb64url = (s: string) => new Uint8Array(Buffer.from(s, "base64url"));

export interface Identity {
  seed: Uint8Array; // 32-byte Ed25519 secret
  pub: Uint8Array; // 32-byte Ed25519 public
}

export function newIdentity(seed: Uint8Array = randomBytes(32)): Identity {
  return { seed, pub: ed25519.getPublicKey(seed) };
}

export function sign(id: Identity, msg: Uint8Array | string): Uint8Array {
  return ed25519.sign(typeof msg === "string" ? enc.encode(msg) : msg, id.seed);
}

export function verify(pub: Uint8Array, msg: Uint8Array | string, sig: Uint8Array): boolean {
  try {
    return ed25519.verify(sig, typeof msg === "string" ? enc.encode(msg) : msg, pub);
  } catch {
    return false;
  }
}

// SSH wire format of an Ed25519 public key, as the relay's /v1/pair expects.
export function sshWirePubkey(pub: Uint8Array): string {
  const name = enc.encode("ssh-ed25519");
  const buf = new Uint8Array(4 + name.length + 4 + 32);
  const dv = new DataView(buf.buffer);
  dv.setUint32(0, name.length);
  buf.set(name, 4);
  dv.setUint32(4 + name.length, 32);
  buf.set(pub, 8 + name.length);
  return b64(buf);
}

export function parseSshWirePubkey(s: string): Uint8Array | null {
  const raw = unb64(s);
  if (raw.length < 51) return null;
  if (dec.decode(raw.slice(4, 15)) !== "ssh-ed25519") return null;
  return raw.slice(19, 51);
}

export function fingerprint(pub: Uint8Array): string {
  return "SHA256:" + Buffer.from(sha256(pub)).toString("base64").replace(/=+$/, "");
}

const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
};

export const clientSigMsg = (ephC: Uint8Array) => concat(enc.encode("paloally-hs1|c|"), ephC);
export const hostSigMsg = (ephC: Uint8Array, ephH: Uint8Array) => concat(enc.encode("paloally-hs1|h|"), ephC, ephH);

export function deriveKeys(shared: Uint8Array, ephC: Uint8Array, ephH: Uint8Array): { c2h: Uint8Array; h2c: Uint8Array } {
  const salt = concat(ephC, ephH);
  return {
    c2h: hkdf(sha256, shared, salt, enc.encode("paloally c2h"), 32),
    h2c: hkdf(sha256, shared, salt, enc.encode("paloally h2c"), 32),
  };
}

export function nonceFor(counter: bigint): Uint8Array {
  const n = new Uint8Array(12);
  new DataView(n.buffer).setBigUint64(4, counter);
  return n;
}

// Sealer/Opener hold one direction's key and counter.
export class Sealer {
  private counter = 0n;
  constructor(private key: Uint8Array) {}
  seal(plaintext: Uint8Array | string): Uint8Array {
    const pt = typeof plaintext === "string" ? enc.encode(plaintext) : plaintext;
    const ct = chacha20poly1305(this.key, nonceFor(this.counter++)).encrypt(pt);
    return concat(new Uint8Array([UNIT_SEALED]), ct);
  }
}

export class Opener {
  private counter = 0n;
  constructor(private key: Uint8Array) {}
  open(unit: Uint8Array): string {
    if (unit[0] !== UNIT_SEALED) throw new Error("not a sealed unit");
    const pt = chacha20poly1305(this.key, nonceFor(this.counter)).decrypt(unit.slice(1));
    this.counter++;
    return dec.decode(pt);
  }
}

export function handshakeUnit(obj: unknown): Uint8Array {
  return concat(new Uint8Array([UNIT_HANDSHAKE]), enc.encode(JSON.stringify(obj)));
}

export function parseHandshake(unit: Uint8Array): any {
  if (unit[0] !== UNIT_HANDSHAKE) throw new Error("expected handshake unit");
  return JSON.parse(dec.decode(unit.slice(1)));
}

export interface Secure {
  sealer: Sealer;
  opener: Opener;
}

// ---- host side ----

// hostAccept handles the client's hello. lookupDevice returns the device's
// pinned Ed25519 pubkey (from pairing) or null.
export function hostAccept(
  hello: any,
  host: Identity,
  lookupDevice: (deviceId: string) => Uint8Array | null,
  ephSeed: Uint8Array = randomBytes(32),
): { reply: Uint8Array; secure: Secure; deviceId: string } {
  if (hello?.t !== "hello" || hello.v !== 1) throw new Error("bad hello");
  const deviceId = String(hello.device_id ?? "");
  const devicePub = lookupDevice(deviceId);
  if (!devicePub) throw new Error("unknown device");
  const ephC = unb64(String(hello.eph ?? ""));
  if (ephC.length !== 32) throw new Error("bad eph");
  if (!verify(devicePub, clientSigMsg(ephC), unb64(String(hello.sig ?? "")))) throw new Error("bad device signature");
  const ephH = x25519.getPublicKey(ephSeed);
  const shared = x25519.getSharedSecret(ephSeed, ephC);
  const { c2h, h2c } = deriveKeys(shared, ephC, ephH);
  const reply = handshakeUnit({ t: "welcome", v: 1, eph: b64(ephH), sig: b64(sign(host, hostSigMsg(ephC, ephH))) });
  return { reply, secure: { sealer: new Sealer(h2c), opener: new Opener(c2h) }, deviceId };
}

// ---- client side (used by tests and the CLI's remote mode) ----

export function clientHello(device: Identity, deviceId: string, ephSeed: Uint8Array = randomBytes(32)) {
  const ephC = x25519.getPublicKey(ephSeed);
  const unit = handshakeUnit({ t: "hello", v: 1, device_id: deviceId, eph: b64(ephC), sig: b64(sign(device, clientSigMsg(ephC))) });
  return {
    unit,
    finish(welcome: any, hostPub: Uint8Array): Secure {
      if (welcome?.t !== "welcome") throw new Error(welcome?.error ?? "handshake rejected");
      const ephH = unb64(String(welcome.eph));
      if (!verify(hostPub, hostSigMsg(ephC, ephH), unb64(String(welcome.sig)))) throw new Error("bad host signature");
      const shared = x25519.getSharedSecret(ephSeed, ephH);
      const { c2h, h2c } = deriveKeys(shared, ephC, ephH);
      return { sealer: new Sealer(c2h), opener: new Opener(h2c) };
    },
  };
}
