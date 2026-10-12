import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { Approval, CardSource } from "./types.ts";
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

// For a card that isn't the assistant's own canUseTool prompt.
export interface AskOptions {
  source?: CardSource; // a session on the computer asks
  tool?: string; // what the card shows as the tool (default: the request's)
  title?: string;
  detail?: string;
  timeoutMs?: number; // default: the owner's approval timeout setting
  timeoutNote?: string; // the card's note when it times out
  abortNote?: string; // …and when the request goes away (the signal)
  abortBy?: string;
  notify?: boolean; // false: no chat card / push (the caller tells the owner itself)
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
    // Prompts from a previous process can't be answered any more. A session's
    // is back in its own terminal.
    for (const a of this.approvals)
      if (a.status === "pending") {
        a.status = "expired";
        if (a.source) a.note = "在电脑上等你";
      }
    this.persist();
  }

  get(id: string): Approval | undefined {
    return this.approvals.find((a) => a.id === id);
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
    return this.ask(req).result;
  }

  // ask puts a card in front of the owner and resolves with their decision.
  // The card itself (status, note) says how it ended.
  ask(req: PermissionRequest, o: AskOptions = {}): { approval: Approval; result: Promise<PermissionDecision> } {
    // A Pal asks through the harness like the assistant does, so its "always
    // allow" is the harness' own rule too; a session through the hooks has none.
    const ownPrompt = !o.source || o.source.kind === "pal";
    const remember = ownPrompt && !req.defaultToNo && !req.suppressAlwaysAllowRule ? describeSuggestion(req.suggestions) : null;
    const approval: Approval = {
      id: newId("a_"),
      tool: o.tool ?? req.toolName,
      title: o.title ?? describeTool(req.toolName, req.input),
      detail: o.detail ?? describeInput(req.toolName, req.input),
      taskId: this.hooks.taskForToolUse(req.toolUseId),
      // the harness marks prompts that must not be approved casually
      careful: !!req.defaultToNo,
      status: "pending",
      createdAt: Date.now(),
      suggestedScope: remember ?? undefined,
      reason: req.reason || undefined,
      ...(o.source ? { source: o.source } : {}),
    };
    this.approvals.push(approval);
    this.persist();
    this.audit.log("approval.requested", { id: approval.id, tool: approval.tool, reason: req.reason, ...(o.source ? { session: o.source.id, sessionName: o.source.name } : {}) });

    const result = new Promise<PermissionDecision>((resolve) => {
      const ms = o.timeoutMs ?? this.hooks.timeoutMinutes() * 60_000;
      const timer = setTimeout(() => this.settle(approval.id, "expired", "timeout", undefined, o.timeoutNote), ms);
      this.pending.set(approval.id, { approval, resolve, timer, input: req.input, suggestions: remember ? req.suggestions : undefined });
      const onAbort = () => this.settle(approval.id, "expired", o.abortBy ?? "aborted", undefined, o.abortNote);
      if (req.signal.aborted) queueMicrotask(onAbort);
      else req.signal.addEventListener("abort", onAbort);
      this.bus.emit("approval.updated", approval);
      if (o.notify !== false) this.hooks.onCreated(approval);
    });
    return { approval, result };
  }

  // answer: first answer wins across all channels. `device`: the paired
  // device that answered, for the audit trail.
  answer(id: string, allow: boolean, by: string, remember = false, device?: string): Approval | undefined {
    const p = this.pending.get(id);
    if (!p) return this.approvals.find((a) => a.id === id);
    this.settle(id, allow ? "allowed" : "denied", by, allow && remember ? p.suggestions : undefined, undefined, device);
    return p.approval;
  }

  // denyAll answers every open prompt of the assistant's with "no" (the stop
  // button). Sessions' cards are theirs, not the assistant's: left alone.
  denyAll(by: string): void {
    for (const [id, p] of [...this.pending]) if (!p.approval.source) this.settle(id, "denied", by);
  }

  // denyFor answers one session's or Pal's open prompts with "no" (its own
  // stop button, or its process ended).
  denyFor(sourceId: string, by: string): void {
    for (const [id, p] of [...this.pending]) if (p.approval.source?.id === sourceId) this.settle(id, "denied", by);
  }

  private settle(id: string, status: "allowed" | "denied" | "expired", by: string, updatedPermissions?: unknown[], note?: string, device?: string): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    clearTimeout(p.timer);
    p.approval.status = status;
    p.approval.decidedAt = Date.now();
    p.approval.decidedBy = by;
    if (note) p.approval.note = note;
    this.persist();
    const src = p.approval.source;
    this.audit.log("approval.decided", {
      id,
      status,
      by,
      ...(device ? { device } : {}),
      tool: p.approval.tool,
      remembered: !!updatedPermissions,
      ...(src ? { session: src.id, sessionName: src.name } : {}),
      ...(note ? { note } : {}),
    });
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
