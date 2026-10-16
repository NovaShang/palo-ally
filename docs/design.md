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
    approvals.ts        转达 harness 的确认请求（不自己做判断）
    audit.ts            外壳自己的事件日志（确认决定、推送、重启、停下）
    probe.ts            探针调度 + watch 持久化 + 游标去重
    artifacts.ts        artifact 约定与资料库
    memory.ts           核心文件 + 原生 auto memory 的可见/可编辑投影
    chat.ts             主对话存档（History）+ seq + 补发
    router.ts           输出路由（App / CLI / 微信 / 推送）
    allies.ts           Allies：和别人的助理传话、约时间，配对、档位、待发队列、回执（docs/allies-prd.md）
    allyGate.ts         处理 Ally 来话那一轮的工具白名单（「只说话不动手」，allies-prd §11.5）
    pals.ts             Pal（docs/pals-prd.md）：主机自己跑的 Claude Code 会话；接管、交还终端、移出、Palo 开 Pal、最多 50 个、同时醒着最多 5 个（闲了睡下，有事叫醒；state/pals.json）
    palSession.ts       一个 Pal：resume 它的记录跑起来、主人的话、流式回复、确认和提问、意外退出后自动接上、绝不两个进程写同一份记录
    palHistory.ts       Pal 的对话记录 → ChatMessage；跟着记录读别的会话发进来的话
    palLauncher.ts      Pal 的进程经 PaloAlly 小助手启动（找不到就直接启动），用主人登录 shell 的环境
    palRecent.ts        最近退出了的对话（pals-prd §10）：SDK 的 listSessions，跟 /resume 一样不列 claude -p 和 SDK 应用的会话，不列 PaloAlly 自己的目录
    sessions.ts         电脑上其他 Claude Code 会话（docs/sessions-prd.md）：列表、对话记录、不在电脑前时确认送到手机
    ccSessions.ts       读 Claude Code 的登记表 / claude agents / 对话记录，合成会话列表
    ccHooks.ts          全局钩子：安装 / 卸载、钩子脚本（~/.paloally/bin/cc-hook）、主机这头的 run/hooks.sock
    ccCli.ts            claude 命令行（agents --json、stop），用主人登录 shell 的环境
    ccSpend.ts          一个会话每天花了多少（从对话记录里的 usage 算）
    away.ts             主人在不在电脑前（锁屏或键鼠空闲 3 分钟）
    channels/           local（unix socket）、relay（E2E + 经 relay 推送）、allyLink（作为客户端连别人的主机）、wechat（iLink）、apns（直推回退）
    proto/              线协议：帧、E2E 握手与封装、RPC 类型、主机之间的 ally.* 消息
  helper/               PaloAlly 小助手（PaloAlly Helper.app）：Swift 源码 + build.sh（构建并用 Developer ID 签名；签好的 app 不进仓库）
  test/                 bun test
ios/         Apple 原生客户端（SwiftUI，iOS + Mac Catalyst）
  PaloAllyKit/          Swift package：协议模型、加密、relay 传输、状态 store（swift test）
  App/                  SwiftUI app（xcodegen project.yml）
