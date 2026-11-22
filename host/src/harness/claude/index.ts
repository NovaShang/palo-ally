import { forkSession as sdkForkSession, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { sdkRename, sdkSource } from "./directory.ts";
import { SpendMeter } from "./spend.ts";
import type { ChatMessage } from "../../types.ts";
import type {
  Harness,
  HarnessDriver,
  HarnessEntry,
  HistoryMapOptions,
  HistoryStore,
  HarnessSettings,
  LiveSession,
  MemoryLocator,
  PendingRewindPoint,
  RecentSource,
  RewindChain,
  RewindPoint,
  Rewinder,
  SessionDirectory,
  SessionRef,
} from "../types.ts";
import { EFFORTS } from "../../modelChoice.ts";
import { AGENT_CORE_FILES, agentMemoryDir, autoMemoryDir } from "../../memory.ts";
import { TranscriptFollower, toPalMessages, transcriptLastLine, transcriptModel, userEntryMessage } from "./history.ts";
import { claudeConfigDir, transcriptPath } from "./paths.ts";
import { peerWrap, startError } from "./process.ts";
import { readRegistry, type RegistryEntry } from "./registry.ts";
import { type ForkSession, beforeCompaction, chainTo, findEntry, forkedUuids, hasFileCheckpoint, leafOf, matchOwnerEntry, ownerText, readTranscript } from "./rewind.ts";
import { PAL_MODES, contextWindowFor, ownerMode, settingsEffort } from "./settings.ts";
import { pageFromTail } from "./tail.ts";
import { type RawSessionMessage, growth, readHead, readTail, transcriptHas } from "./transcript.ts";

// Claude Code as PaloAlly's harness (docs/harness-adapter-design.md §2): the
// parts under harness/claude/ put together behind the Harness interface.
// Tests point it at their own Claude Code folder and replace the parts that
// would otherwise reach this computer's (the SDK's session functions).

export interface ClaudeHarnessOptions {
  driver: HarnessDriver;
  /** Claude Code's config folder (registry, transcripts, settings); default: CLAUDE_CONFIG_DIR or ~/.claude. */
  configDir?: string;
  /** Copies a session up to an entry as a new one (default: the SDK's forkSession). */
  forkSession?: ForkSession;
  /** A session's whole conversation (default: the SDK's getSessionMessages; set, the tail is never paged). */
  readMessages?: (sessionId: string, dir: string) => Promise<RawSessionMessage[]>;
  /** Its ended conversations (default: the SDK's listSessions / getSessionInfo). */
  recentSource?: RecentSource;
  /** Retitles a session without a process (default: the SDK's renameSession). */
  renameSession?: (sessionId: string, title: string, dir: string) => Promise<void>;
  /** The live sessions (default: its registry). */
  registry?: () => RegistryEntry[];
}

const startedAt = (entries: HarnessEntry[]): { startedAt?: number } => {
  const t = Date.parse(entries[0]?.timestamp ?? "");
  return Number.isFinite(t) ? { startedAt: t } : {};
};

const shq = (s: string) => (/^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`);

export class ClaudeHarness implements Harness {
  readonly id = "claude-code";
  readonly driver: HarnessDriver;
  /** Claude Code's config folder. Only harness/claude/ and the modules about the computer's other Claude Code sessions use it. */
  readonly configDir: string;
  readonly history: HistoryStore;
  readonly rewind: Rewinder;
  readonly sessions: SessionDirectory;
  readonly settings: HarnessSettings;
  readonly memory: MemoryLocator;

  constructor(private o: ClaudeHarnessOptions) {
    this.driver = o.driver;
    this.configDir = o.configDir ?? claudeConfigDir();
    this.history = this.makeHistory();
    this.rewind = this.makeRewinder();
    this.sessions = this.makeDirectory();
    this.settings = this.makeSettings();
    this.memory = this.makeMemory();
  }

  /** Where Claude Code keeps a session's transcript. */
  transcript(ref: SessionRef): string {
    return transcriptPath(this.configDir, ref.cwd, ref.sessionId);
  }

  /** The SDK's forkSession (or the test's). */
  get forkSession(): ForkSession {
    return this.o.forkSession ?? ((sid, f) => sdkForkSession(sid, f));
  }

  private makeHistory(): HistoryStore {
    const path = (ref: SessionRef) => this.transcript(ref);
    const meter = new SpendMeter(this.configDir);
    const read = this.o.readMessages ?? ((sid: string, dir: string) => getSessionMessages(sid, { dir }) as Promise<RawSessionMessage[]>);
    return {
      exists: (ref) => existsSync(path(ref)),
      // From the transcript's end, not all of it parsed (tail.ts): a long
      // session's whole file took 20 s a page. Unreadable: nothing.
      page: async (ref, { map, pick, before, limit }) => {
        const convert = (r: RawSessionMessage[]) => toPalMessages(r, map);
        const p = path(ref);
        if (!this.o.readMessages && existsSync(p)) {
          try {
            return await pageFromTail(p, ref.sessionId, ref.cwd, convert, pick, before, limit);
          } catch {
            return [];
          }
        }
        let raw: RawSessionMessage[] = [];
        try {
          raw = await read(ref.sessionId, ref.cwd);
        } catch {
          raw = []; // a new session's transcript isn't there before its first message
        }
        return pick(convert(raw));
      },
      toMessages: (entries, map) => toPalMessages(entries as RawSessionMessage[], map),
      tail: (ref, bytes = 256 * 1024) => readTail(path(ref), bytes),
      head: (ref, bytes = 256 * 1024) => readHead(path(ref), bytes),
      model: (entries) => transcriptModel(entries),
      lastLine: (entries) => transcriptLastLine(entries),
      follow: (ref, onEntry) => new TranscriptFollower(path(ref), onEntry),
      entryMessage: (e, map) => {
        if (e?.type !== "user" || e.isSidechain) return null;
        return userEntryMessage(
          { type: "user", uuid: String(e.uuid ?? ""), message: e.message, timestamp: e.timestamp, origin: e.origin, parent_tool_use_id: null,
            isMeta: e.isMeta, isCompactSummary: e.isCompactSummary, promptSource: e.promptSource } as RawSessionMessage,
          map,
        );
      },
      took: (ref, uuid) => transcriptHas(path(ref), uuid),
      growth: (ref) => growth(path(ref)),
      size: (ref) => {
        try {
          const st = statSync(path(ref));
          return st.isFile() ? st.size : null;
        } catch {
          return null;
        }
      },
      spentOn: (ref, day, tz) => meter.spentOn(ref.cwd, ref.sessionId, day, tz),
      locate: (ref) => path(ref),
    };
  }

  private makeRewinder(): Rewinder {
    const point = (chain: RewindChain, e: HarnessEntry | undefined): RewindPoint | null => {
      if (!e || typeof e.uuid !== "string") return null;
      const at = typeof e.parentUuid === "string" ? e.parentUuid : typeof e.logicalParentUuid === "string" ? e.logicalParentUuid : null;
      return { uuid: e.uuid, index: chain.chain.indexOf(e), at, text: ownerText(e) };
    };
    return {
      chain: (ref, pending?: PendingRewindPoint) => {
        const sessionId = pending ? pending.from : ref.sessionId;
        const entries = readTranscript(this.transcript({ sessionId, cwd: ref.cwd }));
        return { sessionId, entries, chain: chainTo(entries, pending ? pending.at : leafOf(entries)), ...startedAt(entries) };
      },
      ownerChain: (ref) => {
        const entries = readTranscript(this.transcript(ref), ['"type":"user"']);
        return { sessionId: ref.sessionId, entries, chain: entries, ...startedAt(entries) };
      },
      find: (chain, by) => {
        let e: HarnessEntry | undefined;
        if (by.uuid) e = by.exact ? chain.chain.find((x) => x.uuid === by.uuid) : findEntry(chain.chain, by.uuid);
        if (!e && by.words !== undefined) e = matchOwnerEntry(chain.chain, by.words, by.ts ?? 0, by.used);
        return point(chain, e);
      },
      keptIds: (ref, at) => new Set(chainTo(readTranscript(this.transcript(ref)), at).map((e) => e.uuid)),
      needsCopy: (chain, p) => beforeCompaction(chain.chain, p.at),
      copy: async (ref, at, title) => (await this.forkSession(ref.sessionId, { dir: ref.cwd, upToMessageId: at, title })).sessionId,
      renamed: (ref) => forkedUuids(readTranscript(this.transcript(ref))),
      canRestoreFiles: (chain, uuid) => hasFileCheckpoint(chain.entries, uuid),
      ownerWords: (e) => ownerText(e),
      dropped: (chain, p, map: HistoryMapOptions) => toPalMessages(chain.chain.slice(p.index) as RawSessionMessage[], map).map((m: ChatMessage) => m.id),
    };
  }

  private makeDirectory(): SessionDirectory {
    return {
      live: (): LiveSession[] => this.o.registry?.() ?? readRegistry(join(this.configDir, "sessions")),
      recent: this.o.recentSource ?? sdkSource(this.configDir),
      rename: (sid, title, cwd) => (this.o.renameSession ?? sdkRename(this.configDir))(sid, title, cwd),
      resumeCommand: (cwd, sid) => (sid ? `cd ${shq(cwd)} && claude --resume ${sid}` : `cd ${shq(cwd)} && claude`),
    };
  }

  private makeSettings(): HarnessSettings {
    return {
      defaultEffort: (model, cwd) => settingsEffort(model, cwd, this.configDir),
      defaultPermissionMode: () => ownerMode(this.configDir),
      permissionModes: PAL_MODES,
      efforts: EFFORTS,
      contextWindow: (model, tokens, reported) => contextWindowFor(model, tokens, reported),
      startError: (raw) => startError(raw),
      peerWrap: (name, text) => peerWrap(name, text),
    };
  }

  private makeMemory(): MemoryLocator {
    return {
      autoMemoryDir: (cwd, configDir) => autoMemoryDir(cwd, configDir),
      agentMemoryDir: (cwd) => agentMemoryDir(cwd, this.configDir),
      projectFiles: AGENT_CORE_FILES,
    };
  }
}
