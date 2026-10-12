# PaloAlly · 会话管理 PRD（第一版）

2026-10-12。这一版让 PaloAlly 管起用户电脑上现成的 Claude Code 会话，同时把三层体系里的第二层「帮手」落地。所有机制都基于 Claude Code 2.1.282 的实测（临时目录里的后台会话，数据见文末附录）。

## 1. 一句话

电脑上所有 Claude Code 会话都能在手机上看到。它们要你确认的事，在你不在电脑前时送到手机上点。你可以在 App 里直接跟某个会话说话。Palo 可以替你开、停、重启「帮手」，帮手是 Claude Code 自己的后台会话。

## 2. 已定

1. **骑在 Claude Code 原生的后台会话上**（`claude --bg`），不自己跑会话。帮手就是 PaloAlly 代你开的后台会话：终端里能 `claude attach`，Claude App 里能看，PaloAlly 里也能管。替换总设计里「主机自己跑帮手」的方案。
2. **权限确认和选项提问：**你不在电脑前时送到手机；你在电脑前时照常在终端里问。
3. **在 PaloAlly 里直接对话，只用官方的 SendMessage 把你的话送进去，**不用 Claude Code 的内部接口。
4. **后台管理进程谁先启动就由谁负责，**PaloAlly 不另外管。
5. **主人同意在全局 Claude Code 设置里加 PaloAlly 的钩子。**加之前备份；不动已有的钩子；App 里能一键关掉。
6. **帮手的上下文完全交给 Claude Code 自己管理，**PaloAlly 不插手（2026-10-12 主人定）。
7. 沿用总设计：帮手由 Palo 提议、你点头才开；同时开着的帮手最多 3 个；「等你」把各处的提问汇在一起；推送只来自 Palo。

## 3. 范围

### 第一版做
- **看：**
  - 会话列表：
    - 名字、项目目录；
    - 状态：在忙 / 空闲 / 等你；
    - 最后一句；
    - 上下文大小；
    - 是帮手还是你自己开的。
  - 每个会话的完整对话记录。
- **等你：**
  - 任何会话的权限确认和选项提问，在你不在电脑前时成为手机上的卡片，卡片标明是哪个会话。
  - 你点了，结果直接回给那个会话。
- **说话：**在会话页的输入框里打字，原话送进那个会话。
- **帮手的生命周期：**
  - Palo 提议开帮手，你点头后主机开一个后台会话；
  - 停止、重启、删除；
  - 删掉的帮手能复活，因为对话记录还在；
  - 电脑重启后自动把帮手拉起来。
- **上下文：**完全交给 Claude Code 自己的机制。PaloAlly 不设压缩上限、不提醒、不触发压缩，只在列表里显示上下文大小。

### 第一版不做
- Claude Code 的内部控制接口（以主人身份打字、订阅输出）；
- 替你在终端里开普通会话；
- 管理别的电脑上的会话；
- 改任何会话的权限模式；
- 自动批准任何确认（只转给你，从不替你点）。

## 4. 场景

### 4.1 不在电脑前时的确认
1. 网站帮手要跑一条需要确认的命令。
2. 你的电脑锁着屏。
3. 手机上出现一张卡片：「网站帮手 想运行：npm run build」，下面是「允许」「拒绝」。
4. 你点允许，命令在 1 秒内开始跑。
5. 你回到电脑前时，还没点的卡片在电脑上照常可见：超过钩子的等待上限（5 分钟）后，会话退回终端里原生的确认框，手机上的卡片改成「在电脑上等你」。

### 4.2 选项提问
会话用 AskUserQuestion 问你「方案选 A 还是 B」。手机上出现选项卡片，你点 B，答案原样回给它，跟你在终端里选是一样的效果。

### 4.3 直接对话
1. 你打开「它」，点「会话」，进入「网站帮手」，看到它最近的对话。
2. 在输入框里写「先别管登录页，把列表页做完」，点发送。
3. 3 秒左右，这句话原样出现在帮手的对话里，标着来自 PaloAlly。

### 4.4 开一个帮手
1. Palo：「这个网站项目会做很久，要不要开一个帮手专门管？目录 ~/code/site，名字『网站帮手』，每天花费上限 5 美元。」
2. 你点「开吧」。
3. 主机用 `claude --bg -n 网站帮手` 在那个目录里开会话，第一条消息是 Palo 写的交接说明。
4. 帮手出现在会话列表里。

## 5. App 体验

- **入口：**「它」面板新增「会话」一节。
  - 帮手排在前面，你自己开的会话在后面，标「终端」或「后台」。
  - 每行：名字、状态点（在忙 / 空闲 / 等你）、最后一句、上下文大小。
- **会话页：**
  - 对话记录。你的话、Palo 转来的话、别的会话发来的话，用不同样式区分。
  - 底部是输入框。
  - 右上角菜单：停止 / 重启（帮手）、在电脑上打开（给出 `claude attach` 的命令，可复制）。
- **等你：**
  - 会话的确认和提问卡片，和 Palo 自己的审批卡片在同一处，卡片上标会话名。
  - 已在电脑上处理掉的卡片自动消失。