relay/       不新写：复用 github.com/NovaShang/bento 的 relay/（bento-relay-acp，relay.bentoai.dev）
```

## 2. 进程模型

`paloally start` 前台跑 daemon（`paloally service install` 装成 launchd/systemd 常驻）。daemon 内：

- **一个主会话**：Claude Agent SDK `query()`，streaming input（AsyncIterable），常驻；所有通道的用户消息排进同一个输入队列。session id 持久化，进程重启 `resume`。会话名固定为 `Palo`（`--name`），Pal 用 SendMessage 回它就发给这个名字。
- **idle 处理**：空闲 `session.idleCloseMinutes` 后关掉 CLI 子进程（省资源），下条消息 `resume` 同一会话。上下文与压缩交给 harness；外壳只记录压缩事件（`compact_boundary`）用于 §12.3 评估。
- **探针**：独立短上下文 `query()`（便宜模型、`persistSession:false`、结构化输出），只在有 watch 到期时才跑；没到期的 tick 零调用。
- **本地控制面**：`~/.paloally/run/host.sock`（unix socket，行分隔 JSON，同一套 RPC），CLI 子命令通过它和 daemon 说话。
- **会话钩子**（docs/sessions-prd.md §6.3）：`~/.paloally/run/hooks.sock`。全局钩子跑 `~/.paloally/bin/cc-hook <事件名> # PaloAlly`（行尾的注释是 PaloAlly 条目的记号，卸载只删带它的）：主机没在跑（没有 socket）时直接退出；否则写一行 `{event, payload, env}`，主机立刻回 `{"ack":true}`，再回 `{"output": <钩子要打印的 JSON 或 null>}`。350 毫秒内没有 ack、连不上、出任何错，钩子都无输出退出。`PALOALLY_SESSION=1`（主机自己起的会话：主会话、探针、Pal）直接退出。
- **Pal**（docs/pals-prd.md §7）：每个 Pal 一个 SDK `query()`（streaming input，`resume` 它的记录；Palo 新开的用 `sessionId` 指定 id），常驻不关，会话名就是列表里的名字（`--name`），没有 PaloAlly 的工具，系统提示末尾加一句它由 PaloAlly 托管。进程经 PaloAlly 小助手启动（`spawnClaudeCodeProcess`）：主机起小助手 → 小助手以 `responsibility_spawnattrs_setdisclaim` 再起一份自己 → 那一份起 claude，标准输入输出一路继承；fd 3 上报 claude 的 pid。环境用主人登录 shell 的（去掉会话变量）。确认和提问走 `canUseTool`，成了带 `source: {kind:"pal"}` 的卡片。别的会话发进来的话只在记录里，主机跟着记录读出来。意外退出后按 2/5/15/30/60 秒重试，10 分钟内失败超过 5 次就停下并说明原因；主机启动时把醒着的 Pal 逐个接回来（睡着的保持睡着）。睡下和叫醒（pals-prd §12）：空闲 20 分钟（没有在跑的一轮、没有没收下的话、没有等主人的卡片、没有没结束的工具或后台任务）的 Pal 睡下：进程正常关掉，记录留着、标成 `status:"asleep"`；醒着的超过 5 个时，最久没用的空闲那个先睡；在忙或在等主人的从不睡，6 个都忙就暂时超出。主人的话、`pals.wake`、答它的卡片、Palo 的 `pal_send` 都会先 resume 同一个会话再送话，叫醒期间来的话排队，醒了按顺序送进去。叫醒后第一轮的花费（result 的 `total_cost_usd` 减去上一次的累计）记成 `lastWakeUsd`。看门狗只看醒着的。名字（pals-prd §13）：跟着 Claude Code 给这个会话的标题走，每轮结束后和每次启动前用 `getSessionInfo` 读一次（只读记录的头尾），自定义标题变了就改名；读不到自定义标题时名字不动，除非它进程的登记项（`nameSource:"user"`）说它改了名。重名加「 2」。`pals.rename` 让 Claude Code 也改：跑着的用进程里的 `rename_session` 控制请求（跟 IDE 里改名一样），没进程的用 SDK 的 `renameSession` 写进记录。进程的会话名（别的会话 SendMessage 用的）启动时定，改名后下次启动才换；Palo 给 Pal 发话只用 `pal_send`（按 id、现在的名字或以前的名字找）。绝不两个进程写同一份记录：启动前查登记表和 `claude agents`，有别的进程拿着就不启动（主机上次留下的孤儿进程先停掉）；跑着时每 5 秒查一次，别处打开了就立刻让开。Pal 开着 Claude Code 的文件快照（`enableFileCheckpointing`）。主人发给 Pal 的图片和文件（pals-prd §15）：图片是图片块；文件硬链接（不行就复制）到 Pal 目录的 `.paloally/inbox/<媒体 id>/<文件名>`（工作目录里，读它不用确认；`.paloally/.gitignore` 是 `*`），话里加「[文件] 路径」；发出时的文字和附件按消息 uuid 记在 `state/media/sent/<uuid>.json`，`pals.history` 照原样给回去。
- **回到这里重来**（docs/rewind-prd.md，`rewind.ts`）：Palo 和 Pal 都分叉成新会话，原会话的记录不动。分叉点是主人那条消息在记录里的上一条（`parentUuid`，压缩边界跨过去用 `logicalParentUuid`）。分叉点在最近一次压缩之后：下次启动用 `resume` + `forkSession` + 指定新 `sessionId` + `resumeSessionAt`，Claude Code 到第一条消息才写新记录，在那之前「待分叉」记在 runtime.json / Pal 的记录（`rewind: {from, at, cut}`），每次启动照它分叉；在压缩之前：SDK 的 `forkSession` 立刻抄一份（新 uuid），之后照常 resume。Pal 恢复代码：先停掉它，在原会话上起一个不说话的进程调 `rewindFiles`，再分叉。Palo 撤回的消息在 chat.jsonl 标 `rewound`（占一个 seq，不再给客户端）；Pal 的对话在新记录出现前从原会话读到分叉点。Pal 以前的会话记在 `formerSessions`，不出现在「最近的对话」里。
## 3. 外壳给主 agent 的工具（in-process MCP server `paloally`）

