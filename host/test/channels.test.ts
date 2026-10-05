import { describe, expect, test } from "bun:test";
import { createVerify, generateKeyPairSync } from "node:crypto";
import { createServer } from "node:http2";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { ApnsPusher, apnsJwt } from "../src/channels/apns.ts";
import { WechatILink, splitText } from "../src/channels/wechat.ts";
import { writeJson } from "../src/util.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

// A tiny in-memory iLink server.
function ilink() {
  const sent: any[] = [];
  const headers: Record<string, string>[] = [];
  let updates: any[] = [];
  let ret = 0;
  let qrPolls = 0;
  const fetchFn = async (url: string, init?: RequestInit) => {
    const u = new URL(url);
    headers.push(Object.fromEntries(Object.entries((init?.headers as Record<string, string>) ?? {})));
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    const json = (o: unknown) => new Response(JSON.stringify(o), { headers: { "content-type": "application/json" } });
    switch (u.pathname) {
      case "/ilink/bot/get_bot_qrcode":
        return json({ qrcode: "QR1", qrcode_img_content: "https://wx/qr/QR1" });
      case "/ilink/bot/get_qrcode_status":
        qrPolls++;
        return json(qrPolls < 2 ? { status: "wait" } : qrPolls < 3 ? { status: "scaned" } : { status: "confirmed", bot_token: "TOK", ilink_bot_id: "bot1", ilink_user_id: "owner" });
      case "/ilink/bot/getupdates": {
        const msgs = updates;
        updates = [];
        return json({ ret, msgs, get_updates_buf: `buf-${body.get_updates_buf}x` });
      }
      case "/ilink/bot/sendmessage":
        sent.push(body.msg);
        return json({ ret: 0 });
    }
    return json({ ret: -1 });
  };
  return {
    fetchFn,
    sent,
    headers,
    push: (m: any) => updates.push(m),
    setRet: (r: number) => (ret = r),
  };
}

const userMsg = (from: string, text: string, ctx = "ctx-1") => ({
  message_type: 1,
  from_user_id: from,
  to_user_id: "bot1",
  context_token: ctx,
  item_list: [{ type: 1, text_item: { text } }],
});

