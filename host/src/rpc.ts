import type { Hub } from "./hub.ts";
import type { Attachment, Channel } from "./types.ts";
import { readJson, writeJson } from "./util.ts";
import { t } from "./i18n/index.ts";
import { parseScope } from "./files.ts";

export interface RpcContext {
  clientId: string;
  deviceId?: string; // paired device (relay clients)
  channel: Channel; // "app" for relay clients, "cli" for the local socket
  local: boolean; // local socket: may call admin methods
}

export interface RpcRequest {
  id?: number | string;
  method?: string;
  params?: any;
}

// The app-facing protocol (docs/design.md §5.3). test/protocol.test.ts drives
// every one of these and writes the samples the Swift client decodes strictly.
export const RPC_METHODS = [
  "hello", "sync", "chat.send", "chat.history", "chat.search", "chat.around", "chat.rewind", "commands.list", "model.get", "model.set",
  "task.get", "task.stop", "approval.answer", "question.answer", "watch.add", "watch.update", "watch.remove",
  "artifact.list", "artifact.read", "artifact.pin", "memory.list", "memory.read", "memory.write",
  "settings.update", "stop", "push.register", "push.unregister", "device.unpair", "audit.tail",
  "media.upload", "media.uploadChunk", "media.get", "media.read",
  "suggestions.list", "suggestions.dismiss", "host.update",
  "ally.list", "ally.invite", "ally.accept", "ally.remove", "ally.log", "ally.draft.decide", "ally.say", "ally.trust",
  "sessions.list", "sessions.history", "sessions.hooks", "helper.decide",
  "pals.list", "pals.adopt", "pals.release", "pals.remove", "pals.history", "pals.send", "pals.stop", "pals.recent", "pals.wake", "pals.rename", "pals.rewind",
  "pals.create", "pals.folders", "pals.seen", "pals.end", "pals.earlier", "pals.resume",
  "pals.detail", "pals.setModel", "pals.compact", "pals.stopTask", "pals.reveal",
  "workspaces.list", "workspaces.create", "workspaces.update", "workspaces.move", "workspaces.delete", "workbench.tabs.get", "workbench.tabs.set",
  "pair.invite", "device.list", "device.remove",
  "auth.login.start", "auth.login.code", "auth.login.cancel",
  "files.list", "files.read", "files.search", "files.resolve", "files.folders.list", "files.folders.browse", "files.folders.add", "files.folders.remove",
] as const;

export const RPC_EVENTS = [
  "chat.message", "chat.delta", "chat.rewound", "task.updated", "approval.updated", "question.updated", "watch.updated",
  "artifact.updated", "settings.updated", "status", "commands.updated",
  "suggestions.updated", "ally.updated", "ally.entry", "sessions.updated", "pals.updated",
  "workspaces.updated", "workbench.updated",
] as const;

// Admin methods are reachable only on the local unix socket (the owner's own
// machine), never through the relay.
export type AdminHandler = (method: string, params: any) => Promise<unknown> | unknown;

