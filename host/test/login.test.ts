import { afterAll, describe, expect, test } from "bun:test";
import { AuthWatch } from "../src/auth.ts";
import { claudeLogout, maySignOut, statusAccount } from "../src/harness/claude/auth.ts";
import type { LoginAccount, PlanReport } from "../src/harness/types.ts";
import { handleRpc } from "../src/rpc.ts";
import { both, cleanupBoth } from "./bothRuntimes.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeLogin, cleanup, tick, tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

// Signing in again while the login still works, switching the account, and
// signing out: what happens to the processes and to what runs. A pretend
// login throughout: never this computer's.

afterAll(cleanupBoth);

const LIN: LoginAccount = { email: "lin@example.com", organization: "Lin", plan: "max" };
const MEI: LoginAccount = { email: "mei@example.com", organization: "Mei", plan: "pro" };
const ok = (account: LoginAccount): PlanReport => ({ plan: "limits", account, limits: [{ kind: "session", group: "session", used: 40 }] });
/** 「慢」 works until it's released; anything else is answered. */
let release: (() => void)[] = [];
const script: FakeScript = async (text, ctx) => {
  if (text.startsWith("慢")) {
    const cut = await Promise.race([ctx.interrupted.then(() => true), new Promise<boolean>((r) => release.push(() => r(false)))]);
    if (cut) return;
  }
  if (text.startsWith("问")) await ctx.useTool("Bash", { command: "ls" }, { ask: true });
  ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null, messageId: `m_${Math.random()}` });
};

function host() {
  const c = { now: LIN as LoginAccount | null, logout: true, logouts: 0, loggedIn: true, stamp: null as string | null };
  release = [];
  const logins: FakeLogin[] = [];
  const h = both({
    script,
    palScript: script,
    auth: {
      account: async () => c.now,
      logout: async () => (c.logouts++, c.logout),
      loggedIn: async () => c.loggedIn,
      stamp: async () => c.stamp,
      spawnLogin: () => (logins.push(new FakeLogin()), logins.at(-1)!),
    },
  });
  h.driver.plan = () => ok(c.now ?? LIN);
  /** Signs in from the phone, as `account`. */
  const signIn = async (account: LoginAccount) => {
    await h.call("auth.login.start");
    const l = logins.at(-1)!;
    l.say("URL https://claude.com/cai/oauth/authorize?x=1");
    await h.call("auth.login.code", { code: "a#b" });
    c.now = account;
    l.exit(0);
    await tick(30);
  };
  const up = async () => {
    h.hub.conversation.ensureSession();
    await tick(10);
  };
  const end = () => {
    for (const r of release) r();
    h.hub.stop();
    cleanup(h.paths);
  };
  const auth = () => h.hub.status().auth;
  return { ...h, c, logins, signIn, up, end, auth };
}

describe("whose login it is", () => {
  test("as `claude auth status` says", () => {
    expect(statusAccount('{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"lin@example.com","orgId":"o","orgName":"Lin","subscriptionType":"max"}')).toEqual(LIN);
    expect(statusAccount('{"loggedIn":false}')).toBeNull();
    expect(statusAccount("not json")).toBeNull();
    expect(statusAccount(undefined)).toBeNull();
  });

  test("only a host on its own home may sign the computer out: never a test, never a second one", () => {
    const home = "/Users/lin";
    expect(maySignOut({}, home)).toBe(true);
    expect(maySignOut({ PALOALLY_HOME: "/Users/lin/.paloally" }, home)).toBe(true); // as the service sets it
    expect(maySignOut({ PALOALLY_HOME: "/Users/lin/.paloally/" }, home)).toBe(true);
    for (const at of ["/private/tmp/usage-home", "/Users/lin/.paloally-dev", "/Users/lin/.paloally/state", "/Users/mei/.paloally", "./.paloally"]) expect(maySignOut({ PALOALLY_HOME: at }, home), at).toBe(false);
    expect(maySignOut({ NODE_ENV: "test" }, home)).toBe(false);
    expect(maySignOut({ NODE_ENV: "test", PALOALLY_HOME: "/Users/lin/.paloally" }, home)).toBe(false);
  });

  test("the real sign-out never runs in a test", async () => {
    expect(await claudeLogout()).toBe(false);
  });
});

