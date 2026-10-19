# 工作台 RPC 契约

这份文档是 `docs/workbench-plan.md` 的 Phase 0 产出。host 和 app 两边都以它为准。范围是阶段 1 和 2 新增或改动的方法与事件。没写到的方法保持原样。

## 0. 通用约定

- 请求 `{id, method, params}`，成功 `{id, result}`，失败 `{id, error: {message}}`。`message` 是 host 已按主人语言写好的一句话，app 原样显示，不按文字分支。下面「错误」一栏列出会抛错的情况，没有错误码。
- 事件信封是 `{event, data}`，和 `pals.updated` 一样。
- 字段一律 camelCase。时间是毫秒时间戳（Int64）。可选字段缺省时整个键不出现，app 不要依赖 `null`。唯一的例外是 `Workspace.layout`，它明确可以是 `null`。
- id 前缀：会话 `pal_<12位hex>`，工作区 `ws_<12位hex>`（`newId("ws_")`）。右侧栏标签的 key（`workbench.tabs.*`）为 `"palo"`、`"pal:<会话id>"`、`"ws:<工作区id>"` 三种。
- 界面上叫「会话」，线上字段名和方法名仍是 `pals.*`（plan §6.7）。
- 新字段对老 app 全部可忽略；app 用 `TolerantStringEnum` 解码新枚举，未知值落到 `unknown`。
- 每个新方法都要进 `RPC_METHODS`（host）和 `RPCMethod.all`（app），并有 `protocol.test.ts` 样本。

## 1. `Pal` 新增字段

加在现有 `Pal`（`host/src/types.ts`）上，`pals.list`、`pals.updated`、各方法返回的 `pal` 都带。

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `attention` | `"working" \| "waiting" \| "done" \| "idle"` | 必有。host 算：有卡片在等主人则 `waiting`（优先）；`status` 为 `busy` 则 `working`；上一轮正常结束且 `finishedAt > seenAt` 则 `done`；其余（含 `asleep`、`starting`、`stopped`）为 `idle`。`stopped` 的原因仍看 `note`。 |
| `finishedAt` | `Int64?` | 上一轮正常结束的时间。只在真实一轮结束时写，host 重启不写。 |
| `seenAt` | `Int64?` | 主人最后一次看过的时间，各设备共享。 |
| `contextPct` | `Int?` | 上下文已用百分比 0 到 100。还没有用量数据时缺省。 |
| `workspaceId` | `String?` | 所属工作区，最多一个。 |
| `effort` | `"low" \| "medium" \| "high" \| "xhigh" \| "max"?` | 思考深度。缺省表示跟随默认。`model` 字段已存在。 |
| `folded` | `Bool` | 必有。算出来的，不存储：`!workspaceId && now - lastUsedAt > foldDays`。app 的会话区不显示 `folded` 的，它们出现在「以前的」。 |

`pals.updated` 的 `data` 不变：`{pals: Pal[], others, hooks, helper}`，整表替换。`folded` 会随时间变化，host 在跨过边界时也要发一次（每小时检查一次即可）。

示例（`Pal`）：

```json
{"id":"pal_3f9a1c0b2d4e","name":"session-3f9a1c","cwd":"/Users/demo/code/site","sessionId":"7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","status":"idle","lastLine":"登录页做完了","pending":0,"model":"claude-opus-4-5","createdBy":"owner","updatedAt":1792310400000,"attention":"done","finishedAt":1792310400000,"contextPct":42,"workspaceId":"ws_a1b2c3d4e5f6","effort":"high","folded":false}
```

## 2. 会话方法

下面所有带 `id` 的方法，`id` 可以是会话 id、名字或 sessionId（沿用 `Pals.get`）。找不到都报「找不到这个会话」。

### `pals.create`

在任意文件夹直接新建一个会话。