export async function handleRpc(hub: Hub, req: RpcRequest, ctx: RpcContext, admin?: AdminHandler): Promise<unknown> {
  const p = req.params ?? {};
  switch (req.method) {
    case "hello":
      // Which app this device is (the list of devices shows it).
      if (ctx.deviceId) hub.noteDevice(ctx.deviceId, p.client);
      // The app's preferred language (BCP 47, e.g. "zh-Hans-CN"): the first one the host hears decides its language until the owner sets one.
      if (ctx.channel === "app") hub.noteLocale(p.locale);
      return { hostName: hub.config.hostName, version: hub.status().version, status: hub.status(), language: hub.language() };
    case "sync": {
      const since = typeof p.sinceSeq === "number" ? p.sinceSeq : undefined;
      // The app syncs when it comes to the foreground: an Ally's message
      // already in the chat counts as seen.
      if (ctx.channel === "app") hub.allies.ownerActive();
      return {
        seq: hub.chat.lastSeq,
        messages: since === undefined ? hub.chat.recent(100) : hub.chat.since(since, 500),
        tasks: hub.tasks.list(),
        approvals: hub.approvals.list(),
        questions: hub.questions.list(),
        watches: hub.watches.list(),
        artifacts: hub.artifacts.list(),
        settings: hub.config.settings,
        status: hub.status(),
        workspaces: hub.workbench.list(),
        workbenchTabs: hub.workbench.allTabs(),
        // Mid-reply: the whole text so far, which replaces what the client
        // has for that id; later chat.delta events append to it.
        streaming: hub.conversation.streamingReply() ?? undefined,
        // Gone back before (回到这里重来) since then: the client drops these.
        ...(since !== undefined && hub.chat.rewoundSince(since).length ? { rewound: hub.chat.rewoundSince(since) } : {}),
      };
    }
    case "chat.send": {
      const cid = typeof p.clientMsgId === "string" ? p.clientMsgId.slice(0, 100) : undefined;
      // A retried send (the first one did arrive) must not run twice.
      const dup = cid ? hub.chat.findByClientMsgId(cid) : undefined;
      if (dup) return { id: dup.id, seq: dup.seq };
      const attachments = attachmentsOf(hub, p.attachments);
      const r = p.replyTo;
      const replyTo =
        r && typeof r.messageId === "string" && typeof r.excerpt === "string" && r.excerpt.trim()
          ? { messageId: r.messageId.slice(0, 100), excerpt: r.excerpt.trim().slice(0, 300) }
          : undefined;
      const msg = hub.userMessage(String(p.text ?? ""), ctx.channel, undefined, cid, attachments, replyTo);
      if (!msg) throw new Error(t("rpc.err.empty"));
      // Sent by tapping a 「试试」 chip: it's used up.
      if (typeof p.suggestionId === "string") hub.suggestions.use(p.suggestionId);
      return { id: msg.id, seq: msg.seq };
    }
    case "suggestions.list":
      return { suggestions: hub.suggestions.list() };
    case "suggestions.dismiss":
      return { ok: hub.suggestions.dismiss(String(p.id ?? "")) };
    case "media.upload":
      return hub.media.save(String(p.mediaType ?? ""), String(p.data ?? ""));
    case "media.uploadChunk":
      return hub.media.uploadChunk({
        uploadId: typeof p.uploadId === "string" ? p.uploadId : undefined,
        name: String(p.name ?? ""),
        mediaType: typeof p.mediaType === "string" ? p.mediaType : undefined,
        offset: Number(p.offset ?? 0),
        data: String(p.data ?? ""),
        done: !!p.done,
      });
    case "media.read":
      return hub.media.readChunk(String(p.id ?? ""), Number(p.offset ?? 0), Number(p.length ?? 256 * 1024));
    case "media.get": {
      const m = hub.media.read(String(p.id ?? ""));
      if (!m) throw new Error(t("rpc.err.noImage"));
      return { mediaType: m.mediaType, data: m.data };
    }
    case "model.get":
      return await hub.modelInfo();
    case "model.set": {
      const patch: { model?: string | null; effort?: string | null } = {};
      if ("model" in p) patch.model = p.model == null ? null : String(p.model);
      if ("effort" in p) patch.effort = p.effort == null ? null : String(p.effort);
      return { status: await hub.setModel(patch) };
    }
    case "commands.list":
      return { commands: await hub.loadCommands() };
    case "chat.history":
      return { messages: hub.chat.before(Number(p.beforeSeq ?? Infinity), Math.min(Number(p.limit ?? 50), 200)) };
    case "chat.search": {
      const before = typeof p.beforeSeq === "number" ? p.beforeSeq : Infinity;
      return { messages: hub.chat.search(String(p.query ?? ""), Math.max(1, Math.min(Number(p.limit ?? 50), 100)), before) };
    }
    // 回到这里重来 (docs/rewind-prd.md): back to just before one of the
    // owner's messages; its words come back for the composer.
    case "chat.rewind":
      return await hub.rewindChat(String(p.messageId ?? ""), ctx.channel);
    case "chat.around": {
      const clamp = (v: unknown, d: number) => Math.max(0, Math.min(Number(v ?? d), 100));
      return { messages: hub.chat.around(Number(p.seq ?? 0), clamp(p.before, 25), clamp(p.after, 25)) };
    }
    case "task.get": {
      const task = hub.tasks.get(String(p.id));
      if (!task) throw new Error(t("rpc.err.noTask"));
      return { task, activity: hub.tasks.activity(task.id) };
    }
    case "task.stop": {
      const t = await hub.stopTask(String(p.id));
      return { ok: !!t };
    }
    case "approval.answer": {
      const a = hub.approvals.answer(String(p.id), !!p.allow, ctx.channel, !!p.remember, ctx.deviceId);
      if (!a) throw new Error(t("rpc.err.noApproval"));
      // A Pal's card answered after it went to sleep: it's woken (§12).
      if (a.source?.kind === "pal") hub.pals.cardAnswered(a.source.id);
      return { status: a.status };
    }
    // Signing Claude Code in again from the phone (auth.ts). The code goes to
    // the login process only: not to the audit, not to a log.
    case "auth.login.start":
      return { auth: (await hub.auth.startLogin(ctx.deviceId ?? ctx.channel)) ?? null };
    case "auth.login.code":
      return { auth: hub.auth.submitCode(String(p.code ?? "")) ?? null };
    case "auth.login.cancel":
      return { auth: hub.auth.cancelLogin() ?? null };
    case "question.answer": {
      const raw = p.answers && typeof p.answers === "object" ? (p.answers as Record<string, unknown>) : {};
      const answers = Object.fromEntries(Object.entries(raw).map(([k, v]) => [k, String(v ?? "")]));
      const q = hub.questions.answer(String(p.id ?? ""), answers, ctx.channel, ctx.deviceId);
      if (q?.source?.kind === "pal") hub.pals.cardAnswered(q.source.id);
      return { question: q };
    }
    case "watch.add":
      return { watch: hub.watches.add(p, "user") };
    case "watch.update":
      return { watch: hub.watches.update(String(p.id), p.patch ?? {}) };
    case "watch.remove":
      return { ok: hub.watches.remove(String(p.id)) };
    case "artifact.list":
      return { artifacts: hub.artifacts.list() };
    case "artifact.read":
      return hub.artifacts.read(String(p.id), p.path, Number(p.offset ?? 0), Number(p.length ?? 256 * 1024));
    case "artifact.pin":
      return { artifact: hub.artifacts.pin(String(p.id), !!p.pinned) };
    case "memory.list":
      return { files: hub.memory.list(), coreSize: hub.memory.coreSize() };
    case "memory.read":
      return { content: hub.memory.read(String(p.path)), updatedAt: hub.memory.mtime(String(p.path)) };
    case "memory.write":
      // Refuse to overwrite what the assistant changed while the editor was open.
      if (typeof p.baseUpdatedAt === "number" && hub.memory.mtime(String(p.path)) > p.baseUpdatedAt + 1)
        throw new Error(t("rpc.err.fileChanged"));
      hub.memory.write(String(p.path), String(p.content ?? ""));
      hub.audit.log("memory.write", { path: p.path, by: ctx.channel });
      return { ok: true, updatedAt: hub.memory.mtime(String(p.path)) };
    case "settings.update":
      return { settings: hub.updateSettings(p.patch ?? {}) };
    case "stop":
      hub.stopAll(ctx.channel);
      return { status: hub.status() };
    case "push.register": {
      const tokens = readJson<{ token: string; env: string; at: number }[]>(hub.paths.pushTokens, []);
      const token = String(p.token ?? "");
      if (!/^[0-9a-fA-F]{32,200}$/.test(token)) throw new Error("bad token");
      const next = tokens.filter((t) => t.token !== token);
      next.push({ token, env: p.env === "production" ? "production" : "sandbox", at: Date.now() });
      writeJson(hub.paths.pushTokens, next.slice(-10));
      return { ok: true };
    }
    case "push.unregister": {
      const token = String(p.token ?? "");
      const tokens = readJson<{ token: string }[]>(hub.paths.pushTokens, []);
      writeJson(hub.paths.pushTokens, tokens.filter((t) => t.token !== token));
      return { ok: true };
    }
    case "device.unpair":
      if (!ctx.deviceId) throw new Error(t("rpc.err.notDevice"));
      hub.audit.log("device.unpaired", { deviceId: ctx.deviceId });
      // after replying: removing the device closes this very connection
      setTimeout(() => hub.onUnpairDevice?.(ctx.deviceId!), 100);
      return { ok: true };
    // The owner's devices paired with this computer (docs/devices-prd.md):
    // the owner's own apps and the local CLI only, never an Ally.
    case "device.list":
      ownerOnly(ctx);
      return { devices: hub.listDevices(ctx.deviceId) };
    case "device.remove":
      ownerOnly(ctx);
      hub.removeDevice(String(p.deviceId ?? ""), { deviceId: ctx.deviceId, channel: ctx.channel });
      return { ok: true };
    case "audit.tail":
      return { entries: hub.audit.tail(Math.min(Number(p.limit ?? 50), 500)) };
    case "ally.list":
      return { allies: hub.allies.list() };
    case "ally.invite":
      return await hub.allies.invite();
    case "ally.accept":
      return { ally: await hub.allies.accept(String(p.link ?? ""), p.kind, p.trust) };
    case "ally.remove":
      return { ok: hub.allies.remove(String(p.id ?? "")) };
    case "ally.log":
      return { entries: hub.allies.log(String(p.id ?? ""), p.beforeTs, p.limit) };
    case "ally.draft.decide":
      return { entry: hub.allies.decide(String(p.id ?? ""), p.action, p.text) };
    // The owner's own words, sent as they are (§11.3); they're in the app, so
    // what came in before counts as seen.
    case "ally.say": {
      const entry = hub.allies.say(String(p.id ?? ""), p.text);
      if (ctx.channel === "app") hub.allies.ownerActive();
      return { entry };
    }
    case "ally.trust":
      return { ally: hub.allies.setTrust(String(p.id ?? ""), p.trust) };
    // The computer's Claude Code sessions the host doesn't run (docs/sessions-prd.md §7).
    case "sessions.list":
      return { sessions: await hub.sessions.listFresh(), hooks: hub.sessions.hooksEnabled() };
    case "sessions.history": {
      const before = typeof p.before === "string" || typeof p.before === "number" ? p.before : undefined;
      return { messages: await hub.sessions.history(String(p.id ?? ""), before, Number(p.limit ?? 50)) };
    }
    case "sessions.hooks":
      // No `enabled`: only says whether they're on.
      if (typeof p.enabled !== "boolean") return { enabled: hub.sessions.hooksEnabled() };
      return { enabled: hub.sessions.setHooks(p.enabled, ctx.channel) };
    // The assistant's proposal cards: 开吧 opens a Pal (docs/pals-prd.md §6),
    // 接管 takes over a conversation that ended (§10).
    case "helper.decide":
      return await hub.pals.decide(String(p.proposalId ?? ""), String(p.action ?? ""), ctx.channel);
    // Pals: Claude Code sessions the host runs itself (docs/pals-prd.md §8).
    case "pals.list":
      return await hub.pals.listFresh();
    case "pals.adopt":
      // cancel: the owner stopped waiting for a terminal session to be quit.
      if (p.cancel === true) return hub.pals.cancelAdopt(String(p.sessionId ?? ""), ctx.channel);
      return await hub.pals.adopt(String(p.sessionId ?? ""), ctx.channel);
    case "pals.release":
      return await hub.pals.release(String(p.id ?? ""), ctx.channel);
    case "pals.remove":
      await hub.pals.remove(String(p.id ?? ""), ctx.channel);
      return { ok: true };
    case "pals.history": {
      const before = typeof p.before === "string" || typeof p.before === "number" ? p.before : undefined;
      return await hub.pals.history(String(p.id ?? ""), before, Number(p.limit ?? 50));
    }
    // The owner's words, with images and files as Palo takes them (media.upload / uploadChunk).
    case "pals.send":
      return await hub.pals.send(String(p.id ?? ""), String(p.text ?? ""), typeof p.clientMsgId === "string" ? p.clientMsgId : undefined, attachmentsOf(hub, p.attachments));
    case "pals.stop":
      await hub.pals.stopTurn(String(p.id ?? ""), ctx.channel);
      return { ok: true };
    // An asleep Pal (§12) resumes; pals.send wakes one by itself too.
    case "pals.wake":
      return { pal: await hub.pals.wake(String(p.id ?? ""), ctx.channel) };
    // The owner names it (§13): Claude Code's own title for the session too.
    case "pals.rename":
      return { pal: await hub.pals.rename(String(p.id ?? ""), String(p.name ?? ""), ctx.channel) };
    // 回到这里重来 in a Pal (docs/rewind-prd.md): its conversation, and its
    // files if asked; `check` only says whether the files can go back.
    case "pals.rewind":
      if (p.check === true) return await hub.pals.canRestoreFiles(String(p.id ?? ""), String(p.messageId ?? ""));
      return await hub.pals.rewind(String(p.id ?? ""), String(p.messageId ?? ""), { restoreFiles: p.restoreFiles === true, by: ctx.channel });
    // The conversations that ended on the computer lately (§10); pals.adopt takes one over.
    case "pals.recent":
      return { sessions: await hub.pals.recent({ folder: typeof p.folder === "string" ? p.folder : undefined, limit: p.limit }) };
    // The workbench (docs/workbench-rpc.md §2): the owner's own sessions, in any folder.
    case "pals.create":
      return { pal: hub.pals.createSession({ cwd: String(p.cwd ?? ""), name: typeof p.name === "string" ? p.name : undefined, text: typeof p.text === "string" ? p.text : undefined, workspaceId: typeof p.workspaceId === "string" ? p.workspaceId : undefined }, ctx.channel) };
    case "pals.folders":
      return await hub.pals.folders({ limit: p.limit });
    case "pals.seen":
      return { pal: hub.pals.seen(String(p.id ?? "")) };
    case "pals.end":
      return await hub.pals.end(String(p.id ?? ""), ctx.channel);
    case "pals.detail":
      return await hub.pals.detail(String(p.id ?? ""));
    case "pals.setModel":
      return await hub.pals.setModel(String(p.id ?? ""), { model: p.model, effort: p.effort });
    case "pals.compact":
      return await hub.pals.compact(String(p.id ?? ""));
    case "pals.stopTask":
      return await hub.pals.stopTask(String(p.id ?? ""), String(p.taskId ?? ""));
    case "pals.reveal":
      return await hub.pals.reveal(String(p.id ?? ""), p.kind);
    case "pals.earlier":
      return await hub.pals.earlier({ limit: p.limit, folder: typeof p.folder === "string" ? p.folder : undefined });
    case "workspaces.list":
      return { workspaces: hub.workbench.list() };
    case "workspaces.create":
      return hub.workbench.create(p);
    case "workspaces.update":
      return hub.workbench.update(p);
    case "workspaces.move":
      return hub.workbench.move(p);
    case "workspaces.delete":
      return hub.workbench.delete(p);
    case "workbench.tabs.get":
      return hub.workbench.tabsGet(p);
    case "workbench.tabs.set":
      return hub.workbench.tabsSet(p);
    case "pals.resume":
      return await hub.pals.resume({ key: typeof p.key === "string" ? p.key : undefined, kind: typeof p.kind === "string" ? p.kind : undefined, sessionId: typeof p.sessionId === "string" ? p.sessionId : undefined }, ctx.channel);
    // A link that pairs one more of the owner's devices (5 minutes, one
    // device): for the owner's own apps and the local CLI, never an Ally.
    case "pair.invite":
      ownerOnly(ctx, t("rpc.err.ownerAdd"));
      return await hub.pairInvite(ctx.channel);
    // Files on the computer, read-only (docs/files-prd.md): the owner's own
    // devices and the local CLI only, never an Ally or a stranger.
    case "files.list":
      ownerOnly(ctx, t("files.err.owner"));
      return hub.files.list(parseScope(p.scope), typeof p.path === "string" ? p.path : "", p.showHidden === true);
    case "files.read":
      ownerOnly(ctx, t("files.err.owner"));
      return hub.files.read(parseScope(p.scope), String(p.path ?? ""), Number(p.offset ?? 0), Number(p.length ?? 256 * 1024), ctx.deviceId ?? ctx.channel);
    case "files.search":
      ownerOnly(ctx, t("files.err.owner"));
      return hub.files.search(parseScope(p.scope), String(p.query ?? ""), Number(p.limit ?? 50));
    case "files.resolve": {
      ownerOnly(ctx, t("files.err.owner"));
      // `paths`: what the app found in a reply; `text`: one of them.
      const paths = Array.isArray(p.paths) ? p.paths.map(String) : typeof p.text === "string" ? [p.text] : [];
      return hub.files.resolve(parseScope(p.scope), paths);
    }
    case "files.folders.list":
      ownerOnly(ctx, t("files.err.owner"));
      return { folders: hub.files.folders() };
    case "files.folders.browse":
      ownerOnly(ctx, t("files.err.owner"));
      return hub.files.browse(typeof p.path === "string" ? p.path : undefined, p.showHidden === true);
    case "files.folders.add":
      ownerOnly(ctx, t("files.err.owner"));
      return { folder: hub.files.addFolder(String(p.path ?? ""), ctx.deviceId ?? ctx.channel) };
    case "files.folders.remove":
      ownerOnly(ctx, t("files.err.owner"));
      hub.files.removeFolder(String(p.id ?? ""), ctx.deviceId ?? ctx.channel);
      return { ok: true };
    case "host.update":
      // check: only look. Otherwise stage the newest release and switch to it as
      // soon as nothing is in flight (the app's 立即更新); `wait` is for the CLI.
      return hub.updater.updateNow({ check: !!p.check, now: ctx.local && !!p.now, wait: ctx.local && !!p.wait });
    default:
      if (ctx.local && admin && req.method) return await admin(req.method, p);
      throw new Error(`unknown method: ${req.method}`);
  }
}

// The owner's own paired devices and the local socket; an Ally's host never
// reaches these methods, and anything else without a device is refused.
function ownerOnly(ctx: RpcContext, why = t("rpc.err.ownerManage")): void {
  if (!ctx.local && !ctx.deviceId) throw new Error(why);
}

// The media ids a chat.send or pals.send carries, as attachments (at most 10).
function attachmentsOf(hub: Hub, ids: unknown): Attachment[] {
  return (Array.isArray(ids) ? ids : []).slice(0, 10).map((id: unknown) => {
    const a = hub.media.attachment(String(id));
    if (!a) throw new Error(t("rpc.err.attachment"));
    return a;
  });
}

// serve runs one request and shapes the response envelope.
export async function serveRpc(hub: Hub, req: RpcRequest, ctx: RpcContext, admin?: AdminHandler): Promise<unknown> {
  try {
    const result = await handleRpc(hub, req, ctx, admin);
    return { id: req.id, result: result ?? null };
  } catch (e) {
    return { id: req.id, error: { message: e instanceof Error ? e.message : String(e) } };
  }
}