describe("signing in while the login works", () => {
  test("the same account: idle processes start afresh, nothing is said or resumed", async () => {
    const h = host();
    await h.up();
    const a = await h.agent();
    const said = h.hub.chat.recent(50).length;
    const before = { main: h.driver.sessions.length, pals: h.driver.pals.length };
    await h.signIn(LIN);
    expect(h.auth()).toBeUndefined();
    await waitFor(() => h.driver.pals.length === before.pals + 1);
    expect(h.driver.sessions.length).toBe(before.main + 1);
    expect(h.driver.sessions.at(-2)!.closed).toBe(true);
    await waitFor(() => h.statusOf(a.id) === "idle");
    expect(h.driver.pals.at(-1)!.sent).toEqual([]);
    expect(h.hub.chat.recent(50).length).toBe(said);
    expect(h.hub.usageStatus()).toMatchObject({ state: "limits", account: { email: "lin@example.com" } });
    h.end();
  });

  test("one at work goes on undisturbed, and starts afresh when its turn ends", async () => {
    const h = host();
    await h.up();
    const a = await h.agent();
    await h.call("pals.send", { id: a.id, text: "慢慢做" });
    h.hub.userMessage("慢慢来", "app");
    await waitFor(() => h.pal(a.id).busy && h.hub.conversation.busy);
    const before = { main: h.driver.sessions.length, pals: h.driver.pals.length };
    await h.signIn(LIN);
    expect([h.driver.sessions.length, h.driver.pals.length]).toEqual([before.main, before.pals]);
    expect(h.pal(a.id).busy && h.hub.conversation.busy).toBe(true);
    for (const r of release.splice(0)) r();
    await h.hub.idle();
    await waitFor(() => h.driver.pals.length === before.pals + 1 && h.driver.sessions.length === before.main + 1);
    expect(h.said(a.id).at(-1)).toContain("回：慢慢做");
    await waitFor(() => h.statusOf(a.id) === "idle");
    // once
    await h.call("pals.send", { id: a.id, text: "再来" });
    await waitFor(() => !h.pal(a.id).busy);
    await tick(30);
    expect(h.driver.pals.length).toBe(before.pals + 1);
    h.end();
  });

  test("cancelled, or the code refused: nothing changes", async () => {
    const h = host();
    await h.up();
    const n = h.driver.sessions.length;
    await h.call("auth.login.start");
    h.logins[0]!.say("URL https://claude.com/cai/oauth/authorize?x=1");
    expect(h.auth()).toMatchObject({ state: "ok", login: { state: "waiting" } });
    await h.call("auth.login.cancel");
    expect(h.auth()).toBeUndefined();
    await h.call("auth.login.start");
    h.logins[1]!.say("URL https://claude.com/cai/oauth/authorize?x=1");
    await h.call("auth.login.code", { code: "bad" });
    h.logins[1]!.say("INVALID");
    expect(h.auth()?.login?.state).toBe("invalid");
    await h.call("auth.login.cancel");
    expect(h.driver.sessions.length).toBe(n);
    h.end();
  });

  test("another account: the app is told whose before it's told the sign-in is done; the old numbers go; no email in the audit", async () => {
    const h = host();
    await h.up();
    h.hub.planUsage.get(true);
    await tick(10);
    expect(h.hub.usageStatus().limits).toHaveLength(1);
    const from = h.events.length;
    await h.signIn(MEI);
    const after = h.events.slice(from);
    const told = after.findIndex((e) => e.event === "usage.updated" && e.data.usage.account?.email === "mei@example.com");
    const done = after.findIndex((e) => e.event === "status" && !e.data.auth && after.indexOf(e) > told);
    expect(told).toBeGreaterThan(-1);
    expect(after[told]!.data.usage).toMatchObject({ state: "loading", limits: [] });
    expect(done).toBeGreaterThan(told);
    await waitFor(() => h.hub.usageStatus().state === "limits");
    expect(h.hub.usageStatus().account).toEqual(MEI);
    const audit = JSON.stringify(h.hub.audit.tail(100));
    expect(audit).toContain('"changed":true');
    expect(audit).not.toContain("@example.com");
    h.end();
  });

  test("another account while the assistant is at work: its old process isn't asked about it", async () => {
    const h = host();
    await h.up();
    h.hub.userMessage("慢慢来", "app");
    await waitFor(() => h.hub.conversation.busy);
    const asked = h.driver.planAsked;
    await h.signIn(MEI);
    h.hub.planUsage.get(true);
    await h.hub.planUsage.refresh();
    expect(h.driver.planAsked).toBe(asked);
    expect(h.hub.usageStatus()).toMatchObject({ state: "loading", account: MEI });
    for (const r of release.splice(0)) r();
    await h.hub.idle();
    await waitFor(() => h.hub.usageStatus().state === "limits");
    expect(h.hub.usageStatus().account).toEqual(MEI);
    h.end();
  });

  test("what a used-up limit stopped is looked at again at once, not at the old reset", async () => {
    const h = host();
    await h.up();
    const a = await h.agent();
    h.hub.limits.hit({ kind: "pal", id: a.id, name: a.name }, { kind: "weekly_all", resetsAt: Date.now() + 86_400_000 });
    await h.signIn(MEI);
    expect(h.hub.usageStatus().stopped!.agents[0]!.until!).toBeLessThan(Date.now() + 50_000);
    h.end();
  });
});

