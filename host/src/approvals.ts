import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { Approval } from "./types.ts";
import { newId, readJson, truncate, writeJson } from "./util.ts";

// Safety is the harness' job (PRD revision 2026-10-04: "全部依赖 harness").
// Claude Code decides what runs, what is denied, and what needs the owner;
// this module only carries its permission prompts to wherever the owner is
// (app, WeChat, terminal) and hands the answer back, first answer wins.
// "Always allow" means returning the harness' own suggested rule, which the
// harness persists in its own settings.

interface Pending {
  approval: Approval;
  resolve: (d: PermissionDecision) => void;
  timer: ReturnType<typeof setTimeout>;
  input: Record<string, unknown>;
  suggestions?: unknown[];
}

export interface ApprovalHooks {
  taskForToolUse(toolUseId?: string): string | undefined;
  onCreated(a: Approval): void; // hub: chat card + push
  timeoutMinutes(): number;
}

export class ApprovalManager {
  private approvals: Approval[];
  private pending = new Map<string, Pending>();

  constructor(
    private path: string,
    private bus: Bus,
    private audit: Audit,
    private hooks: ApprovalHooks,
  ) {
    this.approvals = readJson<Approval[]>(path, []);
    // Prompts from a previous process can't be answered any more.
    for (const a of this.approvals) if (a.status === "pending") a.status = "expired";
    this.persist();
  }

  list(): Approval[] {
    return [...this.approvals].sort((a, b) => b.createdAt - a.createdAt).slice(0, 100);
  }

  listPending(): Approval[] {
    return this.approvals.filter((a) => a.status === "pending");
  }

  // request is the harness' canUseTool: it wants the owner to decide.
  request(req: PermissionRequest): Promise<PermissionDecision> {
    // The shell's own tools only touch PaloAlly state; never bother the owner.
    if (req.toolName.startsWith("mcp__paloally__")) return Promise.resolve({ behavior: "allow", updatedInput: req.input });

    const remember = !req.defaultToNo && !req.suppressAlwaysAllowRule ? describeSuggestion(req.suggestions) : null;
    const approval: Approval = {
      id: newId("a_"),
      tool: req.toolName,
      title: describeTool(req.toolName, req.input),
      detail: describeInput(req.toolName, req.input),
      taskId: this.hooks.taskForToolUse(req.toolUseId),
      // the harness marks prompts that must not be approved casually
      careful: !!req.defaultToNo,
      status: "pending",
      createdAt: Date.now(),
      suggestedScope: remember ?? undefined,
    };
    this.approvals.push(approval);
    this.persist();
    this.audit.log("approval.requested", { id: approval.id, tool: req.toolName, reason: req.reason });

    return new Promise<PermissionDecision>((resolve) => {
      const timer = setTimeout(() => this.settle(approval.id, "expired", "timeout"), this.hooks.timeoutMinutes() * 60_000);
      this.pending.set(approval.id, { approval, resolve, timer, input: req.input, suggestions: remember ? req.suggestions : undefined });
      req.signal.addEventListener("abort", () => this.settle(approval.id, "expired", "aborted"));
      this.bus.emit("approval.updated", approval);
      this.hooks.onCreated(approval);
    });
  }

  // answer: first answer wins across all channels.
  answer(id: string, allow: boolean, by: string, remember = false): Approval | undefined {
    const p = this.pending.get(id);
    if (!p) return this.approvals.find((a) => a.id === id);
    this.settle(id, allow ? "allowed" : "denied", by, allow && remember ? p.suggestions : undefined);
    return p.approval;
  }

  // denyAll answers every open prompt with "no" (the stop button).
  denyAll(by: string): void {
    for (const id of [...this.pending.keys()]) this.settle(id, "denied", by);
  }

  private settle(id: string, status: "allowed" | "denied" | "expired", by: string, updatedPermissions?: unknown[]): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    clearTimeout(p.timer);
    p.approval.status = status;
    p.approval.decidedAt = Date.now();
    p.approval.decidedBy = by;
    this.persist();
    this.audit.log("approval.decided", { id, status, by, tool: p.approval.tool, remembered: !!updatedPermissions });
    this.bus.emit("approval.updated", p.approval);
    if (status === "allowed") p.resolve({ behavior: "allow", updatedInput: p.input, updatedPermissions });
    else p.resolve({ behavior: "deny", message: status === "expired" ? "没等到主人确认，已取消" : "主人拒绝了这个操作" });
  }

  private persist(): void {
    if (this.approvals.length > 500) this.approvals = this.approvals.slice(-500);
    writeJson(this.path, this.approvals);
  }
}

// ---------------- presentation only (no decisions are made here) ----------------

// describeSuggestion renders the harness' "always allow" suggestion in the
// scope vocabulary the app shows ("cmd:", "domain:", "path:", "tool:").
export function describeSuggestion(suggestions: unknown[] | undefined): string | null {
  for (const s of suggestions ?? []) {
    const u = s as { type?: string; behavior?: string; rules?: { toolName: string; ruleContent?: string }[]; directories?: string[] };
    if (u.type === "addDirectories" && u.directories?.[0]) return `path:${u.directories[0]}`;
    if (u.type !== "addRules" || u.behavior !== "allow" || !u.rules?.length) continue;
    const r = u.rules[0]!;
    const c = r.ruleContent ?? "";
    if (r.toolName === "Bash" && c) return `cmd:${c.replace(/:\*$/, "").replace(/\s*\*$/, "")}`;
    if (c.startsWith("domain:")) return c;
    if (/^(Read|Write|Edit|NotebookEdit|Glob|Grep)$/.test(r.toolName) && c) return `path:${c.replace(/\/\*\*$/, "").replace(/^\/\//, "/")}`;
    return `tool:${r.toolName}`;
  }
  return null;
}

function domainOf(url: unknown): string | null {
  if (typeof url !== "string") return null;
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

function nameTokens(name: string): string[] {
  return name
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

export function describeTool(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return "在电脑上运行一条命令";
  if (tool === "Write") return "写入文件";
  if (tool === "Edit") return "修改文件";
  if (tool === "Read") return "看一个文件";
  if (tool === "WebFetch") return `打开网页 ${domainOf(input.url) ?? ""}`.trim();
  if (tool.startsWith("mcp__")) {
    const leaf = tool.split("__").slice(2).join(" ");
    if (/browser_navigate|claude-in-chrome__navigate/.test(tool)) return `浏览器打开 ${domainOf(input.url) ?? ""}`.trim();
    if (/browser_click/.test(tool)) return `在网页上点击「${truncate(String(input.element ?? ""), 30)}」`;
    if (/browser_type|fill_form|form_input/.test(tool)) return "在网页上填写内容";
    if (/claude-in-chrome__computer/.test(tool)) return "在你的浏览器里操作";
    if (/javascript_tool|browser_evaluate/.test(tool)) return "在你的浏览器里运行一段脚本";
    if (/file_upload|upload_image/.test(tool)) return "往网页上传文件";
    const t = nameTokens(leaf);
    if (t.includes("send") || t.includes("reply") || t.includes("forward")) return "替你发出一条消息";
    if (t.includes("delete") || t.includes("trash") || t.includes("remove")) return "删除一些东西";
    if (t.includes("create") || t.includes("add")) return "替你新建一项内容";
    return "使用一个连接的服务";
  }
  return "做一步操作";
}

function describeInput(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return truncate(String(input.command ?? ""), 4000);
  if (tool === "Write" || tool === "Edit" || tool === "Read") return String(input.file_path ?? "");
  if (input.url) return String(input.url);
  return truncate(JSON.stringify(input), 1000);
}
