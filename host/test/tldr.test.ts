import { afterAll, describe, expect, test } from "bun:test";
import { firstLine, summarizeTranscript, toCCMessages } from "../src/ccSessions.ts";
import { setLang } from "../src/i18n/index.ts";
import { transcriptLastLine } from "../src/palHistory.ts";
import { handleRpc } from "../src/rpc.ts";
import { TLDR_MARKER, isTldrAsk, readTldr, stripTldrMarker, tldrInstruction, tldrPrompt } from "../src/tldr.ts";
import type { ChatMessage } from "../src/types.ts";
import { readJsonl } from "../src/util.ts";
import { cleanup, makeHub } from "./helpers.ts";

// 「TL;DR」 asks the agent itself: an owner message behind a marker, shown
// folded wherever its conversation is read back.

afterAll(() => setLang("zh"));

describe("the TL;DR ask", () => {
  test("the app's marker is the ask; the instruction goes in behind it, in the host's language; read back, it's the instruction without the marker", () => {
    expect(isTldrAsk(TLDR_MARKER)).toBe(true);
    expect(isTldrAsk(` ${TLDR_MARKER}\n`)).toBe(true);
    expect(isTldrAsk(`${TLDR_MARKER} 帮我总结`)).toBe(false);
    expect(isTldrAsk("TL;DR")).toBe(false);
    const zh = tldrPrompt();
    expect(zh.split("\n")[0]).toBe(TLDR_MARKER);
    for (const part of ["3 到 6 条要点", "你说过的原话", "转述的内容", "不要用任何工具", "逐字", "TL;DR 请求也不算", "对话本身的语言"]) expect(zh).toContain(part);
    expect(readTldr(zh)).toBe(tldrInstruction());
    expect(readTldr(tldrInstruction())).toBeNull();
    expect(readTldr("你好")).toBeNull();
    setLang("en");
    const en = tldrPrompt();
    expect(en.startsWith(`${TLDR_MARKER}\n`)).toBe(true);
    for (const part of ["3 to 6 points", "What you said", "Relayed", "use no tools", "verbatim", "TL;DR requests like this one don't count", "conversation's own language"]) expect(en).toContain(part);
    setLang("zh");
  });

  test("the marker never shows in a line made from text: the list's last line, a push, a session's summary", () => {
    expect(stripTldrMarker(`${TLDR_MARKER}\n要点`)).toBe("要点");
    expect(stripTldrMarker("没有标记")).toBe("没有标记");
    expect(firstLine(`${TLDR_MARKER}\n- 列表页按日期排好了`)).toBe("列表页按日期排好了");
    const echoed = [{ type: "assistant", message: { content: [{ type: "text", text: `${TLDR_MARKER}\n- 定了周六中午` }] } }];
    expect(transcriptLastLine(echoed)).toBe("定了周六中午");
    expect(summarizeTranscript(echoed).lastLine).toBe("定了周六中午");
  });

  test("a session read on its own (sessions.history): the ask is the owner's, marked tldr, without the marker", () => {
    const raw = [
      { type: "user", uuid: "1", timestamp: "2026-10-12T10:00:00Z", message: { role: "user", content: "列表要能按日期排序" }, origin: { kind: "human" } },
      { type: "user", uuid: "2", timestamp: "2026-10-12T10:01:00Z", message: { role: "user", content: tldrPrompt() }, origin: { kind: "human" } },
    ];
    expect(toCCMessages(raw as any, "帕帕", "Palo")).toEqual([
      { id: "1", ts: Date.parse("2026-10-12T10:00:00Z"), role: "owner", text: "列表要能按日期排序" },
      { id: "2", ts: Date.parse("2026-10-12T10:01:00Z"), role: "owner", text: tldrInstruction(), tldr: true },
    ]);
  });

  test("in the assistant's conversation: chat.send with the marker goes to the harness as marker and instruction, is kept and shown as a TL;DR ask (no marker, no quote)", async () => {
    const { hub, events, paths, driver } = makeHub();
    const app = { clientId: "app_1", deviceId: "dev-test", channel: "app" as const, local: false };
    const call = async (method: string, params: unknown = {}) => JSON.parse(JSON.stringify((await handleRpc(hub, { method, params }, app)) ?? null));
    const r = await call("chat.send", { text: TLDR_MARKER, clientMsgId: "c-tl", replyTo: { messageId: "m_x", excerpt: "不该带上" } });
    await hub.idle();
    expect(driver.last!.sent.at(-1)).toBe(tldrPrompt());
    const shown = events.filter((e) => e.event === "chat.message").map((e) => e.data as ChatMessage);
    expect(shown[0]).toMatchObject({ id: r.id, role: "user", kind: "text", tldr: true, text: tldrInstruction(), clientMsgId: "c-tl" });
    expect(shown[0]!.replyTo).toBeUndefined();
    expect(shown[1]).toMatchObject({ role: "assistant" });
    expect(shown[0]!.text).not.toContain(TLDR_MARKER);
    // kept so: the log (what history and sync read) has the flag, not the marker
    const kept = readJsonl<ChatMessage>(paths.chat).find((m) => m.id === r.id)!;
    expect(kept).toMatchObject({ tldr: true, text: tldrInstruction() });
    expect((await call("chat.history", { limit: 10 })).messages.find((m: ChatMessage) => m.id === r.id)).toMatchObject({ tldr: true });
    // an ordinary message is not one
    hub.userMessage("你好", "app");
    await hub.idle();
    expect(hub.chat.recent(10).filter((m) => m.tldr).map((m) => m.id)).toEqual([r.id]);
    cleanup(paths);
  });
});
