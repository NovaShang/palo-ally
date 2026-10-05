import { randomBytes } from "node:crypto";
import type { Bus } from "./bus.ts";
import type { HarnessDriver } from "./harness/types.ts";
import { readJson, truncate, writeJson } from "./util.ts";

// 「试试」: things the owner could ask the assistant to do, written by the
// assistant itself from what it knows about the owner (user.md, soul.md, its
// memory index, the services it's connected to). Shown as chips above the
// composer when the chat is quiet; tapping one sends its full prompt. Made by
// one cheap probe-model call, refreshed daily or when few are left.

export interface Suggestion {
  id: string;
  chip: string; // short, starts with a verb (≤ 14 汉字)
  prompt: string; // the full message sent when tapped
  category?: string;
  createdAt: number;
}

type Stored = Suggestion & { status: "new" | "used" | "dismissed"; at?: number };

interface State {
  generatedAt: number;
  items: Stored[];
  connectors: string[];
}

export interface SuggestionDeps {
  driver: HarnessDriver;
  probeModel(): string;
  cwd(): string;
  env?(): Record<string, string> | undefined;
  context(): string; // what the assistant knows about the owner (user.md, soul.md, memory index)
  budgetLeftUsd(): number;
  spend(usd: number): void;
  log(s: string): void;
  now?(): number;
}

const REFRESH_MS = 24 * 3600_000;
const MIN_LEFT = 3;
const KEEP_HISTORY = 60; // used/dismissed kept so they're never suggested again

export const SUGGESTION_SCHEMA = {
  type: "object",
  properties: {
    suggestions: {
      type: "array",
      items: {
        type: "object",
        properties: {
          chip: { type: "string", description: "≤14 个汉字，动词开头，如「找出没在用的订阅」" },
          prompt: { type: "string", description: "主人点了以后发给你的完整请求，第一人称，具体可执行" },
          category: { type: "string" },
        },
        required: ["chip", "prompt"],
      },
    },
  },
  required: ["suggestions"],
} as const;

export const SUGGESTION_SYSTEM = `你是一位私人助理，跑在主人自己的电脑上（能读写文件、用浏览器、跑命令、定提醒和长期盯着的目标，以及下面列出的已连接服务）。
现在要给主人写几条「试试」建议：主人可能还没想到、但你真的能替他办的事。主人在 App 里看到一个短标签，点一下就把完整请求发给你。
要求：
- 贴合主人本人：从他的资料、你的记忆里找具体的线索（家人、工作、习惯、在意的事），不要写谁都适用的空话。
- 必须是你在这台电脑上真能做到的；需要没连接的服务时就别写。
- chip：14 个汉字以内，动词开头，口语，如「找出没在用的订阅」「每周日给我做周报」。
- prompt：主人点了以后发给你的完整请求，第一人称，具体到你能直接开工。
- 混合几类：一次性的事、需要长期盯着的事、整理信息的事。
- 不要重复 avoid 里出现过的建议。
- 写 8 条。`;

export class SuggestionStore {
  private state: State;
  private running: Promise<number> | null = null;

  constructor(
    private path: string,
    private bus: Bus,
    private d: SuggestionDeps,
  ) {
    this.state = readJson<State>(path, { generatedAt: 0, items: [], connectors: [] });
    this.state.items ??= [];
    this.state.connectors ??= [];
  }

  private now(): number {
    return this.d.now?.() ?? Date.now();
  }

  /** Suggestions not used or dismissed yet, newest batch first. */
  list(): Suggestion[] {
    return this.state.items
      .filter((s) => s.status === "new")
      .map(({ id, chip, prompt, category, createdAt }) => ({ id, chip, prompt, ...(category ? { category } : {}), createdAt }));
  }

  get(id: string): Suggestion | undefined {
    return this.list().find((s) => s.id === id);
  }

  dismiss(id: string): boolean {
    return this.mark(id, "dismissed");
  }

  use(id: string): boolean {
    return this.mark(id, "used");
  }

  /** The connected services (MCP server names) the main session reported. */
  setConnectors(tools: string[]): void {
    const names = [...new Set(tools.filter((t) => t.startsWith("mcp__")).map((t) => t.split("__")[1]!).filter((n) => n && n !== "paloally"))].sort();
    if (names.join(",") === this.state.connectors.join(",")) return;
    this.state.connectors = names;
    this.save();
  }