describe("one that waits on the owner", () => {
  const cards = (h: ReturnType<typeof host>) => h.hub.approvals.listPending();

  test("signed in anew: an agent's and the assistant's cards stay, their answers go on, and then they start afresh", async () => {
    const h = host();
    await h.up();
    const a = await h.agent();
    await h.call("pals.send", { id: a.id, text: "问一下" });
    h.hub.userMessage("问问我", "app");
    await waitFor(() => cards(h).length === 2);
    expect(h.statusOf(a.id)).toBe("waiting");
    const before = { main: h.driver.sessions.length, pals: h.driver.pals.length };
    await h.signIn(MEI);
    await tick(50);
    expect([h.driver.sessions.length, h.driver.pals.length]).toEqual([before.main, before.pals]);
    expect(cards(h)).toHaveLength(2);
    expect(h.statusOf(a.id)).toBe("waiting");
    for (const c of cards(h)) await h.call("approval.answer", { id: c.id, allow: true });
    await h.hub.idle();
    await waitFor(() => h.driver.pals.length === before.pals + 1 && h.driver.sessions.length === before.main + 1);
    expect(h.said(a.id).some((x) => x.includes("回：问一下"))).toBe(true);
    h.end();
  });

  test("signed out: their cards stay too; a turn that still ends well on a login in memory isn't a sign-in", async () => {
    const h = host();
    await h.up();
    const a = await h.agent();
    const busy = await h.agent();
    await h.call("pals.send", { id: a.id, text: "问一下" });
    await h.call("pals.send", { id: busy.id, text: "慢慢做" });
    h.hub.userMessage("问问我", "app");
    await waitFor(() => cards(h).length === 2 && h.pal(busy.id).busy);
    const r = await h.call("auth.logout");
    expect(r.auth.stopped).toEqual({ assistant: false, agents: [{ id: busy.id, name: busy.name }], schedules: 0 });
    expect(cards(h)).toHaveLength(2);
    expect(h.statusOf(a.id)).toBe("waiting");
    h.c.loggedIn = false;
    for (const c of cards(h)) await h.call("approval.answer", { id: c.id, allow: true });
    await h.hub.idle();
    await waitFor(() => !h.pal(a.id).busy);
    await tick(30);
    expect(h.auth()).toMatchObject({ state: "expired", signedOut: true });
    // one that fails for want of it is remembered with the rest
    h.driver.resultError = { text: "Not logged in · Please run /login", category: "authentication_failed" };
    await h.call("pals.send", { id: a.id, text: "再来" });
    await waitFor(() => h.auth()?.stopped?.agents.length === 2);
    h.end();
  });
});

