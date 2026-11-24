// The assistant and agents on one host over the fake harness, for the tests
// that pin what both runtimes do at their edges (stop, a stall, 回到这里重来,
// model and effort): only public surfaces (RPCs, bus events, the chat log, the
// fake harness, the watchdog's targets).
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AwayDetector } from "../src/away.ts";
import type { Config, Paths } from "../src/config.ts";
import type { HarnessEvent } from "../src/harness/types.ts";
import type { AuthDeps } from "../src/auth.ts";
import type { LimitDeps } from "../src/limitWatch.ts";
import type { PalsDeps } from "../src/pals.ts";
import { transcriptPath } from "../src/harness/claude/paths.ts";
import { readTranscript } from "../src/harness/claude/rewind.ts";
import { handleRpc } from "../src/rpc.ts";
import type { StallTarget } from "../src/stallWatch.ts";
import type { WechatChannel } from "../src/channels/types.ts";
import type { FakeScript } from "./fakeDriver.ts";
import { FakeClaudeDir, FakeCli } from "./fakeClaude.ts";
import { makeHub } from "./helpers.ts";
import { waitFor } from "./relayClient.ts";

const FAST = { readyMs: 2_000, restartMs: [30, 30, 30, 30, 30], exitWaitMs: 1_000, exitPollMs: 50, stopWaitMs: 400, guardMs: 50, startStaggerMs: 5 };
const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };

export const result = (sessionId: string, consumedUuids?: string[], over: Partial<Extract<HarnessEvent, { type: "result" }>> = {}): HarnessEvent => ({
  type: "result",
  isError: false,
  text: "",
  costUsd: 0,
  totalCostUsd: 0,
  contextTokens: 10,
  sessionId,
  ...(consumedUuids ? { consumedUuids } : {}),
  ...over,
});

const dirs: FakeClaudeDir[] = [];
const clis: FakeCli[] = [];
export function cleanupBoth(): void {
  for (const c of clis.splice(0)) c.close();
  for (const d of dirs.splice(0)) d.cleanup();
}

export function both(o: { script?: FakeScript; palScript?: FakeScript; wechat?: WechatChannel; paths?: Paths; config?: Config; claude?: FakeClaudeDir; spawn?: boolean; pals?: Partial<PalsDeps>; limits?: Partial<LimitDeps>; auth?: Partial<AuthDeps> } = {}) {
  const claude = o.claude ?? new FakeClaudeDir();
  if (!o.claude) dirs.push(claude);
  const cli = new FakeCli(claude);
  clis.push(cli);
  const t = makeHub({
    script: o.script,
    wechat: o.wechat,
    ...(o.paths ? { paths: o.paths } : {}),
    ...(o.config ? { config: o.config } : {}),
    ...(o.limits ? { limits: o.limits } : {}),
    ...(o.auth ? { auth: o.auth } : {}),
    sessions: { claudeDir: claude.dir, cli, away: new AwayDetector(() => null, Date.now, () => false) },
    pals: { timing: FAST, readMessages: async (sid, dir) => readTranscript(transcriptPath(claude.dir, dir, sid)), ...o.pals },
  });
  if (o.palScript) t.driver.palScript = o.palScript;
  if (o.spawn) t.driver.spawnPals = true;
  t.hub.pals.start();
  const project = realpathSync(mkdtempSync(join(tmpdir(), "paloally-both-")));
  const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(t.hub, { method, params }, app)) ?? null));
  /** A new agent in the throwaway folder, up and idle. */
  const agent = async () => {
    const { pal } = await call("pals.create", { cwd: project });
    await waitFor(() => t.hub.pals.list().find((p) => p.id === pal.id)?.status === "idle");
    return pal as { id: string; sessionId: string; name: string };
  };
  const statusOf = (id: string) => t.hub.pals.list().find((p) => p.id === id)?.status;
  const attentionOf = (id: string) => t.hub.pals.list().find((p) => p.id === id)?.attention;
  const palEvents = (event: string, id: string) => t.events.filter((e) => e.event === event && e.data?.pal === id).map((e) => e.data);
  const mainEvents = (event: string) => t.events.filter((e) => e.event === event && !e.data?.pal).map((e) => e.data);
  /** What the agent's page was sent: `role:text`, notices as `notice:text`. */
  const said = (id: string) => palEvents("chat.message", id).map((m) => `${m.kind === "notice" ? "notice" : m.role}:${m.text}`);
  const replies = () => t.hub.chat.since(0).filter((m) => m.role === "assistant");
  /** A session the stall watchdog watches. */
  const stall = (key: string) => ((t.hub.stallWatch as any).d.targets() as StallTarget[]).find((s) => s.key === key)!;
  const pal = (id: string) => t.hub.pals.get(id)!;
  return { ...t, claude, cli, project, call, agent, statusOf, attentionOf, palEvents, mainEvents, said, replies, stall, pal };
}