- 参数：`{cwd: string, name?: string, text?: string, workspaceId?: string}`
- 返回：`{pal: Pal}`
- 行为：
  - 不传 `name` 时内部名为 `session-<短id>`，界面显示「新会话」。第一句话之后 host 自动起名，重名加数字，并广播 `pals.updated`。
  - 不传 `text` 时不发消息，等主人说第一句。传了就作为第一句发出。
  - `workspaceId` 有就直接加入该工作区。
  - 返回时进程可能还在 `starting`。
  - 主人自己新建的会话不设每日花费上限，和在终端里用一样（plan §7.5）；Palo 提议开的仍用 `dailyUsd`。
  - 醒着的上限 `MAX_AWAKE` 为 8，可配置（`settings.maxAwake`）。新会话和 `pals.resume`、`pals.wake` 超出时让最久没动的睡去，但**工作区里正显示的格**不参与挑选（plan §7.4）。「正在显示」由 host 从工作区布局推断：出现在任一 `Workspace.layout` 叶子里的会话都算，不需要 app 另外上报。若全是叶子的会话多于上限，则都保持醒着，不强行睡。
- 错误：找不到文件夹；文件夹在 PaloAlly 自己的目录里；名字过长（40 字）、和助理同名；会话数达上限（`MAX_PALS`）；`workspaceId` 不存在。
- 广播：`pals.updated`，如果加入了工作区还有 `workspaces.updated`。

```json
{"id":"r1","method":"pals.create","params":{"cwd":"/Users/demo/code/site","text":"把登录页做完","workspaceId":"ws_a1b2c3d4e5f6"}}
{"id":"r1","result":{"pal":{"id":"pal_3f9a1c0b2d4e","name":"session-3f9a1c","cwd":"/Users/demo/code/site","sessionId":"7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","status":"starting","pending":0,"createdBy":"owner","updatedAt":1792310400000,"attention":"working","workspaceId":"ws_a1b2c3d4e5f6","folded":false}}}
```

### `pals.detail`

胶囊详情要的全部内容，打开详情时拉一次；之后靠 `pals.updated` 里的 `Pal` 字段和再拉保持新。

- 参数：`{id: string}`
- 返回：

```
{
  pal: Pal,
  contextTokens: Int?,        // 当前上下文 token 数
  contextWindow: Int?,        // 该模型的窗口
  costTotalUsd: Double,       // 累计花费
  spentToday: Double,         // 今天的花费
  model: String?,
  effort: String?,
  models: [{id: String, name: String, efforts: [String]}],  // 可选模型，efforts 是该模型支持的深度，空表示不支持
  tasks: [{id: String, title: String, kind: "subagent" | "bg", startedAt: Int64, summary?: String}],
  lastCompactAt: Int64?
}
```

- 错误：找不到会话。
- 广播：无。`tasks` 变化时 host 发一次 `pals.updated`（`Pal.activity` 或 `Pal.updatedAt` 随之变），app 看到所开详情的会话变了就重拉。

```json
{"id":"r2","method":"pals.detail","params":{"id":"pal_3f9a1c0b2d4e"}}
{"id":"r2","result":{"pal":{"id":"pal_3f9a1c0b2d4e","name":"登录页","cwd":"/Users/demo/code/site","sessionId":"7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","status":"busy","activity":"在改 Login.tsx","pending":0,"createdBy":"owner","updatedAt":1792310400000,"attention":"working","contextPct":42,"effort":"high","folded":false},"contextTokens":84000,"contextWindow":200000,"costTotalUsd":3.82,"spentToday":1.2,"model":"claude-opus-4-5","effort":"high","models":[{"id":"claude-opus-4-5","name":"Opus 4.5","efforts":["low","medium","high"]}],"tasks":[{"id":"t_9c1","title":"跑全部测试","kind":"bg","startedAt":1792310300000}],"lastCompactAt":1792300000000}}
```

### `pals.setModel`

- 参数：`{id: string, model?: string, effort?: string}`，至少给一个。不给的那个不动。
- 返回：`{pal: Pal}`
- 错误：模型不在 `models` 里；该模型不支持这个 `effort`；两个都没给；会话 `stopped`。
- 行为：忙的时候也可以改，对下一轮生效。持久化进记录。
- 广播：`pals.updated`。

```json
{"id":"r3","method":"pals.setModel","params":{"id":"pal_3f9a1c0b2d4e","effort":"max"}}
{"id":"r3","result":{"pal":{"id":"pal_3f9a1c0b2d4e","name":"登录页","cwd":"/Users/demo/code/site","sessionId":"7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","status":"idle","pending":0,"createdBy":"owner","updatedAt":1792310400000,"attention":"idle","effort":"max","folded":false}}}
```

