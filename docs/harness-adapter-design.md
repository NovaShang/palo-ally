# Batch 7 design: the harness adapter and one AgentSession

Status: design only, 2026-11-22. Nothing here is implemented. Written against branch r1 (the base of batches 2 to 5); where batches 2 to 5 change the picture it says so (marked **B2**, **B3**, **B4**, **B5**).

Goal (plan, 新加第 7 批): `conversation.ts` and `palSession.ts` become one `AgentSession` whose differences are flags; everything Claude Code specific moves behind one `Harness` interface under `host/src/harness/claude/`; the app reads a capability descriptor instead of hard-coded Claude lists. No second adapter is written. The assistant keeps its own `chat.jsonl` history.

Ordering assumption: batch 7 starts after batches 2 to 5 are merged. Batch 2 deletes most of what would otherwise have to be moved (the external-session history mapper, `CCMessage`, most of `handoffs.ts`), so moving after it is cheaper and safer.

---

## 1. conversation.ts vs palSession.ts

### 1.1 Responsibility by responsibility

| # | Responsibility | Assistant (`Conversation`, 939 lines) | Agent (`PalSession`, 1445 lines) | Same? | Flag in AgentSession |
|---|---|---|---|---|---|
| 1 | Where its record lives | `runtime.json` (`sessionId`, `rewind`, `contextTokens`, `sessionCostUsd`, `contextWindow`, `lastCompactAt`); model/effort/mode in `config.json` | `PalRecord` in `pals.json` (session, model, effort, appliedEffort, mode, costs, context, pastTasks, rewind, sleep state) | differs in storage only | `store: SessionStore` (two implementations: `RuntimeRecord`, `PalRecordStore`); same field names |
| 2 | Start the process | `ensureSession()`: synchronous `driver.startMain`, sends immediately (the SDK queues input until ready), no ready wait, no holders check, direct spawn, `cwd = ~/.paloally/home` | `start()`/`doStart()`: async, holders check (never two writers), kills its own orphan, title read back, launch through PaloAlly Helper or direct, `ready()` with timeout, one helper-failure retry | differs | `startMode: "lazy-sync" \| "awaited"`, `exclusive: boolean` (holders check + step aside), `launcher: "direct" \| "helper"` |
| 3 | Tools it gets | Full PaloAlly MCP server (`paloallyMcpServer`: watches, allies, pals, pairing, delivery, pending), `toolGate` (ally gate), shared Chrome, disallows Cron/ScheduleWakeup | `palo_send` + delivery tools, pre-allowed; Claude's own SendUserFile off | differs | `toolset: "assistant" \| "agent"` (the host builds a neutral `ToolSpec[]`; the adapter wraps it) |
| 4 | System prompt | `behaviorPrompt(home)` + timezone | `PAL_PROMPT(paloName)` | differs in text only | `appendPrompt: () => string` dependency |
| 5 | Owner input | `sendOwner(text, origin, wechat, images, uuid)`: goes in at once, even mid-turn; quote block and `[来自微信]` prefix built by `hub.ownerBody`; slash commands verbatim | `send(text, {from, peer, attachments})`: ordered `sendChain`, wakes it first; images as blocks, files copied to `.paloally/inbox`; `peerWrap` for pal_send; **no quotes, no WeChat** | mostly same; agent lacks quotes (audit row 6) | none: one `send(UserInput)` with `quote`, `images`, `files`, `peer`, `channel`; quotes become available to agents for free |
| 6 | Host-initiated turns | `enqueue(Turn)`: queue that waits for idle and for owner messages; proactive vs owner; `[skip]`; daily budget; `maintenance` turns (unseen); schedule/goal runs; Pal replies | none (only `tell()` from the host, sent as words) | assistant only | `proactiveTurns: boolean` (enables the `TurnQueue` policy: queue, budget, `[skip]`, router push, goal results) |
| 7 | Which owner messages a turn answers | `pending` map by uuid, `answering` event, `consume(consumedUuids)`, implicit turns (harness-started) closed after 90 s quiet | `pendingUuids` + `pendingText`, `consumedUuids` on result, `init` opens a turn | same idea, two codes | none: one `TurnLedger` |
| 8 | Streaming out | `chat.delta` / `chat.add` into `ChatLog` (seq numbers, `chat.jsonl`); delta ids minted by the host | `bus.emit("chat.delta"/"chat.message", {pal})`; ids are the API message ids (same as the transcript) | differs in sink and id source | `history: "chatLog" \| "transcript"` (selects the `OutputSink`: `ChatLogSink` or `TranscriptSink`) |
| 9 | Reading history | `chat.history` from `chat.jsonl` (hub/rpc) | `pals.history` from the transcript tail (`transcriptTail.ts` + `palHistory.ts`); `TranscriptFollower` shows peer messages that bypass the SDK stream | differs (kept on purpose) | same `history` flag; `followTranscript: boolean` (true for agents) |
| 10 | WeChat | turn from WeChat: typing indicator, paragraph-by-paragraph replies, questions as numbered text | none | assistant only | `wechat: boolean` |
| 11 | Ally turns (只说话不动手) | `allyGate` + `held` owner words + `gateTool` (PreToolUse hook and canUseTool) + `watchGate` | none | assistant only | `allyGate: boolean` |
| 12 | Questions (AskUserQuestion) | `deferQuestion` → items on 等你的事, tool denied at once with "deferred" words; a WeChat turn asks blocking | blocking card with `source`, "X 在等你" push (`onWaiting`) | differs | `questions: "defer" \| "block"` (**B4** makes both PendingItem-driven cards; the flag then only decides whether the harness call returns at once) |
| 13 | Permission prompts | `approvals.request(req)` (no source; push via proactive) | `approvals.ask(req, {source, title, detail})` with `sessionPermission` words + waiting push; own tools pre-allowed | same manager, two call shapes | none: one `permissions.ask(req, source)`; **B4** unifies the card text |
| 14 | Subagents / background tasks | shared `TaskTracker` (`tasks.json`, activity files, `report_task`, transitions → proactive notices, `task.get`) | its own `tasks` map + `pastTasks` (30) in the record | differs | `tasks: "tracker" \| "record"` (both implement one `TaskProjection` interface fed by the same events) |
| 15 | Model / effort / mode | `applyModel`/`applyEffort` live; config holds them; `checkMode` logs a downgrade once | `setModel({model, effort})`, `setMode` live or record-only when asleep; `settingsEffort` default; effort and mode from Stop hook; leaves plan mode | same SDK calls | none: one `setModel/setEffort/setMode` (**B3** already unifies the RPC side and adds validation) |
| 16 | Compaction | Claude Code native at `compactWindowTokens`; host idle trigger (`maybeIdleCompact`: clean break, quiet 5 min, min tokens) as a maintenance `/compact` turn | on demand only (`pals.compact`, a silent `/compact` turn) | differs | `autoCompact: { windowTokens, idleMinutes, minTokens } \| null` |
| 17 | Sleep | never: always up (other sessions find it by name); `onIdle()` kept only for tests | `sleep()`/wake, max awake, idle 20 min | agent only | `canSleep: boolean` |
| 18 | Process died | next send restarts it (`ensureSession`); an `error` event ends the turn | auto restart with backoff, give up after 5 in 10 min (`stoppedFor: failed`); `stoppedFor: elsewhere` when opened in a terminal | differs | `restart: "on-demand" \| "backoff"` |
| 19 | Stall watchdog | `stallTarget(hooks)`: pid from registry, transcript path from hub; recovery re-queues the turn as the same kind (proactive / owner / goal), resends untaken words, drops an ally turn | `stallTarget()`; recovery = shutdown, resend untaken, "continue" | same shape, two codes | none: one `stallTarget()`; the turn-kind part is in `TurnQueue` (flag 6) |
| 20 | Stop | `stopAll`: clear queue, deny all un-sourced approvals/questions, stop SDK tasks, interrupt, end turn now, close process | `interrupt`: drop its cards, interrupt, end after 250 ms settle, `windingDown` | same intent | none: one `stop(by)`; the queue clear is `TurnQueue`'s |
| 21 | Rewind (回到这里重来) | `hub.rewindChat`: chat.jsonl message → transcript entry by uuid or by words+time (`matchOwnerEntry`, `backfillOwnerUuids`), fork or copy past compaction, `chat.rewind` marks messages | `PalSession.rewind`: transcript chain, owner-words check, optional file restore through a throwaway process, fork or copy | same core, two codes (audit row 7) | none for the core (`Rewinder`); `history` flag decides how dropped messages are marked |
| 22 | Cost | `usage.add("mainUsd")` per turn; daily budget for proactive turns | `noteCost`: running totals, wake cost, `SpendMeter` reads transcripts per day | differs | `budget: "mainDaily" \| null`; cost accounting itself is shared |
| 23 | Login failure | `onAuth({text, watchId})` with what to resume | `onAuth(pal, ok)` | same | none: `auth` event with the turn's description |
| 24 | Name for SendMessage | `peerName = "Palo"` | `spawnedAs = rec.name`, `renameLive`, title read back (§13) | same intent | none: `name` + optional `followTitle: boolean` |
| 25 | File checkpointing | off | on (rewind can restore files) | agent only | `fileCheckpoints: boolean` |
| 26 | Reconnect mid-reply | `streamingReply()` | `streaming()` | same | none |
| 27 | Status shown | `Hub.status()` (`Status`) | `toWire()` (`Pal`) + `detailInfo()` | differs in wire shape | wire shapes stay (old apps); both built from one `AgentState` |