| 工具 | 作用 |
|---|---|
| `report_task(id, summary, status, title?)` | 任务列表权威来源；驱动列表 / 主对话「收到」「结果」/ 完成推送 |
| `register_watch(title, instruction, interval_minutes? , at?, kind?)` | 自注册 watch，外壳持久化 |
| `list_watches()` / `remove_watch(id)` | |
| `SendUserFile(files, caption?, status, display?, temporary?)` | 照 Claude Code 原生 SendUserFile 定义（多一个 `temporary`）：文件在对话里显示成卡片（图片直接显示），默认同时进产出物库；`status: proactive` 推送；主人在微信上时也发到微信 |
| `Artifact(file_path, title?, description?, files?)` | 照 Claude Code 原生 Artifact 发布：要长期留存的页面/文档进产出物库并在对话里出卡片；同一路径再发布 = 更新 |
| `notify_user(text, urgent?)` | 主动推送（经路由器：App 推送；微信只发非敏感回执） |
| `ally_list()` | Ally 列表：id、对方主人的称呼、助理名、标签、档位（能对话 / 每句要你看）、是否在线 |
| `ally_send(to, text, urgent?, slots?, replyTo?)` | 给「能对话」的 Ally 直接发出；给「每句要你看」的只生成草稿卡片，主人点「发送」（`ally.draft.decide`）才进待发队列。聊天里都是 `kind:"ally"`、`dir:"out"`、`role:"assistant"`。处理某个 Ally 来话的那一轮里，只有回给它的话能直接发出，给别的 Ally 的一律是草稿 |
| `pals_list()` | 主人的 Pal（id、现在的名字、目录、状态（asleep 是睡着了）、最后一句）和电脑上其他会话；跟 Pal 说话用 `pal_send` |
| `pal_send(name, text)` | 给一个 Pal 发话（Palo 给 Pal 发话只用它，不用 SendMessage），醒着睡着都行：睡着的先叫醒（同一个会话 resume），再把话送进去。`name` 是 Pal 的 id、现在的名字或以前的名字（改名以后也找得到，不重启它）。Pal 对话里显示为「Palo 说」（`from` = 助理的名字），Pal 那边读到的是来自 `Palo` 会话的 SendMessage，回话照旧用 SendMessage 发给 Palo。处理 Ally 来话的那一轮里不许用 |
| `pal_propose(name, dir, duty, dailyUsd)` | 只生成提议卡片（聊天里 `kind:"helper"`），立即返回；主人点「开吧」（`helper.decide`）才开，交接说明是 Pal 的第一条消息 |
| `pals_recent(folder?)` | 最近 30 天里退出了的对话（同 `pals.recent`，最多 30 条）：sessionId、目录、标题、最后活动时间；folder 是路径或目录名 |
| `pal_adopt(sessionId)` | 只生成接管卡片「接管『标题』（目录）」（聊天里 `kind:"pal_adopt"`），立即返回；主人点「接管」（`helper.decide`）才接。正开着的、已经是 Pal 的、PaloAlly 自己的不出卡片 |

## 4. 安全（全部依赖 harness）

- 判断哪些操作能做、哪些要问：Claude Code 的 `auto` 模式和它自己的权限规则。外壳没有自己的规则或分类器，只有一道闸门，见下一条。
- 例外：处理 Ally 来话的那一轮（从来话交给 harness，到 harness 的某个 result 的 `user_message_uuids` 列出它为止），外壳只放行 `allyGate.ts` 的白名单：`ally_send` / `ally_list`、只读日历（按名字判断）、只读记忆（user.md、soul.md、自动记忆文件夹）、`AskUserQuestion`、`ToolSearch`。闸门是主会话的 PreToolUse 钩子（SDK 回调）：Claude Code 每次调工具都先问它，在 auto 模式和允许规则之前，说拒绝就拒绝；`canUseTool` 里再查一遍。每次拒绝记审计 `ally.tool.denied`。这期间主人的话留在外壳，那一轮结束后作为主人的一轮再交给 harness；别的主动轮次也等着。子 agent 的调用（`agent_id`）不受这道闸门管。
- `canUseTool` → 审批卡片，转到 App / 微信 / 终端，多端先答先得，超时默认拒绝。卡片标「做了撤不回」= harness 给的 `defaultToNo`；「以后都允许」= 原样交回 harness 的 `suggestions`（`updatedPermissions`），规则存在 Claude Code 自己的设置里。
- 停下：harness 的 `interrupt()` + `stopTask()`；卡死的轮次直接结束、换新进程（resume 同一会话），不留阻塞状态。
- 探针：`permissionMode: "auto"` + `permissionPrompts: "none"`，只加载读类工具（为了上下文短，不是安全名单）。
- 审计：工具调用以 harness 的会话记录为准；外壳只记自己的事件（确认决定、推送、重启、Ally 那一轮被拒的工具）。