### `pals.compact`

- 参数：`{id: string}`
- 返回：`{}`
- 错误：会话正忙（先停下再压缩）；会话 `stopped`。睡眠中的会话先唤醒。
- 行为：host 发 `/compact`，不当作主人的消息显示。完成后更新 `lastCompactAt` 和 `contextPct`。
- 广播：`pals.updated`。

```json
{"id":"r4","method":"pals.compact","params":{"id":"pal_3f9a1c0b2d4e"}}
{"id":"r4","result":{}}
```

### `pals.stopTask`

停一个后台任务或子 agent。

- 参数：`{id: string, taskId: string}`
- 返回：`{}`
- 错误：任务不存在或已结束；停不掉（「停不下来」）。
- 广播：`pals.updated`。

```json
{"id":"r5","method":"pals.stopTask","params":{"id":"pal_3f9a1c0b2d4e","taskId":"t_9c1"}}
{"id":"r5","result":{}}
```

### `pals.seen`

标记主人已看。幂等；已经 `seenAt >= finishedAt` 时不广播。app 在打开会话、或会话在可见的格里完成一轮时乐观调用。

- 参数：`{id: string}`
- 返回：`{pal: Pal}`
- 错误：找不到会话。
- 广播：`pals.updated`（让其他设备同步）。

```json
{"id":"r6","method":"pals.seen","params":{"id":"pal_3f9a1c0b2d4e"}}
{"id":"r6","result":{"pal":{"id":"pal_3f9a1c0b2d4e","name":"登录页","cwd":"/Users/demo/code/site","sessionId":"7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","status":"idle","pending":0,"createdBy":"owner","updatedAt":1792310400000,"attention":"idle","finishedAt":1792310400000,"seenAt":1792310460000,"folded":false}}}
```

### `pals.end`

结束会话：关进程，从列表移走，记入「以前的」，之后还能接着聊。区别于 `pals.remove`（只写 `former`）和 `pals.release`（交还终端，RPC 保留，界面不再用）。

- 参数：`{id: string}`
- 返回：`{earlier: EarlierItem}`，见 `pals.earlier`，`kind` 为 `"ended"`。
- 错误：找不到会话。
- 行为：同时从所属工作区摘掉（并清掉该工作区布局里的叶子）。`ended` 最多保留 200 条。
- 广播：`pals.updated`，如果摘了工作区成员还有 `workspaces.updated`。

```json
{"id":"r7","method":"pals.end","params":{"id":"pal_3f9a1c0b2d4e"}}
{"id":"r7","result":{"earlier":{"kind":"ended","key":"ended:7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","sessionId":"7b0c1e5a-1d2f-4a56-9c3e-0a1b2c3d4e5f","name":"登录页","cwd":"/Users/demo/code/site","at":1792310500000,"workspaceId":"ws_a1b2c3d4e5f6"}}}
```

### `pals.reveal`

在电脑上打开会话的文件夹。

- 参数：`{id: string, kind: "finder" | "terminal"}`
- 返回：`{}`
- `finder`：在访达里打开这个文件夹。
- `terminal`：**开一个普通 shell，cd 到这个文件夹，不 resume 这个会话**（plan §6.1）。会话照常由 host 托管，所以和单写者保护无关，也不需要先让会话睡眠。
- 错误：文件夹已不存在；host 不在能开窗口的环境里（无桌面）；`kind` 不认识。
- 广播：无。

```json
{"id":"r8","method":"pals.reveal","params":{"id":"pal_3f9a1c0b2d4e","kind":"terminal"}}
{"id":"r8","result":{}}
```

### `pals.folders`

新建会话时「最近的文件夹」候选。由会话的 `cwd`、已结束的会话和 `pals.recent` 去重得来，按最近使用排序，不含 PaloAlly 自己的目录。选「其他文件夹」时用 `files.folders.browse`。

- 参数：`{limit?: Int}`，默认 20，最大 50。
- 返回：`{folders: [{path: String, name: String, lastUsedAt: Int64}]}`，`name` 是文件夹名。
- 错误：无。广播：无。

