import { afterAll, beforeAll, expect, test } from "bun:test";
import { setLang, tIn, DICTIONARIES } from "../src/i18n/index.ts";
import { PAL_PROMPT } from "../src/pals.ts";
import { startError, stallContinue } from "../src/palSession.ts";
import { rewindBusy, rewindNoFiles, rewindNotFound } from "../src/rewind.ts";
import { stallContinue as convStall } from "../src/conversation.ts";

const CJK = /[一-鿿]/;

beforeAll(() => setLang("en"));
afterAll(() => setLang("zh"));

test("Pal and rewind texts in English have no Chinese", () => {
  const texts = [
    PAL_PROMPT("Palo"),
    stallContinue(),
    convStall(),
    rewindBusy(),
    rewindNoFiles(),
    rewindNotFound(),
    startError("Error: not logged in"),
    startError("session_held_by_background"),
    startError("No conversation found"),
    startError(""),
  ];
  for (const s of texts) expect(s).not.toMatch(CJK);
});

test("every pals, sessions, handoff and rewind key has English without Chinese", () => {
  for (const [k, v] of Object.entries(DICTIONARIES.en)) {
    if (!/^(pals|sessions|handoff|rewind|stall)\./.test(k)) continue;
    expect(v, k).not.toMatch(CJK);
    const holes = (x: string) => [...new Set(x.match(/\{\w+\}/g) ?? [])].sort();
    expect(holes(v), k).toEqual(holes((DICTIONARIES.zh as Record<string, string>)[k]!));
  }
});

test("params fill in", () => {
  expect(tIn("en", "handoff.askBody", { title: "Fix", peer: "web" })).toBe('"Fix" is waiting for your answer in web. Check that computer.');
  expect(tIn("zh", "pals.noPal")).toBe("找不到这个会话");
});