describe("signing out", () => {
  test("what runs is stopped and remembered, without a push; after a sign-in all of it goes on", async () => {
    const h = host();
    await h.up();
    const a = await h.agent();
    const idle = await h.agent();
    const w = h.hub.watches.add({ title: "晨报", instruction: "慢慢写晨报", at: ["08:00"] }, "user");
    await h.call("pals.send", { id: a.id, text: "慢慢做" });
    h.hub.userMessage("慢慢整理纪要", "app");
    await waitFor(() => h.pal(a.id).busy && h.hub.conversation.busy);
    (h.hub as any).onSchedule(w); // queued behind it
    const r = await h.call("auth.logout");
    expect(r.auth).toMatchObject({ state: "expired", signedOut: true, stopped: { assistant: true, agents: [{ id: a.id }], schedules: 1 } });
    expect(h.c.logouts).toBe(1);
    expect(h.hub.conversation.busy).toBe(false);
    await waitFor(() => h.statusOf(a.id) === "asleep" && h.statusOf(idle.id) === "asleep"); // nothing left with the login in its memory
    expect(h.pusher.pushes).toEqual([]);
    expect(h.hub.chat.recent(30).some((m) => m.text.includes("登录过期"))).toBe(false);
    // the numbers aren't asked of a process with no login
    h.c.now = null;
    h.driver.plan = () => ({ plan: "none", limits: [] });
    h.hub.planUsage.get(true);
    await h.hub.planUsage.refresh();
    expect(h.hub.usageStatus().state).not.toBe("none");
    expect(h.hub.usageStatus().account).toEqual(LIN);
    // again: already out
    expect((await h.call("auth.logout")).auth.signedOut).toBe(true);
    expect(h.c.logouts).toBe(1);

    h.driver.plan = () => ok(LIN);
    await h.signIn(LIN);
    expect(h.auth()).toBeUndefined();
    await waitFor(() => h.driver.pals.some((p) => p.sent.some((x) => x.includes("因为退出登录停下"))));
    await h.hub.idle();
    const main = h.driver.sessions.flatMap((s) => s.sent).join("\n");
    expect(main).toContain("慢慢整理纪要");
    expect(main).toContain("可以接着做了");
    expect(main).not.toContain("登录过期了");
    for (const x of release.splice(0)) x();
    h.end();
  });

  test("it couldn't be signed out: said so, and what was stopped goes on", async () => {
    const h = host();
    h.c.logout = false;
    const a = await h.agent();
    await h.call("pals.send", { id: a.id, text: "慢慢做" });
    await waitFor(() => h.pal(a.id).busy);
    await expect(handleRpc(h.hub, { method: "auth.logout", params: {} }, { clientId: "app_1", deviceId: "d", channel: "app", local: false })).rejects.toThrow("没能退出登录");
    expect(h.auth()).toBeUndefined();
    await waitFor(() => h.driver.pals.some((p) => p.sent.some((x) => x.includes("请从断的地方接着做"))));
    h.end();
  });

  test("signed in at the computer: seen when a stored login is there again and works; kept over a restart", async () => {
    const paths = tmpPaths();
    let stamp: string | null = "20261019070000Z";
    let loggedIn = true;
    const recovered: string[] = [];
    const mk = () =>
      new AuthWatch({
        path: `${paths.state}/auth.json`, scriptDir: paths.state, notify: async () => true, changed: () => {}, audit: () => {}, log: () => {}, pollMs: 10,
        recovered: (m, how, _since, out) => recovered.push(`${how}:${out}:${Object.values(m.pals).join()}`),
        stamp: async () => stamp, loggedIn: async () => loggedIn, spawnLogin: () => new FakeLogin(),
      });
    const a = mk();
    stamp = null; // signed out: the stored login is gone
    loggedIn = false;
    await a.didSignOut({ palo: [], pals: { p1: "网站" }, schedules: [] });
    a.stop();
    const b = mk();
    expect(b.status()).toMatchObject({ state: "expired", signedOut: true });
    b.start();
    await tick(40);
    expect(recovered).toEqual([]);
    stamp = "20261019132531Z"; // something is stored, but it doesn't work
    await tick(40);
    expect(recovered).toEqual([]);
    loggedIn = true;
    await tick(40);
    expect(recovered).toEqual(["computer:true:网站"]);
    expect(b.status()).toBeUndefined();
    b.stop();
    // one that ran out, with no date of the stored login to go by: as before, not by this
    stamp = null;
    const c = mk();
    c.failed({ kind: "pal", id: "p1", name: "网站" });
    await tick(10);
    stamp = "20261019140000Z";
    await tick(40);
    expect(c.expired).toBe(true);
    c.stop();
    cleanup(paths);
  });

  test("an app from before it takes it for an expired login: its banner and sign-in work", async () => {
    const h = host();
    await h.call("auth.logout");
    expect(h.auth()?.state).toBe("expired");
    expect(h.auth()?.since).toBeGreaterThan(0);
    await h.signIn(LIN);
    expect(h.auth()).toBeUndefined();
    h.end();
  });
});