```json
{"id":"r0","method":"pals.folders","params":{}}
{"id":"r0","result":{"folders":[{"path":"/Users/demo/code/site","name":"site","lastUsedAt":1792310400000},{"path":"/Users/demo/docs","name":"docs","lastUsedAt":1792000000000}]}}
```

### `pals.earlier`

「以前的」列表：已结束的、自动收起的、电脑上最近结束的对话，合并后按 `at` 新到旧排。

- 参数：`{limit?: Int, folder?: string}`。`limit` 默认 50，最大 200。`folder` 同 `pals.recent`。
- 返回：`{items: EarlierItem[]}`

```
EarlierItem {
  kind: "ended" | "folded" | "recent",
  key: String,          // "ended:<sessionId>" | "folded:<palId>" | "recent:<sessionId>"，稳定，做列表 id
  id?: String,          // folded 才有：会话 id
  sessionId: String,    // 三种都有
  name: String,         // recent 用 pals.recent 的 title
  cwd: String,
  at: Int64,            // ended: 结束时间；folded: lastUsedAt；recent: lastModified
  workspaceId?: String  // 仅 ended，结束前所属的工作区
}
```

- 去重：一个 sessionId 只出现一次，优先级 `folded` > `ended` > `recent`。正在作为会话托管的不出现在 `ended`/`recent`。
- 错误：无（读不到电脑上的对话时 `recent` 部分为空）。
- 广播：无。列表变化跟着 `pals.updated`，app 看到后重拉。

```json
{"id":"r9","method":"pals.earlier","params":{"limit":20}}
{"id":"r9","result":{"items":[{"kind":"folded","key":"folded:pal_77aa00bb11cc","id":"pal_77aa00bb11cc","sessionId":"0d8e4b6a-2c11-4f3e-8d9a-5b6c7d8e9f01","name":"周报","cwd":"/Users/demo/docs","at":1792000000000},{"kind":"recent","key":"recent:5a1f2e3d-4c5b-4a69-8788-99aabbccddee","sessionId":"5a1f2e3d-4c5b-4a69-8788-99aabbccddee","name":"修复构建","cwd":"/Users/demo/code/app","at":1791900000000}]}}
```

### 「以前的」怎么接着聊：新增 `pals.resume`

决定：加一个 `pals.resume`，app 不用按 `kind` 分支调 `pals.wake` 或 `pals.adopt`。`pals.wake` 和 `pals.adopt` 原样保留（`adopt` 还是「从终端搬进来…」的入口）。

- 参数：`{key: string}`（`EarlierItem.key`），或 `{kind, sessionId}` 二选一也可（给了 `key` 就忽略后者）。
- 返回：`{pal: Pal}`
- 行为：`folded:` 对应 `pals.wake`（会话本来就在，只是被收起；唤醒后 `lastUsedAt` 更新，所以 `folded` 变回 `false`）。`ended:` 和 `recent:` 对应 `pals.adopt` 的已结束分支（新建 `Pal`，沿用名字和文件夹）；`ended:` 且原工作区还在时，恢复加入该工作区。
- 错误：该项已不存在（已被别处接管、记录过期）；对话正在电脑上的终端里打开（沿用 `pals.heldJustNow`，让主人先退出终端）；会话数达上限；醒着的会话已满且无法让别的睡去时同 `pals.wake`。
- 广播：`pals.updated`，必要时 `workspaces.updated`。

```json
{"id":"r10","method":"pals.resume","params":{"key":"recent:5a1f2e3d-4c5b-4a69-8788-99aabbccddee"}}
{"id":"r10","result":{"pal":{"id":"pal_55e0c4a1b2d3","name":"修复构建","cwd":"/Users/demo/code/app","sessionId":"5a1f2e3d-4c5b-4a69-8788-99aabbccddee","status":"starting","pending":0,"createdBy":"owner","updatedAt":1792310600000,"attention":"idle","folded":false}}}
```

## 3. 工作区

### 数据

```
Workspace {
  id: String,                 // ws_<hex>
  name: String,               // 空串表示还没起名，界面显示成员名拼起来
  memberIds: [String],        // 会话 id，顺序即侧栏顺序
  layout: LayoutNode | null,  // 平铺布局，null 表示还没排（app 用默认排法）
  createdAt: Int64,
  updatedAt: Int64
}
```

