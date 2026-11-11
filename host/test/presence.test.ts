import { describe, expect, test } from "bun:test";
import { DONE_PUSH, DonePushes, type DonePush } from "../src/donePush.ts";
import { Presence, PRESENCE_TTL_MS } from "../src/presence.ts";
import { Router } from "../src/router.ts";
import { handleRpc } from "../src/rpc.ts";
import type { Audit } from "../src/audit.ts";
import type { ChatMessage } from "../src/types.ts";
import { cleanup, makeHub, RecordingPusher, testConfig } from "./helpers.ts";

const MIN = 60_000;

describe("owner presence", () => {
  test("a connection counts for 90 s after it last said it's in front; leaving or closing ends it at once", () => {
    let clock = 1_000_000;
    const p = new Presence(() => clock);
    expect(p.present()).toBe(false); // an app that never says anything never counts
    expect(p.note("a", true)).toBe(true);
    expect(p.present()).toBe(true);
    clock += PRESENCE_TTL_MS - 1;
    expect(p.present()).toBe(true);
    expect(p.note("a", true)).toBe(false); // the heartbeat: no change
    clock += PRESENCE_TTL_MS - 1;
    expect(p.present()).toBe(true);
    clock += 2;
    expect(p.present()).toBe(false); // no heartbeat for 90 s
    p.note("a", true);
    p.note("b", true);
    p.note("a", false);
    expect(p.present()).toBe(true); // b is still in front
    p.drop("b");
    expect(p.present()).toBe(false); // its connection closed
  });

  test("while present a non-urgent message isn't pushed nor sent to WeChat; urgent and whilePresent ones are; quiet hours still apply to whilePresent", async () => {
    const pusher = new RecordingPusher();
    const logged: { type: string; fields: Record<string, unknown> }[] = [];
    const audit = { log: (type: string, fields: Record<string, unknown> = {}) => logged.push({ type, fields }) } as unknown as Audit;
    const sent: string[] = [];
    const wechat = { available: () => true, sendProactive: async (t: string) => (sent.push(t), true) };
    const config = testConfig((c) => (c.settings.wechatProactive = "full"));
    let present = true;
    let quiet = false;
    const r = new Router(() => ({ ...config.settings, quietHours: quiet ? { start: "00:00", end: "23:59" } : null }), [pusher], wechat, audit);
    r.ownerPresent = () => present;
    const msg = (text: string): ChatMessage => ({ seq: 1, id: `m_${text}`, role: "assistant", kind: "text", text, channel: "system", ts: 1 });
    expect(await r.proactive(msg("一般"))).toEqual({ pushed: false, wechat: false, suppressed: "present" });
    expect(logged.at(-1)).toEqual({ type: "deliver.suppressed", fields: { reason: "present", msg: "m_一般" } });
    expect(pusher.pushes).toEqual([]);
    expect(sent).toEqual([]);
    expect((await r.proactive(msg("紧急"), { urgent: true })).pushed).toBe(true);
    expect((await r.proactive(msg("登录过期"), { whilePresent: true })).pushed).toBe(true);
    expect(pusher.pushes.map((p) => p.body)).toEqual(["紧急", "登录过期"]);
    quiet = true;
    expect((await r.proactive(msg("夜里"), { whilePresent: true })).suppressed).toBe("quiet");
    quiet = false;
    present = false;
    expect((await r.proactive(msg("走开了"))).pushed).toBe(true); // away from the app: as before
    expect(sent).toEqual(["紧急", "登录过期", "走开了"]);
  });

  test("the presence RPC: an open connection in front holds notify_user's push; leaving, or the connection closing, lets it through", async () => {
    const { hub, pusher, paths } = makeHub();
    const h = hub.toolHandlers();
    const ctx = { clientId: "app_1_dev-x", deviceId: "dev-x", channel: "app" as const, local: false };
    // a connection that isn't open doesn't count
    expect(await handleRpc(hub, { method: "presence", params: { active: true } }, ctx)).toEqual({ ok: true });
    expect(await h.notify_user({ text: "一" })).toContain("已推送");
    hub.attach({ id: ctx.clientId, kind: "app", send: () => {} });
    await handleRpc(hub, { method: "presence", params: { active: true } }, ctx);
    expect(await h.notify_user({ text: "二" })).toContain("正在用 App");
    expect(await h.notify_user({ text: "三", urgent: true })).toContain("已推送");
    await handleRpc(hub, { method: "presence", params: { active: false } }, ctx);
    expect(await h.notify_user({ text: "四" })).toContain("已推送");
    await handleRpc(hub, { method: "presence", params: { active: true } }, ctx);
    hub.detach(ctx.clientId);
    expect(await h.notify_user({ text: "五" })).toContain("已推送");
    expect(pusher.pushes.map((p) => p.body)).toEqual(["一", "三", "四", "五"]);
    // the message is in the conversation either way
    expect(hub.chat.recent(10).map((m) => m.text)).toContain("二");
    hub.stop();
    cleanup(paths);
  });
});