## 5. 线协议（host ↔ 客户端）

### 5.1 传输

- **远程**：复用 bento relay（默认 `https://relay.bentoai.dev`）。daemon 侧帧格式、配对、Ed25519 挑战均按 `bento/docs/relay-protocol.md`，不改 relay。
  - daemon：`POST /v1/daemon/register`（头 `x-bento-daemon-id`），再 `GET wss /v1/daemon/socket?daemon_id&ts&pubkey&sig&proto=1`，签名消息 `bento-daemon-register:<daemon_id>:<ts>`（pubkey/sig 为 base64url）。
  - 客户端配对：`POST /v1/pair?daemon_id=…` body `{code, device_pubkey, device_label}`；`device_pubkey` 为 SSH wire 格式 base64（`[u32 11]"ssh-ed25519"[u32 32][raw32]`）。成功返回 `{status:"ok", device_id, host_fingerprint, daemon_label}`。
  - 客户端连接：`GET wss /v1/tunnel?daemon_id&device_id&ts&pubkey&sig`，签名消息 `bento-device-attach:<daemon_id>:<device_id>:<ts>`。
  - 配对码由 host 发 control `pair.open` 拿到；host 展示二维码 / 链接：
    `paloally://pair?relay=<url>&daemon=<daemon_id>&code=<6位>&hostkey=<host Ed25519 pub, base64url>`
- **本地**：unix socket，每行一个 JSON（即下面 5.3 的明文消息），无加密。
- **多台电脑（客户端侧）**：一个客户端可以配对多台 host（PRD §6.9）。Keychain 里存 `paired-hosts`（`PairedHost` 的 JSON 数组，按主人排序；旧版单个 `paired-host` 首次加载时迁移进去）。每台 host 一条独立的 relay tunnel + 一个 `AppStore`；前台时全部连接，当前那台渲染界面，其余的只用来算未读（本地记每台的 `lastSeenSeq`，首次同步时以当时的 seq 为基线）和待确认数。名字、颜色、已读位置、当前是哪台存在 UserDefaults（`hostMeta`，演示模式用 `hostMeta.demo`）。设备身份全局一把；每台 host 在配对时各自分配 `device_id`。推送 payload 带 `hostId`（= host 的 daemon id），客户端据此切换。

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

**模型**（以 `host/src/types.ts` 为准；样例由 `host/test/protocol.test.ts` 生成到 `ios/PaloAllyKit/Tests/PaloAllyKitTests/Fixtures/protocol.json`，Swift 端严格解码）