### 1.2 The flags

```ts
/** What makes the assistant the assistant. An agent is AgentSession with AGENT_FLAGS. */
export interface AgentFlags {
  history: "chatLog" | "transcript";      // where its conversation is kept and read (assistant: chat.jsonl, kept as is)
  followTranscript: boolean;               // show transcript lines that bypass the SDK stream (peer SendMessage)
  proactiveTurns: boolean;                 // TurnQueue: host-initiated turns, [skip], push, budget, goal results
  wechat: boolean;                         // WeChat turns: typing, paragraph streaming, text questions
  allyGate: boolean;                       // 只说话不动手 during an Ally's turn
  questions: "defer" | "block";            // AskUserQuestion: to 等你 at once, or a blocking card
  autoCompact: { windowTokens: number; idleMinutes: number; minTokens: number } | null;
  canSleep: boolean;
  restart: "on-demand" | "backoff";
  startMode: "lazy-sync" | "awaited";      // assistant sends before ready; agent waits for ready()
  exclusive: boolean;                      // holders check; step aside when another process opens the session
  launcher: "direct" | "helper";
  fileCheckpoints: boolean;
  tasks: "tracker" | "record";
  budget: "mainDaily" | null;
  toolset: "assistant" | "agent";
  followTitle: boolean;                    // name follows the harness' session title
}

export const ASSISTANT_FLAGS: AgentFlags = {
  history: "chatLog", followTranscript: false, proactiveTurns: true, wechat: true, allyGate: true,
  questions: "defer", autoCompact: { windowTokens: cfg, idleMinutes: cfg, minTokens: cfg },
  canSleep: false, restart: "on-demand", startMode: "lazy-sync", exclusive: false, launcher: "direct",
  fileCheckpoints: false, tasks: "tracker", budget: "mainDaily", toolset: "assistant", followTitle: false,
};
export const AGENT_FLAGS: AgentFlags = {
  history: "transcript", followTranscript: true, proactiveTurns: false, wechat: false, allyGate: false,
  questions: "block", autoCompact: null, canSleep: true, restart: "backoff", startMode: "awaited",
  exclusive: true, launcher: "helper", fileCheckpoints: true, tasks: "record", budget: null,
  toolset: "agent", followTitle: true,
};
```

Flags that are only "assistant has it" today (proactive turns, WeChat, ally gate) are written as pluggable policies, not `if (flags.x)` sprinkled through the class: `TurnQueue`, `WechatRelay`, `AllyGate` attach to the session's hooks (`beforeSend`, `onToolGate`, `onTurnEnd`, `onStop`). That keeps AgentSession near the size of PalSession today, not the sum of both.

Open choices worth the owner's note (not blocking): an agent could get `autoCompact` (idle compaction before the prompt cache dies saves money on long-lived agents) and the assistant could get `fileCheckpoints`. Both become one-line flag changes; neither is part of this batch.

### 1.3 AgentSession

