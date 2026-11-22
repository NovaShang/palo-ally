import { describe, expect, test } from "bun:test";
import { firstLine, summarizeTranscript } from "../src/ccSessions.ts";
import { toPalMessages, transcriptLastLine } from "../src/palHistory.ts";
import { handleRpc } from "../src/rpc.ts";
import { TLDR_MARKER, isTldrAsk, stripTldrMarker } from "../src/tldr.ts";
import { cleanup, makeHub, tick } from "./helpers.ts";

// 「TL;DR」 is gone. An older app's tap (the marker alone) does nothing, and
// an old ask kept in a transcript (marker first) shows without the marker.

const oldAsk = `${TLDR_MARKER}\n（主人点了「TL;DR」）请把这段对话最近的一段写成要点给我看。`;

describe("what 「TL;DR」 left behind", () => {
  test("an older app's tap is the marker alone", () => {
    expect(isTldrAsk(TLDR_MARKER)).toBe(true);
    expect(isTldrAsk(` ${TLDR_MARKER}\n`)).toBe(true);
    expect(isTldrAsk(oldAsk)).toBe(false);
    expect(isTldrAsk("TL;DR")).toBe(false);
  });

  test("the marker never shows in a line made from text: the list's last line, a session's summary", () => {
    expect(stripTldrMarker(`${TLDR_MARKER}\n要点`)).toBe("要点");
    expect(stripTldrMarker("没有标记")).toBe("没有标记");
    expect(firstLine(`${TLDR_MARKER}\n- 列表页按日期排好了`)).toBe("列表页按日期排好了");
    const echoed = [{ type: "assistant", message: { content: [{ type: "text", text: `${TLDR_MARKER}\n- 定了周六中午` }] } }];
    expect(transcriptLastLine(echoed)).toBe("定了周六中午");
    expect(summarizeTranscript(echoed).lastLine).toBe("定了周六中午");
  });

  test("an old ask in a session's conversation (pals.history) is the owner's words without the marker", () => {
    const raw = [
      { type: "user", uuid: "1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "列表要能按日期排序" }, origin: { kind: "human" } },
      { type: "user", uuid: "2", timestamp: "2026-10-12T10:01:00Z", message: { role: "user", content: oldAsk }, origin: { kind: "human" } },
    ];
    expect(toPalMessages(raw as any, { pal: "s1", assistantName: "帕帕", paloName: "Palo" }).map((m) => [m.id, m.role, m.text])).toEqual([
      ["1", "user", "列表要能按日期排序"],
      ["2", "user", "（主人点了「TL;DR」）请把这段对话最近的一段写成要点给我看。"],
    ]);
  });

  test("chat.send with the marker alone (an older app) does nothing: nothing kept, nothing sent, no error", async () => {
    const { hub, events, paths, driver } = makeHub();
    const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
    const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(hub, { method, params }, app)) ?? null));
    expect(await call("chat.send", { text: TLDR_MARKER, clientMsgId: "c-tl" })).toEqual({ id: "", seq: 0 });
    await hub.idle();
    await tick(5);
    expect(events.filter((e) => e.event === "chat.message")).toEqual([]);
    expect(hub.chat.recent(10)).toEqual([]);
    expect(driver.last?.sent ?? []).toEqual([]);
    cleanup(paths);
  });
});
