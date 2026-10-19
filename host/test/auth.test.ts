import { describe, expect, test } from "bun:test";
import { AuthWatch, isAuthFailure } from "../src/auth.ts";
import { FakeLogin, cleanup, makeHub, tick, tmpPaths } from "./helpers.ts";

// Claude Code's login running out: noticed at the first failure, the owner
// told once, schedules and checks held, signed in again from the phone, and
// what was held resumed.

const EXPIRED = { text: "Failed to authenticate: OAuth session expired and could not be refreshed", category: "authentication_failed" };

describe("isAuthFailure", () => {
  test("by the SDK's error kind or the words Claude Code uses", () => {
    expect(isAuthFailure("anything", "authentication_failed")).toBe(true);
    expect(isAuthFailure(EXPIRED.text)).toBe(true);
    expect(isAuthFailure("Not logged in · Please run /login")).toBe(true);
    expect(isAuthFailure("rate limit reached", "rate_limit")).toBe(false);
    expect(isAuthFailure("fetch failed")).toBe(false);
    expect(isAuthFailure(undefined)).toBe(false);
  });
});

describe("the login running out", () => {
  test("the first failed turn marks it expired and tells the owner once; schedules and checks wait", async () => {
    const { hub, driver, pusher, paths } = makeHub();
    driver.resultError = EXPIRED;
    hub.userMessage("帮我整理一下下午的会议纪要", "app");
    await hub.idle();
    await tick(20);
    expect(hub.status().auth).toMatchObject({ state: "expired" });
    expect(pusher.pushes.map((p) => p.title)).toEqual(["Claude Code 登录过期"]);
    const notices = hub.chat.recent(20).filter((m) => m.channel === "system");
    expect(notices.map((m) => m.text)).toEqual([expect.stringContaining("重新登录")]); // the one notice, no per-turn error
    // another failure: nothing more said
    hub.userMessage("还有这个", "app");
    await hub.idle();
    await tick(20);
    expect(pusher.pushes).toHaveLength(1);
    // a schedule due now is held, a check doesn't run
    const w = hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["08:00"] }, "user");
    const sent = driver.sessions.flatMap((s) => s.sent).length;
    (hub as any).onSchedule(w);
    hub.watches.add({ title: "看邮件", instruction: "看看有没有新邮件", intervalMinutes: 30 }, "user");
    await hub.probe.tick();
    await hub.idle();
    expect(driver.sessions.flatMap((s) => s.sent).length).toBe(sent);
    expect(driver.probes).toHaveLength(0);
    hub.stop();
    cleanup(paths);
  });

  test("signed in again from the phone: the link out, a wrong code, the right one, then what was held resumes", async () => {
    const { hub, driver, paths, logins } = makeHub();
    driver.resultError = EXPIRED;
    hub.userMessage("帮我整理一下下午的会议纪要", "app");
    await hub.idle();
    const w = hub.watches.add({ title: "晨报", instruction: "写晨报", at: ["08:00"] }, "user");
    (hub as any).onSchedule(w);

    expect((await hub.auth.startLogin("dev-x"))?.login).toMatchObject({ state: "starting" });
    const login = logins[0]!;
    login.say("URL https://claude.com/cai/oauth/authorize?code=true&client_id=x");
    expect(hub.status().auth?.login).toMatchObject({ state: "waiting", url: "https://claude.com/cai/oauth/authorize?code=true&client_id=x" });
    expect(() => hub.auth.submitCode("")).toThrow();
    hub.auth.submitCode("  wrong-code ");
    expect(login.written).toEqual(["wrong-code"]);
    expect(hub.status().auth?.login?.state).toBe("checking");
    login.say("INVALID");
    expect(hub.status().auth?.login?.state).toBe("invalid");
    hub.auth.submitCode("abc#def");
    driver.resultError = undefined;
    login.exit(0);
    await tick(30);
    await hub.idle();
    expect(hub.status().auth).toBeUndefined();
    // the code went nowhere else
    const audit = JSON.stringify(hub.audit.tail(100));
    expect(audit).not.toContain("abc#def");
    expect(audit).toContain("auth.recovered");
    // the schedule ran, and the assistant got what it didn't finish
    const received = driver.sessions.flatMap((s) => s.sent).join("\n");
    expect(received).toContain("写晨报");
    expect(received).toContain("帮我整理一下下午的会议纪要");
    expect(received).toContain("现在恢复了");
    hub.stop();
    cleanup(paths);
  });

  test("a turn that goes through (signed in at the computer) ends it, with a note when nothing of the assistant's was cut short", async () => {
    const { hub, driver, paths } = makeHub();
    driver.resultError = EXPIRED;
    await hub.probe.tick(); // nothing due: no run
    hub.auth.failed({ kind: "probe" });
    expect(hub.status().auth?.state).toBe("expired");
    driver.resultError = undefined;
    hub.userMessage("在吗", "app");
    await hub.idle();
    await tick(20);
    expect(hub.status().auth).toBeUndefined();
    expect(hub.chat.recent(20).some((m) => m.channel === "system" && m.text.startsWith("Claude Code 登录恢复了"))).toBe(true);
    hub.stop();
    cleanup(paths);
  });

  test("a check that fails for want of a login stays due", async () => {
    const { hub, driver, paths } = makeHub();
    driver.probeResponder = () => ({ output: undefined, costUsd: 0, error: EXPIRED.text });
    const w = hub.watches.add({ title: "看邮件", instruction: "看看有没有新邮件", intervalMinutes: 30 }, "user");
    await hub.probe.tick();
    expect(driver.probes).toHaveLength(1);
    expect(hub.watches.get(w.id)?.lastCheckedAt).toBeUndefined();
    expect(hub.status().auth?.state).toBe("expired");
    hub.stop();
    cleanup(paths);
  });

  test("kept across a restart; a cancelled sign-in ends its process; a changed stored login at the computer ends it", async () => {
    const paths = tmpPaths();
    const recovered: string[] = [];
    let stamp = "20261019070000Z";
    const mk = () => {
      const logins: FakeLogin[] = [];
      const w = new AuthWatch({
        path: `${paths.state}/auth.json`,
        scriptDir: paths.state,
        notify: async () => true,
        recovered: (m, how) => recovered.push(`${how}:${m.schedules.join(",")}:${Object.values(m.pals).join(",")}`),
        changed: () => {},
        audit: () => {},
        log: () => {},
        stamp: async () => stamp,
        loggedIn: async () => true,
        spawnLogin: () => (logins.push(new FakeLogin()), logins.at(-1)!),
        pollMs: 10,
      });
      return { w, logins };
    };
    const a = mk().w;
    a.failed({ kind: "pal", id: "pal_1", name: "网站" });
    a.hold("w_1");
    await tick(5);
    a.stop();
    const { w: b, logins } = mk();
    expect(b.expired).toBe(true);
    await b.startLogin("dev");
    b.cancelLogin();
    expect(logins[0]!.killed).toBe(true);
    expect(b.status()).toMatchObject({ state: "expired" });
    b.start();
    stamp = "20261019132531Z"; // signed in at the computer
    await tick(60);
    expect(b.expired).toBe(false);
    expect(recovered).toEqual(["computer:w_1:网站"]);
    b.stop();
    cleanup(paths);
  });
});