describe("「回复了」 pushes", () => {
  function setup() {
    let clock = 10_000_000;
    const sent: DonePush[] = [];
    let due: { fn: () => void; at: number } | null = null;
    const d = new DonePushes({
      now: () => clock,
      send: (p) => sent.push(p),
      later: (fn, ms) => {
        due = { fn, at: clock + ms };
        return () => (due = null);
      },
    });
    const advance = (ms: number) => {
      clock += ms;
      if (due && due.at <= clock) {
        const f = due.fn;
        due = null;
        f();
      }
    };
    return { d, sent, advance, pending: () => due !== null };
  }

  test("only a turn of 2 minutes or more is pushed, with its session's name, first line and id", () => {
    const { d, sent } = setup();
    d.finished("p1", "官网", "改好了", DONE_PUSH.minTurnMs - 1);
    expect(sent).toEqual([]);
    d.finished("p1", "官网", "改好了", DONE_PUSH.minTurnMs);
    expect(sent).toEqual([{ title: "官网 回复了", body: "改好了", pal: "p1" }]);
  });

  test("a session at most once in 10 minutes", () => {
    const { d, sent, advance } = setup();
    d.finished("p1", "官网", "一", 3 * MIN);
    advance(9 * MIN);
    d.finished("p1", "官网", "二", 3 * MIN);
    expect(sent).toHaveLength(1);
    advance(MIN);
    d.finished("p1", "官网", "三", 3 * MIN);
    expect(sent.map((p) => p.body)).toEqual(["一", "三"]);
  });

  test("at most one in 2 minutes overall: sessions finishing meanwhile go out as one 「N 个会话回复了」 without a session id", () => {
    const { d, sent, advance, pending } = setup();
    d.finished("p1", "官网", "一", 3 * MIN);
    advance(30_000);
    d.finished("p2", "笔记整理", "二", 3 * MIN);
    advance(30_000);
    d.finished("p3", "日志", "三", 3 * MIN);
    expect(sent).toHaveLength(1);
    expect(pending()).toBe(true);
    advance(59_999);
    expect(sent).toHaveLength(1);
    advance(1);
    expect(sent[1]).toEqual({ title: "2 个会话回复了", body: "笔记整理、日志" });
    // only one held: its own push, when the 2 minutes are up
    advance(MIN);
    d.finished("p4", "设计", "四", 3 * MIN);
    expect(sent).toHaveLength(2);
    advance(MIN);
    expect(sent[2]).toEqual({ title: "设计 回复了", body: "四", pal: "p4" });
  });

  test("a long list is cut short; English too", async () => {
    const { setLang } = await import("../src/i18n/index.ts");
    const { d, sent, advance } = setup();
    d.finished("p0", "零", "零", 3 * MIN);
    for (let i = 1; i <= 7; i++) d.finished(`p${i}`, `会话${i}`, "x", 3 * MIN);
    advance(2 * MIN);
    expect(sent[1]).toEqual({ title: "7 个会话回复了", body: "会话1、会话2、会话3、会话4、会话5 等" });
    setLang("en");
    try {
      d.finished("a", "Site", "x", 3 * MIN);
      d.finished("b", "Notes", "x", 3 * MIN);
      advance(2 * MIN);
      expect(sent[2]).toEqual({ title: "2 sessions replied", body: "Site, Notes" });
    } finally {
      setLang("zh");
    }
  });
});
