# PaloAlly · Pals 与导航 PRD

2026-10-12。取代 `sessions-prd.md` 里「后台会话 + 跑腿转话」的做法：Pal 改为由 PaloAlly 主机自己 host（resume 原会话的记录），你在 Pal 里打的字就是主人输入。`sessions-prd.md` 的全局钩子、在不在电脑前、对话记录读取这几部分继续有效。

## 1. 一句话

App 用标准 iOS 导航：一个列表，最上面是你的助理 Palo，下面是 Pals 和 Allies。
- **Pal** 是这台电脑上的一个 Claude Code 会话。接管进来后，点开就是一个远程模式的 Claude Code：完整对话、流式输出，确认和提问都在手机上点。
- **Ally** 是跟你配对的人和他们的助理。

## 2. 已定（2026-10-12 主人定）

1. **导航用标准 iOS 逻辑，**不做「压在下面一层」的抽屉。
   - iPhone：打开 App 直接是 Palo 对话，左上角返回到列表（像「信息」App）。
   - Mac 和 iPad：可收起的系统侧栏。
2. **列表结构：**Palo 一行在最上；下面是 Pals 一节、Allies 一节。
3. **点对话顶部中间的小球，进入主助理的管理界面，**也就是原来「它」里的目标、任务、记忆、设置。
4. **Pal 由我们自己 host。**你显式把一个 Claude Code 会话加进来（接管），主机 resume 它的记录接着跑。Palo 自己开的长期会话天生就是 Pal。
5. **接管一个还开着的会话前，先停掉原进程，**不做分叉。
6. **接管的会话经 PaloAlly 小助手 App 启动。**你给小助手一次「完全磁盘访问」，之后所有 Pal 的 macOS 权限一致。
7. **Palo 和 Pal 之间用 Claude Code 原生的 SendMessage 沟通。**
8. **Pal 的上下文完全交给 Claude Code 自己管理。**

## 3. 列表

- **Palo：**名字、状态（在想 / 空闲 / 等你），点了进入 Palo 对话。
- **Pals**
  - **已接管的 Pal：**名字、状态点（在忙 / 空闲 / 等你）、最后一句、项目目录。点了进入它的对话。
  - **电脑上其他活着的 Claude Code 会话（未接管）：**淡一些显示，带「接管」按钮。
    - 不接管也能看到状态。
    - 它们的确认在你不在电脑前时照样转到手机（全局钩子，见 `sessions-prd.md` §6.3）。
- **Allies：**每个 Ally 一行，最后加一行「添加」。
- **角标：**每行右侧显示「等你」的数量。

## 4. Pal 的对话

- **界面复用 Palo 的对话界面：**
  - 流式输出、淡入、平滑跟随；
  - 权限卡片、选项提问、取消。
- **你打的字：**直接作为主人输入进入这个会话，和在终端里敲一样。
- **权限和提问：**一律送到 App（不管你在不在电脑前），因为接管后 App 就是它的界面。
- **右上角菜单：**
  - 停止当前这一轮；
  - 「交还终端」：主机关掉自己的进程，给出一行 `claude --resume <id>` 可复制；
  - 移出 Pals。
- **Palo 和 Pal 之间的来往：**
  - Pal 对话里显示为「Palo 说」；
  - Palo 对话里只有 Palo 用自己的话说结果。

## 5. 接管

1. 在 Pals 里对一个未接管的会话点「接管」。
2. 原会话的处理：
   - **后台会话：**主机用 `claude stop` 停掉它。
   - **终端会话：**App 提示「请在终端里退出它（/exit），退出后自动接管」。
   - 主机看到原进程结束后继续。
3. 主机 resume：
   - 用原记录的 sessionId 和原目录，模型从记录里读，权限模式用你的默认；
   - 起一个固定名字（就是列表里的名字），这样 Palo 能用 SendMessage 找到它。
4. 接管完成，进入对话页，上下文一字不丢。
5. 原进程停不下来或一直没退出时，不接管，提示原因。绝不让两个进程同时写同一份记录。

## 6. Palo 开 Pal

Palo 提议，你点头，主机新开一个会话，第一条消息是 Palo 写的交接说明。沿用 `sessions-prd.md` 帮手的提议卡片和花费上限，但会话由主机 host，不再用 `claude --bg`。

## 7. 主机

### 7.1 每个 Pal 一个会话
- 复用 Palo 现有的 SDK 会话机制（`query` + `resume`），每个 Pal 一个实例，各自记录：sessionId、目录、名字、花费。
- 需要把主机里「只有一个主会话」的地方改成按会话区分。研究结论见附录。

### 7.2 一直开着
- Pal 默认一直开着，这样 SendMessage 随时能送到。
- 进程意外退出时自动 resume。
- 电脑重启后，主机启动时把所有 Pal resume 回来。
- 同时开着的 Pal 最多 5 个，超过时提议移出最久没用的一个。

