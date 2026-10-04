import { dirname, resolve } from "node:path";
import type { Audit } from "./audit.ts";
import type { Bus } from "./bus.ts";
import type { PermissionDecision, PermissionRequest } from "./harness/types.ts";
import type { Approval } from "./types.ts";
import { newId, readJson, truncate, writeJson } from "./util.ts";

// ---------------- classification ----------------

const OWN_SERVER = "mcp__paloally__";
const SENSITIVE_MSG = "主人把这个网站放进了「不让助理碰」的名单，不能打开。请告诉主人需要的话自己去电脑上看。";

// ---- shell: classify each simple command by its program, not by substrings ----

// splitCommands breaks a shell line into simple commands (on ; && || | & newlines
// and inside $(…) / backticks), keeping quoted strings as single words.
export function splitCommands(line: string): string[][] {
  const cmds: string[][] = [];
  let words: string[] = [];
  let cur = "";
  let quote: string | null = null;
  const endWord = () => {
    if (cur) words.push(cur);
    cur = "";
  };
  const endCmd = () => {
    endWord();
    if (words.length) cmds.push(words);
    words = [];
  };
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (quote) {
      if (c === quote) quote = null;
      else cur += c;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      continue;
    }
    if (c === "\\" && i + 1 < line.length) {
      cur += line[++i];
      continue;
    }
    if (c === "$" && line[i + 1] === "(") {
      endCmd();
      i++;
      continue;
    }
    if (";|&\n`()".includes(c)) {
      endCmd();
      continue;
    }
    if (/\s/.test(c)) {
      endWord();
      continue;
    }
    cur += c;
  }
  endCmd();
  return cmds;
}

