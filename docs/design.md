# PaloAlly · 实现设计（对应 PRD v2）

本文是 `paloally-prd-v2.md` 的工程落地。PRD 说「做什么」，本文说「怎么做」，以及 host ↔ 客户端的线协议（两端以此为准）。

## 1. 仓库结构

```
host/        桌面 host = 一个 CLI 程序（Bun + TypeScript），daemon + onboarding
  src/
    cli.ts              入口：paloally <command>
    config.ts           ~/.paloally 布局、config.json
    home.ts             home 目录模板（CLAUDE.md / user.md / soul.md / artifacts / watches）
    hub.ts              中枢：把各通道、harness、任务、审批、探针串起来
    harness/            驱动层（ACP 形状接口，V1 只有 Claude Code 实现 + 测试用 fake）
    tasks.ts            任务只读投影 + report_task
    approvals.ts        审批、细粒度 auto 规则、不可逆闸
    audit.ts            审计日志
    probe.ts            探针调度 + watch 持久化 + 游标去重
    artifacts.ts        artifact 约定与资料库
    memory.ts           核心文件 + 原生 auto memory 的可见/可编辑投影
    chat.ts             主对话存档（History）+ seq + 补发
    router.ts           输出路由（App / CLI / 微信 / 推送）
    channels/           local（unix socket）、relay（E2E）、wechat（iLink）、apns
    proto/              线协议：帧、E2E 握手与封装、RPC 类型
  test/                 bun test
ios/         Apple 原生客户端（SwiftUI，iOS + Mac Catalyst）
  PaloAllyKit/          Swift package：协议模型、加密、relay 传输、状态 store（swift test）
  App/                  SwiftUI app（xcodegen project.yml）
relay/       不新写：复用 ~/code/bento/relay（bento-relay-acp，relay.bentoai.dev）
```

## 2. 进程模型

`paloally start` 前台跑 daemon（`paloally service install` 装成 launchd/systemd 常驻）。daemon 内：

- **一个主会话**：Claude Agent SDK `query()`，streaming input（AsyncIterable），常驻；所有通道的用户消息排进同一个输入队列。session id 持久化，进程重启 `resume`。
- **idle 处理**：空闲 `session.idleCloseMinutes` 后关掉 CLI 子进程（省资源），下条消息 `resume` 同一会话。`session.rollAfterTokens > 0` 时，空闲且上下文超阈值则先发一轮 flush（「把要紧的写进记忆」）再换新会话。Phase 0 默认不滚动，只记录压缩事件（`compact_boundary`）用于 §12.3 评估。
- **探针**：独立短上下文 `query()`（便宜模型、`persistSession:false`、结构化输出），只在有 watch 到期时才跑；没到期的 tick 零调用。
- **本地控制面**：`~/.paloally/run/host.sock`（unix socket，行分隔 JSON，同一套 RPC），CLI 子命令通过它和 daemon 说话。

## 3. 外壳给主 agent 的工具（in-process MCP server `paloally`）

| 工具 | 作用 |
|---|---|
| `report_task(id, summary, status, title?)` | 任务列表权威来源；驱动列表 / 主对话「收到」「结果」/ 完成推送 |
| `register_watch(title, instruction, interval_minutes? , at?, kind?)` | 自注册 watch，外壳持久化 |
| `list_watches()` / `remove_watch(id)` | |
| `publish_artifact(slug, title, main_file, type?, pinned?)` | 登记/更新 artifact 元数据 |
| `notify_user(text, urgent?)` | 主动推送（经路由器：App 推送；微信只发非敏感回执） |

## 4. 安全

- `canUseTool` → 审批卡片（多端先答先得，超时默认拒绝）。
- `PreToolUse` hook：kill 状态下一律 deny；不可逆/对外动作（发送、付款、删除、push、对外 POST…）强制 `ask`，即使 auto 规则或 CC 自身规则允许也不放行。
- auto 规则：`{tool, scope}`，scope 必须是域名 / 收件人 / 路径前缀 / 命令前缀之一，拒绝 `*` 和空 scope（不允许整类放行）；不可逆动作不可进 auto。
- 审计：`~/.paloally/audit/YYYY-MM-DD.jsonl`，记录每次工具调用（Pre/Post）、审批决定、对外消息、kill/resume。
- kill switch：中断主会话、停所有任务、暂停探针、拒绝一切工具调用，直到 `resume`。持久化，重启后仍生效。
- 浏览器（可选）：注入 Playwright MCP + 专属 profile；`sensitiveDomains` 里的域名一律拒绝导航。