一个会话最多属于一个工作区，由 host 强制。工作区里的会话不会自动收起。工作区的右侧栏标签不在这里，存在 `workbench.tabs` 的 `"ws:<id>"` 键下。

### 布局树 `LayoutNode`

模型沿用 Bento 的 `LayoutTree.Node`：单位画布 [0,1]×[0,1] 上的比例矩形，每个节点带 `w h x y`。区别只有叶子：Bento 的 `id: Int` 换成 `session: String`（会话 id）。因为 Swift 合成的枚举 Codable 格式不适合线上，这里用显式的 `type` 字段，app 要手写 `Codable`。

```
LayoutNode =
  { "type": "leaf",   "session": String, "w": Double, "h": Double, "x": Double, "y": Double }
| { "type": "hsplit", "w": Double, "h": Double, "x": Double, "y": Double, "children": [LayoutNode] }   // 子项左右并排
| { "type": "vsplit", "w": Double, "h": Double, "x": Double, "y": Double, "children": [LayoutNode] }   // 子项上下叠放
```

规则：

- 根的 `x y` 为 0，`w h` 为 1。每个 split 至少两个子节点，子项的矩形铺满父矩形，没有缝。
- 叶子的 `session` 在整棵树里不重复，且必须是 `memberIds` 的成员。
- host 只做轻校验和存储：解析失败、`session` 重复、不在成员里则拒绝；比例是否铺满不校验，客户端用 `LayoutTree` 的 renormalize 修正。
- 成员被摘掉（`workspaces.move`、`pals.end`、`pals.remove`）时，host 把对应叶子从树里删掉，兄弟节点顶上，不做比例重算（app 重算）；树空了则 `layout` 变 `null`。
- 以最后写入者为准，不合并（plan §6.8）。

```json
{"type":"hsplit","w":1,"h":1,"x":0,"y":0,"children":[
  {"type":"leaf","session":"pal_3f9a1c0b2d4e","w":0.5,"h":1,"x":0,"y":0},
  {"type":"vsplit","w":0.5,"h":1,"x":0.5,"y":0,"children":[
    {"type":"leaf","session":"pal_55e0c4a1b2d3","w":0.5,"h":0.5,"x":0.5,"y":0},
    {"type":"leaf","session":"pal_77aa00bb11cc","w":0.5,"h":0.5,"x":0.5,"y":0.5}]}]}
```

### 右侧栏标签 `PaneTab`

```
PaneTab =
  { "kind": "files" }                      // 文件树；范围由所属 agent 决定：会话是它的文件夹，Palo 是默认文件范围
| { "kind": "library" }                    // 成果库
| { "kind": "preview", "path": String }    // 预览一个文件，path 是 host 上的绝对路径，按 files.read 的路径规则
| { "kind": "web", "url": String }         // 网页，只接受 http 和 https
```

- 标签按数组顺序显示，`files` 和 `library` 各最多一个，`preview` 同一 `path` 只一个，`web` 同一 `url` 只一个。host 去重，不报错。
- host 校验：`kind` 认识，`preview.path` 非空，`web.url` 是 http(s)。不检查文件是否存在。
- 未知 `kind`（新版本 app 写的）host 原样保留，只在不认识时不报错，避免多设备版本不一致时丢状态。

### `workspaces.list`

- 参数：无。
- 返回：`{workspaces: Workspace[]}`，按 `updatedAt` 新到旧。
- 错误：无。

```json
{"id":"w1","method":"workspaces.list","params":{}}
{"id":"w1","result":{"workspaces":[{"id":"ws_a1b2c3d4e5f6","name":"官网","memberIds":["pal_3f9a1c0b2d4e","pal_55e0c4a1b2d3"],"layout":null,"createdAt":1792300000000,"updatedAt":1792310000000}]}}
```

### `workspaces.create`