```ts
export class AgentSession {
  readonly id: string;                     // "palo" for the assistant, the Pal id for an agent
  readonly flags: AgentFlags;
  readonly harness: Harness;               // which adapter runs it (always Claude Code now)
  readonly rec: SessionStore;              // RuntimeRecord | PalRecordStore (same fields)

  // live state (one AgentState, read by toStatus() / toWire() / detail())
  private proc: HarnessProcess | null;
  private phase: "asleep" | "starting" | "up" | "stopping" | "stopped";
  private stopReason?: "failed" | "elsewhere";
  private ledger: TurnLedger;              // owner messages in flight by uuid, answering/consumed, implicit turns
  private stream: StreamAssembler;         // deltas → texts by message id, cut-off streams closed
  private tasks: TaskProjection;           // TaskTracker or RecordTasks
  private sink: OutputSink;                // ChatLogSink (assistant) | TranscriptSink (agent)
  private policies: SessionPolicy[];       // TurnQueue, WechatRelay, AllyGate (assistant only)
  model?: string; effort?: string; mode?: string; contextTokens?: number; contextWindow?: number;

  // lifecycle
  start(): Promise<void>;                  // awaited, or no-op + lazy for startMode "lazy-sync"
  sleep(): Promise<void>;                  // throws unless flags.canSleep
  shutdown(): Promise<void>;               // process gone, nothing writes the transcript after this
  stopFor(reason, note): void; clearStop(): void;

  // input
  send(input: UserInput): Promise<ChatMessage>;      // owner, the assistant (peer) or the host (from)
  enqueue(turn: Turn): void;                         // TurnQueue only (flags.proactiveTurns)
  stop(by: string): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  compact(): Promise<void>;

  // settings (live when up, record-only when asleep)
  setModel(model?: string): Promise<void>; setEffort(effort?: string): Promise<void>; setMode(mode: string): Promise<void>;
  rename(title: string): Promise<boolean>;

  // rewind
  rewind(target: { messageId?: string; uuid?: string }, o: { restoreFiles: boolean }): Promise<RewindResult>;
  canRestoreFiles(uuid: string): boolean;

  // reads
  get busy(): boolean; get quiet(): boolean; idleSince(): number | null;
  streaming(): { id: string; text: string } | null;
  stallTarget(): StallTarget;
  state(): AgentState;                     // → Hub.status() for the assistant, Pal + PalDetail for an agent
}
```

**Lifecycle.**

```
            send / wake / host start
  asleep ───────────────────────────► starting ──ready()──► up (idle ⇄ busy ⇄ waiting)
    ▲  ▲                                 │  │                  │   │
    │  └──────── sleep() (canSleep) ─────┼──┼──────────────────┘   │ process exits by itself
    │                                    │  └─ held elsewhere ──► stopped(elsewhere) ── freed ──► starting
    │                                    └─ fails ×5/10 min ───► stopped(failed) ── owner's words ──► starting
    └──────────── shutdown() ◄──────────── backoff restart (restart: "backoff") / next send (restart: "on-demand")
```

The assistant never enters `asleep` (`canSleep: false`) and with `restart: "on-demand"` a dead process just means `phase = asleep-like idle` until the next `send` or `enqueue`. `startMode: "lazy-sync"` keeps today's behavior: `send` pushes into the SDK queue right after `harness.start()`, without awaiting `ready()` (the SDK buffers). This is the most delicate part of the merge (see 4.3).

**Events** (one emitter; Hub and Pals subscribe; replaces the dozen `deps` callbacks of both classes):

| Event | Payload | Who listens |
|---|---|---|
| `changed` | `AgentState` | Pals (`pals.updated`), Hub (`status`) |
| `message` / `delta` | `ChatMessage` / `{id, text}` | the sink (ChatLog, or bus with `pal`) |
| `turnStart` | `{ uuids, origin }` | Hub (activity), donePush |
| `turnEnd` | `{ finished, error?, errorCategory?, costUsd, answered[] }` | Pals (done push, spend), Proactive, **B5** 下一件 |
| `waiting` | `{ approvalId? , questionId?, body }` | waitingPush |
| `auth` | `{ ok: boolean, what?: {text, watchId?} }` | AuthWatch |
| `woke` / `stopped` | `{}` / `{ reason, note }` | Pals |
| `compacted` | `{ trigger, reason, preTokens, postTokens? }` | metrics, audit |
| `models` / `commands` | `ModelOption[]` / `SlashCommandInfo[]` | HarnessInfo cache → capability descriptor |

---

## 2. The Harness interface

