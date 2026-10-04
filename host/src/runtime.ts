import { readJson, writeJson } from "./util.ts";

// RuntimeState is the small file that survives restarts: which harness session
// to resume, what it has cost so far, and when the host was last alive.
export interface Runtime {
  sessionId?: string;
  sessionCostUsd?: number; // running total the harness reports for this session
  lastHeartbeat?: number;
}

export class RuntimeState {
  readonly data: Runtime;

  constructor(private path: string) {
    this.data = readJson<Runtime>(path, {});
  }

  update(patch: Partial<Runtime>): void {
    Object.assign(this.data, patch);
    writeJson(this.path, this.data);
  }
}
