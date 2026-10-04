import type { Bus } from "./bus.ts";
import type { ModelOption, SlashCommandInfo } from "./harness/types.ts";
import { readJson, writeJson } from "./util.ts";

// HarnessInfo caches what the harness tells us about itself — its slash
// commands and selectable models — so clients can ask even while no CLI
// process is running. Lookups with an empty cache start one and wait.
export class HarnessInfo {
  private terminalCommands = new Set(["doctor", "color", "focus", "reload-plugins", "exit", "quit", "statusline", "terminal-setup", "vim", "ide"]);
  private commandWaiters: (() => void)[] = [];
  private modelWaiters: (() => void)[] = [];

  constructor(
    private stateDir: string,
    private bus: Bus,
    private startHarness: () => void, // ensure a CLI process exists
    private settle: () => void, // after a lookup: let an otherwise idle process close
  ) {}

  private get commandsPath() {
    return `${this.stateDir}/commands.json`;
  }

  private get modelsPath() {
    return `${this.stateDir}/models.json`;
  }

  // ---- slash commands (a hidden entry: no hints in the UI) ----

  setTerminalCommands(names: string[]): void {
    this.terminalCommands = new Set(names);
  }

  saveCommands(cmds: SlashCommandInfo[]): void {
    writeJson(this.commandsPath, cmds);
    this.bus.emit("commands.updated", { commands: this.commandList() });
    for (const w of this.commandWaiters.splice(0)) w();
  }

  // commandList merges the harness' commands with PaloAlly's own (which win on
  // a name clash) and drops the ones that only make sense in a terminal.
  commandList(): SlashCommandInfo[] {
    const own: SlashCommandInfo[] = [
      { name: "stop", description: "停下手上的事" },
      { name: "status", description: "看看我在忙什么" },
    ];
    const ownNames = new Set(own.map((c) => c.name));
    const harness = readJson<SlashCommandInfo[]>(this.commandsPath, []).filter(
      (c) => !ownNames.has(c.name) && !this.terminalCommands.has(c.name) && c.name !== "help" && !c.name.startsWith("_"),
    );
    return [...own, ...harness.sort((a, b) => a.name.localeCompare(b.name))];
  }

  async loadCommands(timeoutMs = 8000): Promise<SlashCommandInfo[]> {
    if (readJson<SlashCommandInfo[]>(this.commandsPath, []).length === 0) await this.waitFor(this.commandWaiters, timeoutMs);
    return this.commandList();
  }

  // ---- models ----

  saveModels(models: ModelOption[]): void {
    writeJson(this.modelsPath, models);
    for (const w of this.modelWaiters.splice(0)) w();
  }

  models(): ModelOption[] {
    return readJson<ModelOption[]>(this.modelsPath, []);
  }

  async loadModels(timeoutMs = 8000): Promise<ModelOption[]> {
    if (this.models().length === 0) await this.waitFor(this.modelWaiters, timeoutMs);
    return this.models();
  }

  private async waitFor(waiters: (() => void)[], timeoutMs: number): Promise<void> {
    const ready = new Promise<void>((r) => waiters.push(r));
    this.startHarness();
    await Promise.race([ready, new Promise((r) => setTimeout(r, timeoutMs))]);
    this.settle();
  }
}