```ts
ChatMessage { seq:number; id:string; role:"user"|"assistant"|"system";
  kind:"text"|"task"|"approval"|"question"|"notice"|"clipboard"|"ally"|"helper"|"pal_adopt"; text:string;
  channel:"app"|"cli"|"wechat"|"probe"|"schedule"|"system"; ts:number /*ms*/;
  proactive?:boolean; taskId?:string; approvalId?:string;
  clientMsgId?:string /* chat.send 带来的会原样回显 */;
  allyId?:string; allyName?:string; dir?:"in"|"out"; entryId?:string; author?:"owner"|"assistant"
  /* kind "ally"：收到的话 role "system"（author 是对方本人或对方的助理）；助理发出的 role "assistant"
     （草稿卡片，或「能对话」时直接发出）；主人自己说的（ally.say）role "user"、channel "system"；
     最新文字和状态看 entry */;
  proposal?:HelperProposal|PalAdoptProposal
  /* kind "helper"：Palo 提议开 Pal（HelperProposal）；kind "pal_adopt"：Palo 提议接管一个退出了的对话
     （PalAdoptProposal）。状态变了，同一条消息（同 id、同 seq）再发一次 chat.message */;
  pal?:string /* 属于哪个 Pal 的对话（Pal.id）；没有 = Palo 的。Pal 的消息不进 Palo 的对话，seq = 毫秒时间 */;
  from?:string /* Pal 对话里不是主人说的 user 消息：助理的名字（Palo 的话）或别的会话的名字 */;
  uuid?:string /* Palo 对话里主人的消息在 Claude Code 记录里的 uuid；有它才能「回到这里重来」（docs/rewind-prd.md） */ }
HelperProposal { id /* helper.decide 的 proposalId */; name; cwd; duty; dailyUsd:number;
  status:"pending"|"created"|"discarded"|"expired"; sessionId? /* 开了以后 */; palId?; note? }
PalAdoptProposal { id /* helper.decide 的 proposalId */; sessionId; cwd; title;
  status:"pending"|"adopted"|"discarded"|"failed"; palId? /* 接管了以后 */; note? /* failed 的原因 */ }
RecentSession { sessionId; cwd; title /* 自定义标题，否则 Claude Code 的摘要，否则第一句话的前 40 个字 */;
  lastModified:number /*ms*/; size:number /* 记录的字节数 */ }
Pal { id /* pal_… */; name /* SendMessage 用的名字 */; cwd; sessionId;
  status:"busy"|"idle"|"waiting"|"starting"|"stopped"|"asleep" /* asleep：睡着了，没有进程 */; activity?; note? /* stopped 的原因 */;
  lastLine?; pending:number; model?; lastWakeUsd? /* 上次叫醒后第一轮花了多少（美元） */; createdBy:"owner"|"palo"; updatedAt }
CCSession { id /* Claude Code 的 session id */; name; cwd; kind:"terminal"|"background" /* "helper" 不再出现 */;
  status:"busy"|"idle"|"waiting"|"stopped"; waitingFor?; lastLine?; contextTokens?:number; updatedAt;
  adopting?:boolean /* pals.adopt 在等它在终端里退出 */ }
CCMessage { id; ts; role:"owner"|"assistant"|"peer"|"palo"; text; from?
  /* owner：主人在电脑上打的字；palo：助理（会话名 Palo）用 SendMessage 发来的，from 为助理的名字；
     peer：别的会话发来的，from 为它的名字 */ }
CardSource { kind:"session"|"pal"; id /* CCSession.id 或 Pal.id */; name }
AllyInfo { id; kind:"family"|"mine"; ownerName; assistantName; online:boolean;
  lastSeen:number /*0 = 没联系上过*/; lastEntry?:AllyEntry;
  trust:"converse"|"review" /* 你的助理怎么回对方：能对话 / 每句要你看 */;
  theirTrust?:"converse"|"review" /* 对方的助理怎么回你；对方是第一版主机时没有 */ }
AllyEntry { id; allyId; dir:"in"|"out"; ts; text; urgent:boolean;
  slots?:{start:string; end:string}[] /*ISO 8601 带时区*/; replyTo?:string;
  status:"draft"|"queued"|"sent"|"delivered"|"seen"|"rejected"; note?:string /*rejected 的原因*/;
  author:"owner"|"assistant" /* 发出的：主人自己 / 助理代说；收到的：对方本人 / 对方的助理 */ }
Task { id; title; summary; status:"running"|"done"|"failed"|"needs_input"|"stopped";
  source:"auto"|"report"; createdAt; updatedAt; activityCount:number }
TaskActivity { ts; kind:"tool_use"|"tool_result"|"text"; tool?:string; text:string }
Approval { id; tool; title; detail; taskId?;
  careful:boolean /* harness 标了 defaultToNo */;
  status:"pending"|"allowed"|"denied"|"expired"; createdAt; decidedAt?; decidedBy?;
  suggestedScope?:string /* "cmd:…" | "domain:…" | "path:…" | "tool:…"，来自 harness 的建议规则 */;
  source?:CardSource /* 电脑上某个会话要的确认（没有 suggestedScope） */;
  note?:string /* 会话的卡片没等到回答就结束时："在电脑上等你"（钩子超时，会话回到终端里问）
                  或 "已在电脑上处理"（在电脑上答掉了 / 会话接着干了）；两种都是 status "expired" */ }
Question 同样有 source? 和 note?。会话的卡片不进聊天记录（没有对应的 ChatMessage），App 放在对话末尾。
Watch { id; title; kind:"check"|"schedule"; instruction; intervalMinutes?:number;
  at?:string[] /*"HH:MM" 本地时区*/; enabled:boolean; createdBy:"agent"|"user";
  lastCheckedAt?; lastTriggeredAt?; skipIfActiveMinutes?:number }
Artifact { id; title; type; mainFile; pinned:boolean; updatedAt;
  files:{path:string; size:number}[] }
Settings { timezone; quietHours:{start:"HH:MM"; end:"HH:MM"}|null;
  maxProactivePerDay:number; probeIntervalMinutes:number; approvalTimeoutMinutes:number;
  wechatProactive:"off"|"hint"|"full" }
PairedDevice { deviceId; label; platform?:"ios"|"mac" /* 那台设备的 App 在 hello 里说的 */; pairedAt:number;
  lastSeen?:number; online:boolean /* 现在连着 */; current:boolean /* 就是发起调用的这台 */ }
Status { online:boolean; busy:boolean; activity?:string /* 忙时在干嘛 */;
  model:string; effort?:string; sessionId?:string;
  wechat:"off"|"connected"|"expired"; version:string }
MemoryFile { path; scope:"core"|"auto"; size; updatedAt }
SlashCommand { name; description; argumentHint? }
ModelOption { value; displayName; description; efforts:string[] }
```