## 5. 线协议（host ↔ 客户端）

### 5.1 传输

- **远程**：复用 bento relay（默认 `https://relay.bentoai.dev`）。daemon 侧帧格式、配对、Ed25519 挑战均按 `bento/docs/relay-protocol.md`，不改 relay。
  - daemon：`POST /v1/daemon/register`（头 `x-bento-daemon-id`），再 `GET wss /v1/daemon/socket?daemon_id&ts&pubkey&sig&proto=1`，签名消息 `bento-daemon-register:<daemon_id>:<ts>`（pubkey/sig 为 base64url）。
  - 客户端配对：`POST /v1/pair?daemon_id=…` body `{code, device_pubkey, device_label}`；`device_pubkey` 为 SSH wire 格式 base64（`[u32 11]"ssh-ed25519"[u32 32][raw32]`）。成功返回 `{status:"ok", device_id, host_fingerprint, daemon_label}`。
  - 客户端连接：`GET wss /v1/tunnel?daemon_id&device_id&ts&pubkey&sig`，签名消息 `bento-device-attach:<daemon_id>:<device_id>:<ts>`。
  - 配对码由 host 发 control `pair.open` 拿到；host 展示二维码 / 链接：
    `paloally://pair?relay=<url>&daemon=<daemon_id>&code=<6位>&hostkey=<host Ed25519 pub, base64url>`
- **本地**：unix socket，每行一个 JSON（即下面 5.3 的明文消息），无加密。

### 5.2 E2E（每条 relay stream）

每个 WebSocket 消息 = 一个 unit，首字节是类型：

- `0x01` 握手（明文 JSON，UTF-8）
- `0x02` 密文：`ciphertext || tag(16)`，ChaCha20-Poly1305，nonce = 4 个 0 字节 + 8 字节大端计数器（每方向从 0 开始，每发一条 +1），AAD 为空。

握手：

1. 客户端 → `0x01 {"t":"hello","v":1,"device_id":"…","eph":"<X25519 公钥 b64>","sig":"<b64>"}`，sig = Ed25519(设备私钥, `"paloally-hs1|c|" + eph_c_raw`)。
2. host 用配对时存下的设备公钥验签，回 `0x01 {"t":"welcome","v":1,"eph":"<b64>","sig":"<b64>"}`，sig = Ed25519(host 私钥, `"paloally-hs1|h|" + eph_c_raw + eph_h_raw`)。客户端用配对时拿到的 hostkey 验签。失败则 `0x01 {"t":"error","error":"…"}` 并关闭。
3. `shared = X25519(eph)`；`k_c2h = HKDF-SHA256(ikm=shared, salt=eph_c_raw‖eph_h_raw, info="paloally c2h", 32)`，`k_h2c` 同理 info=`"paloally h2c"`。

（签名串里的 `"paloally-hs1|c|"` 是 UTF-8 字节，后接原始 32 字节公钥。b64 为标准 base64。）

### 5.3 应用消息（密文 unit 的明文 / 本地 socket 的一行）

请求 `{"id":<number>,"method":"…","params":{…}}` → 响应 `{"id":<number>,"result":…}` 或 `{"id":<number>,"error":{"message":"…"}}`；事件 `{"event":"…","data":…}`。

**模型**

