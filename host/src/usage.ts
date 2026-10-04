import { readJson, writeJson, zonedParts } from "./util.ts";

export interface Usage {
  day: string;
  mainUsd: number;
  probeUsd: number;
}

// UsageLedger keeps today's spend (main conversation and probe) in the
// owner's time zone, resetting at local midnight.
export class UsageLedger {
  constructor(
    private path: string,
    private timezone: () => string,
  ) {}

  today(): Usage {
    const day = zonedParts(Date.now(), this.timezone()).dateKey;
    const u = readJson<Usage>(this.path, { day, mainUsd: 0, probeUsd: 0 });
    return u.day === day ? u : { day, mainUsd: 0, probeUsd: 0 };
  }

  add(field: "mainUsd" | "probeUsd", usd: number): void {
    if (!usd) return;
    const u = this.today();
    u[field] += usd;
    writeJson(this.path, u);
  }

  over(field: "mainUsd" | "probeUsd", capUsd: number): boolean {
    return capUsd > 0 && this.today()[field] >= capUsd;
  }
}