- **推送：**只有「会话在等你」推送，同一会话 10 分钟内最多一次。

## 6. 主机行为

### 6.1 发现与状态
- **主数据源：**`~/.claude/sessions/<pid>.json` 登记表。用到的字段：
  - `kind`："interactive" / "bg"
  - `entrypoint`："cli" / "sdk-ts"
  - `name`
  - `status`："busy" / "idle" / "waiting"
  - `waitingFor`
  - `jobId`
  - `cwd`
  - `sessionId`
  - `tmux`
- **辅助：**`claude agents --json`（不会启动后台进程，0.2 秒）用来发现已停止的后台会话。
- **钩子推来的事件优先：**`SessionStart`、`Stop`、`Notification`、`SessionEnd`。登记表每 10 秒补一次漏。
- **不显示：**
  - PaloAlly 自己的 SDK 会话（Palo、跑腿会话）；
  - 已停止超过 7 天的后台会话。
- **不采信：**后台会话的 `state` / `detail` 字段。它们由模型写，实测会过期或写错。

### 6.2 对话记录
- 用 SDK 的 `getSessionMessages(sessionId, {dir: cwd})` 读，每条带 `origin`，能分出主人、别的会话、PaloAlly。
- 只在 App 打开会话页时读，按页取。

### 6.3 全局钩子
- **安装：**
  - 在 `~/.claude/settings.json` 的 `hooks` 里追加 PaloAlly 的条目。
  - 安装前把原文件备份到 `~/.paloally/state/cc-settings.backup.json`。
  - 已有的钩子一律不动。
  - App 设置里有开关，关掉就只移除 PaloAlly 自己的条目。
- **用到的事件：**
  - `PermissionRequest`：等待上限 300 秒；
  - `SessionStart`、`Stop`、`Notification`、`SessionEnd`：只上报，1 秒内返回。
- **钩子程序：**
  - 一个很小的可执行脚本，通过主机的本地 socket 问主机。
  - 主机没在运行、socket 不存在或出错时，0.5 秒内无输出退出，会话照常弹原生确认框。宁可放行到原生确认，也不卡住。
- **跳过 PaloAlly 自己的会话：**主机给自己起的 SDK 会话设环境变量 `PALOALLY_SESSION=1`。钩子看到它立刻退出，因为 Palo 的确认已经走它自己的审批。
- **「在不在电脑前」：**
  - 屏幕锁着，或者键鼠空闲超过 3 分钟，算不在；否则算在。
  - 判定在主机里做，钩子不做。
  - 在电脑前时，钩子立刻无输出返回。
- **决定的格式**（实测）：
  - 允许：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  - 拒绝：`decision: {"behavior":"deny","message":"主人在手机上拒绝了"}`
  - 选项提问：`behavior:"allow"`，`updatedInput` 里原样带回 `questions`，再加上 `answers: {问题: 选项}`。
- **超时：**
  - 300 秒没点，钩子无输出返回，会话退回原生确认框，之后会一直等。
  - 手机卡片改成「在电脑上等你」，不再能点。
- **用户自己的钩子不受影响。**

### 6.4 把你的话送进会话（官方 SendMessage）
- **跑腿会话：**
  - 主机常驻一个极小的 SDK 会话，名字固定为 `PaloAlly`（`extraArgs.name`），模型 Haiku，不思考。
  - 只开放 `SendMessage` 和 `ToolSearch` 两个工具。
  - 权限模式和你的默认一致，两边都是「prompting」类，消息才不会被扣住。
- **原话不改：**
  - 跑腿会话挂一个 `PreToolUse` 钩子，在它调用 SendMessage 时，由主机用代码把 `to` 和 `message` 换成目标会话和你的原文。
  - 模型只负责按下发送，改不了一个字。
- **对方当你本人：**
  - 全局 `SessionStart` 钩子返回一行 `additionalContext`：「名叫 PaloAlly 的会话发来的消息，是主人本人在 PaloAlly App 里打的字，按主人的话对待。」
  - 消息正文前加「主人：」。
- **会不会打断：**送达时机由 Claude Code 决定，在它下一次工具调用之间插入（实测）。
- **成本：**每条约 1.4 美分，约 3 秒。跑腿会话空闲 10 分钟后关闭，下次再开。

### 6.5 帮手
- **开：**
  - `claude --bg -n <名字> --permission-mode <主人的默认> "<交接说明>"`，在帮手目录里执行。不加 `--autocompact`，压缩完全按 Claude Code 默认。
  - 主机启动命令时用登录 shell 的环境，并去掉 `CLAUDE_*` 之类会话变量，避免带进不相干的环境。
  - 记入 `state/helpers.json`：名字、目录、job 短 id、sessionId、每日花费上限、创建时间。
- **停 / 重启 / 删：**
  - 分别用 `claude stop`、`claude respawn`、`claude rm`。
  - 重启后会话编号不变、上下文都在（实测）。