const WRAPPERS = new Set(["sudo", "env", "nohup", "time", "command", "exec", "nice", "xargs", "caffeinate", "timeout"]);
const DANGEROUS_CODE = /(rmtree|os\.remove|os\.unlink|\.unlink\(|os\.rmdir|rmSync|unlinkSync|fs\.rm\b|os\.system|subprocess|shutil\.move|requests\.(post|put|delete|patch)|httpx\.(post|put|delete)|smtplib|sendmail|urlopen\([^)]*data=)/;

function isIrreversibleCommand(words: string[]): boolean {
  let i = 0;
  // skip env assignments and wrappers (and their flags)
  while (i < words.length && (/^\w+=/.test(words[i]!) || WRAPPERS.has(words[i]!.split("/").pop()!) || (i > 0 && WRAPPERS.has(words[i - 1]!.split("/").pop()!) && words[i]!.startsWith("-")))) i++;
  const prog = (words[i] ?? "").split("/").pop()!;
  const args = words.slice(i + 1);
  const has = (...xs: string[]) => args.some((a) => xs.includes(a));
  const sub = args.find((a) => !a.startsWith("-")) ?? "";
  switch (prog) {
    case "rm": case "rmdir": case "shred": case "srm": case "unlink": case "trash": case "truncate":
      return true;
    case "sh": case "bash": case "zsh": case "dash": {
      const c = args.indexOf("-c");
      return c >= 0 && args[c + 1] !== undefined && isIrreversible("Bash", { command: args[c + 1] });
    }
    case "python": case "python3": case "node": case "ruby": case "perl": case "bun": case "deno": {
      const flag = args.findIndex((a) => a === "-c" || a === "-e" || a === "--eval");
      if (flag >= 0) return DANGEROUS_CODE.test(args[flag + 1] ?? "");
      if (prog === "bun") return sub === "publish";
      return false;
    }
    case "find":
      return has("-delete") || args.some((a, k) => (a === "-exec" || a === "-execdir" || a === "-ok") && /(^|\/)rm$|shred|unlink/.test(args[k + 1] ?? ""));
    case "git":
      if (sub === "push" || sub === "filter-branch" || sub === "filter-repo") return true;
      if (sub === "reset") return has("--hard");
      if (sub === "clean") return args.some((a) => /^-[a-z]*f/.test(a));
      if (sub === "branch") return has("-D", "--delete");
      if (sub === "checkout" || sub === "restore") return has("--", ".") && has(".");
      return false;
    case "curl": {
      const method = args.findIndex((a) => a === "-X" || a === "--request");
      if (method >= 0 && /^(POST|PUT|DELETE|PATCH)$/i.test(args[method + 1] ?? "")) return true;
      return args.some((a) => /^(-d|--data.*|-F|--form.*|--json|-T|--upload-file)$/.test(a) || /^-X(POST|PUT|DELETE|PATCH)$/i.test(a));
    }
    case "wget":
      return args.some((a) => a.startsWith("--post") || a.startsWith("--method"));
    case "mail": case "sendmail": case "mutt": case "msmtp": case "mailx":
      return true;
    case "scp": case "sftp":
      return true;
    case "rsync":
      return has("--delete", "--delete-after", "--delete-before", "--remove-source-files") || args.some((a) => /^[^/\s]+:/.test(a));
    case "osascript":
      return args.some((a) => /\b(send|delete|empty trash)\b/i.test(a));
    case "gh": {
      const s2 = args.filter((a) => !a.startsWith("-"));
      const verb = `${s2[0] ?? ""} ${s2[1] ?? ""}`;
      return /^(pr (create|merge|close|comment|review)|issue (create|close|delete|comment)|release (create|delete)|repo (delete|create|archive)|gist create)$/.test(verb) || (s2[0] === "api" && args.some((a, k) => (a === "-X" || a === "--method") && /POST|PUT|DELETE|PATCH/i.test(args[k + 1] ?? "")));
    }
    case "npm": case "pnpm": case "yarn":
      return sub === "publish" || sub === "unpublish";
    case "kubectl":
      return sub === "delete";
    case "docker":
      return sub === "rm" || sub === "rmi" || (sub === "system" && has("prune")) || (sub === "volume" && has("rm"));
    case "shutdown": case "reboot": case "halt":
      return true;
    case "dd":
      return args.some((a) => a.startsWith("of="));
    case "diskutil":
      return /erase|partition|unmount/i.test(sub);
    case "psql": case "mysql": case "sqlite3":
      return args.some((a) => /\b(drop|delete|truncate|update)\b/i.test(a));
  }
  return prog.startsWith("mkfs");
}

const INTERPRETERS = new Set(["python", "python3", "node", "bun", "deno", "ruby", "perl", "bash", "sh", "zsh", "dash", "npx", "bunx", "eval", "xargs", "env", "sudo", "osascript", "php", "lua"]);

// ---- MCP / browser: match verbs on whole name tokens ("list_posts" ≠ "post") ----
const IRREVERSIBLE_VERBS = new Set(["send", "reply", "forward", "post", "publish", "delete", "trash", "remove", "pay", "purchase", "checkout", "transfer", "share", "submit", "invite", "cancel", "archive", "unsubscribe", "merge", "push", "comment", "destroy", "drop", "wipe", "revoke", "rsvp", "respond"]);

function nameTokens(name: string): string[] {
  return name
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

function isIrreversibleMcpName(leaf: string): boolean {
  const t = nameTokens(leaf);
  if (t.some((x) => IRREVERSIBLE_VERBS.has(x))) return true;
  const creates = t.includes("create") || t.includes("update") || t.includes("place") || t.includes("add");
  // creating events sends invites; rules/filters can auto-forward mail; orders cost money
  return creates && t.some((x) => ["event", "events", "rule", "filter", "order", "invitation", "forwarding"].includes(x));
}

const IRREVERSIBLE_CLICK = /(pay|buy|purchase|checkout|place order|submit|send|delete|remove|confirm|transfer|reply|post|publish|支付|付款|购买|下单|提交|发送|删除|确认|转账|回复|发布|发表)/i;
const BROWSER_ALWAYS_ASK = /^browser_(evaluate|handle_dialog|file_upload)$/;
// Reading and searching change nothing; never interrupt the owner for them.
const READ_ONLY_TOOLS = new Set(["Read", "Glob", "Grep", "LS", "NotebookRead", "WebSearch", "ToolSearch", "TodoWrite", "TaskOutput", "ListMcpResourcesTool", "ReadMcpResourceTool"]);

// Claude in Chrome (the owner's own browser): reading the page is harmless;
// running script or uploading files in a logged-in browser always asks.
const CHROME_READ_ONLY = /^mcp__claude-in-chrome__(read_page|get_page_text|find|tabs_context_mcp|read_console_messages|read_network_requests|list_connected_browsers|shortcuts_list)$/;
const CHROME_ALWAYS_ASK = /^mcp__claude-in-chrome__(javascript_tool|file_upload|upload_image)$/;

// Looking at the current page changes nothing.
const BROWSER_READ_ONLY = /^mcp__[^_]+(?:_[^_]+)*__browser_(snapshot|take_screenshot|console_messages|network_requests|wait_for)$/;
const BROWSER_INTERACT = /browser_(click|type|press_key|fill_form|select_option|file_upload|drag)/;

// isIrreversible: sending, paying, deleting and other outward actions are
// never auto-approved (PRD §6.5.4).
export function isIrreversible(tool: string, input: Record<string, unknown>): boolean {
  if (tool.startsWith(OWN_SERVER)) return false;
  if (tool === "Bash") {
    const cmd = String(input.command ?? "");
    return splitCommands(cmd).some(isIrreversibleCommand);
  }
  if (CHROME_ALWAYS_ASK.test(tool)) return true;
  if (tool.startsWith("mcp__")) {
    const leaf = tool.split("__").slice(2).join("__");
    if (BROWSER_ALWAYS_ASK.test(leaf)) return true;
    if (BROWSER_INTERACT.test(leaf)) {
      const text = `${input.element ?? ""} ${input.text ?? ""} ${input.key ?? ""}`;
      return (
        IRREVERSIBLE_CLICK.test(text) ||
        (leaf === "browser_press_key" && /enter/i.test(String(input.key))) ||
        (leaf === "browser_type" && input.submit === true)
      );
    }
    return isIrreversibleMcpName(leaf);
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
    // Interpreters run arbitrary code: "always allow python3 -c" would allow anything.
    if (INTERPRETERS.has(words[0]!.split("/").pop()!)) return null;
    return `cmd:${words.slice(0, 2).join(" ")}`;
  }
  if (tool === "WebFetch") {
    const d = domainOf(input.url);
    return d ? `domain:${d}` : null;
  }
  if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") {
    const raw = String(input.file_path ?? input.notebook_path ?? "");
    if (!raw.startsWith("/")) return null;
    const dir = dirname(resolve(raw)); // normalizes ../ so a rule can't be escaped
    return dir && dir !== "/" ? `path:${dir}` : null;
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
    case "path": {
      const c = resolve(cv);
      return c === rv || c.startsWith(rv + "/");
    }
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
    if (!/browser_navigate|browser_tabs|WebFetch|claude-in-chrome__(navigate|tabs_create)/.test(tool)) return false;
    const d = domainOf(input.url);
    if (!d) return false;
    return this.hooks.sensitiveDomains().some((s) => d === s || d.endsWith("." + s));
  }

  // preGate runs on every tool call before the harness decides.
  preGate(tool: string, input: Record<string, unknown>): { decision: "allow" | "deny" | "ask" | "pass"; reason?: string } {
    if (this.hooks.isKilled()) return { decision: "deny", reason: "主人按了「全部停下」，现在什么都不能做。" };
    // The shell's own tools (report_task, register_watch…) only touch PaloAlly state.
    if (tool.startsWith(OWN_SERVER)) return { decision: "allow" };
    if (this.isSensitiveNavigation(tool, input)) return { decision: "deny", reason: SENSITIVE_MSG };
    if (BROWSER_READ_ONLY.test(tool) || CHROME_READ_ONLY.test(tool) || READ_ONLY_TOOLS.has(tool)) return { decision: "allow" };
    if (isIrreversible(tool, input)) return { decision: "ask", reason: "这一步做了撤不回，要主人点头" };
    return { decision: "pass" };
  }

  // request is the harness' canUseTool: the harness wants to prompt.
  request(req: PermissionRequest): Promise<PermissionDecision> {
    if (this.hooks.isKilled()) return Promise.resolve({ behavior: "deny", message: "助理已被急停" });
    if (req.toolName.startsWith(OWN_SERVER)) return Promise.resolve({ behavior: "allow", updatedInput: req.input });
    if (this.isSensitiveNavigation(req.toolName, req.input)) {
      return Promise.resolve({ behavior: "deny", message: SENSITIVE_MSG });
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
      title: describeTool(req.toolName, req.input), // ours, in plain Chinese; the SDK's title is English
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
  if (tool === "Bash") return truncate(String(input.command ?? ""), 4000); // show what will actually run
  if (tool === "Write" || tool === "Edit") return String(input.file_path ?? "");
  if (input.url) return String(input.url);
  return truncate(JSON.stringify(input), 500);
}