### 7.3 经小助手启动
- 用 SDK 的 `spawnClaudeCodeProcess`，经已签名的 PaloAlly 小助手 App 启动 claude 进程。
- 用登录 shell 的环境，去掉不相干的会话变量。
- 小助手 App 是安装包的一部分，用 Developer ID 签名。
- 先做验证：
  - 经小助手启动的进程，macOS 是否把权限记在小助手头上；
  - 标准输入输出能否稳定转接。
- 验证失败时，退回由主机直接启动，并在 App 里如实说明权限限制。
- **验证结果（2026-10-12，主机实现时测）：**
  - 小助手（`host/helper`，`host/helper/build.sh` 构建并用 Developer ID 签名）用 `responsibility_spawnattrs_setdisclaim` 再起一份自己，这一份对自己负责，claude 是它的子进程。系统查到 claude 的「负责进程」就是小助手（`PaloAllyHelper --check <pid>`）。
  - 同一条 `ls ~/Library/Safari`（完全磁盘访问才能读的目录）：从有权限的终端直接起的会话能读；经小助手起的会话被拒绝。说明权限确实按小助手算；主人给小助手「完全磁盘访问」后，所有 Pal 都有。
  - 标准输入输出直接继承下去，中间不转手；一轮对话、工具调用、resume 都正常，退出码和信号原样传递。
  - 小助手没装或起不来时，主机直接启动 claude，`pals.list` 的 `helper: false`，App 说明权限跟主机一样。

### 7.4 其他
- **确认和提问：**走 SDK 的 `canUseTool`。卡片带 `source: {kind: "pal", id, name}`，复用现有的审批和提问。
- **推送：**Pal 在等你时推送「X 在等你」，同一个 Pal 10 分钟内最多一次。
- **去掉的部分：**`sessions-prd.md` 里的 `claude --bg` 帮手和跑腿转话都去掉。全局钩子只用于未接管的会话。
- **Palo 的名字：**Palo 自己的会话名固定为 `Palo`（SendMessage 用的名字），Pal 回它就发给 `Palo`；Pal 对话里来自这个名字的话显示为助理说的。Pal 的系统提示末尾加一句：它由 PaloAlly 托管、主人在手机上看，名叫 Palo 的会话是主人的助理。
- **同类权限：**SendMessage 只在两边权限模式同一类时立刻送达（Palo 是 auto）。主人的默认模式若是 bypassPermissions，Palo 发给 Pal 的话会被扣住。

## 8. 接口（在 `sessions.*` 基础上调整）

| 方法 | 参数 | 返回 |
|---|---|---|
| `pals.list` | `{}` | `{pals: Pal[], others: CCSession[], hooks}` |
| `pals.adopt` | `{sessionId}` | `{pal}`，或 `{waiting: "exit-in-terminal"}` |
| `pals.adopt` | `{sessionId, cancel: true}` | `{cancelled}`，不再等终端退出 |
| `pals.release` | `{id}` | `{resumeCommand}` |
| `pals.remove` | `{id}` | `{ok}` |
| `pals.history` | `{id, before?, limit?}` | `{messages}`，格式同 `chat.history` |
| `pals.send` | `{id, text, clientMsgId?}` | `{id, seq}` |
| `pals.stop` | `{id}` | `{ok}`，停当前这一轮 |

**事件：**
- `pals.updated`；
- `chat.delta` 和 `chat.message` 新增可选 `pal` 字段，标明属于哪个 Pal，没有该字段就是 Palo；
- 审批和提问带 `source`。

`Pal`：`{id, name, cwd, sessionId, status: "busy" | "idle" | "waiting" | "starting" | "stopped", lastLine?, pending, model?, createdBy: "owner" | "palo"}`

**主机定下的细节**（2026-10-12，实现时补；样例见 `ios/PaloAllyKit/Tests/PaloAllyKitTests/Fixtures/protocol.json`）：
- `pals.list` 和 `pals.updated` 的内容一样：`{pals, others, hooks, helper}`。
  - `others`：电脑上其他会话（`CCSession[]`，不含 Pal）；等着在终端里退出、退出后就接管的那个带 `adopting: true`。
  - `hooks`：全局钩子开没开（同 `sessions.list`）。
  - `helper`：Pal 是不是经 PaloAlly 小助手启动。false 时 Pal 的 macOS 权限跟主机一样，App 如实说明。
  - 列表或任何一个 Pal 的状态变了，就发整张。Pal 按最近活动排在前面。
  - 发得及时：一轮结束、`pals.stop`、出现或答完一张卡片、起停，300 毫秒内发出。`pals.stop` 后 Claude Code 迟迟不结束这一轮时（工具一时停不下来），主机 250 毫秒后自己把它算作结束，这一轮剩下的输出不再让它显示「在忙」。
