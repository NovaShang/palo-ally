import { describe, expect, test } from "bun:test";
import { Audit } from "../src/audit.ts";
import { Bus } from "../src/bus.ts";
import type { PermissionRequest } from "../src/harness/types.ts";
import { QuestionManager, parseItems, parseTextAnswer, questionText } from "../src/questions.ts";
import type { Question } from "../src/types.ts";
import { cleanup, tmpPaths } from "./helpers.ts";

// AskUserQuestion: the owner's choices go back to the harness as `answers`
// (question text → label, multi-select labels joined by ", ", or own words).

function mk(timeoutMinutes = 30) {
  const paths = tmpPaths();
  const created: Question[] = [];
  const m = new QuestionManager(`${paths.state}/q.json`, new Bus(), new Audit(paths.audit), {
    taskForToolUse: () => undefined,
    onCreated: (q) => created.push(q),
    timeoutMinutes: () => timeoutMinutes,
  });
  return { m, created, paths };
}

const ask = {
  questions: [
    {
      question: "要把面签加进 Outlook 吗？",
      header: "日历",
      options: [
        { label: "加进去", description: "加到工作日历" },
        { label: "先不加", description: "以后再说" },
        { label: "加到家庭日历", description: "" },
      ],
      multiSelect: false,
    },
    {
      question: "提前多久提醒？",
      header: "提醒",
      options: [{ label: "前一天" }, { label: "当天早上" }, { label: "出发前一小时" }],
      multiSelect: true,
    },
  ],
};

const req = (input: Record<string, unknown>, signal = new AbortController().signal): PermissionRequest => ({
  toolName: "AskUserQuestion",
  input,
  toolUseId: "tu",
  signal,
});

describe("QuestionManager", () => {
  test("a question becomes a card; answers go back as the tool's own input", async () => {
    const { m, created, paths } = mk();
    const p = m.request(req(ask));
    expect(created).toHaveLength(1);
    const q = m.listPending()[0]!;
    expect(q.items.map((i) => i.question)).toEqual(["要把面签加进 Outlook 吗？", "提前多久提醒？"]);
    expect(q.items[0]!.options[2]).toEqual({ label: "加到家庭日历" }); // empty description dropped
    expect(q.items[1]!.multiSelect).toBe(true);
    m.answer(q.id, { "要把面签加进 Outlook 吗？": "加进去", "提前多久提醒？": "前一天, 当天早上" }, "app");
    m.answer(q.id, { "要把面签加进 Outlook 吗？": "先不加", "提前多久提醒？": "前一天" }, "wechat"); // late: ignored
    const d = await p;
    expect(d).toEqual({
      behavior: "allow",
      updatedInput: { ...ask, answers: { "要把面签加进 Outlook 吗？": "加进去", "提前多久提醒？": "前一天, 当天早上" } },
    });
    expect(m.get(q.id)).toMatchObject({ status: "answered", answeredBy: "app" });
    cleanup(paths);
  });

  test("a skipped question goes back as no answer in words, never as a choice; skipping all is allowed", async () => {
    const { m, paths } = mk();
    const p = m.request(req(ask));
    const q = m.listPending()[0]!;
    m.answer(q.id, { "要把面签加进 Outlook 吗？": "加进去" }, "app");
    const d = await p;
    expect(d.behavior === "allow" && d.updatedInput!.answers).toEqual({
      "要把面签加进 Outlook 吗？": "加进去",
      "提前多久提醒？": "（没有回答：主人跳过了这题，别当成他的选择）",
    });
    expect(m.get(q.id)).toMatchObject({ status: "answered", answers: { "要把面签加进 Outlook 吗？": "加进去" }, skipped: ["提前多久提醒？"] });

    const p2 = m.request(req(ask));
    const q2 = m.listPending()[0]!;
    m.answer(q2.id, {}, "app");
    const d2 = await p2;
    expect(d2.behavior === "allow" && Object.values(d2.updatedInput!.answers as Record<string, string>)).toEqual([
      "（没有回答：主人跳过了这题，别当成他的选择）",
      "（没有回答：主人跳过了这题，别当成他的选择）",
    ]);
    expect(m.get(q2.id)).toMatchObject({ status: "answered", answers: {}, skipped: ["要把面签加进 Outlook 吗？", "提前多久提醒？"] });
    cleanup(paths);
  });

  test("own words that are only numbers are passed on as such, not as option 1", async () => {
    const { m, paths } = mk();
    const p = m.request(req(ask));
    m.answer(m.listPending()[0]!.id, { "要把面签加进 Outlook 吗？": "1", "提前多久提醒？": "11" }, "app");
    const d = await p;
    const told = d.behavior === "allow" ? (d.updatedInput!.answers as Record<string, string>) : {};
    expect(told["要把面签加进 Outlook 吗？"]).toBe("「1」（主人在「其他」里只写了数字，没有点选项，不能当成选了第几项）");
    expect(told["提前多久提醒？"]).toStartWith("「11」");
    cleanup(paths);
  });

  test("the owner's own words (「其他」) are a valid answer", async () => {
    const { m, paths } = mk();
    const p = m.request(req({ questions: [ask.questions[0]] }));
    m.answer(m.listPending()[0]!.id, { "要把面签加进 Outlook 吗？": "等我问问太太再说" }, "app");
    const d = await p;
    expect(d.behavior === "allow" && d.updatedInput!.answers).toEqual({ "要把面签加进 Outlook 吗？": "等我问问太太再说" });
    cleanup(paths);
  });

  test("timeout, abort and stop deny with a message so the model carries on", async () => {
    const { m, paths } = mk(0.0005); // ~30ms
    const d1 = await m.request(req(ask));
    expect(d1.behavior).toBe("deny");
    expect(d1.behavior === "deny" && d1.message).toContain("按你的判断继续");
    expect(m.list()[0]!.status).toBe("expired");

    const { m: m2, paths: p2 } = mk();
    const ac = new AbortController();
    const p = m2.request(req(ask, ac.signal));
    ac.abort();
    expect((await p).behavior).toBe("deny");
    const p3 = m2.request(req(ask));
    m2.cancelAll("stop:app");
    expect((await p3).behavior).toBe("deny");
    expect(m2.listPending()).toHaveLength(0);
    cleanup(paths);
    cleanup(p2);
  });

  test("malformed input is denied without bothering the owner", async () => {
    const { m, created, paths } = mk();
    expect((await m.request(req({ questions: [{ question: "?", options: [] }] }))).behavior).toBe("deny");
    expect(created).toHaveLength(0);
    expect(parseItems({})).toEqual([]);
    cleanup(paths);
  });

  test("a restart expires questions nobody can answer any more; a session's goes back to its terminal, a Pal's just ends", async () => {
    const { m, paths } = mk();
    void m.request(req(ask));
    m.ask(req(ask), { source: { kind: "session", id: "s1", name: "终端的" } });
    m.ask(req(ask), { source: { kind: "pal", id: "pal_1", name: "网站" } });
    const again = new QuestionManager(`${paths.state}/q.json`, new Bus(), new Audit(paths.audit), {
      taskForToolUse: () => undefined,
      onCreated: () => {},
      timeoutMinutes: () => 30,
    });
    expect(again.listPending()).toHaveLength(0);
    expect(again.list().every((q) => q.status === "expired")).toBe(true);
    expect(again.list().map((q) => [q.source?.kind ?? "own", q.note ?? null]).sort()).toEqual([
      ["own", null],
      ["pal", null],
      ["session", "在电脑上等你"],
    ]);
    m.cancelAll("test");
    m.cancelFor("s1", "test");
    m.cancelFor("pal_1", "test");
    expect(m.listPending()).toHaveLength(0);
    cleanup(paths);
  });
});

