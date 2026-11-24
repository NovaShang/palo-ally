import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { askPlan, loginAccount, planReport } from "../src/harness/claude/usage.ts";
import type { PlanReport } from "../src/harness/types.ts";
import { PlanUsage } from "../src/planUsage.ts";
import { handleRpc } from "../src/rpc.ts";
import type { UsageStatus } from "../src/types.ts";
import { cleanup, makeHub, tick, tmpPaths } from "./helpers.ts";

// Claude 用量: what Claude Code answers, as the host takes it (the method is
// experimental, so nothing in it is relied on), when it's asked, and where
// the answer goes.

const AT = "2026-11-26T01:00:00.123456+00:00";
const MS = Date.parse(AT);

describe("the usage method's answer", () => {
  // the shape seen on SDK 0.3.322: no five-hour window, the server's rows, and a lot of nulls
  const seen = {
    session: { total_cost_usd: 1.5, model_usage: {} },
    subscription_type: "max",
    rate_limits_available: true,
    rate_limits: {
      five_hour: null,
      seven_day: { utilization: 57, resets_at: AT, limit_dollars: null, used_dollars: null },
      seven_day_opus: null,
      tangelo: null,
      limits: [
        { kind: "weekly_all", group: "weekly", percent: 57, severity: "normal", resets_at: AT, scope: null, is_active: true },
        { kind: "weekly_scoped", group: "weekly", percent: 44.4, severity: "normal", resets_at: AT, scope: { model: { id: null, display_name: "Opus" }, surface: null }, is_active: false },
      ],
      spend: { used: { amount_minor: 1234, currency: "USD" }, percent: 3 },
      extra_usage: { is_enabled: false, monthly_limit: 5000, used_credits: 12, utilization: 1, currency: "USD" },
      model_scoped: [{ display_name: "Opus", utilization: 44, resets_at: AT }],
    },
    behaviors: null,
  };

  test("the server's rows, in its order, whatever they are; no money", () => {
    const r = planReport(seen, { email: "lin@example.com", plan: "max" });
    expect(r).toEqual({
      plan: "limits",
      account: { email: "lin@example.com", plan: "max" },
      limits: [
        { kind: "weekly_all", group: "weekly", used: 57, resetsAt: MS, windowMs: 7 * 86400_000 },
        { kind: "weekly_scoped", group: "weekly", used: 44, resetsAt: MS, windowMs: 7 * 86400_000, scope: "Opus" },
      ],
      extraUsage: false,
    });
    expect(JSON.stringify(r)).not.toMatch(/USD|1234|5000/);
  });

  test("without the rows, the windows it types; what's null isn't there", () => {
    const { limits: _, ...typed } = seen.rate_limits;
    expect(planReport({ ...seen, rate_limits: typed }).limits.map((l) => [l.kind, l.scope, l.used])).toEqual([["weekly_all", undefined, 57], ["weekly_scoped", "Opus", 44]]);
    const all = { five_hour: { utilization: 112.6, resets_at: null }, seven_day_opus: { utilization: 9, resets_at: AT }, seven_day_sonnet: null };
    expect(planReport({ ...seen, rate_limits: all }).limits).toEqual([
      { kind: "session", group: "session", used: 100, windowMs: 5 * 3600_000 },
      { kind: "weekly_scoped", group: "weekly", used: 9, resetsAt: MS, windowMs: 7 * 86400_000, scope: "Opus" },
    ]);
    // a kind it doesn't know comes as it is; a row without numbers doesn't
    const odd = { limits: [{ kind: "monthly", group: "monthly", percent: 3, resets_at: "soon" }, { kind: "weekly_all", percent: "57" }, null, 7] };
    expect(planReport({ ...seen, rate_limits: odd }).limits).toEqual([{ kind: "monthly", group: "monthly", used: 3 }]);
  });

  test("a login without limits, one that may not see them, and no answer", () => {
    const off = { ...seen, rate_limits_available: false, rate_limits: null };
    expect(planReport({ ...off, subscription_type: null }, { apiKeySource: "ANTHROPIC_API_KEY" }).plan).toBe("none");
    expect(planReport({ ...off, subscription_type: null }, { provider: "bedrock" }).plan).toBe("none");
    expect(planReport(off, { email: "lin@example.com", plan: "max" }).plan).toBe("hidden");
    expect(planReport({ ...seen, rate_limits: null }).plan).toBe("unreadable");
    for (const x of [null, undefined, "x", 3]) expect(planReport(x, { plan: "max" })).toEqual({ plan: "unreadable", limits: [], account: { plan: "max" } });
  });

  test("the account: the plan's bare name; a key and another provider said, the usual login not", () => {
    expect(loginAccount({ email: "lin@example.com", organization: "Lin", subscriptionType: "Claude Max", apiProvider: "firstParty" })).toEqual({ email: "lin@example.com", organization: "Lin", plan: "max" });
    expect(loginAccount({ apiProvider: "firstParty", apiKeySource: "ANTHROPIC_API_KEY" })).toEqual({ apiKeySource: "ANTHROPIC_API_KEY" });
    expect(loginAccount({ apiProvider: "bedrock" })).toEqual({ provider: "bedrock" });
    expect(loginAccount({ apiProvider: "firstParty", apiKeySource: "none" })).toBeUndefined();
    expect(loginAccount(null)).toBeUndefined();
  });

  test("the method gone or failing: the account alone; `behaviors` never asked for", async () => {
    const account = async () => ({ email: "lin@example.com", subscriptionType: "max" });
    const alone = { limits: [], account: { email: "lin@example.com", plan: "max" } };
    expect(await askPlan({ accountInfo: account })).toEqual({ plan: "unsupported", ...alone });
    const NAME = "usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET";
    for (const bad of [async () => Promise.reject(new Error("x")), () => { throw new Error("x"); }]) {
      expect(await askPlan({ accountInfo: account, [NAME]: bad } as any)).toEqual({ plan: "unreadable", ...alone });
    }
    const opts: unknown[] = [];
    const q = { accountInfo: async () => Promise.reject(new Error("x")), [NAME]: async (o: unknown) => (opts.push(o), seen) };
    expect((await askPlan(q as any)).limits).toHaveLength(2);
    expect(opts).toEqual([{ skipBehaviors: true }]);
  });
});

