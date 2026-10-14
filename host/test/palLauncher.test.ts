import { describe, expect, test } from "bun:test";
import { PalLauncher } from "../src/palLauncher.ts";

const base = { root: "/nowhere", find: () => "/x/PaloAllyHelper", env: async () => ({}) };

describe("which way a Pal starts", () => {
  test("auto: through the helper only once it has Full Disk Access; without it, directly", async () => {
    let fda = false;
    let checks = 0;
    const l = new PalLauncher({ ...base, fda: async () => (checks++, fda) });
    expect((await l.launch()).helper).toBeNull();
    expect(l.usesHelper).toBe(false);
    fda = true;
    expect((await l.launch()).helper).toBeNull(); // checked again only after a minute
    expect(checks).toBe(1);
    (l as any).access.at = 0;
    expect((await l.launch()).helper).toBe("/x/PaloAllyHelper");
    expect(l.usesHelper).toBe(true);
  });

  test("a probe that fails counts as no access; 'helper' and 'direct' are taken as set", async () => {
    const failing = new PalLauncher({ ...base, fda: async () => Promise.reject(new Error("held")) });
    expect((await failing.launch()).helper).toBeNull();
    const forced = new PalLauncher({ ...base, mode: () => "helper", fda: async () => false });
    expect((await forced.launch()).helper).toBe("/x/PaloAllyHelper");
    const direct = new PalLauncher({ ...base, mode: () => "direct", fda: async () => true });
    expect((await direct.launch()).helper).toBeNull();
  });
});
