import type { Hub } from "./hub.ts";
import type { Channel } from "./types.ts";
import { readJson, writeJson } from "./util.ts";

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

// Admin methods are reachable only on the local unix socket (the owner's own
// machine), never through the relay.
export type AdminHandler = (method: string, params: any) => Promise<unknown> | unknown;

export async function handleRpc(hub: Hub, req: RpcRequest, ctx: RpcContext, admin?: AdminHandler): Promise<unknown> {
  const p = req.params ?? {};
  switch (req.method) {
    case "hello":
      return { hostName: hub.config.hostName, version: hub.status().version, status: hub.status() };
    case "sync": {
      const since = typeof p.sinceSeq === "number" ? p.sinceSeq : undefined;
      return {
        seq: hub.chat.lastSeq,
        messages: since === undefined ? hub.chat.recent(100) : hub.chat.since(since, 500),
        tasks: hub.tasks.list(),
        approvals: hub.approvals.list(),
        watches: hub.watches.list(),
        artifacts: hub.artifacts.list(),
        settings: hub.config.settings,
        status: hub.status(),
      };
    }
    case "chat.send": {
      const cid = typeof p.clientMsgId === "string" ? p.clientMsgId.slice(0, 100) : undefined;
      // A retried send (the first one did arrive) must not run twice.
      const dup = cid ? hub.chat.findByClientMsgId(cid) : undefined;
      if (dup) return { id: dup.id, seq: dup.seq };
      const msg = hub.userMessage(String(p.text ?? ""), ctx.channel, undefined, cid);
      if (!msg) throw new Error("空消息");
      return { id: msg.id, seq: msg.seq };
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
    case "task.get": {
      const task = hub.tasks.get(String(p.id));
      if (!task) throw new Error("没有这个任务");
      return { task, activity: hub.tasks.activity(task.id) };
    }
    case "task.stop": {
      const t = await hub.stopTask(String(p.id));
      return { ok: !!t };
    }
    case "approval.answer": {
      const a = hub.approvals.answer(String(p.id), !!p.allow, ctx.channel, !!p.remember);
      if (!a) throw new Error("没有这个确认请求");
      return { status: a.status };
    }
    case "approval.rules":
      return { rules: hub.approvals.listRules() };
    case "approval.removeRule":
      return { ok: hub.approvals.removeRule(String(p.id)) };
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
        throw new Error("这个文件刚被助理改过，请重新打开再改");
      hub.memory.write(String(p.path), String(p.content ?? ""));
      hub.audit.log("memory.write", { path: p.path, by: ctx.channel });
      return { ok: true };
    case "settings.update":
      return { settings: hub.updateSettings(p.patch ?? {}) };
    case "kill":
      hub.kill(ctx.channel);
      return { status: hub.status() };
    case "resume":
      hub.resume(ctx.channel);
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
      if (!ctx.deviceId) throw new Error("这个连接不是配对设备");
      hub.audit.log("device.unpaired", { deviceId: ctx.deviceId });
      // after replying: removing the device closes this very connection
      setTimeout(() => hub.onUnpairDevice?.(ctx.deviceId!), 100);
      return { ok: true };
    case "audit.tail":
      return { entries: hub.audit.tail(Math.min(Number(p.limit ?? 50), 500)) };
    default:
      if (ctx.local && admin && req.method) return await admin(req.method, p);
      throw new Error(`unknown method: ${req.method}`);
  }
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
