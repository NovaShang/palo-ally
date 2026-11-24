import type { HarnessEvent, LoginAccount, PlanLimit, PlanReport } from "../types.ts";

// Claude Code's /usage data and account, as the host takes them. The SDK's
// method is experimental: fields may be missing, null or gone, so everything
// is read as untrusted. Percentages and reset times only: the money in it
// isn't taken.

const HOUR = 3600_000;
const WINDOW: Record<string, number> = { session: 5 * HOUR, weekly: 7 * 24 * HOUR };

const str = (v: unknown): string | undefined => (typeof v === "string" && v.trim() ? v.trim() : undefined);

/** accountInfo(), as the owner's app shows it. */
export function loginAccount(raw: unknown): LoginAccount | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const a = raw as Record<string, unknown>;
  const provider = str(a.apiProvider);
  const keySource = str(a.apiKeySource);
  const plan = str(a.subscriptionType)?.toLowerCase().replace(/^claude\s+/, "");
  const out: LoginAccount = {
    ...(str(a.email) ? { email: str(a.email) } : {}),
    ...(str(a.organization) ? { organization: str(a.organization) } : {}),
    ...(plan ? { plan } : {}),
    ...(provider && provider !== "firstParty" ? { provider } : {}),
    ...(keySource && keySource !== "none" && keySource !== "oauth" ? { apiKeySource: keySource } : {}),
  };
  return Object.keys(out).length ? out : undefined;
}

function limit(kind: string, group: string, used: unknown, resets: unknown, scope?: string): PlanLimit | null {
  if (typeof used !== "number" || !Number.isFinite(used)) return null;
  const at = typeof resets === "string" ? Date.parse(resets) : NaN;
  return {
    kind,
    group,
    used: Math.max(0, Math.min(100, Math.round(used))),
    ...(Number.isFinite(at) ? { resetsAt: at } : {}),
    ...(WINDOW[group] ? { windowMs: WINDOW[group] } : {}),
    ...(scope ? { scope } : {}),
  };
}

// The server's own rows, in its order, when the answer has them (the SDK's
// type for this method doesn't list them); else the windows it does type.
function limits(r: any): PlanLimit[] {
  const rows = (Array.isArray(r.limits) ? r.limits : []).map((x: any) =>
    x && typeof x === "object" ? limit(str(x.kind) ?? "", str(x.group) ?? "", x.percent, x.resets_at, str(x.scope?.model?.display_name) ?? str(x.scope?.surface?.display_name)) : null,
  );
  const named = rows.filter((x: PlanLimit | null): x is PlanLimit => !!x && !!x.kind);
  if (named.length) return named;
  const scoped = (Array.isArray(r.model_scoped) ? r.model_scoped : []).map((x: any) => limit("weekly_scoped", "weekly", x?.utilization, x?.resets_at, str(x?.display_name)));
  const typed = [
    limit("session", "session", r.five_hour?.utilization, r.five_hour?.resets_at),
    limit("weekly_all", "weekly", r.seven_day?.utilization, r.seven_day?.resets_at),
    ...(scoped.length
      ? scoped
      : [
          limit("weekly_scoped", "weekly", r.seven_day_opus?.utilization, r.seven_day_opus?.resets_at, "Opus"),
          limit("weekly_scoped", "weekly", r.seven_day_sonnet?.utilization, r.seven_day_sonnet?.resets_at, "Sonnet"),
        ]),
  ];
  return typed.filter((x): x is PlanLimit => !!x);
}

/** The usage method's answer (`raw`) with the account it's for. */
export function planReport(raw: unknown, account?: LoginAccount): PlanReport {
  const base = { limits: [], ...(account ? { account } : {}) };
  if (!raw || typeof raw !== "object") return { plan: "unreadable", ...base };
  const u = raw as any;
  const plan = str(u.subscription_type)?.toLowerCase();
  const acc: LoginAccount | undefined = plan && !account?.plan ? { ...account, plan } : account;
  const withAcc = { limits: [], ...(acc ? { account: acc } : {}) };
  if (u.rate_limits_available === false) {
    // A subscription whose login may not see its limits (no profile scope), or a login that has none.
    const hidden = !!acc?.plan && !acc.provider && !acc.apiKeySource;
    return { plan: hidden ? "hidden" : "none", ...withAcc };
  }
  // It applies, but the numbers didn't come this time.
  if (!u.rate_limits || typeof u.rate_limits !== "object") return { plan: "unreadable", ...withAcc };
  const extra = u.rate_limits.extra_usage?.is_enabled;
  return { plan: "limits", ...withAcc, limits: limits(u.rate_limits), ...(typeof extra === "boolean" ? { extraUsage: extra } : {}) };
}

// What a turn's rate_limit_event calls the limits, as the plan's rows have them.
const EVENT_LIMITS: Record<string, { kind: string; scope?: string }> = {
  five_hour: { kind: "session" },
  seven_day: { kind: "weekly_all" },
  seven_day_opus: { kind: "weekly_scoped", scope: "Opus" },
  seven_day_sonnet: { kind: "weekly_scoped", scope: "Sonnet" },
  seven_day_overage_included: { kind: "weekly_scoped" },
};

/** rate_limit_event: blocked when the request was refused (past the limit on extra usage, it isn't). */
export function limitEvent(raw: unknown): HarnessEvent | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as any;
  const type = str(r.rateLimitType);
  if (typeof r.status !== "string") return null;
  const at = typeof r.resetsAt === "number" && r.resetsAt > 0 ? r.resetsAt : undefined;
  return {
    type: "limit",
    blocked: r.status === "rejected" && r.isUsingOverage !== true && r.overageInUse !== true,
    ...(type ? (EVENT_LIMITS[type] ?? { kind: type }) : {}),
    ...(at ? { resetsAt: at < 1e12 ? at * 1000 : at } : {}),
  };
}

/** Asks a running process: its account and, when it has the (experimental) method, its limits; never `behaviors`, which scan a week of transcripts. */
export async function askPlan(q: { accountInfo(): Promise<unknown> }): Promise<PlanReport> {
  const account = loginAccount(await q.accountInfo().catch(() => undefined));
  const ask = (q as unknown as Record<string, unknown>).usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET;
  if (typeof ask !== "function") return { plan: "unsupported", limits: [], ...(account ? { account } : {}) };
  let raw: unknown = null;
  try {
    raw = await ask.call(q, { skipBehaviors: true });
  } catch {
    // (its words may name the account)
  }
  return planReport(raw, account);
}