**方法**（`RPC_METHODS` in `host/src/rpc.ts`）

| method | params | result |
|---|---|---|
| `hello` | `{client:"ios"\|"mac"\|"cli", version}` | `{hostName, version, status}` |
| `sync` | `{sinceSeq?:number}` | `{seq, messages, tasks, approvals, watches, artifacts, settings, status, streaming?, rewound?}`（rewound：sinceSeq 之后撤回的消息 id，客户端拿掉；messages：sinceSeq 之后的，最多 500；无 sinceSeq 时最近 100。streaming：正在写的回复 `{id, text}`，text 是到目前为止的全文，替换客户端手里同 id 的内容，之后的 chat.delta 接着追加） |
| `chat.send` | `{text, clientMsgId?, attachments?, replyTo?}` | `{id, seq}`（同一 clientMsgId 重发只执行一次，返回原来的；attachments 是 `media.upload` / `media.uploadChunk` 给的 id，最多 10 个） |
| `chat.history` | `{beforeSeq, limit}` | `{messages}` |
| `chat.rewind` | `{messageId}` | `{text}`（回到主人这条消息之前：这条和之后的撤回，文字给输入框；正在忙时报错「它还在忙，先停下再重来」。docs/rewind-prd.md） |
| `commands.list` | `{}` | `{commands:SlashCommand[]}` |
| `model.get` | `{}` | `{model, setting, effort, models:ModelOption[]}` |
| `model.set` | `{model?:string\|null, effort?:string\|null}` | `{status}` |
| `task.get` | `{id}` | `{task, activity:TaskActivity[]}` |
| `task.stop` | `{id}` | `{ok}` |
| `approval.answer` | `{id, allow, remember?}` | `{status}`（remember = 把 harness 的建议规则交回给它） |
| `watch.add` | `Watch` 去掉 id/createdBy | `{watch}` |
| `watch.update` | `{id, patch}` | `{watch}` |
| `watch.remove` | `{id}` | `{ok}` |
| `artifact.list` | `{}` | `{artifacts}` |
| `artifact.read` | `{id, path?, offset?, length?}` | `{data /*b64*/, size, mime, eof}`（每块 ≤ 256 KiB） |
| `artifact.pin` | `{id, pinned}` | `{artifact}` |
| `memory.list` | `{}` | `{files, coreSize}` |
| `memory.read` | `{path}` | `{content, updatedAt}` |
| `memory.write` | `{path, content, baseUpdatedAt?}` | `{ok, updatedAt}`（文件在 baseUpdatedAt 之后被改过则报错「这个文件刚被助理改过，请重新打开再改」） |
| `settings.update` | `{patch}` | `{settings}` |
| `stop` | `{}` | `{status}`（harness 的 interrupt + stopTask；不留阻塞状态） |
| `push.register` / `push.unregister` | `{token, env?}` / `{token}` | `{ok}` |
| `device.unpair` | `{}` | `{ok}`（移除发起调用的这台设备） |
| `device.list` | `{}` | `{devices:PairedDevice[]}`（这台电脑配对过的主人的设备，发起调用的这台在最前、`current: true`；只给主人自己的设备和本机命令行。docs/devices-prd.md） |
| `device.remove` | `{deviceId}` | `{ok}`（断开另一台设备、让 relay 忘掉它，记审计 `device.removed`；不能是发起调用的这台（用 `device.unpair`）） |
| `audit.tail` | `{limit}` | `{entries}` |
| `ally.list` | `{}` | `{allies:AllyInfo[]}` |
| `ally.invite` | `{}` | `{link, expiresAt}`（`paloally://ally?relay&daemon&code&hostkey&name&exp`，10 分钟，一次性；App 画成二维码） |
| `ally.accept` | `{link, kind:"family"\|"mine", trust?:"converse"\|"review"}` | `{ally:AllyInfo}`（两段配对都完成才返回，通常几秒；不带 trust 是 review。邀请方那边新 Ally 一律先是 review） |
| `ally.remove` | `{id}` | `{ok}`（发 `ally.bye`，中继忘掉对方设备，记录保留） |
| `ally.log` | `{id, beforeTs?, limit?}` | `{entries:AllyEntry[]}`（从旧到新，默认 50 条，最多 200） |
| `ally.draft.decide` | `{id, action:"send"\|"edit"\|"discard", text?}` | `{entry}`（send 带 text 就发改过的；edit 只改文字；discard 记为 rejected「没发」） |
| `ally.say` | `{id, text}` | `{entry}`（主人自己的话，author "owner"，不经卡片直接进待发队列；也算主人「已看到」） |
| `ally.trust` | `{id, trust:"converse"\|"review"}` | `{ally:AllyInfo}`（同时发 `ally.updated`；对方从下一个 `ally.hello` 得知） |
| `sessions.list` | `{}` | `{sessions:CCSession[], hooks:boolean}`（未接管的会话，最近活动的在前；hooks = 全局钩子开着没有） |
| `sessions.history` | `{id, before?, limit?}` | `{messages:CCMessage[]}`（从旧到新；before = 客户端手里最早一条的 id，也接受毫秒时间；默认 50 条，最多 200。`id` 可以是电脑上开着的会话，也可以是 `pals.recent` 里退出了的对话（目录从 Claude Code 的记录里查）。只读：不写记录、不占着它。App 开着这个会话的页面时每 3 秒再要一次最新一页，记录的大小和修改时间没变时主机不再读一遍） |
| `sessions.hooks` | `{enabled?}` | `{enabled}`（不带 enabled 只查不改） |
| `helper.decide` | `{proposalId, action:"create"\|"discard"}` | `{pal?}`（create 返回开好或接管好的 Pal；已经答过的再答一次，返回原来的结果。`pal_adopt` 卡片接管不成时返回 `{}`，卡片变成 failed、带原因，可以再点） |
| `pals.list` | `{}` | `{pals:Pal[], others:CCSession[], hooks:boolean, helper:boolean}`（所有 Pal，包括睡着的；helper = Pal 经 PaloAlly 小助手启动） |
| `pals.adopt` | `{sessionId}` | `{pal}`，或 `{waiting:"exit-in-terminal"}`（终端会话：退出后自动接管，结果看 `pals.updated`；已经退出的对话直接 resume，返回 `{pal}`；已经有 50 个 Pal 时报错） |
| `pals.release` | `{id}` | `{resumeCommand}`（`cd <目录> && claude --resume <sessionId>`；返回时主机的进程已退出。回到这里重来以后还没再说话的，先用 SDK 的 `forkSession` 把对话现在的样子抄成新会话，命令指向它；回到第一条之前的给 `cd <目录> && claude`。pals-prd §15） |
| `pals.remove` | `{id}` | `{ok}` |
| `pals.history` | `{id, before?, limit?}` | `{messages:ChatMessage[], streaming?}`（从旧到新；before = 最早一条的 id 或毫秒时间；默认 50，最多 200；streaming 同 `sync`） |
| `pals.send` | `{id, text, clientMsgId?, attachments?}` | `{id, seq}`（同一 clientMsgId 只送一次；睡着的先叫醒，叫醒期间来的话排队按顺序送进去，送进去了才返回；停着的 Pal 先接着跑。attachments 同 `chat.send`：图片是图片块，文件放进 Pal 目录的 `.paloally/inbox/<id>/<文件名>`，话里加「[文件] 路径」；有附件时 text 可以是空的。pals-prd §15） |
| `pals.wake` | `{id}` | `{pal}`（睡着的 resume 同一个会话，起来了才返回；醒着的原样返回） |
| `pals.rename` | `{id, name}` | `{pal}`（Claude Code 给这个会话的标题也改，终端、`/resume`、claude.ai 看到的一样；名字不能空、最多 40 个字、不能是助理的名字，别的 Pal 用着的加「 2」；不重启它） |
| `pals.stop` | `{id}` | `{ok}`（结束当前这一轮，它开着的卡片按拒绝处理） |
| `pals.rewind` | `{id, messageId, restoreFiles?}` / `{id, messageId, check: true}` | `{text, filesRestored}` / `{canRestoreFiles}`（Pal 回到主人这条消息之前，`restoreFiles` 时代码也回到那时；没有这条的文件快照报「这一步之前的代码没法恢复」，对话不动。docs/rewind-prd.md） |
| `pals.recent` | `{folder?, limit?}` | `{sessions:RecentSession[]}`（最近 30 天里退出了的对话，最新的在前，默认也最多 50 个；不含正开着的、Pal、PaloAlly 自己的；folder 是路径（该目录及以下）或目录名） |