const MIN = 60_000;
const LIMITS = (used = 48, resetsAt?: number): PlanReport => ({
  plan: "limits",
  account: { email: "lin@example.com", plan: "max" },
  limits: [{ kind: "session", group: "session", used, ...(resetsAt ? { resetsAt } : {}) }],
});

function make(o: { path?: string; now?: number; timeoutMs?: number } = {}) {
  const paths = tmpPaths();
  const path = o.path ?? `${paths.state}/plan-usage.json`;
  const c = {
    paths, path, now: o.now ?? 1_000_000_000_000, asked: 0, working: false, up: true,
    answer: (async () => LIMITS()) as () => Promise<PlanReport>,
    changes: [] as UsageStatus[], logs: [] as string[],
  };
  const u = new PlanUsage({
    path,
    ask: () => (c.up ? (c.asked++, c.answer()) : undefined),
    working: () => c.working,
    changed: (s) => c.changes.push(s),
    log: (s) => c.logs.push(s),
    now: () => c.now,
    ...(o.timeoutMs ? { timeoutMs: o.timeoutMs } : {}),
  });
  return { u, c };
}

describe("when it's asked", () => {
  test("the page: what's known at once, asked again a minute later, not twice in one", async () => {
    const { u, c } = make();
    expect(u.get(true)).toEqual({ state: "loading", limits: [] });
    expect(u.get(true).state).toBe("loading"); // one question at a time
    await tick(1);
    expect(c.asked).toBe(1);
    expect(u.get(true)).toMatchObject({ state: "limits", at: c.now });
    expect(c.asked).toBe(1);
    c.now += MIN;
    c.answer = async () => LIMITS(60);
    expect(u.get(true).limits[0]!.used).toBe(48);
    await tick(1);
    expect(c.asked).toBe(2);
    expect(c.changes.map((s) => s.limits[0]!.used)).toEqual([48, 60]);
    // an app that connects is answered from what's kept, ten minutes long
    c.now += 9 * MIN;
    u.get();
    expect(c.asked).toBe(2);
    c.now += MIN;
    u.get();
    expect(c.asked).toBe(3);
    cleanup(c.paths);
  });

  test("every ten minutes while something works, never while nothing does", async () => {
    const { u, c } = make();
    await u.refresh();
    c.now += 60 * MIN;
    u.tick();
    expect(c.asked).toBe(1);
    c.working = true;
    u.tick();
    await tick(1);
    expect(c.asked).toBe(2);
    c.now += 9 * MIN;
    u.tick();
    expect(c.asked).toBe(2);
    c.now += MIN;
    u.tick();
    expect(c.asked).toBe(3);
    cleanup(c.paths);
  });

  test("a limit that resets is asked about, and for a while again if the answer is still the old one", async () => {
    const { u, c } = make();
    const resetsAt = c.now + 30 * MIN;
    c.answer = async () => LIMITS(84, resetsAt);
    await u.refresh();
    c.now = resetsAt - 1;
    u.tick();
    expect(c.asked).toBe(1);
    c.now = resetsAt;
    u.tick();
    await tick(1);
    expect(c.asked).toBe(2);
    for (let i = 0; i < 60; i++) {
      c.now += MIN;
      u.tick();
      await tick(0);
    }
    expect(c.asked).toBe(2 + 5); // every five minutes, for half an hour
    cleanup(c.paths);
  });

  test("no process up: nothing asked, nothing changed, asked when it comes up", async () => {
    const { u, c } = make();
    c.up = false;
    u.get(true);
    c.working = true;
    u.tick();
    await tick(1);
    expect(c.asked).toBe(0);
    expect(c.changes).toEqual([]);
    c.up = true;
    u.processUp();
    await tick(1);
    expect(u.status.state).toBe("limits");
    u.processUp(); // again soon: no need
    expect(c.asked).toBe(1);
    cleanup(c.paths);
  });
});