describe("WeChat iLink", () => {
  test("QR login, owner-only receive, reply with context token", async () => {
    const paths = tmpPaths();
    const srv = ilink();
    let now = 1_000_000;
    const w = new WechatILink(paths.wechat, "https://ilink.test", srv.fetchFn, () => now, async () => {});
    const { qrcode, qrUrl } = await w.beginLogin();
    expect(qrUrl).toBe("https://wx/qr/QR1");
    const statuses: string[] = [];
    expect(await w.waitLogin(qrcode, 60_000, (s) => statuses.push(s))).toBe(true);
    expect(statuses).toEqual(["wait", "scaned", "confirmed"]);
    expect(w.status()).toBe("connected");

    const got: string[] = [];
    w.onMessage = (t, target) => got.push(`${t}|${target.contextToken}`);
    srv.push(userMsg("owner", "帮我订个餐厅"));
    srv.push(userMsg("stranger", "hi"));
    srv.push({ message_type: 2, from_user_id: "bot1", item_list: [] }); // bot echo
    srv.push({ ...userMsg("owner", ""), item_list: [{ type: 3, voice_item: { text: "语音转的文字" } }], context_token: "ctx-2" });
    expect(await w.pollOnce()).toBe(2);
    expect(got).toEqual(["帮我订个餐厅|ctx-1", "[语音转文字] 语音转的文字|ctx-2"]);

    const h = srv.headers.at(-1)!;
    expect(h.AuthorizationType).toBe("ilink_bot_token");
    expect(h.Authorization).toBe("Bearer TOK");
    expect(h["X-WECHAT-UIN"]).toBeTruthy();

    await w.reply({ userId: "owner", contextToken: "ctx-2" }, "好的");
    expect(srv.sent[0]).toMatchObject({ to_user_id: "owner", context_token: "ctx-2", message_type: 2, item_list: [{ type: 1, text_item: { text: "好的" } }] });

    // state survives restart (token, owner, cursor)
    const w2 = new WechatILink(paths.wechat, "https://ilink.test", srv.fetchFn, () => now);
    expect(w2.loggedIn).toBe(true);
    cleanup(paths);
  });

  test("limits: ≤10 per user turn, context expires after 24h, long text is split", async () => {
    const paths = tmpPaths();
    const srv = ilink();
    let now = 1_000_000;
    writeJson(paths.wechat, { botToken: "TOK", ownerUserId: "owner" });
    const w = new WechatILink(paths.wechat, "https://ilink.test", srv.fetchFn, () => now, async () => {});
    expect(await w.sendProactive("x")).toBe(false); // no context yet
    srv.push(userMsg("owner", "hi", "ctx-a"));
    await w.pollOnce();
    for (let i = 0; i < 12; i++) await w.sendProactive(`m${i}`);
    expect(srv.sent).toHaveLength(10);
    expect(w.available()).toBe(false);
    srv.push(userMsg("owner", "again", "ctx-b")); // a new user message resets the turn budget
    await w.pollOnce();
    expect(w.available()).toBe(true);
    now += 24 * 3600_000 + 1;
    expect(w.available()).toBe(false);
    expect(await w.sendProactive("late")).toBe(false);

    const parts = splitText("a".repeat(1000) + "\n" + "b".repeat(1500), 1800);
    expect(parts).toHaveLength(2);
    expect(parts.join("\n")).toBe("a".repeat(1000) + "\n" + "b".repeat(1500));
    cleanup(paths);
  });

  test("quoted messages, media in and out through the encrypted CDN", async () => {
    const paths = tmpPaths();
    const srv = ilink();
    const crypto = await import("node:crypto");
    const key = crypto.randomBytes(16);
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), crypto.randomBytes(40)]);
    const enc = (k: Buffer, b: Buffer) => { const c = crypto.createCipheriv("aes-128-ecb", k, null); return Buffer.concat([c.update(b), c.final()]); };
    let uploaded: Buffer | null = null;
    const sent = srv.sent;
    const fetchFn = async (url: string, init?: RequestInit) => {
      const u = new URL(url);
      if (u.pathname === "/c2c/download") return new Response(new Uint8Array(enc(key, png)));
      if (u.pathname === "/c2c/upload") {
        uploaded = Buffer.from(init!.body as Uint8Array);
        return new Response("", { headers: { "x-encrypted-param": "DL" } });
      }
      if (u.pathname === "/ilink/bot/getuploadurl") return new Response(JSON.stringify({ upload_param: "UP" }));
      return srv.fetchFn(url, init);
    };
    writeJson(paths.wechat, { botToken: "TOK", ownerUserId: "owner" });
    const w = new WechatILink(paths.wechat, "https://ilink.test", fetchFn, Date.now, async () => {}, join(paths.root, "media"));
    const got: string[] = [];
    w.onMessage = (t) => got.push(t);
    srv.push({ ...userMsg("owner", ""), item_list: [{ type: 1, text_item: { text: "这个呢" }, ref_msg: { title: "上一条" } }] });
    srv.push({ ...userMsg("owner", ""), item_list: [{ type: 2, image_item: { media: { encrypt_query_param: "Q" }, aeskey: key.toString("hex") } }] });
    await w.pollOnce();
    expect(got[0]).toBe("[引用: 上一条]\n这个呢");
    const path = got[1]!.replace("[图片] ", "");
    expect(path.endsWith(".png")).toBe(true);
    expect((await import("node:fs")).readFileSync(path).equals(png)).toBe(true);

    expect(await w.sendFile(w.ownerTarget()!, path)).toBe(true);
    expect(uploaded!.length % 16).toBe(0);
    expect(sent.at(-1).item_list[0]).toMatchObject({ type: 2, image_item: { media: { encrypt_query_param: "DL" } } });
    cleanup(paths);
  });

  test("session expiry (-14) marks expired and stops", async () => {
    const paths = tmpPaths();
    const srv = ilink();
    writeJson(paths.wechat, { botToken: "TOK" });
    const w = new WechatILink(paths.wechat, "https://ilink.test", srv.fetchFn, Date.now, async () => {});
    w.log = () => {};
    srv.setRet(-14);
    await w.pollOnce();
    expect(w.status()).toBe("expired");
    cleanup(paths);
  });
});

describe("APNs", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

  test("JWT is ES256 with raw r||s signature", () => {
    const jwt = apnsJwt(pem, "KEYID", "TEAM", 1700000000);
    const [h, b, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h!, "base64url").toString())).toEqual({ alg: "ES256", kid: "KEYID" });
    expect(JSON.parse(Buffer.from(b!, "base64url").toString())).toEqual({ iss: "TEAM", iat: 1700000000 });
    const v = createVerify("SHA256");
    v.update(`${h}.${b}`);
    expect(v.verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s!, "base64url"))).toBe(true);
  });

  test("pushes over HTTP/2 to every token; drops 410 tokens", async () => {
    const paths = tmpPaths();
    const keyPath = join(paths.root, "key.p8");
    writeFileSync(keyPath, pem);
    const seen: { path: string; headers: any; body: any }[] = [];
    const server = createServer();
    server.on("stream", (stream: any, headers) => {
      let body = "";
      stream.on("data", (c: Buffer) => (body += c));
      stream.on("end", () => {
        const path = String(headers[":path"]);
        seen.push({ path, headers, body: JSON.parse(body) });
        stream.respond({ ":status": path.includes("dead") ? 410 : 200 });
        stream.end();
      });
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const port = (server.address() as any).port;
    writeJson(paths.pushTokens, [
      { token: "a".repeat(64), env: "sandbox" },
      { token: "dead" + "b".repeat(60), env: "sandbox" },
    ]);
    const p = new ApnsPusher({ keyPath, keyId: "K", teamId: "T", bundleId: "com.novashang.paloally", host: `http://127.0.0.1:${port}` }, paths.pushTokens, true, "pa-host1");
    expect(p.available()).toBe(true);
    await p.push("标题", "正文", { seq: 3 });
    expect(seen).toHaveLength(2);
    expect(seen[0]!.headers["apns-topic"]).toBe("com.novashang.paloally");
    expect(seen[0]!.headers.authorization).toStartWith("bearer ");
    expect(seen[0]!.body).toMatchObject({ aps: { alert: { title: "标题", body: "正文" } }, seq: 3 });
    expect(seen[0]!.body.hostId).toBe("pa-host1"); // top level, next to aps
    const left = JSON.parse(await Bun.file(paths.pushTokens).text());
    expect(left).toHaveLength(1);
    p.close();
    server.close();
    cleanup(paths);
  });
});