One interface in `host/src/harness/types.ts`; one implementation in `host/src/harness/claude/`; a fake in `host/test/fakeHarness.ts` (today's `fakeDriver.ts` + `fakeClaude.ts`, combined). Nothing above `harness/` imports `@anthropic-ai/claude-agent-sdk` or knows a transcript path.

```ts
export interface Harness {
  readonly id: string;                                 // "claude-code"
  capabilities(): HarnessCapabilities;                 // §3; models/commands filled from the cache

  // ---- processes ----
  start(o: StartOptions): HarnessProcess;              // spawn, resume or fork
  probe(req: ProbeRequest): Promise<ProbeResult>;      // one-shot structured run (watches, setup check)

  // ---- conversations on disk ----
  history: HistoryStore;
  rewind: Rewinder;
  sessions: SessionDirectory;

  // ---- the harness' own config ----
  memory: MemoryLocator;
  auth: HarnessAuth;
  settings: HarnessSettings;
  hooks: HookInstaller | null;                         // global hooks for sessions the host doesn't run
  tools: ToolVocabulary;                               // what its tool names mean
}

export type SessionRef = { sessionId: string; cwd: string };

export interface StartOptions {
  cwd: string;
  session: { kind: "new"; id?: string } | { kind: "resume"; id: string } | { kind: "fork"; from: string; at: string; id: string };
  model?: string; effort?: string; permissionMode: string;
  appendSystemPrompt?: string;
  tools: ToolSpec[];                                   // harness-neutral: name, description, zod schema, handler
  preApproved: string[];                               // ToolSpec names that never ask
  disallowBuiltIn: ("schedule" | "sendUserFile")[];    // capability words, mapped to Cron*/SendUserFile by the adapter
  extraMcpServers?: Record<string, unknown>;
  canUseTool(req: PermissionRequest): Promise<PermissionDecision>;
  toolGate?: ToolGate;
  name?: string;                                       // what other sessions message it by
  ownerOrigin?: boolean;
  fileCheckpoints?: boolean;
  autoCompactWindowTokens?: number;
  sharedBrowser?: boolean;
  priorCostUsd?: number;
  env?: Record<string, string>; baseEnv?: Record<string, string>;
  spawn?: Spawner;                                     // neutral: (cmd, args, cwd, env, signal) → ChildLike
  onEvent(e: HarnessEvent): void; onExit?(error?: string): void; stderr?(s: string): void;
}

export interface UserInput {
  uuid: string;
  text: string;                                        // the owner's words, without any wrapping
  images?: ImageInput[];
  files?: string[];                                    // absolute paths already put where it can read them
  quote?: string;                                      // a quoted excerpt (rendered by the adapter; Claude: "> " lines)
  peer?: { from: string };                             // another session's words (Claude: <cross-session-message>)
  channelTag?: string;                                 // e.g. "来自微信"
}

export interface HarnessProcess {
  send(input: UserInput): void;
  interrupt(): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  setModel(model?: string): Promise<void>;
  setEffort(effort?: string): Promise<void>;
  setPermissionMode(mode: string): Promise<void>;
  compact(uuid: string): void;                         // Claude: send "/compact" as a turn
  rename?(title: string): Promise<void>;
  rewindFiles?(uuid: string, dryRun?: boolean): Promise<FilesRewound>;
  ready(): Promise<void>;
  close(): void;
  readonly closed: boolean;
  readonly lastActivity: number;
  readonly pid?: number;
}

// HarnessEvent: unchanged from today's harness/types.ts (it is already neutral). Added:
//   { type: "process"; pid: number }  (replaces reading the pid back from ~/.claude/sessions for the assistant)

export interface HistoryStore {
  page(ref: SessionRef, o: { before?: string | number; limit: number; map: HistoryMapOptions }): Promise<ChatMessage[]>; // tail-read, paged
  follow(ref: SessionRef, onEntry: (m: ChatMessage) => void, o: { skip?: Set<string>; map: HistoryMapOptions }): { poke(): void; stop(): void };
  exists(ref: SessionRef): boolean;
  took(ref: SessionRef, uuid: string): boolean;        // stall: did the session take this message (transcriptHas)
  growth(ref: SessionRef): string;                     // stall: transcript + subagents' size signature
  summary(ref: SessionRef): { lastLine?: string; model?: string; contextTokens?: number };
  spentOn(ref: SessionRef, day: string, tz: string): number; // SpendMeter
  locate(ref: SessionRef): string | undefined;         // a path for diagnostics and logs only, never parsed above harness/
}

export interface Rewinder {
  /** The conversation as it stands, as rewind targets (owner messages, oldest first). pending: a fork not yet written. */
  chain(ref: SessionRef, pending?: PendingRewind): RewindChain;
  find(chain: RewindChain, by: { uuid?: string; words?: string; ts?: number; used?: Set<string> }): RewindPoint | null;
  /** Fork on next start, or copy now when the point is before the last compaction. */
  prepare(ref: SessionRef, point: RewindPoint, title: string): Promise<{ next: StartOptions["session"]; pending?: PendingRewind; renamed?: Map<string, string> }>;
  dropped(chain: RewindChain, point: RewindPoint, map: HistoryMapOptions): string[]; // message ids that leave
  canRestoreFiles(ref: SessionRef, uuid: string): boolean;
  /** For hand-back to a terminal: a session id that resumes to exactly this conversation (copied if pending). */
  materialize(ref: SessionRef, pending: PendingRewind | undefined, title: string): Promise<string | null>;
}

export interface SessionDirectory {
  live(): LiveSession[];                               // ~/.claude/sessions/<pid>.json
  holders(sessionId: string, own?: number): Promise<Holder[]>; // registry + `claude agents`
  recent(o: { days: number; limit: number; folder?: string }): Promise<RecentSession[]>; // listSessions
  info(sessionId: string, cwd?: string): Promise<{ title?: string; cwd?: string } | undefined>;
  rename(sessionId: string, title: string, cwd: string): Promise<void>;
  stopBackground(sessionId: string): Promise<void>;
  resumeCommand(ref: SessionRef | { cwd: string }): string; // "cd … && claude --resume …"
  watch(onChange: () => void): () => void;             // registry changes (fs.watch + poll)
}

export interface MemoryLocator {
  autoMemoryDir(cwd: string): string;                  // <config>/projects/<cwd-slug>/memory
  projectInstructions(cwd: string): string;            // <cwd>/CLAUDE.md
  coreInjection(home: string): string;                 // where the assistant's core files are injected (CLAUDE.md)
}

export interface HarnessAuth {
  loggedIn(): Promise<boolean>;
  stamp(): Promise<string | null>;                     // when the stored login last changed (no secret)
  spawnLogin(): LoginProcess;                          // `claude auth login` under expect
  isAuthFailure(text?: string, category?: string): boolean;
}

export interface HarnessSettings {
  defaultEffort(model: string | undefined, cwd: string): string | undefined; // ccEffort.settingsEffort
  defaultPermissionMode(): string;                     // pals.ownerMode (settings.json)
  contextWindow(model: string | undefined, tokens?: number, reported?: number): number;
  canonicalModel(model: string): string;
  modelOption(model: string | undefined, options: ModelOption[]): string | undefined; // pals.optionFor
  loginEnv(): Promise<Record<string, string>>; cleanEnv(env: Record<string, string | undefined>): Record<string, string>;
  ownSessionEnv: Record<string, string>;               // PALOALLY_SESSION=1
}

export interface ToolVocabulary {
  ask: string;                                         // "AskUserQuestion"
  subagent: ReadonlySet<string>;                       // Agent, Task
  handback: string;                                    // SubagentHandback
  selfReporting: ReadonlySet<string>;                  // stall: tools that write their own transcript
  peerSend: string;                                    // SendMessage
  qualified(server: string, tool: string): string;     // "mcp__paloally__palo_send"
  classify(tool: string, input: Record<string, unknown>): ToolClass; // read | write | run | web | agent | message | plumbing | other, + paths/command
  parseQuestion(input: Record<string, unknown>): QuestionItem[]; // questions.parseItems
  answerQuestion(input: Record<string, unknown>, answers: Record<string, string>): Record<string, unknown>;
}
```

`ToolClass` is what `copy.ts` (activity words, permission card words), `allyGate.ts` (read-only paths check), `approvals.ts` (always-allow keys), `tasks.ts` and `stallWatch.ts` use instead of comparing tool names. `allyGate.ts` stays host-side (it is a policy), but reads `classify()`; its tests (`allyGate.test.ts`, `allyGate.live.test.ts`) are the guard.

### 2.1 Where each current module goes

| Current module / function | Moves to | Note |
|---|---|---|
| `harness/claude.ts` (driver, `mapMessage`, `sessionOptions`, `probeOptions`, MCP server builders) | `harness/claude/process.ts`, `harness/claude/events.ts`, `harness/claude/mcp.ts` | MCP builders take `ToolSpec[]` instead of `ToolHandlers`; tool texts move to `host/src/tools/` (host-owned, harness-neutral) |
| `harness/types.ts` | stays; gains `Harness`, `StartOptions`, `UserInput`, sub-interfaces | `MainSession` renamed `HarnessProcess` (alias kept one release) |
| `handoffs.ts`: `claudeConfigDir`, `transcriptPath`, `readTail`, `readHead`, `SessionRegistry` | `harness/claude/paths.ts`, `harness/claude/transcript.ts` | done 2026-11-23: `SessionRegistry` and `summarizeTail` are gone; handoffs.ts follows agents by their own events |
| `ccSessions.ts`: `readRegistry`, `RegistryEntry`, `summarizeTranscript`, `peerBody`, `userText`, `isCompactSummaryText` | `harness/claude/registry.ts`, `harness/claude/transcript.ts` | **B2** deletes `toCCMessages`, `CCMessage`, `pageMessages`; the `SessionWatch` list logic stays host-side over `sessions.live()` |
| `palHistory.ts` (`toPalMessages`, `userEntryMessage`, `TranscriptFollower`, `transcriptModel`, `transcriptLastLine`) | `harness/claude/history.ts` | `pagePalMessages` and `CARD_TOOLS`/`cardKey` stay host-side (`chatPage.ts`) |
| `transcriptTail.ts` (tail window over `getSessionMessages`) | `harness/claude/history.ts` | |
| `rewind.ts` (`readTranscript`, `chainTo`, `leafOf`, `findEntry`, `matchOwnerEntry`, `beforeCompaction`, `hasFileCheckpoint`, `forkedUuids`, `ForkSession`) | `harness/claude/rewind.ts` | `PendingRewind` type and the i18n strings stay host-side |
| SDK `forkSession` in `hub.ts`, `pals.ts`, `palSession.ts` | `harness/claude/rewind.ts` (`prepare`, `materialize`) | |
| SDK `getSessionMessages` in `pals.ts`, `sessions.ts`, `transcriptTail.ts` | `harness/claude/history.ts` | |
| SDK `listSessions` / `getSessionInfo` / `renameSession` in `palRecent.ts` | `harness/claude/directory.ts` | `RecentSessions` filtering (own folders, temp roots) stays host-side |
| `stallWatch.ts`: `transcriptHas`, `growth`, `SELF_REPORTING` | `history.took`, `history.growth`, `tools.selfReporting` | `killHard`, `apiSockets`, `diagnoseInto` are OS-level: stay |
| `ccEffort.ts` | `harness/claude/settings.ts` (`defaultEffort`, `canonicalModel`) | |
| `pals.ts`: `ownerMode`, `optionFor`, `baseModel`, `PAL_MODES`; `palSession.ts`: `contextWindowOf/For`, `startError`, `peerWrap` | `harness/claude/settings.ts`, `harness/claude/process.ts` | `PAL_MODES` becomes `capabilities().permissionModes` |
| `hub.ts` / `pals.ts` effort list `["low","medium","high","xhigh","max"]` (two copies) | `capabilities().efforts` | **B3** merges the two copies first |
| `ccSpend.ts` (prices, transcript usage) | `harness/claude/spend.ts` (`history.spentOn`) | |
| `ccCli.ts` (`claude agents`, stop background, `loginEnv`, `cleanSessionEnv`, `findClaude`) | `harness/claude/cli.ts` | |
| `ccHooks.ts` (installer into `settings.json`, hook script, `HookServer`) | installer + script → `harness/claude/hooks.ts`; `HookServer` (unix socket) stays host-side | hook payloads normalized to `{ kind: "permission" \| "question" \| "notify" \| "stop", sessionId, tool, input }` before `sessions.ts` sees them |
| `memory.ts`: `autoMemoryDir` | `harness/claude/memory.ts`; `MemoryView` stays host-side, built from `harness.memory` | **B3** adds agent memory (CLAUDE.md + project memory): it should call `autoMemoryDir`/`projectInstructions` only, so B7 is a re-point |
| `auth.ts`: `isAuthFailure`, `credentialsStamp`, `claudeLoggedIn`, expect script | `harness/claude/auth.ts`; `AuthWatch` stays host-side | |
| `questions.ts`: `ASK_TOOL`, `parseItems`, answers-into-input | `tools.ask`, `tools.parseQuestion`, `tools.answerQuestion` | `QuestionManager` stays |
| `copy.ts` `describeActivity`, `KEEP_LINE`, tool label switch; `approvals.ts` `sessionPermission`, Bash always-allow key | read `tools.classify()` | host keeps the words, the adapter the names |
| `tasks.ts` `SUBAGENT_TOOLS`, `SubagentHandback` | `tools.subagent`, `tools.handback` | |
| `harnessInfo.ts` (commands/models cache, terminal-only commands list) | stays host-side; the terminal-only default list moves to `harness/claude/commands.ts` | |
| `setup.ts` `checkHarness` (direct `query`) | `harness.probe` | |
| `palLauncher.ts` | stays (it starts any process through the Helper); `Spawner` type no longer imports the SDK's `SpawnedProcess` | |
| `pals.ts` `release` copy "claude --resume" | `sessions.resumeCommand` | |

---

## 3. The capability descriptor

### 3.1 Shape

```jsonc
// HarnessCapabilities (host/src/harness/types.ts; Kit: HarnessCapabilities.swift)
{
  "id": "claude-code",
  "name": "Claude Code",                       // shown where the app says which tool runs an agent
  "version": "2.1.x",                          // the CLI's, when known
  "commandPrefix": "/",                        // slash commands; null = none
  "login": {
    "kind": "oauth-code",                      // "oauth-code" (link out, code back) | "api-key" | "none"
    "account": "Claude",                       // "使用 {account} 账号登录"
    "fromPhone": true                          // auth.login.start works
  },
  "models": [                                  // ModelOption, as today's model.get / pals.detail
    { "id": "opus[1m]", "name": "Opus", "description": "…", "efforts": ["low","medium","high","xhigh","max"],
      "resolved": "claude-opus-5-5[1m]", "contextWindow": 1000000 }
  ],
  "efforts": ["low","medium","high","xhigh","max"],       // ids; the app localizes known ids, else shows labels[id] or the id
  "permissionModes": ["default","auto","acceptEdits","plan"],
  "labels": { "xhigh": "Extra high", "acceptEdits": "Accept edits" }, // host-language labels for ids the app may not know
  "features": {
    "rewind": true, "restoreFiles": true, "compact": true, "autoCompact": true,
    "takeOverTerminal": true, "handBackToTerminal": true, "rename": true,
    "subagents": true, "backgroundTasks": true, "images": true, "files": true,
    "questions": { "multiSelect": true, "maxOptions": 4 },
    "liveModelSwitch": true, "liveModeSwitch": true, "projectMemory": true, "globalHooks": true
  },
  "terminal": {                                 // copy that names terminal commands
    "exitCommand": "/exit",
    "resumeCommand": "claude --resume {sessionId}",
    "newCommand": "claude"
  },
  "memory": { "projectFile": "CLAUDE.md" }
}
```

### 3.2 Where it rides

| Where | Field | Why |
|---|---|---|
| `hello` result | `harnesses: { [id]: HarnessCapabilities }`, `harness: "claude-code"` (the assistant's) | once per connection; the app caches it per host |
| `harness.updated` event (new) | `{ id, capabilities }` | models or commands change (first process up, CLI update). Old apps ignore unknown events (AppStore event switch `default: break`) |
| `status` (assistant) | `harness?: string` | which descriptor applies to the assistant |
| `Pal` wire (`pals.list` / `pals.updated`) | `harness?: string` (absent = `"claude-code"`) | per agent; one host could run two harnesses later |
| `pals.detail` | keeps `models`, `efforts`, `permissionModes`, `modelOption` (already per agent) and adds `features?` (only where the agent differs from its harness, e.g. `restoreFiles: false` for one without checkpoints) | per-agent dynamics stay where they are |
| `model.get` | unchanged | old apps |

Nothing is removed: `pals.detail.permissionModes`, `models`, `efforts` stay; the descriptor is the default the app falls back to when they're absent, and the source of everything that has no field today.

### 3.3 App places that read it

Today the app has no capability field at all: `HelloResult` (Kit `Models/RPCTypes.swift:260`) decodes only `hostName`, `version`, `status`, `language`, `machineId`, `direct`. Features are found by probing an RPC and catching "unknown method" (`palsSupported`, `sessionsSupported`… in `AppStoreShared.swift:31-57`) or by a missing field (`PalDetail.permissionModes`). The descriptor joins that: `AppStore.harness(for: scope) -> HarnessCapabilities`, from `hello.harnesses` keyed by `status.harness` / `Pal.harness`. With an old host (no `harnesses`) the Kit uses `HarnessCapabilities.claudeCodeFallback`, today's lists in one file, so the app keeps working and every Claude list lives in exactly one place.

Paths: A = `ios/App/Sources`, K = `ios/PaloAllyKit/Sources/PaloAllyKit`, D = K/Demo.

| Area | Hard-coded today | Reads instead |
|---|---|---|
| Login sheet | A/Chat/ClaudeLoginSheet.swift:31 "主机上的 Claude Code 登录过期了…用你的 Claude 账号同意，再把代码粘贴回来"; A/Chat/ChatView.swift:867-874 banner "Claude Code 登录过期了" | `name` and `login.account` in the copy; `login.kind` picks the flow (`oauth-code`: link + code field as today; `api-key` / `none`: a "sign in at the host" line, no code field); `login.fromPhone` false hides the sheet's button |
| Model name | K/Models/Commands.swift:112-121 `ModelName.short` parses `claude-<family>-<n>-<n>[1m]` into "Opus 5.5" (used by ModelPicker:46, TitleOrb:374, PaloDetailForm:110, AgentDetailView:135) | the matching `models[].name` (by `id` or `resolved`); unknown id: shown as is. `ModelName.short` stays only inside `claudeCodeFallback` |
| Model colors | K/Workbench/IndicatorModel.swift:9-43 matches `haiku`/`sonnet`/`opus`/`fable` (not used in App now) | delete, or color by position in `models` |
| Default model | ModelPicker.swift:16, PaloDetailForm.swift:105-109 treat the first model as default and send `null` | unchanged rule, but documented as the descriptor's (`models[0]` is the harness default) |
| Effort labels | K/Models/Commands.swift:82-94 `EffortName.label` (low 浅 … max 最深); IndicatorModel.swift:67-76 short labels | the order and ids from `efforts` (or the model's `efforts`); label: the app's catalog for a known id, else `labels[id]`, else the id |
| Permission modes | K/Models/Commands.swift:96-109 `PermissionModeName.label` (six Claude modes); AgentDetailView.swift:155-163 | list from `pals.detail.permissionModes` (already) else `permissionModes`; labels as for effort; the "auto needs a model that has it" hint only when `runningMode != permissionMode` (already generic) |
| Questions | K/Models/Models.swift:396-475 QuestionItem shaped after AskUserQuestion; A/Chat/QuestionCard.swift:107-111 "· 可多选", :261-287 answers joined by ", " | `features.questions.multiSelect` gates the multi-select UI; the answer format is the host's job (`question.answer` keeps `answers`; the adapter's `answerQuestion` builds the tool input). **B4** moves this card onto the PendingItem shell, which mostly retires the Claude shape |
| Tool names | K/Support/Friendly.swift:11-64 (bash, read, edit, webfetch… → labels; `runsCommand` = Bash); used by ApprovalCard.swift:30, 92, SessionCopy.swift:54, Copy.swift:65, TasksSection.swift:273 | the host sends `toolClass` (`run`/`read`/`write`/`web`/`agent`/`message`/`other`) on `Approval` and `TaskActivity` (from `tools.classify`); Friendly maps the class, falling back to today's name table for old hosts |
| Slash commands | none hard-coded (from `commands.list`); ComposerView.swift:223 opens the list on "/" | the trigger character is `commandPrefix` (null: no command list) |
| Terminal copy | A/Pals/AdoptFlow.swift:92-94 and A/Sessions/SessionPage.swift:99 "在终端里输入 /exit 退出它"; A/Settings/SettingsView.swift:64 "Claude Code 要你点头的事…"; A/Pals/PalPage.swift:144 "主机上的 Claude Code 里也会是这个名字"; A/Workbench/HistoryPicker.swift:137 "…开着的 Claude Code 也会出现在这里"; A/Chat/ChatView.swift:467 "和在终端里一样" | `{exitCommand}` and `{name}` filled into the strings (the catalog keeps one string with placeholders). **B2** removes SessionPage and the "接管" flow, so two of these go anyway |
| Resume command | K/Models/Pals.swift:174 and K/Store/AppStore+Pals.swift:264-270 fall back to `"claude --resume <id>"`; K/Models/Sessions.swift:64-78 `"claude attach <id>"` (no caller) | `terminal.resumeCommand` template; delete the unused `attachCommand` |
| Feature gates | rewind menu (A/Chat/MessageRow.swift:111, K/Store/AppStore+Rewind.swift:13-37), restore-files toggle (A/Chat/RewindPanel.swift:28-62), 压缩 button (A/Workbench/Detail/DetailParts.swift:123-170), adopt / 终端里开着 (A/Workbench/HistoryPicker.swift:61), rename | `features.rewind`, `features.restoreFiles` (plus `pals.rewind {check}` as today), `features.compact`, `features.takeOverTerminal`, `features.rename` |
| Hooks toggle | A/Settings/SettingsView.swift:56-66 (Claude Code's global hooks, `sessions.hooks`) | shown when the harness has hooks (`features.globalHooks`, add to 3.1) |
| Memory files | A/Assistant/MemorySection.swift:83-85, 197-199 (`MEMORY.md`, scope `auto` mirrors Claude's auto memory) | `memory.projectFile` for the agent's instructions file name (**B3** adds agent memory) |
| Context window | not hard-coded (reads `contextWindow`) | unchanged |
| Demo host | D/DemoHost.swift:237 (claude.com OAuth URL), :278, 996-1021, 1161, 1465; D/DemoHost+Workbench.swift:21-150; D/DemoHost+Pals.swift:151-171, 261-702; D/DemoHost+Files.swift:116 | the demo's hello returns a descriptor built from one `DemoHost.claudeCode` constant; the demo's Claude literals stay (it imitates a Claude host) but live in that one place |

Type names (`CCSession`, `CCSessionKind`) and RPC names stay, per the rules; only user-visible words and lists move.

---

## 4. Migration order

Rules for every step: one commit, `bun run typecheck && bun test` green, Kit `swift test` green when the app changes, demo host in the same commit as the host behavior it mirrors, no RPC removed, no stored file renamed.

### 4.1 Steps

| # | Commit | Risk | Tests |
|---|---|---|---|
| 0 | **Characterization.** Add `test/agentContract.test.ts`: the same scripted fake turns run against `Conversation` and `PalSession` (via Hub and Pals), pinning the rows of table 1.1 that differ (queued proactive turn waits, ally gate holds owner words, question deferred vs blocking, sleep, backoff restart, stop settles, rewind drops ids). Add golden transcript fixtures (`test/fixtures/transcripts/*.jsonl`: plain, compaction, fork, peer message, images, sidechain, tool results) and snapshot `toPalMessages`, `chainTo`, `matchOwnerEntry` over them. | low | new only |
| 1 | **Move, don't change.** `git mv` the Claude-only modules into `harness/claude/` (table 2.1), old paths re-export. | low | all existing |
| 2 | **Harness object.** `ClaudeHarness` assembles them behind `Harness`; `Hub` builds one and passes `harness` instead of `claudeDir` / `forkSession` / `readMessages` / `recentSource` / `renameSession` deps. Tests build `ClaudeHarness` over `FakeClaudeDir` (what they already do), so fixtures don't change. | low-medium | all existing |
| 3 | **History through the harness.** `pals.history`, `PalSession` constructor (`readTail`/`readHead`), `TranscriptFollower` → `harness.history`. **B2** makes `sessions.history` a thin agent-history call; this step just re-points it. | medium | pals.test history cases, fixtures snapshot |
| 4 | **Rewind through the harness.** `hub.rewindChat`, `backfillOwnerUuids`, `PalSession.rewind`, `pals.release` → `harness.rewind`. | **high**: past-compaction copy, uuid renaming in chat.jsonl, pending-fork resume | rewind.test (24), run `rewind.live.test.ts` |
| 5 | **Directory, stall, spend, effort, mode, memory, auth** through the harness, one commit each (7 small commits). | low each; memory and auth medium (owner files) | sessions, stallWatch, ccEffort, auth, palRecent tests; add a memory path test per agent (**B3**) |
| 6 | **Hooks installer** into `harness/claude/hooks.ts`; payload normalization before `sessions.ts`. | **high**: writes the owner's `~/.claude/settings.json`; must add and remove exactly the same entries as today | ccHooks.test, plus a new round-trip test: install with the old code, remove with the new, file byte-identical |
| 7 | **Tool vocabulary.** `copy.ts`, `approvals.ts`, `allyGate.ts`, `tasks.ts`, `stallWatch.ts`, `questions.ts` read `harness.tools`. | **high** for `allyGate.ts` (security) | allyGate.test, run `allyGate.live.test.ts`; activity.test |
| 8 | **Neutral tools.** `ToolSpec[]` (name, description, zod, handler) defined host-side in `host/src/tools/`; the adapter wraps with `createSdkMcpServer`; **B5**'s backlog tools join here. `ToolHandlers` stays as the handler type. | medium | paloSend.test, hub tool tests, `paloSend.live.test.ts` |
| 9 | **Capabilities on the wire.** `harness.capabilities()`, `hello.harnesses`, `status.harness`, `Pal.harness`, `harness.updated`; demo host same commit. | low (additive) | protocol.test snapshot of hello and Pal; Kit decoding test with and without the field |
| 10 | **App reads the descriptor**, place by place (3.3), with `claudeCodeFallback`; one commit per area (models/effort, permission modes, login page, terminal copy, feature gates). | medium (UI) | Kit tests per area; demo walk on Mac (model sheet, details, login page, hand-back sheet) |
| 11 | **Shared parts extracted** without merging classes: `TurnLedger`, `StreamAssembler`, `TaskProjection` (`TaskTracker` + `RecordTasks`), `OutputSink` (`ChatLogSink`, `TranscriptSink`); both classes use them. | medium | step-0 contract test |
| 12 | **ProcessHost** extracted from `PalSession` (start, ready, holders, backoff, sleep, kill, helper retry); `Conversation` uses it with `startMode: "lazy-sync"`, `restart: "on-demand"`, `exclusive: false`. | **highest**: the assistant must stay reachable by name, never sleep, keep sending before ready, keep `restartIdle` after login | hub.test (74), pals.test (67), stallWatch, contract test; run `pals.live`, `paloSend.live`, `compactWindow.live`; one night on the owner's Mac before step 13 |
| 13 | **AgentSession.** `PalSession` becomes `AgentSession` + `AGENT_FLAGS`; `Conversation` becomes a facade: `new AgentSession(ASSISTANT_FLAGS)` with `TurnQueue`, `WechatRelay`, `AllyGate` policies. Public API of `Conversation` unchanged so `hub.ts` and its tests don't move. | **high**: proactive/owner attribution, `[skip]`, WeChat paragraphs, budget drop, goal results, implicit turns | hub.test, allies.test, allyGate tests, e2e.test; contract test must be unchanged |
| 14 | **One code path for rewind / settings / stop** in Hub and Pals (call `AgentSession` methods; the RPC handlers stay). | medium | rewind, pals, hub |
| 15 | **Remove the facades and re-export shims** (after a release with them). | low | typecheck |

Batches 2 to 5 shrink or shift steps: **B2** removes `toCCMessages`/`CCMessage`/most of `handoffs.ts` (steps 1 and 3 move less) and makes take-over automatic (the queue-until-terminal-exits path becomes part of `ProcessHost`, step 12: `exclusive` sessions wait instead of failing). **B3** merges the two effort lists and the model/effort setters (step 5 and 14 are smaller) and adds agent memory (step 5 re-points it). **B4** generates permission and question cards in one place (step 13's `questions` flag shrinks to "defer or block"). **B5** adds backlog tools to both tool sets (step 8 must include them) and needs `turnEnd.finished` (step 13 keeps it).

### 4.2 Test strategy

- **What covers it today:** `hub.test.ts` (74 tests: owner turns, proactive turns, ally gate, compaction, rewind, stall, stop, auth), `pals.test.ts` (67: start, holders, sleep/wake, rename, history, rewind with files, model/mode, compact, tasks), `rewind.test.ts` (24), `stallWatch.test.ts`, `sessions.test.ts`, `handoffs.test.ts`, `tasks.test.ts`, `allyGate.test.ts`, `ccHooks.test.ts`, `ccEffort.test.ts`, `auth.test.ts`, `palRecent.test.ts`, `paloSend.test.ts`, `protocol.test.ts`, `e2e.test.ts`. All drive the real classes over `fakeDriver.ts` and `fakeClaude.ts` (`FakeClaudeDir`: registry, transcripts, `claude agents`).
- **Live tests** (real Claude Code, run by hand at the risky steps): `rewind.live`, `pals.live`, `palMedia.live`, `paloSend.live`, `allyGate.live`, `compactWindow.live`, `live`.
- **To add:** (1) the step-0 contract test, kept unchanged from step 0 to 15: it is the proof that the merge changed nothing; (2) golden transcript fixtures with snapshots, so moving the mappers is checked byte for byte; (3) `harness.contract.test.ts`: any `Harness` (Claude over `FakeClaudeDir`, and `FakeHarness`) passes the same checks for history paging, rewind targets, holders, resume command; this is also the checklist a second adapter would pass; (4) a flags-matrix test on `AgentSession`: one scripted run under each flag value; (5) hooks install/remove round trip on a copy of a real `settings.json`; (6) wire snapshots: `hello`, `Pal`, `pals.detail` with the old fields present; (7) Kit: decode descriptor present/absent, fallback lists, and each UI area's view model reading it.
- **Smoke before handing over** (rules): Mac demo walk of the model sheet, details (assistant and agent), login page, hand-back sheet, slash command list; iPhone simulator compile; the lead's phone check.

### 4.3 The risky steps, said plainly

1. **Step 12, the assistant's process lifecycle.** Today `ensureSession()` is synchronous and `send` goes straight into the SDK queue; the PalSession path awaits `ready()` and checks holders. If the assistant inherits "await ready" its first message after a restart could race with `answering` events, and if it inherits `exclusive` a stale registry entry could stop it. Mitigation: `startMode: "lazy-sync"` and `exclusive: false`, plus the contract test's "send before ready" case.
2. **Step 13, turn attribution.** The assistant decides per result whether a turn answered the owner (folded owner words into a proactive turn show as a normal reply, no push). That logic moves into `TurnQueue`; a mistake shows as pushes for ordinary replies or lost proactive cards. Mitigation: move `endTurn` as one piece into `TurnQueue.onTurnEnd`, not rewrite it.
3. **Step 4, rewind.** Past-compaction copies rename uuids in `chat.jsonl`; a mistake breaks rewind for older messages silently. Mitigation: fixtures + `rewind.live`.
4. **Step 6, hooks.** Writes the owner's settings. Mitigation: round-trip test; the hook marker string unchanged.
5. **Step 7, allyGate.** A mis-classified tool lets an Ally's turn act. Mitigation: `classify()` must be at least as strict as today for every tool name in `allyGate.test.ts`; unknown tools classify as `other` (denied).

### 4.4 Compatibility with old apps

- All RPC names, params and results stay; new fields only (`hello.harnesses`, `hello.harness`, `status.harness`, `Pal.harness`, `pals.detail.features`), one new event (`harness.updated`, ignored by old apps).
- `pals.detail.permissionModes` / `models` / `efforts` keep being sent: old apps read them today.
- Stored files unchanged: `pals.json` (`PalRecord` gains optional `harness`, absent = claude-code), `runtime.json`, `chat.jsonl`, `tasks.json`, `config.json`.
- New app with an old host: `claudeCodeFallback` (today's lists) when `hello.harnesses` is absent.
- Wording the old app shows ("claude --resume …") comes from `pals.release`'s `resumeCommand`, which is already host-built; unchanged.

---

## 5. Estimate

AI work hours, including the Mac demo walk and the simulator compile where the app changes; the owner's phone check per the plan's batch rule is not counted.

| Step | Hours |
|---|---|
| 0 characterization test + transcript fixtures | 2.5 |
| 1 move under harness/claude/ | 1 |
| 2 Harness object, Hub/Pals deps | 1.5 |
| 3 history | 1 |
| 4 rewind (+ live run) | 2 |
| 5 directory, stall, spend, effort, mode, memory, auth (7 commits) | 2.5 |
| 6 hooks installer (+ round-trip test) | 1 |
| 7 tool vocabulary (+ allyGate live run) | 1.5 |
| 8 neutral ToolSpec, MCP wrapping | 1.5 |
| 9 capabilities on the wire + demo host | 1 |
| 10 app reads the descriptor (Kit + views + demo walk) | 3.5 |
| 11 shared parts extracted | 2 |
| 12 ProcessHost (+ live runs) | 3 |
| 13 AgentSession + assistant policies | 4 |
| 14 one path for rewind / settings / stop | 1.5 |
| 15 remove facades and shims | 0.5 |
| **Total** | **30** |

That is above the plan's 20 to 28: the app part (step 10) and the characterization test (step 0) were not in it. If batches 2 to 4 land as planned, steps 3, 5, 13 and 14 shrink by about 3 hours, which brings it to about 27. Steps 0 to 10 (about 19 hours) are useful alone: the adapter and the descriptor can ship without the runtime merge, and steps 11 to 15 can wait.