describe("what's kept", () => {
  test("the last answer, over a restart (owner-only file)", async () => {
    const a = make();
    await a.u.refresh();
    const b = make({ path: a.c.path });
    b.c.up = false;
    expect(b.u.get()).toEqual(a.u.status);
    expect(b.u.status.state).toBe("limits");
    cleanup(a.c.paths);
    cleanup(b.c.paths);
  });

  test("no answer: the numbers stay as of when they came, and are news again once there is one", async () => {
    const { u, c } = make();
    await u.refresh();
    const at = c.now;
    c.now += MIN;
    c.answer = async () => Promise.reject(new Error("lin@example.com 403"));
    await u.refresh();
    expect(u.status).toMatchObject({ state: "limits", at, stale: true, limits: [{ used: 48 }] });
    expect(c.logs.join()).not.toContain("@");
    c.now += MIN;
    c.answer = async () => LIMITS(50);
    await u.refresh();
    expect(u.status.stale).toBeUndefined();
    expect(u.status).toMatchObject({ at: c.now, limits: [{ used: 50 }] });
    cleanup(c.paths);
  });

  test("another account with no answer: the old account's numbers go", async () => {
    const { u, c } = make();
    await u.refresh();
    c.answer = async () => ({ plan: "unreadable", limits: [], account: { email: "mei@example.com", plan: "pro" } });
    await u.refresh();
    expect(u.status).toEqual({ state: "unsupported", limits: [], account: { email: "mei@example.com", plan: "pro" } });
    cleanup(c.paths);
  });

  test("never an answer, the method gone, a login without limits: no numbers are made up", async () => {
    for (const [plan, state] of [["unreadable", "unsupported"], ["unsupported", "unsupported"], ["none", "none"], ["hidden", "hidden"]] as const) {
      const { u, c } = make();
      c.answer = async () => ({ plan, limits: [], account: { plan: "max" } });
      await u.refresh();
      expect(u.status).toEqual({ state, limits: [], account: { plan: "max" } });
      cleanup(c.paths);
    }
  });

  test("a question that never comes back is given up on", async () => {
    const { u, c } = make({ timeoutMs: 10 });
    c.answer = () => new Promise(() => {});
    await u.refresh();
    expect(u.status.state).toBe("unsupported");
    c.answer = async () => LIMITS();
    await u.refresh();
    expect(u.status.state).toBe("limits");
    cleanup(c.paths);
  });
});

describe("on the host", () => {
  const ctx = { clientId: "app_1_dev-x", deviceId: "dev-x", channel: "app" as const, local: false };
  const get = async (hub: any, params = {}) => ((await handleRpc(hub, { method: "usage.get", params }, ctx)) as any).usage as UsageStatus;

  test("asking never starts the assistant; once it's up, its answer goes to the apps and nowhere else", async () => {
    const { hub, driver, pusher, paths, events } = makeHub();
    driver.plan = () => LIMITS();
    expect(await get(hub, { refresh: true })).toEqual({ state: "loading", limits: [] });
    await tick(5);
    expect(driver.sessions).toHaveLength(0);
    expect(driver.planAsked).toBe(0);
    hub.userMessage("在吗", "app");
    await hub.idle();
    await tick(5);
    expect(await get(hub)).toMatchObject({ state: "limits", account: { email: "lin@example.com" } });
    expect(events.filter((e) => e.event === "usage.updated").map((e) => e.data.usage.state)).toEqual(["limits"]);
    // not in the conversation, the audit, a push
    expect(JSON.stringify(hub.audit.tail(100))).not.toContain("lin@");
    expect(JSON.stringify(pusher.pushes)).not.toContain("lin@");
    expect(JSON.stringify(hub.chat.recent(50))).not.toContain("lin@");
    expect(JSON.stringify(hub.status())).not.toContain("lin@");
    expect(readFileSync(`${paths.state}/plan-usage.json`, "utf8")).toContain("lin@");
    hub.stop();
    cleanup(paths);
  });

  test("a harness that can't be asked: still an answer, nothing known", async () => {
    const { hub, paths } = makeHub();
    hub.userMessage("在吗", "app");
    await hub.idle();
    await tick(5);
    expect(await get(hub, { refresh: true })).toEqual({ state: "unsupported", limits: [] });
    hub.stop();
    cleanup(paths);
  });
});
