// The model and thinking depth of the assistant and of an agent at their
// edges, pinned before the two setters become one (docs/harness-adapter-design.md
// step 14): while a turn runs, with no process (asleep, stopped, not started),
// a live switch that fails, a bad choice, back to the default, kept across the
// host's restart. The assistant's choice is kept in config.json, an agent's in
// its record.
import { afterAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { both, cleanupBoth, result } from "./bothRuntimes.ts";
import { tmpPaths } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";
import type { FakeScript } from "./fakeDriver.ts";

afterAll(cleanupBoth);

const script: FakeScript = async (text, ctx) => {
  if (text.startsWith("慢")) return new Promise<void>(() => {});
  ctx.emit({ type: "assistant_text", text: `回：${text}`, parentToolUseId: null });
};

describe("the assistant's", () => {
  const config = (t: ReturnType<typeof both>) => JSON.parse(readFileSync(t.paths.config, "utf8"));

  test("while a turn runs: switched live, model first, the turn left alone; kept in config.json; one status; audited", async () => {
    const t = both({ script });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    const m = t.hub.userMessage("慢慢来", "app")!;
    const n = t.events.length;
    const { status } = await t.call("model.set", { effort: "low", model: "default" });
    expect(status).toMatchObject({ busy: true, effort: "low", model: "default" });
    expect(t.driver.liveSwitches).toEqual(["model:default", "effort:low"]);
    expect(t.events.slice(n).filter((e) => e.event === "status")).toHaveLength(1);
    expect(config(t)).toMatchObject({ model: "default", effort: "low" });
    expect(t.hub.audit.tail(5).find((e) => e.type === "model.set")).toMatchObject({ model: "default", effort: "low" });
    expect(t.driver.sessions).toHaveLength(1);
    expect(t.driver.last!.closed).toBe(false);
    const p = t.driver.last!;
    p.opts.onEvent({ type: "assistant_text", text: "答完了", parentToolUseId: null });
    p.opts.onEvent(result(p.sessionId, [m.uuid!]));
    expect(t.replies().at(-1)!.text).toBe("答完了");
  });

  test("one of the two: the other stays; null: back to the default, gone from config.json; nothing asked: fine", async () => {
    const t = both({ script });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    await t.call("model.set", { model: "default", effort: "high" });
    await t.call("model.set", { effort: "low" });
    expect(config(t)).toMatchObject({ model: "default", effort: "low" });
    await t.call("model.set", { model: null, effort: null });
    expect(t.driver.liveSwitches).toEqual(["model:default", "effort:high", "effort:low", "model:undefined", "effort:undefined"]);
    expect("model" in config(t)).toBe(false);
    expect("effort" in config(t)).toBe(false);
    expect(t.hub.status().effort).toBeUndefined();
    await t.call("model.set", {});
    expect(t.driver.liveSwitches).toHaveLength(5);
  });

  test("a bad choice: refused, nothing switched, nothing kept", async () => {
    const t = both({ script });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    await t.call("model.set", { model: "default", effort: "low" });
    const before = config(t);
    for (const bad of [{ effort: "turbo" }, { model: "gpt-9" }, { model: "haiku", effort: "low" }, { model: "gpt-9", effort: "low" }]) await expect(t.call("model.set", bad)).rejects.toThrow();
    expect(config(t)).toEqual(before);
    expect(t.hub.status().effort).toBe("low");
    expect(t.driver.liveSwitches).toEqual(["model:default", "effort:low"]);
  });

  test("with no process: kept, none is started for it; the next one starts on them, also after the host's restart", async () => {
    const paths = tmpPaths();
    const t = both({ script, paths });
    await t.call("model.set", { model: "haiku" });
    await t.call("model.set", { model: null, effort: "max" });
    expect(t.driver.sessions).toHaveLength(0);
    expect(t.driver.liveSwitches).toEqual([]);
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts).toMatchObject({ effort: "max" });
    expect(t.driver.last!.opts.model).toBeUndefined();
    await t.call("model.set", { effort: "high" });
    t.hub.conversation.close();
    await t.call("model.set", { effort: "low" }); // closed: not switched live
    expect(t.driver.liveSwitches).toEqual(["effort:high"]);
    t.hub.userMessage("再来", "app");
    await t.hub.idle();
    expect(t.driver.last!.opts.effort).toBe("low");
    expect(config(t)).toMatchObject({ effort: "low" });
    t.hub.stop();
  });

  test("a live switch that fails: said in the log only, the choice is kept and the other one is still switched", async () => {
    const logs: string[] = [];
    const t = both({ script });
    (t.hub.conversation as any).d.log = (s: string) => logs.push(s);
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    t.driver.last!.setModel = async () => {
      throw new Error("not now");
    };
    const { status } = await t.call("model.set", { model: "default", effort: "low" });
    expect(status.effort).toBe("low");
    expect(config(t)).toMatchObject({ model: "default", effort: "low" });
    expect(t.driver.liveSwitches).toEqual(["effort:low"]);
    expect(logs).toContain("setModel failed: Error: not now");
  });

  test("the model shown is the chosen one at once, then what the harness says it runs", async () => {
    const t = both({ script });
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    expect(t.hub.status().model).toBe("fake-model");
    expect((await t.call("model.set", { model: "default" })).status.model).toBe("default");
    const p = t.driver.last!;
    p.opts.onEvent({ type: "init", sessionId: p.sessionId, model: "claude-opus-5-5", tools: [] });
    expect(t.hub.status().model).toBe("claude-opus-5-5");
    expect((await t.call("model.set", { model: null })).status.model).toBe("claude-opus-5-5");
  });
});