  needsRefresh(now = this.now()): boolean {
    return now - this.state.generatedAt >= REFRESH_MS || this.list().length < MIN_LEFT;
  }

  /** Refreshes in the background when due; never runs two at once. */
  maybeRefresh(reason: string): void {
    if (this.running || !this.needsRefresh()) return;
    void this.refresh(reason);
  }

  async refresh(reason = "manual"): Promise<number> {
    if (this.running) return this.running;
    this.running = this.generate(reason).finally(() => (this.running = null));
    return this.running;
  }

  private async generate(reason: string): Promise<number> {
    if (this.d.budgetLeftUsd() <= 0) {
      this.d.log("suggestions skipped: daily probe budget used up");
      return 0;
    }
    const avoid = this.state.items.map((s) => s.chip).slice(-KEEP_HISTORY);
    const prompt = JSON.stringify(
      {
        now: new Date(this.now()).toISOString(),
        connected_services: this.state.connectors,
        about_owner: truncate(this.d.context(), 6000),
        avoid,
      },
      null,
      1,
    );
    const res = await this.d.driver.runProbe({
      model: this.d.probeModel(),
      cwd: this.d.cwd(),
      systemPrompt: SUGGESTION_SYSTEM,
      prompt,
      mcpServers: {},
      tools: [],
      outputSchema: SUGGESTION_SCHEMA as unknown as Record<string, unknown>,
      maxTurns: 2,
      strictMcp: true,
      env: this.d.env?.(),
    });
    this.d.spend(res.costUsd);
    if (res.error) {
      this.d.log(`suggestions error: ${res.error}`);
      // Wait a while before retrying a failing generation.
      this.state.generatedAt = this.now() - REFRESH_MS + 3600_000;
      this.save();
      return 0;
    }
    const seen = new Set(avoid);
    const fresh = parseSuggestions(res.output)
      .filter((s) => !seen.has(s.chip))
      .map((s) => ({ ...s, id: `sg_${randomBytes(5).toString("hex")}`, createdAt: this.now(), status: "new" as const }));
    // The new batch replaces the unused old ones; used/dismissed stay as history.
    const history = this.state.items.filter((s) => s.status !== "new").slice(-KEEP_HISTORY);
    this.state = { ...this.state, generatedAt: this.now(), items: [...history, ...fresh] };
    this.save();
    this.d.log(`suggestions: ${fresh.length} new (${reason}), $${res.costUsd.toFixed(4)}`);
    this.emit();
    return fresh.length;
  }

  private mark(id: string, status: "used" | "dismissed"): boolean {
    const s = this.state.items.find((x) => x.id === id && x.status === "new");
    if (!s) return false;
    s.status = status;
    s.at = this.now();
    this.save();
    this.emit();
    this.maybeRefresh(`few left after ${status}`);
    return true;
  }

  private emit(): void {
    this.bus.emit("suggestions.updated", { suggestions: this.list() });
  }

  private save(): void {
    writeJson(this.path, this.state);
  }
}

export function parseSuggestions(output: unknown): { chip: string; prompt: string; category?: string }[] {
  let o = output;
  if (typeof o === "string") {
    try {
      o = JSON.parse(o);
    } catch {
      return [];
    }
  }
  const rows = (o as { suggestions?: unknown })?.suggestions;
  if (!Array.isArray(rows)) return [];
  const out: { chip: string; prompt: string; category?: string }[] = [];
  for (const r of rows) {
    if (!r || typeof r !== "object") continue;
    const chip = String((r as any).chip ?? "").trim().replace(/^试试[:：]\s*/, "");
    const prompt = String((r as any).prompt ?? "").trim();
    if (!chip || !prompt) continue;
    const category = typeof (r as any).category === "string" && (r as any).category.trim() ? String((r as any).category).trim().slice(0, 20) : undefined;
    out.push({ chip: chip.slice(0, 24), prompt: prompt.slice(0, 600), ...(category ? { category } : {}) });
  }
  return out.slice(0, 12);
}