describe("Relay push", () => {
  const { RelayPusher } = require("../src/channels/relayPush.ts") as typeof import("../src/channels/relayPush.ts");
  const tok = (c: string) => c.repeat(64);

  function setup(results: Record<string, { ok: boolean; status: number; reason?: string } | "timeout">, state: "connected" | "disconnected" = "connected") {
    const paths = tmpPaths();
    writeJson(paths.pushTokens, [{ token: tok("a"), env: "sandbox" }, { token: tok("b"), env: "production" }]);
    const sent: any[] = [];
    const relay = {
      state,
      async pushViaRelay(req: any) {
        sent.push(req);
        const r = results[req.token[0]];
        if (r === "timeout" || !r) throw new Error("relay push timed out");
        return r;
      },
    };
    const fallbackCalls: string[] = [];
    const fallback = { name: "apns", available: () => true, push: async (t: string) => void fallbackCalls.push(t) };
    return { paths, sent, relay, fallback, fallbackCalls };
  }

  test("pushes each token through the relay; drops dead tokens", async () => {
    const s = setup({ a: { ok: true, status: 200 }, b: { ok: false, status: 410, reason: "Unregistered" } });
    const p = new RelayPusher(s.relay, s.paths.pushTokens, s.fallback, "pa-host1");
    expect(p.available()).toBe(true);
    await p.push("PaloAlly", "有一条新消息", { seq: 1, taskId: undefined });
    // the relay spreads `data` next to `aps`, so hostId lands top-level in the APNs payload
    expect(s.sent.map((x) => [x.env, x.title, x.data])).toEqual([
      ["sandbox", "PaloAlly", { seq: 1, hostId: "pa-host1" }],
      ["production", "PaloAlly", { seq: 1, hostId: "pa-host1" }],
    ]);
    expect((await import("../src/util.ts")).readJson<any[]>(s.paths.pushTokens, []).map((t) => t.token)).toEqual([tok("a")]);
    expect(s.fallbackCalls).toEqual([]);
    cleanup(s.paths);
  });

  test("falls back to host-direct when the relay can't push (old relay, not configured, offline)", async () => {
    const old = setup({ a: "timeout", b: "timeout" });
    await new RelayPusher(old.relay, old.paths.pushTokens, old.fallback).push("t", "b", {});
    expect(old.fallbackCalls).toEqual(["t"]);
    cleanup(old.paths);

    const nc = setup({ a: { ok: false, status: 0, reason: "NotConfigured" }, b: { ok: false, status: 0, reason: "NotConfigured" } });
    await new RelayPusher(nc.relay, nc.paths.pushTokens, nc.fallback).push("t", "b", {});
    expect(nc.fallbackCalls).toEqual(["t"]);
    cleanup(nc.paths);

    const off = setup({}, "disconnected");
    const p = new RelayPusher(off.relay, off.paths.pushTokens, off.fallback);
    expect(p.available()).toBe(true); // via the fallback
    await p.push("t", "b", {});
    expect(off.sent).toEqual([]);
    expect(off.fallbackCalls).toEqual(["t"]);
    cleanup(off.paths);
  });

  test("without a fallback, a failed push is an error the router logs", async () => {
    const s = setup({ a: { ok: false, status: 0, reason: "NotConfigured" }, b: "timeout" });
    const p = new RelayPusher(s.relay, s.paths.pushTokens);
    await expect(p.push("t", "b", {})).rejects.toThrow("relay push failed");
    const off = setup({}, "disconnected");
    expect(new RelayPusher(off.relay, off.paths.pushTokens).available()).toBe(false);
    cleanup(s.paths);
    cleanup(off.paths);
  });
});
