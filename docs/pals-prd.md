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

### 7.4 其他
- **确认和提问：**走 SDK 的 `canUseTool`。卡片带 `source: {kind: "pal", id, name}`，复用现有的审批和提问。
- **推送：**Pal 在等你时推送「X 在等你」，同一个 Pal 10 分钟内最多一次。
- **去掉的部分：**`sessions-prd.md` 里的 `claude --bg` 帮手和跑腿转话都去掉。全局钩子只用于未接管的会话。

## 8. 接口（在 `sessions.*` 基础上调整）

| 方法 | 参数 | 返回 |
|---|---|---|
| `pals.list` | `{}` | `{pals: Pal[], others: CCSession[], hooks}` |
| `pals.adopt` | `{sessionId}` | `{pal}`，或 `{waiting: "exit-in-terminal"}` |
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