- 参数：`{name?: string, memberIds: string[]}`。`memberIds` 至少一个。
- 返回：`{workspace: Workspace}`
- 行为：成员已在别的工作区的，先从旧的摘出来（迁移），旧工作区变空则一并删除。`layout` 初始为 `null`。
- 错误：`memberIds` 为空；有成员不存在；名字过长（40 字）。
- 广播：`workspaces.updated`；成员的 `workspaceId` 变了，所以也发 `pals.updated`。

```json
{"id":"w2","method":"workspaces.create","params":{"name":"官网","memberIds":["pal_3f9a1c0b2d4e","pal_55e0c4a1b2d3"]}}
{"id":"w2","result":{"workspace":{"id":"ws_a1b2c3d4e5f6","name":"官网","memberIds":["pal_3f9a1c0b2d4e","pal_55e0c4a1b2d3"],"layout":null,"createdAt":1792300000000,"updatedAt":1792300000000}}}
```

### `workspaces.update`

只改给出的字段。客户端拖分隔线时节流 500ms 调用。

- 参数：`{id: string, name?: string, layout?: LayoutNode | null}`
- 返回：`{workspace: Workspace}`
- 错误：工作区不存在；`layout` 不合法（见布局树规则）；名字过长。
- 广播：`workspaces.updated`（包括发起的这台，app 用 `updatedAt` 丢掉比自己新写入还旧的回声）。

```json
{"id":"w3","method":"workspaces.update","params":{"id":"ws_a1b2c3d4e5f6","name":"官网改版"}}
{"id":"w3","result":{"workspace":{"id":"ws_a1b2c3d4e5f6","name":"官网改版","memberIds":["pal_3f9a1c0b2d4e","pal_55e0c4a1b2d3"],"layout":null,"createdAt":1792300000000,"updatedAt":1792310100000}}}
```

### `workspaces.move`

把一个会话移进、移出或移到另一个工作区。成员的增删都走这一个方法；多选就逐个调用。

- 参数：`{palId: string, workspaceId?: string}`。不给 `workspaceId` 表示移出，变回普通会话。
- 返回：`{workspaces: Workspace[]}`，所有被改动的工作区（旧的和新的，旧的变空则已删除，不在里面）。
- 行为：互斥由 host 强制，会话在别的工作区时先从那边摘出来。摘出成员时按布局树规则删叶子。旧工作区因迁移变空会被删。新成员加在 `memberIds` 末尾，不改 `layout`（app 自己把它放进树里再 `workspaces.update`）。
- 错误：会话不存在；`workspaceId` 不存在。
- 广播：`workspaces.updated` 和 `pals.updated`。

```json
{"id":"w4","method":"workspaces.move","params":{"palId":"pal_77aa00bb11cc","workspaceId":"ws_a1b2c3d4e5f6"}}
{"id":"w4","result":{"workspaces":[{"id":"ws_a1b2c3d4e5f6","name":"官网","memberIds":["pal_3f9a1c0b2d4e","pal_77aa00bb11cc"],"layout":null,"createdAt":1792300000000,"updatedAt":1792310200000}]}}
```

### `workspaces.delete`

- 参数：`{id: string}`
- 返回：`{ok: true}`
- 行为：成员变回普通会话，不结束它们。
- 错误：工作区不存在。
- 广播：`workspaces.updated`、`pals.updated`。

```json
{"id":"w5","method":"workspaces.delete","params":{"id":"ws_a1b2c3d4e5f6"}}
{"id":"w5","result":{"ok":true}}
```

### 事件 `workspaces.updated`

和 `pals.updated` 一样整表替换，数据是 `{workspaces: Workspace[]}`。

```json
{"event":"workspaces.updated","data":{"workspaces":[{"id":"ws_a1b2c3d4e5f6","name":"官网","memberIds":["pal_3f9a1c0b2d4e"],"layout":null,"createdAt":1792300000000,"updatedAt":1792310300000}]}}
```

### `workbench.tabs.get` 与 `workbench.tabs.set`

右侧栏的标签状态，由 host 保存（和工作区一起放在 `workbench.json`），按「上下文 key」存：

- `"palo"`：助理；
- `"pal:<会话id>"`：不在工作区里的会话；
- `"ws:<工作区id>"`：工作区（里面所有格共用一个右侧栏）。

```
TabsState { tabs: [PaneTab], active: Int, open: Bool, updatedAt: Int64 }
```