- `Pal` 另有三个字段：`activity?`（busy 时在干嘛，同 `Status.activity`）、`note?`（stopped 时为什么：花费过了上限 / 接连启动不起来 / 在别处打开了）、`updatedAt`。`id` 是 `pal_…`，不是 `sessionId`；除了 `pals.adopt`，各方法都用 `id`。
- `pals.adopt`：
  - 已经是 Pal 的，返回原来那个。
  - 终端会话返回 `{waiting: "exit-in-terminal"}`。主机每 0.5 秒看一次原进程，它退出后自动接管，新的 Pal 出现在 `pals.updated` 里。等 30 分钟还没退出就不等了，Palo 的对话里说一声。
  - 停不下来、resume 失败、已经满 5 个，都报错，原因在错误信息里；满了时点名最久没用的那个。
  - 取消（`{sessionId, cancel: true}`）：主机不再等，之后在终端里退出也不会接管，并立刻发 `pals.updated`（这个会话不再带 `adopting`）。返回 `{cancelled: true}`；没有在等的返回 `{cancelled: false}`，已经接管成 Pal 的另带 `pal`。
- `pals.release` 返回 `{resumeCommand: "cd <目录> && claude --resume <sessionId>"}`，带 `cd` 是为了在原目录里接着跑。返回时主机的进程已经退出。
- `pals.history`：`before` 是客户端手里最早那条的 `id`（也接受毫秒时间）；返回从旧到新，默认 50 条，最多 200 条。最新一页另带 `streaming?: {id, text}`：正在写的回复，之后的 `chat.delta` 接着往上追加。
- Pal 的消息（`chat.message` / `chat.delta` 带 `pal`）：
  - 不进 Palo 的对话。`seq` 就是毫秒时间，只用来排序，不要算进 Palo 的 sync 序号。
  - 回复的 `id` 是 API 消息的 id：流式、收尾和历史里都一样。主人打的字，`id` 就是记录里那条的 uuid。
  - 别的会话发进来的话是 `role: "user"`，带 `from`：Palo 的话 `from` 是助理的名字，别的会话的话 `from` 是那个会话的名字。Palo 开的 Pal 的第一条（交接说明）也算 Palo 的话。
- `pals.send`：同一个 `clientMsgId` 重发只送一次。停着的 Pal（花费上限、接连起不来）会先接着跑；在别处开着时报错。
- `pals.stop`：结束当前这一轮，这个 Pal 还开着的卡片按「拒绝」处理。
- 卡片：带 `source: {kind: "pal", id, name}`，不进 Palo 的聊天记录（App 放在 Pal 对话的末尾）。Pal 的卡片有「以后都允许」（`suggestedScope`，规则存在 Claude Code 自己那里），等待时长同主人设的确认等待时间。「X 在等你」的推送 data 带 `pal`。
- `helper.decide` 的 create 现在返回 `{pal?}`（原来是 `{session?}`）。`HelperProposal` 开好以后带 `palId`。
- 去掉：`sessions.send`、`sessions.control`。保留：`sessions.list`、`sessions.history`、`sessions.hooks`、`sessions.updated`，都只含未接管的会话。
  - App 连上后只调 `pals.list`：其他会话（`others`）和钩子开关（`hooks`）都在里面，不再另调 `sessions.list`。只有不认识 `pals.list` 的旧主机才改调 `sessions.list`。钩子开关照旧用 `sessions.hooks` 改。

## 9. 验收

1. 接管一个后台会话：从点「接管」到能在手机上对话，不超过 10 秒，上下文完整。
2. 接管终端会话：在终端 /exit 后 5 秒内自动接管。
3. 在 Pal 里打字，会话把它当主人的话（记录里 origin 是主人），流式显示到手机。
4. Pal 要确认的命令出现在手机上，点允许后 1 秒内执行。
5. Palo 用 SendMessage 给 Pal 派活，Pal 收到并回话。
6. 「交还终端」后，用给出的命令在终端里接着用，上下文完整。
7. 电脑重启后，Pal 全部自动回来。
8. 接管过程中任何时刻，同一份记录都不会被两个进程同时写入。

## 附录

- 主机里写死「一个主会话」的地方：路径、Conversation、Hub、状态、预算、RPC 都只认一个会话（2026-10-11 研究）。改成按会话区分的工作量估计 6-8 小时。
- SDK 能 resume 磁盘上的任何会话记录；后台管理进程还握着的会话会报 `session_held_by_background`，所以接管前必须先停（2026-10-12 实测）。

## 10. 接管最近的对话（2026-10-12 主人同意）

已经退出的 Claude Code 对话，也能直接接进 Pals，不用回终端重新打开。

