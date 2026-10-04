import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { Approval } from "./types.ts";
import { describeInput, describeTool } from "./copy.ts";
import { newId, readJson, writeJson } from "./util.ts";

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
// Card wording lives in copy.ts.

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