describe("questions on a text channel (WeChat)", () => {
  const q = (items = ask.questions): Question => ({ id: "q_1", items: parseItems({ questions: items }), status: "pending", createdAt: 0 });

  test("rendered as numbered options", () => {
    const one = questionText(q([ask.questions[0]!]));
    expect(one).toContain("要把面签加进 Outlook 吗？");
    expect(one).toContain("1) 加进去：加到工作日历");
    expect(one).toContain("回数字选");
    const two = questionText(q());
    expect(two).toContain("2. 提前多久提醒？（可多选）");
    expect(two).toContain("每行回一个问题");
  });

  test("numbers pick options; multi-select takes several; words are the owner's own answer", () => {
    expect(parseTextAnswer(q([ask.questions[0]!]), "2")).toEqual({ "要把面签加进 Outlook 吗？": "先不加" });
    // single-select keeps the first number only
    expect(parseTextAnswer(q([ask.questions[0]!]), "1,3")).toEqual({ "要把面签加进 Outlook 吗？": "加进去" });
    expect(parseTextAnswer(q([ask.questions[1]!]), "1，3")).toEqual({ "提前多久提醒？": "前一天, 出发前一小时" });
    expect(parseTextAnswer(q([ask.questions[0]!]), "周末再说吧")).toEqual({ "要把面签加进 Outlook 吗？": "周末再说吧" });
    expect(parseTextAnswer(q(), "1\n2 3")).toEqual({ "要把面签加进 Outlook 吗？": "加进去", "提前多久提醒？": "当天早上, 出发前一小时" });
    expect(parseTextAnswer(q(), "1；随便")).toEqual({ "要把面签加进 Outlook 吗？": "加进去", "提前多久提醒？": "随便" });
    // several questions, one line: can't tell which is which
    expect(parseTextAnswer(q(), "1")).toBeNull();
  });

  test("「跳过」 skips all, or one question on its own line", () => {
    expect(parseTextAnswer(q(), "跳过")).toEqual({});
    expect(parseTextAnswer(q([ask.questions[0]!]), "skip")).toEqual({});
    expect(parseTextAnswer(q(), "1\n跳过")).toEqual({ "要把面签加进 Outlook 吗？": "加进去" });
  });
});