```ts
ChatMessage { seq:number; id:string; role:"user"|"assistant"|"system";
  kind:"text"|"task"|"approval"|"notice"; text:string;
  channel:"app"|"cli"|"wechat"|"probe"|"schedule"|"system"; ts:number /*ms*/;
  proactive?:boolean; taskId?:string; approvalId?:string }
Task { id; title; summary; status:"running"|"done"|"failed"|"needs_input"|"stopped";
  source:"auto"|"report"; createdAt; updatedAt; activityCount:number }
TaskActivity { ts; kind:"tool_use"|"tool_result"|"text"; tool?:string; text:string }
Approval { id; tool; title; detail; taskId?; irreversible:boolean;
  status:"pending"|"allowed"|"denied"|"expired"; createdAt; decidedAt?; decidedBy?;
  suggestedScope?:string }
Watch { id; title; kind:"check"|"schedule"; instruction; intervalMinutes?:number;
  at?:string[] /*"HH:MM" 本地时区*/; enabled:boolean; createdBy:"agent"|"user";
  lastCheckedAt?; lastTriggeredAt?; skipIfActiveMinutes?:number }
Artifact { id; title; type; mainFile; pinned:boolean; updatedAt;
  files:{path:string; size:number}[] }
Settings { timezone; quietHours:{start:"HH:MM"; end:"HH:MM"}|null;
  maxProactivePerDay:number; probeIntervalMinutes:number; approvalTimeoutMinutes:number }
Status { online:boolean; killed:boolean; busy:boolean; model:string;
  sessionId?:string; wechat:"off"|"connected"|"expired"; version:string }
MemoryFile { path; scope:"core"|"auto"; size; updatedAt }
```

**方法**

| method | params | result |
|---|---|---|
| `hello` | `{client:"ios"\|"mac"\|"cli", version}` | `{hostName, version, status}` |
| `sync` | `{sinceSeq?:number}` | `{seq, messages, tasks, approvals, watches, artifacts, settings, status}`（messages：sinceSeq 之后的，最多 500；无 sinceSeq 时最近 100） |
| `chat.send` | `{text, clientMsgId?}` | `{id, seq}` |
| `chat.history` | `{beforeSeq, limit}` | `{messages}` |
| `task.get` | `{id}` | `{task, activity:TaskActivity[]}` |
| `task.stop` | `{id}` | `{ok}` |
| `approval.answer` | `{id, allow, remember?}` | `{status}` |
| `watch.add` | `Watch` 去掉 id/createdBy | `{watch}` |
| `watch.update` | `{id, patch}` | `{watch}` |
| `watch.remove` | `{id}` | `{ok}` |
| `artifact.list` | `{}` | `{artifacts}` |
| `artifact.read` | `{id, path?, offset?, length?}` | `{data /*b64*/, size, mime, eof}`（每块 ≤ 256 KiB） |
| `artifact.pin` | `{id, pinned}` | `{artifact}` |
| `memory.list` | `{}` | `{files}` |
| `memory.read` | `{path}` | `{content}` |
| `memory.write` | `{path, content}` | `{ok}` |
| `settings.update` | `{patch}` | `{settings}` |
| `kill` / `resume` | `{}` | `{status}` |
| `push.register` | `{token, env:"sandbox"\|"production"}` | `{ok}` |
| `audit.tail` | `{limit}` | `{entries}` |

**事件**：`chat.message`（ChatMessage）、`chat.delta`（`{id, text}` 追加文本，最终以同 id 的 `chat.message` 收尾）、`task.updated`（Task）、`approval.updated`（Approval）、`watch.updated`（`{watch}` 或 `{removed:id}`）、`artifact.updated`（Artifact）、`settings.updated`、`status`（Status）。

## 6. 路由规则

- 所有主对话消息进 History（`state/chat.jsonl`，带 seq），广播给所有已连接的 App/CLI 客户端；客户端断线重连用 `sync{sinceSeq}` 补齐。
- 来自微信的一轮，回复也回微信（受 iLink 限制：每轮主动 ≤10 条，≤5 条/秒，context_token 24h 失效）。
- 主动消息（探针 / 定时 / notify_user / 任务完成 / 待审批）：推 APNs（若配置）；微信只发不含正文的提示（`settings.wechatProactive = "hint"`，可改 `"full"`/`"off"`）。
- 免打扰时段内的非 urgent 主动消息不推送，只进主对话；超过 `maxProactivePerDay` 同理。
- host 掉线：启动时若距上次心跳 > 2×tick，主对话发「我掉线过」通知，并对错过的定时 watch 补跑一次。