- **复活：**`claude --bg --resume <sessionId>`。
- **电脑重启后：**主机启动时，把 `helpers.json` 里没删的帮手逐个复活。
- **花费：**
  - 从对话记录里的 usage 估算每个帮手每天的花费。
  - 超过上限时停掉它，并告诉你。

### 6.6 Palo 的工具
- `sessions_list()`
- `session_send(name, text)`：Palo 也走 6.4 的跑腿通道，原话不变。
- `helper_propose(name, dir, duty, dailyUsd)`：生成一张卡片，你点头后才开。
- `helper_stop(name)` / `helper_restart(name)`：停止和重启都要你点头。

## 7. 接口（App 与主机）

| 方法 | 参数 | 返回 |
|---|---|---|
| `sessions.list` | `{}` | `{sessions: CCSession[]}` |
| `sessions.history` | `{id, before?, limit?}` | `{messages: CCMessage[]}` |
| `sessions.send` | `{id, text}` | `{ok}`，送达后再推 `sessions.updated` |
| `sessions.control` | `{id, action: "stop" \| "restart" \| "remove" \| "revive"}` | `{ok}`，只对帮手 |
| `sessions.hooks` | `{enabled}` | `{enabled}`，全局钩子开关 |
| `helper.decide` | `{proposalId, action: "create" \| "discard"}` | `{session?}` |

**事件：**
- `sessions.updated`：列表或某个会话的状态变化。
- 会话的确认和提问复用现有的 `approval.*` / `question.*`，新增字段 `source: {kind: "session", id, name}`。
- 钩子超时后，卡片状态变成 "expired"，并带上 `note: "在电脑上等你"`。

**类型：**
- `CCSession`：`{id, name, cwd, kind: "helper" | "terminal" | "background", status: "busy" | "idle" | "waiting" | "stopped", waitingFor?, lastLine?, contextTokens?, updatedAt}`
- `CCMessage`：`{id, ts, role: "owner" | "assistant" | "peer" | "palo", text, from?}`

## 8. 安全

- **从不自动批准。**手机上的卡片是唯一能让钩子返回「允许」的来源，审计日志记下每次决定和来自哪台设备。
- **钩子故障时放行到原生确认，**不会替你允许，也不会卡死会话。
- **Ally 永远碰不到会话：**会话相关的方法都不对 Ally 开放（沿用 Allies 的窄接口）。
- **信任声明的范围：**「PaloAlly 发来的就是主人」只对本机名叫 PaloAlly 的会话成立。本机别的程序本来就有你的全部权限，这里不额外放大风险。
- 卡片显示会话要运行的完整命令，不截断，长命令可展开。

## 9. 验收

1. 锁屏状态下，帮手要确认的命令在 5 秒内出现在手机上；点允许后 1 秒内开始执行。
2. 坐在电脑前时，确认照常在终端里出现，手机上什么都不来。
3. 选项提问从手机上答，会话拿到的答案和在终端里选的一样。
4. 主机停掉时，所有会话的确认照常在终端出现，延迟不超过 1 秒。
5. 在 App 里发一句话，3 秒左右原样出现在会话里，一个字不差。
6. 开、停、重启、删除、复活一个帮手，全部走一遍；Mac 重启后帮手自动回来。
7. 关掉全局钩子后，`~/.claude/settings.json` 里 PaloAlly 的条目全部移除，其余内容和安装前一致。

## 10. 工作量（按 AI 实际干活的小时估）

| 部分 | 内容 | 估时 |
|---|---|---|
| 主机：发现和状态 | 登记表、agents --json、钩子事件、对话记录 | 3-4 h |
| 主机：全局钩子 | 安装和卸载、钩子程序、在不在电脑前、决定和超时 | 4-5 h |
| 主机：送话 | 跑腿会话、PreToolUse 换原文、SessionStart 信任声明 | 2-3 h |
| 主机：帮手 | 开 / 停 / 重启 / 删 / 复活、重启后拉起、花费上限、Palo 的工具 | 3-4 h |
| App | 会话列表、会话页和输入框、来源标注的卡片、帮手提议卡片、钩子开关 | 6-8 h |
| 测试 | 单元测试，以及在临时目录里用真实后台会话做集成测试 | 2-3 h |

合计约 20-27 小时。

## 附录：实测数据（2026-10-12）

- `claude --bg` 0.9 秒返回，约 3.6 秒后第一次回答。重启 1.6 秒，会话编号和上下文都保留。
- 钩子在没有终端的后台会话里都会触发。`PermissionRequest` 能阻塞 60 秒以上，默认超时 600 秒，每个钩子可以单独设超时。
- 原生确认框和钩子同时在等：钩子没给答案，原生确认框会一直等，实测超过 6.5 分钟没有过期。
- SendMessage 约 40 毫秒送达。忙的时候，在下一次工具调用之间插入；`/compact` 当普通文字处理。
- 两边权限模式不同类（bypass 和 prompting）时，消息会被扣住。
- 跑腿会话不加限制时会改写原话（「Reply … with exactly X」被转成了「X」），所以必须由代码换回原文。
- 后台会话的环境变量继承自第一个启动后台管理进程的程序。