- **列出：**
  - 主机用 SDK 的 `listSessions` 读磁盘上的对话记录，列出最近 30 天里退出了的对话，最多 50 个，按目录分组、按最后修改时间倒序。
  - 不列：
    - 正在运行的会话（它们在 `others` 里）；
    - 已经是 Pal 的；
    - PaloAlly 自己的会话（Palo、探针、测试用的临时目录）。
- **每条：**会话编号、目录、标题、最后修改时间、记录大小。
  - 标题依次取：自定义标题、Claude Code 的摘要、第一句话的前 40 个字。
- **接管：**沿用 `pals.adopt{sessionId}`。对已经退出的对话，没有进程要停，直接 resume，几秒内成为 Pal。双写保护照旧：接管前再查一次有没有进程握着这份记录。
- **App：**Pals 一节最后加一行「最近的对话」，点进去是按目录分组的列表，点一条就接管并打开它的 Pal 页。
- **Palo：**
  - 新工具 `pals_recent(folder?)` 列出这些对话。
  - 新工具 `pal_adopt(sessionId)` 不直接接管，而是生成一张卡片「接管『标题』（目录）」，主人点「接管」才接（和 `pal_propose` 一样，走 `helper.decide` 同类的卡片流程）。
  - 主人说「把 X 目录里那个对话接过来」时，Palo 先查，再出卡片；有多个候选时让主人选。

接口：

| 方法 | 参数 | 返回 |
|---|---|---|
| `pals.recent` | `{folder?, limit?}` | `{sessions: RecentSession[]}` |

`RecentSession`：`{sessionId, cwd, title, lastModified, size}`

卡片：聊天消息 `kind: "pal_adopt"`，带 `proposal: {id, sessionId, cwd, title, status: "pending" | "adopted" | "discarded" | "failed", palId?, note?}`。主人点「接管」或「不用」，用 `helper.decide{proposalId, action: "create" | "discard"}`。

**主机定下的细节**（2026-10-12，实现时补；样例见 `protocol.json` 的 `pals.recent` 和 `kind: "pal_adopt"` 的两条消息）：
- `pals.recent`：
  - 按最后修改时间倒序的一张表，按目录分组是 App 的事。`limit` 默认 50，最多 50。`folder` 给路径时是这个目录和它下面的，给名字时按目录名找。
  - 跟 Claude Code 的 `/resume` 一样，不列 `claude -p` 跑的和别的应用用 SDK 开的会话；Palo 开的 Pal 被移出或交还终端以后例外，照样列。
  - 也不列：PaloAlly 测试用的临时目录（`paloally-…`）和 Claude Code 子 agent 的临时目录（`/tmp/claude-<uid>/…`）；目录已经没了的；记录不在 Claude Code 给这个目录放记录的地方的（resume 不回来）。
  - 读 SDK 的 `listSessions`（每份记录只读开头和结尾各 64 KB），结果留 5 秒。
- `pals.adopt` 接管退出了的对话：不用停进程，直接 resume，返回 `{pal}`。名字取自定义标题（16 个字以内，长了在词边上截），没有就用目录名；重名加编号。接管前那一刻要是有进程开着这份记录，报错不接管。
- `pal_adopt` 卡片：
  - 正开着的、已经是 Pal 的、PaloAlly 自己的、找不到的，不出卡片，工具直接说原因；已经有 5 个 Pal 时让 Palo 先问主人移出哪个。同一个对话已经有一张没答的卡片，不再出第二张。
  - 点「接管」：`helper.decide` 返回 `{pal}`，卡片变成 adopted、带 `palId`；再点一次返回同一个 Pal。
  - 接不成（resume 失败、满 5 个、这时在终端里开着）：返回 `{}`，卡片变成 failed、`note` 写原因；可以再点「接管」重试。在终端里开着的不会等它退出（那种在 Pals 列表里点「接管」）。
  - 点「不用」：返回 `{}`，卡片变成 discarded。

## 11. 小助手没有完全磁盘访问时直接启动（2026-10-13）

实测根因：经 PaloAlly Helper 启动的 Claude Code 一碰到受保护的文件，macOS 就把这次访问挂起，转给 sandboxd 去问 tccd。Helper 没有完全磁盘访问，tccd 30 毫秒内拒了，但进程从此不再动：CPU 为 0，不理 SIGTERM，连接也被服务器关掉。10:57、12:48、17:45 三次卡死，每次都精确对上一条 kTCCServiceSystemPolicyAllFiles 的 approval 请求，责任方都是 dev.paloally.helper。

做法：`pals.launch` 为 "auto" 时，主机启动 Pal 前先经 Helper 读一个只有完全磁盘访问才能读的文件（`~/Library/Application Support/com.apple.TCC/TCC.db` 的 1 个字节），3 秒超时，每分钟最多查一次。读得到才经 Helper 启动，否则直接启动，和 Palo 一样。主人给 Helper 开了完全磁盘访问之后，下一个启动的 Pal 自动改经 Helper。
