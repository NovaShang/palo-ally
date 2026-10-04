import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { Approval } from "./types.ts";
import { newId, readJson, truncate, writeJson } from "./util.ts";

// ---------------- classification ----------------

const OWN_SERVER = "mcp__paloally__";

const IRREVERSIBLE_BASH: RegExp[] = [
  /(^|[\s;&|(])rm\s/,
  /(^|[\s;&|(])rmdir\s/,
  /(^|[\s;&|(])shred\s/,
  /\bgit\s+push\b/,
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\s+-[a-z]*f/,
  /\bgit\s+branch\s+-D\b/,
  /\bcurl\b.*(\s-X\s*(POST|PUT|DELETE|PATCH)|\s(-d|--data|--data-raw|--data-binary|-F|--form)\b)/i,
  /\b(wget)\b.*--post/i,
  /\b(mail|sendmail|mutt)\b/,
  /\bosascript\b.*\b(send|delete)\b/i,
  /\bgh\s+(pr\s+(create|merge|close)|issue\s+(create|close|delete)|release\s+create|repo\s+delete)\b/,
  /\b(npm|bun|pnpm|yarn)\s+publish\b/,
  /\bkubectl\s+delete\b/,
  /\bdocker\s+(rm|rmi|system\s+prune)\b/,
  /\b(shutdown|reboot|halt)\b/,
  /\bdd\s+if=/,
  /\bmkfs\b/,
  /\bdrop\s+(table|database)\b/i,
  /\bdelete\s+from\b/i,
];

const IRREVERSIBLE_MCP = /(send|reply|forward|post|publish|delete|trash|remove|pay|purchase|order|checkout|transfer|share|submit|invite|cancel|archive|unsubscribe)/i;
const IRREVERSIBLE_CLICK = /(pay|buy|purchase|checkout|place order|submit|send|delete|remove|confirm|transfer|支付|付款|购买|下单|提交|发送|删除|确认|转账)/i;
const BROWSER_INTERACT = /browser_(click|type|press_key|fill_form|select_option|file_upload|drag)/;

// isIrreversible: sending, paying, deleting and other outward actions are
// never auto-approved (PRD §6.5.4).
export function isIrreversible(tool: string, input: Record<string, unknown>): boolean {
  if (tool.startsWith(OWN_SERVER)) return false;
  if (tool === "Bash") {
    const cmd = String(input.command ?? "");
    return IRREVERSIBLE_BASH.some((r) => r.test(cmd));
  }
  if (tool.startsWith("mcp__")) {
    const leaf = tool.split("__").slice(2).join("__");
    if (BROWSER_INTERACT.test(leaf)) {
      const text = `${input.element ?? ""} ${input.text ?? ""} ${input.key ?? ""}`;
      return IRREVERSIBLE_CLICK.test(text) || (leaf === "browser_press_key" && /enter/i.test(String(input.key)));
    }
    return IRREVERSIBLE_MCP.test(leaf);
  }
  return false;
}

export function domainOf(url: unknown): string | null {
  if (typeof url !== "string") return null;
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

// scopeFor derives the narrow scope an auto rule may cover for this call.
// null means no safe narrow scope exists, so "always allow" is not offered.
export function scopeFor(tool: string, input: Record<string, unknown>, currentDomain?: string): string | null {
  if (tool === "Bash") {
    const words = String(input.command ?? "").trim().split(/\s+/).filter(Boolean);
    if (!words.length || /[;&|`$<>]/.test(String(input.command))) return null; // compound commands never get a rule
    return `cmd:${words.slice(0, 2).join(" ")}`;
  }
  if (tool === "WebFetch") {
    const d = domainOf(input.url);
    return d ? `domain:${d}` : null;
  }
  if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") {
    const p = String(input.file_path ?? input.notebook_path ?? "");
    const dir = p.slice(0, p.lastIndexOf("/"));
    return dir && dir !== "" ? `path:${dir}` : null;
  }
  if (tool.startsWith("mcp__")) {
    const recipient = input.to ?? input.recipient ?? input.email ?? input.chat_id ?? input.channel;
    if (typeof recipient === "string" && recipient) return `recipient:${recipient}`;
    const d = domainOf(input.url) ?? currentDomain;
    if (d && /browser_/.test(tool)) return `domain:${d}`;
    return null;
  }
  return null;
}

export interface AutoRule {
  id: string;
  tool: string;
  scope: string;
  createdAt: number;
}

export function validateRule(tool: string, scope: string): string | null {
  if (!tool || tool === "*" || /[*?]/.test(tool)) return "规则必须指定具体工具";
  const m = /^(cmd|domain|path|recipient):(.+)$/.exec(scope ?? "");
  if (!m) return "规则必须限定在命令、域名、路径或收件人上，不能整类放行";
  const v = m[2]!.trim();
  if (!v || v === "*" || v === "/" || /^\*/.test(v)) return "规则范围太宽";
  return null;
}

export function ruleMatches(rule: AutoRule, tool: string, scope: string | null): boolean {
  if (!scope || rule.tool !== tool) return false;
  const [rk, rv] = splitScope(rule.scope);
  const [ck, cv] = splitScope(scope);
  if (rk !== ck) return false;
  switch (rk) {
    case "domain":
      return cv === rv || cv.endsWith("." + rv);
    case "path":
      return cv === rv || cv.startsWith(rv + "/");
    default:
      return cv === rv;
  }
}

function splitScope(s: string): [string, string] {
  const i = s.indexOf(":");
  return [s.slice(0, i), s.slice(i + 1)];
}

// ---------------- manager ----------------

interface Pending {
  approval: Approval;
  resolve: (d: PermissionDecision) => void;
  timer: ReturnType<typeof setTimeout>;
  input: Record<string, unknown>;
}

export interface ApprovalHooks {
  isKilled(): boolean;
  taskForToolUse(toolUseId?: string): string | undefined;
  onCreated(a: Approval): void; // hub: chat card + push
  timeoutMinutes(): number;
  sensitiveDomains(): string[];
}

export class ApprovalManager {
  private approvals: Approval[];
  private rules: AutoRule[];
  private pending = new Map<string, Pending>();
  private currentDomain: string | undefined;

  constructor(
    private path: string,
    private rulesPath: string,
    private bus: Bus,
    private audit: Audit,
    private hooks: ApprovalHooks,
  ) {
    this.approvals = readJson<Approval[]>(path, []);
    // Pending approvals from a previous process can't be answered any more.
    for (const a of this.approvals) if (a.status === "pending") a.status = "expired";
    this.rules = readJson<AutoRule[]>(rulesPath, []);
    this.persist();
  }

  list(): Approval[] {
    return [...this.approvals].sort((a, b) => b.createdAt - a.createdAt).slice(0, 100);
  }

  listPending(): Approval[] {
    return this.approvals.filter((a) => a.status === "pending");
  }

  listRules(): AutoRule[] {
    return [...this.rules];
  }

  addRule(tool: string, scope: string): AutoRule {
    const err = validateRule(tool, scope);
    if (err) throw new Error(err);
    const rule: AutoRule = { id: newId("r_"), tool, scope, createdAt: Date.now() };
    this.rules.push(rule);
    this.persist();
    this.audit.log("rule.added", { tool, scope });
    return rule;
  }

  removeRule(id: string): boolean {
    const before = this.rules.length;
    this.rules = this.rules.filter((r) => r.id !== id);
    this.persist();
    if (this.rules.length !== before) this.audit.log("rule.removed", { id });
    return this.rules.length !== before;
  }

  noteNavigation(url: unknown): void {
    this.currentDomain = domainOf(url) ?? this.currentDomain;
  }

  isSensitiveNavigation(tool: string, input: Record<string, unknown>): boolean {
    if (!/browser_navigate|browser_tabs|WebFetch/.test(tool)) return false;
    const d = domainOf(input.url);
    if (!d) return false;
    return this.hooks.sensitiveDomains().some((s) => d === s || d.endsWith("." + s));
  }

  // preGate runs on every tool call before the harness decides.
  preGate(tool: string, input: Record<string, unknown>): { decision: "allow" | "deny" | "ask" | "pass"; reason?: string } {
    if (this.hooks.isKilled()) return { decision: "deny", reason: "助理已被急停，所有操作暂停" };
    // The shell's own tools (report_task, register_watch…) only touch PaloAlly state.
    if (tool.startsWith(OWN_SERVER)) return { decision: "allow" };
    if (this.isSensitiveNavigation(tool, input)) return { decision: "deny", reason: "该网站在敏感账号名单里，助理的浏览器不碰它" };
    if (isIrreversible(tool, input)) return { decision: "ask", reason: "不可逆/对外动作，需要你单独确认" };
    return { decision: "pass" };
  }

  // request is the harness' canUseTool: the harness wants to prompt.
  request(req: PermissionRequest): Promise<PermissionDecision> {
    if (this.hooks.isKilled()) return Promise.resolve({ behavior: "deny", message: "助理已被急停" });
    if (req.toolName.startsWith(OWN_SERVER)) return Promise.resolve({ behavior: "allow", updatedInput: req.input });
    if (this.isSensitiveNavigation(req.toolName, req.input)) {
      return Promise.resolve({ behavior: "deny", message: "该网站在敏感账号名单里" });
    }
    const irreversible = isIrreversible(req.toolName, req.input);
    const scope = scopeFor(req.toolName, req.input, this.currentDomain);
    if (!irreversible) {
      const rule = this.rules.find((r) => ruleMatches(r, req.toolName, scope));
      if (rule) {
        this.audit.log("approval.auto", { tool: req.toolName, scope, rule: rule.id, input: req.input });
        return Promise.resolve({ behavior: "allow", updatedInput: req.input });
      }
    }

    const approval: Approval = {
      id: newId("a_"),
      tool: req.toolName,
      title: req.title || describeTool(req.toolName, req.input),
      detail: describeInput(req.toolName, req.input),
      taskId: this.hooks.taskForToolUse(req.toolUseId),
      irreversible,
      status: "pending",
      createdAt: Date.now(),
      suggestedScope: irreversible ? undefined : (scope ?? undefined),
    };
    this.approvals.push(approval);
    this.persist();
    this.audit.log("approval.requested", { id: approval.id, tool: req.toolName, input: req.input, irreversible });

    return new Promise<PermissionDecision>((resolve) => {
      const timer = setTimeout(
        () => this.settle(approval.id, "expired", "timeout"),
        this.hooks.timeoutMinutes() * 60_000,
      );
      this.pending.set(approval.id, { approval, resolve, timer, input: req.input });
      req.signal.addEventListener("abort", () => this.settle(approval.id, "expired", "aborted"));
      this.bus.emit("approval.updated", approval);
      this.hooks.onCreated(approval);
    });
  }

  // answer: first answer wins across all channels.
  answer(id: string, allow: boolean, by: string, remember = false): Approval | undefined {
    const p = this.pending.get(id);
    if (!p) return this.approvals.find((a) => a.id === id);
    if (remember && allow && p.approval.suggestedScope && !p.approval.irreversible) {
      try {
        this.addRule(p.approval.tool, p.approval.suggestedScope);
      } catch (e) {
        this.audit.log("rule.rejected", { error: String(e) });
      }
    }
    this.settle(id, allow ? "allowed" : "denied", by);
    return p.approval;
  }

  // denyAll is the kill switch's sweep.
  denyAll(by: string): void {
    for (const id of [...this.pending.keys()]) this.settle(id, "denied", by);
  }

  private settle(id: string, status: "allowed" | "denied" | "expired", by: string): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    clearTimeout(p.timer);
    p.approval.status = status;
    p.approval.decidedAt = Date.now();
    p.approval.decidedBy = by;
    this.persist();
    this.audit.log("approval.decided", { id, status, by, tool: p.approval.tool });
    this.bus.emit("approval.updated", p.approval);
    if (status === "allowed") p.resolve({ behavior: "allow", updatedInput: p.input });
    else p.resolve({ behavior: "deny", message: status === "expired" ? "没等到确认，已取消" : "用户拒绝了这个操作" });
  }

  private persist(): void {
    // Keep the last 500 decisions.
    if (this.approvals.length > 500) this.approvals = this.approvals.slice(-500);
    writeJson(this.path, this.approvals);
    writeJson(this.rulesPath, this.rules);
  }
}

// ---------------- human-readable cards (no tech words) ----------------

function describeTool(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return "在电脑上运行一条命令";
  if (tool === "Write") return "写入文件";
  if (tool === "Edit") return "修改文件";
  if (tool === "WebFetch") return `打开网页 ${domainOf(input.url) ?? ""}`.trim();
  if (tool.startsWith("mcp__")) {
    const leaf = tool.split("__").slice(2).join(" ");
    if (/browser_navigate/.test(tool)) return `浏览器打开 ${domainOf(input.url) ?? ""}`.trim();
    if (/browser_click/.test(tool)) return `在网页上点击「${truncate(String(input.element ?? ""), 30)}」`;
    if (/browser_type|fill_form/.test(tool)) return "在网页上填写内容";
    return `使用 ${leaf}`;
  }
  return `使用 ${tool}`;
}

function describeInput(tool: string, input: Record<string, unknown>): string {
  if (tool === "Bash") return truncate(String(input.command ?? ""), 500);
  if (tool === "Write" || tool === "Edit") return String(input.file_path ?? "");
  if (input.url) return String(input.url);
  return truncate(JSON.stringify(input), 500);
}