**事件**（`RPC_EVENTS`）：`chat.message`（ChatMessage）、`chat.delta`（`{id, text}` 追加文本，最终以同 id 的 `chat.message` 收尾；轮次中断时外壳也会补发收尾）、`chat.rewound`（`{id, ids, pal?}`：回到这里重来，`id` 那条和它之后的都拿掉，`ids` 是主机知道的那些；断线时错过的，`sync{sinceSeq}` 的 `rewound` 给出 id）、`task.updated`（Task）、`approval.updated`（Approval）、`watch.updated`（`{watch}` 或 `{removed:id}`）、`artifact.updated`（Artifact）、`settings.updated`（Settings）、`status`（Status）、`commands.updated`（`{commands}`）、`ally.updated`（`{allies}`，整张列表）、`ally.entry`（`{entry}`，新的来往或状态变化）、`sessions.updated`（`{sessions}`，整张未接管会话的列表，变了就发）、`pals.updated`（同 `pals.list` 的结果，变了就发整张）。`chat.message` / `chat.delta` 带 `pal` 时属于那个 Pal 的对话（`chat.delta` 是 `{id, text, pal?}`）。会话和 Pal 的确认和提问走 `approval.updated` / `question.updated`，带 `source`。

Ally 的连接（别人的主机作为客户端连进来）不走上面这些：只接受 `ally.hello` / `ally.message` / `ally.receipt` / `ally.bye` 四种，其他一律断开（`docs/allies-prd.md` §7.3、§7.6）。第二版（§11.4、§11.5）：`ally.message` 带 `author`（没有或不认识的值当 "assistant"），`ally.hello` 带可选的 `trust`（发送方给对方的档位，对方存成 `theirTrust`；同一连接上后来的 hello 只更新称呼和档位）。

