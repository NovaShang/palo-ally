import { describe, expect, test } from "bun:test";
import { x25519 } from "@noble/curves/ed25519.js";
import { resolve } from "node:path";
import { checkFixture } from "./helpers.ts";
import {
  Opener,
  Sealer,
  b64,
  clientHello,
  clientSigMsg,
  deriveKeys,
  hostAccept,
  newIdentity,
  nonceFor,
  parseHandshake,
  parseSshWirePubkey,
  sign,
  sshWirePubkey,
} from "../src/proto/e2e.ts";

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const seed = (n: number) => new Uint8Array(32).fill(n);

describe("E2E", () => {
  test("handshake round trip and sealed messages both ways", () => {
    const host = newIdentity();
    const dev = newIdentity();
    const hello = clientHello(dev, "dev-1");
    const acc = hostAccept(parseHandshake(hello.unit), host, (id) => (id === "dev-1" ? dev.pub : null));
    const client = hello.finish(parseHandshake(acc.reply), host.pub);
    for (let i = 0; i < 3; i++) {
      expect(acc.secure.opener.open(client.sealer.seal(`c${i}`))).toBe(`c${i}`);
      expect(client.opener.open(acc.secure.sealer.seal(`h${i}`))).toBe(`h${i}`);
    }
  });

  test("rejects unknown device, bad device signature, wrong host key", () => {
    const host = newIdentity();
    const dev = newIdentity();
    const other = newIdentity();
    expect(() => hostAccept(parseHandshake(clientHello(dev, "x").unit), host, () => null)).toThrow("unknown device");
    expect(() => hostAccept(parseHandshake(clientHello(other, "dev").unit), host, () => dev.pub)).toThrow("bad device signature");
    const hello = clientHello(dev, "dev");
    const acc = hostAccept(parseHandshake(hello.unit), host, () => dev.pub);
    expect(() => hello.finish(parseHandshake(acc.reply), other.pub)).toThrow("bad host signature");
  });

  test("tampering, replay, and reordering fail", () => {
    const k = new Uint8Array(32).fill(7);
    const s = new Sealer(k);
    const u0 = s.seal("a");
    const u1 = s.seal("b");
    const tampered = u0.slice();
    tampered[3]! ^= 1;
    expect(() => new Opener(k).open(tampered)).toThrow();
    const o = new Opener(k);
    expect(() => o.open(u1)).toThrow(); // out of order
    const o2 = new Opener(k);
    o2.open(u0);
    expect(() => o2.open(u0)).toThrow(); // replay
  });

  test("ssh wire pubkey round trip", () => {
    const id = newIdentity();
    const w = sshWirePubkey(id.pub);
    expect(Buffer.from(w, "base64").length).toBe(51);
    expect(hex(parseSshWirePubkey(w)!)).toBe(hex(id.pub));
  });

  test("nonce layout", () => {
    expect(hex(nonceFor(1n))).toBe("000000000000000000000001");
    expect(hex(nonceFor(258n))).toBe("000000000000000000000102");
  });

  // Deterministic vectors for the Swift client's interop test.
  test("writes interop vectors", () => {
    const device = newIdentity(seed(1));
    const host = newIdentity(seed(2));
    const ephCSeed = seed(3);
    const ephHSeed = seed(4);
    const ephC = x25519.getPublicKey(ephCSeed);
    const ephH = x25519.getPublicKey(ephHSeed);
    const { c2h, h2c } = deriveKeys(x25519.getSharedSecret(ephCSeed, ephH), ephC, ephH);
    const hello = clientHello(device, "dev-vec", ephCSeed);
    const acc = hostAccept(parseHandshake(hello.unit), host, () => device.pub, ephHSeed);
    const welcome = parseHandshake(acc.reply);
    const plaintext = JSON.stringify({ id: 1, method: "hello", params: { client: "ios" } });
    const vectors = {
      device_seed_hex: hex(device.seed),
      device_pub_b64: b64(device.pub),
      host_seed_hex: hex(host.seed),
      host_pub_b64: b64(host.pub),
      eph_c_seed_hex: hex(ephCSeed),
      eph_h_seed_hex: hex(ephHSeed),
      eph_c_pub_b64: b64(ephC),
      eph_h_pub_b64: b64(ephH),
      // Ed25519 signatures are deterministic, so these are exact
      client_sig_b64: b64(sign(device, clientSigMsg(ephC))),
      host_sig_b64: welcome.sig,
      device_ssh_wire_b64: sshWirePubkey(device.pub),
      k_c2h_hex: hex(c2h),
      k_h2c_hex: hex(h2c),
      plaintext,
      c2h_unit0_hex: hex(new Sealer(c2h).seal(plaintext)),
      h2c_unit0_hex: hex(new Sealer(h2c).seal(plaintext)),
    };
    expect(welcome.eph).toBe(vectors.eph_h_pub_b64);
    checkFixture(resolve(import.meta.dir, "../../ios/PaloAllyKit/Tests/PaloAllyKitTests/Fixtures/e2e-vectors.json"), vectors);
  });
});