`workbench.tabs.get`

- 参数：`{key?: string}`。不给则返回全部。
- 返回：`{states: {[key]: TabsState}}`。没存过的 key 不出现，app 用默认（`open: false`，`tabs: []`，`active: 0`）。
- 错误：无。

`workbench.tabs.set`

- 参数：`{key: string, tabs: PaneTab[], active?: Int, open: Bool}`。整体替换。客户端节流 500ms，以最后写入为准。
- 返回：`{state: TabsState}`
- 错误：key 格式不对，或指向不存在的会话或工作区；`tabs` 不合法。
- 广播：`workbench.updated`，数据 `{key, state}`；发起的这台也会收到，app 用 `updatedAt` 去回声。会话被 `pals.end` 或 `pals.remove`、工作区被删时，对应 key 一并删除，广播 `{key, state: null}`。

```json
{"id":"p1","method":"workbench.tabs.set","params":{"key":"pal:pal_3f9a1c0b2d4e","tabs":[{"kind":"library"},{"kind":"web","url":"https://example.com"}],"active":1,"open":true}}
{"id":"p1","result":{"state":{"tabs":[{"kind":"library"},{"kind":"web","url":"https://example.com"}],"active":1,"open":true,"updatedAt":1792310400000}}}
{"event":"workbench.updated","data":{"key":"pal:pal_3f9a1c0b2d4e","state":{"tabs":[{"kind":"library"},{"kind":"web","url":"https://example.com"}],"active":1,"open":true,"updatedAt":1792310400000}}}
```

## 4. `sync` 新增

`sync` 的返回多两个键（老 app 忽略即可）：

- `workspaces: Workspace[]`
- `workbenchTabs: {[key]: TabsState}`（等同 `workbench.tabs.get` 不带参数）

会话列表仍然不在 `sync` 里（沿用 `pals.list` 和 `pals.updated`）。`hello` 不变。

```json
{"id":"s1","method":"sync","params":{"sinceSeq":120}}
{"id":"s1","result":{"seq":130,"messages":[],"tasks":[],"approvals":[],"questions":[],"watches":[],"artifacts":[],"settings":{},"status":{},"workspaces":[{"id":"ws_a1b2c3d4e5f6","name":"官网","memberIds":["pal_3f9a1c0b2d4e"],"layout":null,"createdAt":1792300000000,"updatedAt":1792310300000}],"workbenchTabs":{"palo":{"tabs":[{"kind":"library"}],"active":0,"open":true,"updatedAt":1792310000000}}}}
```

（示例里只列了和本文有关的键，其余按现有 `sync` 不变；`settings` 新增 `foldDays: Int`（默认 3，`0` 表示不自动收起）和 `maxAwake: Int`（默认 8），都经 `settings.update` 修改。）

## 5. 汇总

新增方法（进 `RPC_METHODS` 和 `RPCMethod.all`）：`pals.create`、`pals.folders`、`pals.detail`、`pals.setModel`、`pals.compact`、`pals.stopTask`、`pals.seen`、`pals.end`、`pals.reveal`、`pals.earlier`、`pals.resume`、`workspaces.list`、`workspaces.create`、`workspaces.update`、`workspaces.move`、`workspaces.delete`、`workbench.tabs.get`、`workbench.tabs.set`。

新增事件：`workspaces.updated`、`workbench.updated`。`pals.updated` 形状不变。

方法名的取舍：`pals.setModel` 和 `pals.stopTask` 按 `workbench-plan.md` §2.3，驼峰，和 `pairInvite`、`pushRegister` 一类一致；`workspaces.move` 取代了成员增删；标签状态用 `workbench.tabs.*`，不再有工作区自己的 `tabs`。线上字段名按 Phase 0 任务书用 `attention`、`finishedAt`、`seenAt`、`contextPct`，计划 §2.2 里的 `state`、`ctx`、`costUsd` 对应 `attention`、`contextPct`、`pals.detail` 里的 `costTotalUsd`。host 内部用一个 `workbench.json` 存工作区、标签状态和 `ended` 列表，对 app 不可见。计划里的 `pals.tasks` 不再单设，任务并入 `pals.detail.tasks`。
