import type { ModelOption } from "./harness/types.ts";
import { t } from "./i18n/index.ts";

// The model and thinking depth an agent runs on: the one check the
// assistant's model.set and an agent's pals.setModel both go through.

/** The thinking depths Claude Code knows. */
export const EFFORTS = ["low", "medium", "high", "xhigh", "max"] as const;

/**
 * The option a model is: its own value, or the alias whose full id it is (an
 * alias's [1m] has to match too).
 */
export function optionFor(model: string | undefined, options: ModelOption[]): string | undefined {
  if (!model) return undefined;
  const norm = (s: string) => s.trim().toLowerCase();
  const m = norm(model);
  return (
    options.find((o) => norm(o.value) === m)?.value ??
    options.find((o) => o.resolved && norm(o.resolved) === m)?.value ??
    // a dated id ("claude-opus-5-5-20260101[1m]") against its undated one
    options.find((o) => o.resolved && norm(o.resolved).replace(/-\d{8}(?=\[|$)/, "") === m.replace(/-\d{8}(?=\[|$)/, ""))?.value
  );
}

/**
 * Refuses a choice that can't run: a depth that isn't one, or that the model
 * it will run on doesn't take; a model the harness doesn't offer (before it
 * has listed any: anything that doesn't look like a model id). `null` (back to
 * the default) is always fine. `current`: the model it runs on when the
 * choice names none (undefined: the harness' default, its first option).
 */
export function checkModelChoice(
  models: ModelOption[],
  choice: { model?: string | null; effort?: string | null },
  current: string | undefined,
): void {
  const { model, effort } = choice;
  if (effort != null && !(EFFORTS as readonly string[]).includes(effort)) throw new Error(t("pals.effortBad"));
  if (model != null) {
    const ok = models.length ? models.some((m) => m.value === model) : /^[\w.\-:[\]]{1,80}$/.test(model);
    if (!ok) throw new Error(t("pals.modelUnknown", { model }));
  }
  if (effort != null) {
    const on = model !== undefined ? model : current;
    const entry = on ? models.find((m) => m.value === optionFor(on, models)) : models[0];
    if (entry && !entry.efforts.includes(effort)) throw new Error(t("pals.effortUnsupported"));
  }
}