## 6. 路由规则

- 所有主对话消息进 History（`state/chat.jsonl`，带 seq），广播给所有已连接的 App/CLI 客户端；客户端断线重连用 `sync{sinceSeq}` 补齐。
- 来自微信的一轮，回复也回微信（受 iLink 限制：每轮主动 ≤10 条，≤5 条/秒，context_token 24h 失效）。
- 主动消息（探针 / 定时 / notify_user / 任务完成 / 待审批）：手机推送；微信只发不含正文的提示（`settings.wechatProactive = "hint"`，可改 `"full"`/`"off"`）。
- 手机推送走 relay：APNs 密钥属于 App 开发者，只放在 relay 的 Worker secrets 里（别人的主机不可能有它）。主机把 App 注册的推送 token 连同提示文字，经已认证的 daemon socket 发 `push` 控制消息，relay 校验「这台主机在此配对过设备」、按主机限频（10/分钟、60/小时）后代发 APNs，回 `push_result`（见 bento `docs/relay-protocol.md`）。推送内容只放提示，正文进 App 后再经 E2E 取；以后可加 Notification Service Extension 做端到端加密的推送正文。`config.apns` 配了密钥的主机（开发者自用）在 relay 推不了时（掉线、relay 版本旧、未配置）回退为主机直推。
- 免打扰时段内的非 urgent 主动消息不推送，只进主对话；超过 `maxProactivePerDay` 同理。
- host 掉线：启动时若距上次心跳 > 2×tick，主对话发「我掉线过」通知，并对错过的定时 watch 补跑一次。
