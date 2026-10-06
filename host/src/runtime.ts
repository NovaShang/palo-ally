import { readJson, writeJson } from "./util.ts";

// RuntimeState is the small file that survives restarts: which harness session
// to resume, what it has cost so far, and when the host was last alive.
export interface Runtime {
  sessionId?: string;
  sessionCostUsd?: number; // running total the harness reports for this session
  lastHeartbeat?: number;
  briefCreated?: boolean; // the default 晨报 goal was set up once (deleting it keeps it gone)
  contextTokens?: number; // the main session's context size after its last turn
  lastTurnAt?: number; // when the main session last finished a turn
  lastCompactAt?: number;
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