describe("an agent's", () => {
  const saved = (t: ReturnType<typeof both>, id: string) => JSON.parse(readFileSync(t.paths.pals, "utf8")).pals.find((r: any) => r.id === id);

  test("while a turn runs: switched live, model first, the turn left alone; kept in its record; audited", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    await t.call("pals.send", { id: pal.id, text: "慢慢来" });
    await waitFor(() => t.statusOf(pal.id) === "busy");
    const r = await t.call("pals.setModel", { id: pal.id, effort: "low", model: "default" });
    expect(r.pal).toMatchObject({ status: "busy", model: "default", effort: "low" });
    expect(t.driver.liveSwitches).toEqual(["model:default", "effort:low"]);
    expect(saved(t, pal.id)).toMatchObject({ model: "default", effort: "low" });
    expect(t.hub.audit.tail(5).find((e) => e.type === "pal.model")).toMatchObject({ pal: pal.id, model: "default", effort: "low" });
    await t.call("pals.setModel", { id: pal.id, effort: "high" });
    expect(saved(t, pal.id)).toMatchObject({ model: "default", effort: "high" });
    await t.hub.pals.stopAndWait();
  });

  test("asleep or still starting: only its record changes; it starts on them", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    await t.pal(pal.id).sleep();
    const n = t.driver.pals.length;
    await t.call("pals.setModel", { id: pal.id, model: "default", effort: "max" });
    expect(t.driver.pals).toHaveLength(n);
    expect(t.driver.liveSwitches).toEqual([]);
    expect(saved(t, pal.id)).toMatchObject({ status: "asleep", model: "default", effort: "max" });
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const startPal = t.driver.startPal.bind(t.driver);
    t.driver.startPal = (opts) => {
      const s = startPal(opts);
      s.ready = () => gate;
      return s;
    };
    const waking = t.call("pals.wake", { id: pal.id });
    await waitFor(() => t.driver.pals.length === n + 1);
    expect(t.driver.pals.at(-1)!.opts).toMatchObject({ model: "default", effort: "max" });
    await t.call("pals.setModel", { id: pal.id, effort: "low" });
    expect(t.driver.liveSwitches).toEqual([]);
    expect(saved(t, pal.id).effort).toBe("low");
    release();
    await waking;
    await t.hub.pals.stopAndWait();
  });

  test("a live switch that fails: the caller is told, the other isn't switched; both are kept for its next start", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    t.driver.pals.at(-1)!.setModel = async () => {
      throw new Error("not now");
    };
    await expect(t.call("pals.setModel", { id: pal.id, model: "default", effort: "low" })).rejects.toThrow("not now");
    expect(t.driver.liveSwitches).toEqual([]);
    expect(saved(t, pal.id)).toMatchObject({ model: "default", effort: "low" });
    expect(t.hub.audit.tail(5).some((e) => e.type === "pal.model")).toBe(false);
    await t.hub.pals.stopAndWait();
  });

  test("a bad choice, or none: refused, nothing switched, nothing kept; stopped: refused", async () => {
    const t = both({ palScript: script });
    // (the harness has said which models it offers)
    t.hub.userMessage("hi", "app");
    await t.hub.idle();
    const pal = await t.agent();
    await t.call("pals.setModel", { id: pal.id, model: "default", effort: "low" });
    for (const bad of [{ effort: "turbo" }, { model: "gpt-9" }, { model: "haiku", effort: "low" }, {}, { model: null }, { model: "", effort: "" }]) await expect(t.call("pals.setModel", { id: pal.id, ...bad })).rejects.toThrow();
    expect(saved(t, pal.id)).toMatchObject({ model: "default", effort: "low" });
    expect(t.driver.liveSwitches).toEqual(["model:default", "effort:low"]);
    t.pal(pal.id).stopFor("failed", "x");
    await waitFor(() => t.statusOf(pal.id) === "stopped");
    await expect(t.call("pals.setModel", { id: pal.id, effort: "high" })).rejects.toThrow();
    expect(saved(t, pal.id).effort).toBe("low");
    await t.hub.pals.stopAndWait();
  });

  test("the list hears of it, and what its process says it runs replaces it", async () => {
    const t = both({ palScript: script });
    const pal = await t.agent();
    const n = t.events.length;
    await t.call("pals.setModel", { id: pal.id, model: "default" });
    const list = t.events.slice(n).filter((e) => e.event === "pals.updated").at(-1)!.data.pals;
    expect(list.find((p: any) => p.id === pal.id)).toMatchObject({ model: "default" });
    const p = t.driver.pals.at(-1)!;
    p.opts.onEvent({ type: "init", sessionId: p.sessionId, model: "claude-opus-5-5", tools: [] });
    p.opts.onEvent(result(p.sessionId, []));
    expect(t.hub.pals.list().find((x) => x.id === pal.id)!.model).toBe("claude-opus-5-5");
    await t.hub.pals.stopAndWait();
  });
});
