# PaloAlly 工作台 PRD 实施计划

说明:以下结论来自我读过的代码。没读过的地方我标了「未核实」。

改动类别标记:
- **R** = 原样复用
- **R+** = 复用并做小改
- **B** = 从 Bento 拷贝
- **N** = 真正新写

## 0. 先说结论

1. 复用约束基本可以满足。`PalPage` 已经通过 `store.palStore(id)` 给每个 Pal 一个独立的 `AppStore`,所以一格的内容就是 `ChatView` 加这个 store,不用重写。
2. 主要的新东西有五块:
   - host 侧的「会话生命周期」:新建、状态、seen、自动收起、结束。
   - host 侧的工作区持久化。
   - 平铺布局宿主(SwiftUI)。
   - 标题胶囊和详情浮层。
   - 侧栏收起后的玻璃胶囊和悬浮侧栏。
3. PRD 里有几处和现有代码冲突,见第 4 节。最大的一处是:host 目前最多同时醒着 5 个 Pal(`MAX_AWAKE`),20 分钟不动就睡(`sleepIdleMs`),而平铺可能同时开 6 格以上。

## 1. PRD 逐节对照

### 1.1 §2、§3 概念和状态

| 项 | 现状(已核实) | 缺什么 | 类别 |
| --- | --- | --- | --- |
| 会话 = Pal | `host/src/pals.ts` 的 `Pals`、`palSession.ts` 的 `PalSession`;app 侧是 `Pal` 模型(`ios/PaloAllyKit/Sources/PaloAllyKit/Models/Pals.swift`) | 界面文案里不再出现「Pals」「帮手」(`ConversationList` 的节标题 `Text("Pals")`、`PalPage` 菜单里的「移出 Pals」、`PalCopy.swift`、`SessionCopy.swift`) | R+(只改文案) |
| 状态 | `PalStatus` 只有 `busy/idle/waiting/starting/stopped/asleep/unknown`。`PalSession.status()` 的判定:`pendingCards()>0` 为 waiting,`busy` 为 busy | 没有「做完了」,也没有 seen。Palo 的未读只有 `AppModel.markSeen()` 的 per-host `lastSeen`,没有 per-会话的 seen | N(host 加 `state` 和 `seen`) |
| 「等你」推送 | 已有 `Pals.pushWaiting` 通过 `router.proactive` 推送 | 无 | R |
| 工作区、自动收起 | 没有 | host 持久化 | N |

### 1.2 §4、§12 侧栏和 iPhone 首页

- 现状:`MainScreen` 里是 `NavigationSplitView`。侧栏 `ConversationList` 是 `List(selection: $model.selection)`,按顺序排:
  - `PaloRow`
  - `Section("Pals")`:`PalRow`、`OtherSessionRow`、`RecentListRow`
  - Allies
  - 设备
- 选中值是 `AppModel.Conversation`:`.palo/.pal/.ally/.recent/.session/.devices`。
- 缺:
  - Palo 大卡片。
  - 工作区节(可展开)。
  - 普通会话,按最近活动排,最后一行「以前的 N」。
  - ＋菜单、状态点统一。
  - `Conversation` 要加 `.workspace(id)`。
- 做法:
  - **R+** 保留 `NavigationSplitView` 和 `List(selection:)`,改 `ConversationList` 的 sections。
  - **R+** 复用 `PalTile`、`PalRow` 的圆点颜色逻辑(`Copy.palStatusColor`)。
  - **R+** iPhone 首页就是同一个 `ConversationList`(`compactColumn` 已经支持),只改内容。
  - `OtherSessionRow` 是「电脑上别的 Claude Code 会话,要接管」。PRD 没提它。建议收进「以前的」页,或者放进新建菜单的「接管电脑上的会话」,待确认(见第 5 节)。

### 1.3 §5 主区域和平铺

- 现状:`ConversationDetail` 按 `selection` 切换 `ChatView()`(Palo)和 `PalPage(palID:)`(会话)。
- `.workspace(id)` 是新 case。
- 平铺宿主:
  - **B** `LayoutTree.swift`:纯数据,树结构加 Codable。只依赖 `BentoFoundation`/`BentoUI`,需要在拷贝时去掉这两个 import。我没核实它具体用了这两个包里的什么,拷贝时要看。
  - **B** `PaneDropZone.swift`:只 import CoreGraphics,可以原样拷。
  - **B(需改)** `WorkspaceViewModel.swift`(864 行):取它的布局和焦点逻辑,砍掉终端、daemon 同步部分。
  - **B(SwiftUI 重写 AppKit 部分)** `TiledPaneHost_macOS.swift`(1167 行)、`DividerOverlay_macOS.swift`。AppKit 引用很少(`NSView/NSEvent/NSCursor/NSPanel` 只有约 6 处),所以多数是 SwiftUI 逻辑,翻译成本可控。
  - 分隔线拖动:用 SwiftUI `DragGesture`。标题胶囊拖放:用 `.draggable` 加 `.dropDestination`,或 UIKit 的 `UIDragInteraction`。
  - 一格 = 现有 `PalPage` 的内容,不重写。**R+**:`ChatView` 现在读环境里的单个 `VoiceInputController`,每格需要自己的实例或用「活动格」路由。
  - 每格需要 `.environment(store.palStore(id))`,和 `PalPage` 一样。

### 1.4 §6 标题胶囊和详情

逐项对照:

| 详情项 | host | app | 类别 |
| --- | --- | --- | --- |
| 名字可改 | `pals.rename` 已有(`Pals.rename`,会同步 Claude Code 标题) | `palRename` 的 alert 已有 | R |
| 状态 | 见 1.1 | 圆点已有 | R+ |
| 文件(右栏打开树) | `files.list` 的 scope 已支持 `pal`(`FileBrowser.root`),`FileScope.pal(id)` | `FilesPanel`、`model.filesPanel`、`FileTreeView` 已有 | R |
| 在访达/终端打开 | 无 RPC | Mac 上由 app 通过 host 执行 | N(host 新 `pals.reveal {id, how:"finder"|"terminal"}`,约 20 行) |
| 模型、思考深度 | 只有 Palo 的 `model.set` / `Hub.setModel`;`MainSession.setModel/setEffort` 在 `harness/types.ts` 里有,但 `PalSession` 没暴露(用 `rec.model` 启动时传入) | `ModelPicker.swift`、`ModelRow.swift` 可复用,但它们读 Palo 的 store | host N(`pals.setModel`),app R+(ModelPicker 参数化) |
| 上下文用量 + 压缩 | Palo 有 `contextTokens`(`Conversation.lastContextTokens`),且 `/compact` 通过 `enqueue` 发送。`PalSession` 收到 `result` 但没记 `contextTokens`,也没处理 `compact` 事件 | 无 | host N(记录并下发),压缩可直接 `pals.send "/compact"`(未核实 Pal 的 `send` 是否放行 slash,需要用 fake driver 测) |
| 后台任务和子 agent,可单独停 | `PalSession.bgTasks` 只存 `taskIds`,没有标题/描述;`task_started` 在 `palSession.ts` 里没处理。Palo 侧 `tasks.ts` 有完整的 `Task` 和 `task.stop`、`Hub.stopTask`;`MainSession.stopTask(taskId)` 可用 | `TasksSection.swift`、`TaskDetailView` 读 Palo 的 tasks | host N(PalSession 记录 `task_started` 的描述、暴露 `pals.tasks` 和 `pals.stopTask`),app R+(`TasksSection` 参数化) |
| 本次用量 | `rec.costTotalUsd`、`SpendMeter.spentOn(cwd, sessionId, day, tz)`、`lastWakeUsd` 都有,但没发给 app | 无 | host R+(把 `costTotalUsd` 和今日花费加进 detail 载荷) |
| 所在工作区:并排…、移到… | 无 | 无 | N |
| 结束会话 | `pals.remove`(抛出 Pals,transcript 保留,进 `data.former`,最多 20 条)和 `pals.release`(交还终端) | 现有的 `PalPage` 的 ConfirmPanel | R+(「结束」语义用 `remove`,文案改) |
| Palo 的目标/履历/记忆 | `AssistantView` 的 `AssistantTab`(`watches` 为目标,`memory`,`tasks`)和 `MemorySection`、`WatchesSection`、`TasksSection`、`IdentityEditor`。目前是 `ManagementSheet`/`.manage` 页 | 放进详情浮层里 | R+(这些 section 视图原样放进浮层) |
| 浮层样式 | `MacPageStrip` 已经是浮在内容上的玻璃条 | 点开的玻璃浮层 | N(`.popover` + glass,iPhone 用 `.presentationDetents([.medium])`) |

### 1.5 §6 其他

| 项 | 现状 | 类别 |
| --- | --- | --- |
| 停止键替换麦克风 | `store.stop()` 和 `pals.stop`(`stopTurn`)已有。Composer 里是否有停止键、忙时发的话是否排队:我没读 `ComposerView`(1023 行),未核实 | R+(待查) |
| 工具步骤收成一行 | 未核实 `MessageRow` 是否已折叠 | 待查 |
| 后台任务一条 | 无 | N(小) |
| 「Palo 转来的」标注 | `peerWrap`(`palSession.ts`)已包装转来的话,`CCMessage` 有 `peer` 角色 | R+(`MessageRow` 加一个标签) |

### 1.6 §7 右侧栏

- 现状:
  - `.inspector` 里的 `LibraryPanel` 里放 `FilesPanel` 或 `LibraryView`,由 `model.filesPanel` 决定。
  - 打开链接:`FileLinks.swift`、`FilesNavigation.swift`。
  - 预览:`PaloAllyFilePreview` 包。
- 缺:
  - 标签条(浏览器标签)。
  - 网页标签不重载:**B** `PreviewDock_macOS.swift`(333 行)。它依赖 `BentoFilePreviewKit` 和 `BentoVoiceKit`,需要去依赖,改成 PaloAlly 的 `PaloAllyFilePreview`。
  - 每个工作区、会话、Palo 页各记一份标签和开关,由 host 保存。
- 第一个标签:Palo 页是成果,会话页是文件。
- 做法:**R** `LibraryView` 和 `FilesPanel` 原样作为第一个标签的内容;新的只有标签栏和 per-上下文的状态(N)。

### 1.7 §8 侧栏收起

- 现状:`model.columnVisibility`、`MacWindowChrome` 里系统侧栏按钮。
- 缺:
  - 红绿灯旁的玻璃胶囊:N。
  - 鼠标靠左边缘浮出侧栏:N,Catalyst 可用 `.onContinuousHover` 加左边缘 8pt 的透明热区。
  - iPad 边缘滑动:`UIScreenEdgePanGestureRecognizer`。
- 玻璃浮层可以用已有的 `glassEffect`(`MacPageStrip` 里已经在用)。

### 1.8 §9 新建

- 现状:没有「在任意文件夹新建会话」。
  - `Pals.create` 是 private,只能由 Palo 的 `pal_propose` 提案,owner 点「开吧」(`decide`)触发。
  - 它要求 name、duty、dailyUsd>0 都有(`checkProposal`),并且拒绝 PaloAlly 自己的目录。
  - 文件夹选择已有:`files.folders.browse`/`add`、`FilePickers.swift`、`DirectoryPickerPath.swift`、`LazyDirectoryTreeStore`。
  - 最近用过的文件夹列表:没有。可以从 `Pals.recent` 的 cwd 加 pals 的 cwd 推出来(host 新方法 `pals.folders`)。
- 缺:
  - N:host 的 `pals.create {cwd, name?, workspaceId?}`。需要放宽 `checkProposal`:没有 duty 和 dailyUsd 也能建,`createdBy:"owner"`,名字为空先给占位名,第一轮结束后自动命名。已有 `readTitle` 在每轮结束后读回 Claude Code 的标题,可以复用它做自动命名。
  - N:app 的新建面板(最近文件夹加搜索,⌘N 加 ⌘↩)。用 `NewPaneDirectoryPanel_macOS.swift`(207 行)做**B**参考,但它是 `NSOpenSavePanel` 加 NSView accessory,需要用 SwiftUI 重写,只拷逻辑。

### 1.9 §10 沉浸感

- 现状:
  - `MacPageStrip` 已经用 `safeAreaBar` 做浮在内容上的标题条。
  - `ChatView` 的输入框是 `.safeAreaInset(edge: .bottom)`(`ChatView.swift` 201 行)。
  - `ChatScroll.Metrics` 从 `ScrollGeometry.contentInsets` 读 `insetTop`、`bottomInset`,所以对内容穿过玻璃条这件事,坐标器已经在用 inset 处理。
  - 所以 Mac 上顶部其实已经是沉浸的。
- 缺:
  - iPhone 和 iPad 目前用系统导航栏。改成同样的浮动胶囊要动 `ChatView` 的 `pageTop`。
  - 「滚动到边缘只做轻微模糊,不用实心条」靠系统的 scroll edge effect(`safeAreaBar` 本来就有)。
- 风险点:每格是 `ChatView` 嵌在一个更小的容器里。坐标器依赖窗口坐标(`FloatingTitleOrb` 用了 `.global`),格内需要改成局部坐标。

### 1.10 §11 语音

- 现状:`VoiceInputController` 单实例放在 `MainScreen` 的 environment 里。`ChatView` 里有 `VoiceScrimLayer`、`VoiceWordsLayer(orbPlacement:)`,`FloatingTitleOrb`、`OrbPresence`、`VoiceInputOverlay.swift`(843 行)。
- 缺:
  - 球只在对 Palo 说话时出现,球从侧栏的 Palo 项飞出来。
  - 对会话说话时:不出现球,标题胶囊上的状态点变音量条,边框发亮。
- 做法:
  - **R** 麦克风、听写、三个松手区域整套原样用。
  - **R+** `ChatView` 加参数 `voiceStyle: .orb | .tile`:
    - `.tile` 隐藏 `FloatingTitleOrb`,在胶囊上显示音量。
    - 只对 `.orb` 保留现有行为。
  - 球从侧栏飞出:N,小工作量,用 `matchedGeometryEffect` 或 `onGeometryChange` 取侧栏 Palo 项的 frame。
  - 现有 `PalPage` 的语音已经走同一个 controller,所以会话页上「不出现球」可能需要改,待核实 `FloatingTitleOrb` 在 `PalPage` 里是否显示。
  - 平铺时:多个 `ChatView`,一个 `VoiceInputController`。要用「活动格」路由:只有活动格的 composer 挂载 voice。

## 2. host 侧新增数据与 RPC(契约)

### 2.1 持久化

新文件放在现有 `Paths` 里(`host/src/config.ts`,具体字段名未核实)。`writeJson/readJson` 是现有模式,沿用 `Pals.save()` 的做法。

```
workbench.json
{
  workspaces: [{ id, name, members: [palId], layout: <LayoutTree JSON>, activePal, createdAt }],
  tabs: { [contextKey]: { open: bool, active: tabId, tabs: [{id,kind,url|path|artifactId,title}] } },
    // contextKey = "palo" | "pal:<id>" | "ws:<id>"
  seen: { [palId]: lastDoneAt },
  foldDays: 3
}
```

PalRecord 加字段(在 `palSession.ts` 的 `PalRecord`):
- `workspaceId?`
- `doneAt?`
- `seenAt?`
- `endedAt?`
- `autoNamed?`

### 2.2 Pal 线上载荷(`Pal` 类型加字段,app 的 `Pals.swift` 同步)

- `state`: `"working" | "waiting" | "done" | "idle"`。这是由 `status`、`pending`、`doneAt/seenAt` 推导出来的,不改原有 `status`,老客户端不受影响。
- `workspaceId?`、`folded?`、`effort?`、`ctx?: {used, window?}`、`costUsd?`、`todayUsd?`。

### 2.3 新增 RPC

在 `rpc.ts` 的 `RPC_METHODS` 加,并要在 `test/protocol.test.ts` 里逐个驱动(现有约定:每个方法和事件都必须在那里触发,并写出 Swift 解码用的样本)。

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `pals.create` | `{cwd, name?, workspaceId?, text?}` | `{pal}` |
| `pals.folders` | `{}` | `{folders:[{path,name,lastUsedAt}]}` |
| `pals.seen` | `{id}` | `{pal}`(清除「做完了」) |
| `pals.end` | `{id}` | `{}`(等价 `remove`,记 `endedAt`,进 earlier) |
| `pals.earlier` | `{limit?, before?}` | `{sessions:[…]}`,合并「结束的 + 超过 foldDays 的普通会话 + `Pals.recent`」 |
| `pals.setModel` | `{id, model?, effort?}` | `{pal}` |
| `pals.detail` | `{id}` | `{ctx, models, tasks:[{id,title,kind,status}], costUsd, todayUsd}` |
| `pals.compact` | `{id}` | `{}` |
| `pals.stopTask` | `{id, taskId}` | `{}` |
| `pals.reveal` | `{id, how}` | `{}` |
| `workspaces.list/create/update/delete` | 名字、成员、布局 | 完整的工作区 |
| `workspaces.move` | `{palId, workspaceId?}` | |
| `workbench.tabs.get/set` | `{key}` / `{key, state}` | |

新增事件:`workspaces.updated`、`workbench.updated`(`RPC_EVENTS` 里加,同样要被测试触发)。`pals.updated` 现有通道继续用,载荷多几个字段。

自动收起不用定时器:`list()` 里按 `lastUsedAt` 和 `foldDays` 计算 `folded`,在 `Pals.start()` 已有的定时检查里顺手触发 `emitSoon()`。

## 3. 分阶段计划

原则:host 阶段(TS,`bun test`,不需要 Xcode)和 app 阶段文件互不重叠,可并行。契约在 H1 结束时冻结,app 先用 fixtures。

### 总览

| 阶段 | 负责 | 内容 | 预估 |
| --- | --- | --- | --- |
| H1 | host | 状态、seen、earlier、end、create | 5–6h |
| H2 | host | 会话详情(模型、上下文、任务、用量、reveal) | 5–6h |
| H3 | host | 工作区、标签持久化 | 4–5h |
| A1 | app | 模型层、侧栏树、状态点、以前的页 | 6h |
| A2 | app | 新建面板、标题胶囊、详情浮层 | 7h |
| A3 | app | 工作区平铺 | 8h |
| A4 | app | 右侧栏标签 | 6h |
| A5 | app | 侧栏收起、浮出、胶囊 | 5h |
| A6 | app | 语音(格内、球飞出)、沉浸、iPhone | 6h |

并行关系:H1 完成后 A1 开工;H2 对应 A2;H3 对应 A3 和 A4。A5 和 A6 只依赖 app 自身,可以在 H3 期间做。

### H1(host):生命周期和状态

- 改:
  - `host/src/pals.ts`(`create` 放宽并公开、`end`、`earlier`、`folders`、`seen`)
  - `host/src/palSession.ts`(`doneAt/seenAt`、`toWire` 的 `state`;在 `result` 里 `endTurn()` 之后设 `doneAt`;owner 说话或 `pals.seen` 清除)
  - `host/src/types.ts`(`Pal` 加字段)
  - `host/src/rpc.ts`(方法和列表)
  - 文案在 `host/src/i18n/zh`、`en`
- 自动命名:`create` 不传 name 时用占位名,在 `onTurnEnd → readTitle` 里把 `autoNamed` 的会话改成 Claude Code 标题。这条路径已经有(`readTitle`)。
- 测试:
  - `test/pals.test.ts`:create 无 duty;done→seen 的状态流转;seen 跨两个 channel 一致(发 `pals.updated`);foldDays 计算(注入 `now`,`PalsDeps` 已有 `now`);end 后出现在 earlier,adopt 可恢复。
  - `test/protocol.test.ts`:新方法。
  - `test/fakeDriver.ts`:已有,用它。
- 真机验证:无;建议用 `pals.live.test.ts` 手跑一次 create 真 Claude Code。

### H2(host):详情

- 改:`palSession.ts`:
  - 记录 `result.contextTokens`、`compact` 事件、`task_started/task_progress/task_notification` 描述,保存成 `bgTasks` 的 Map。
  - 加 `setModel/setEffort/stopTask`,代理到 `proc`(`MainSession` 已有这些方法)。
  - 不在运行的(睡着的)Pal 改 `rec.model`/`rec.effort`,下次启动生效。`PalRecord` 加 `effort`,`mapOptions`/启动处传入(`palSession.ts` 335 行附近的 `model: rec.model` 是传入点)。
- 改 `pals.ts`、`rpc.ts`:`detail/setModel/compact/stopTask/reveal`。
  - `reveal` 在 macOS 上用 `open` 和 `osascript`/`open -a Terminal`,需要走已有的 `shellTools` 或 `util`,未核实。
  - 用量:`SpendMeter.spentOn` 和 `rec.costTotalUsd`。
- 测试:fakeDriver 需要能发 `task_started`、`compact`、带 `contextTokens` 的 `result`(看 `fakeDriver.ts` 是否已支持,未核实)。覆盖:睡着时 setModel 不唤醒;stopTask 调到 driver;compact 后 ctx 变小。
- 真机验证:用真 Claude Code 切模型,看下一轮确实换了(`init` 事件的 `model`)。

### H3(host):工作区和标签

- 新文件 `host/src/workbench.ts`:`Workbench` 类,构造方式照 `Pals`(deps 注入、`save()`、`emitSoon()`)。
- 改 `hub.ts`(接线,像 `this.pals = new Pals(...)` 那段),`rpc.ts`,`types.ts`。
- 规则:
  - 一个会话最多属于一个工作区。
  - 工作区里的会话不自动收起。
  - 在工作区里关一格 = `pals.end`,同时从布局里移除。
  - 布局树当不透明 JSON 存,host 只校验成员集合和布局叶子一致,不理解几何。
- 容量:工作区成员的 `lastUsedAt` 参与 `balance()`,避免被睡掉后用户看到「闲着」却回复慢。见风险 1。
- 测试:`test/workbench.test.ts`(CRUD、成员唯一、重启后恢复、pal 结束后成员清理);protocol 样本。
- 真机验证:无。

### A1(app):模型层和侧栏

- 改:
  - `PaloAllyKit/.../Models/Pals.swift`(新字段,**R+**)
  - 新 `Models/Workspaces.swift`
  - `Store/AppStore+Pals.swift` 加 `workspaces`、`seen`;新 `Store/AppStore+Workbench.swift`
  - `RPCTypes.swift`(方法名)
  - `AppModel.swift` 的 `Conversation` 加 `.workspace`
  - `Home/ConversationList.swift`:Palo 大卡片、工作区节、会话节、以前的 N、Allies、底部 ＋/设置
  - `RecentConversationsPage.swift` 改为「以前的」,**R+**
- 复用:`PalTile`、`PalRow` 圆点颜色、`WaitingBadge`、`palRename`。
- 测试:`PaloAllyKitTests/PalsTests.swift`、`ProtocolContractTests.swift`(读 H1 导出的样本)、新 `WorkspacesTests.swift`;`LocalizationTests`(新增字符串都要进本地化表,这个测试存在,具体规则未核实)。
- 真机验证:Mac 窗口、iPad、iPhone 各看一次侧栏;状态点四种颜色;其他设备点开后本机点变灰(需要两端)。

### A2(app):新建、胶囊、详情

- 新:`App/Sources/Workbench/TitleCapsule.swift`、`AgentDetailView.swift`(复用 `ModelPicker`、`TasksSection`、`MemorySection`、`WatchesSection`,参数化 store)、`NewSessionPanel.swift`。
- 改:`PalPage.swift`(把 `MacPageStrip` 换成胶囊;`⋯` 菜单里的功能移到详情;**R+** 保留 ConfirmPanel 流程)、`ChatView.swift`(`pageTop` 已是注入点,尽量不动)、`AssistantView.swift`(Palo 的详情复用其 section)。
- 测试:AppStoreTests 里 `createPal`、`setModel` 的 RPC 调用;UI 测试用现有 `accessibilityIdentifier` 风格。
- 真机验证:Mac 浮层位置、iPhone 半屏面板;长文件夹路径换行;离线时按钮禁用。

### A3(app):平铺

- 新:`Workbench/LayoutTree.swift`(**B**)、`PaneDropZone.swift`(**B**)、`WorkspaceLayoutModel.swift`(**B** 取自 `WorkspaceViewModel`)、`TiledWorkspaceView.swift`(**N**,SwiftUI,参照 `TiledPaneHost_macOS`)、`WorkspaceToolbar.swift`(参照 `WorkspaceToolbar_macOS.swift`,674 行,取核心)。
- 改:`RootView.swift` 的 `ConversationDetail` 增加 `.workspace` 分支;`ChatView` 加 `voiceStyle`、局部坐标参数(**R+**,最小)。
- 测试:布局树的拷贝测试跟 Bento 的 `LayoutTree` 测试一起搬(Bento 里有 Tests 目录,未核实内容);焦点、分割、交换、关闭的纯逻辑测试放 `PaloAllyKitTests`(要把 LayoutTree 放进 Kit 才能测)。
- 真机验证:Catalyst 的拖放(两种:分隔线、标题胶囊拖到另一格);iPad 11 寸最多 2 格;窗口缩放;每格 composer 的键盘焦点。

### A4(app):右侧栏标签

- 新:`Workbench/BrowserTabs.swift`、`WebTabHost.swift`(**B** 取自 `PreviewDock_macOS`:保持 `WKWebView` 存活,切换只隐藏)。
- 改:`RootView.swift` 的 `LibraryInspector`/`LibraryPanel`,**R+**:第一个标签放现有内容;`FileLinks.swift`/`FilesNavigation.swift` 的打开动作改成往标签栏加一个标签并展开侧栏。
- 测试:标签状态编码/解码、host 往返。
- 真机验证:网页标签切换不重载;每个上下文各记各的;iPhone 整页版。

### A5(app):侧栏收起

- 新:`Workbench/CollapsedSidebarCapsule.swift`、`EdgeRevealSidebar.swift`。
- 改:`MainScreen` 的 `NavigationSplitView`,**R+**:收起时用 overlay 模式,不再依赖系统挤压。
- 真机验证:Catalyst 鼠标悬停热区;ESC/点外面收回;⌃⌘S。

### A6(app):语音、沉浸、iPhone 收尾

- 改:`ChatView`、`VoiceInputOverlay`、`TitleOrb`(球飞出;`.tile` 模式音量条)。
- iPhone:会话页右上的按钮打开整页(复用 `FilesPanel`/`LibraryView` 的 push 路径,`libraryBeside` 已经区分 phone)。
- 真机验证:iPhone 真机(按住说话);Mac 上玻璃效果 macOS 27 才有,低版本回退要看(`glassEffect` 现在已在用,说明目标版本满足,未核实最低版本)。

## 4. 与现有行为的冲突

| 冲突 | 说明 | 建议 |
| --- | --- | --- |
| 5 个醒着上限 | `MAX_AWAKE = 5`,`sleepIdleMs = 20min`,`balance()` 会让最久未用的空闲会话睡眠。平铺 6 格以上,或者「做完了」后 20 分钟,会话会睡下去。状态里 `asleep` 会被显示成「闲着」,但回复要先唤醒 | 工作区成员和当前可见的格不参与睡眠挑选;`MAX_AWAKE` 调到 8 左右并配置化。需要用户确认 |
| 创建门槛 | `checkProposal` 要求 duty 和 `dailyUsd>0`,名字必填且唯一 | `pals.create` 走另一条路径,不改提案路径 |
| 「结束」语义 | `remove` 会把会话放进 `former` 并只保留 20 条;PRD 的「以前的」是长期列表 | `earlier` 直接读 SDK 的 `listSessions`(`Pals.recent` 已经这样做,30 天、50 条上限),另加 `endedAt` 做排序,别依赖 `former` |
| 「Pals」「帮手」用词 | `PalCopy.swift`、`ConversationList`、`PalPage` 菜单、host 的 i18n 里都有 | 统一文案清理放在 A1/A2 里 |
| `交还终端` | PRD 不再提它,详情里只有「在终端里打开」 | 保留 `pals.release` 作为详情里的次要项,待确认 |
| 「它」页 | PRD 把它并进 Palo 详情,但 `AssistantView` 是整页,有导航栈 | 保留页面作为「查看全部」的后备,详情里放精简版 |
| Palo 的 seen | 现在没有 per-会话 seen,`AppModel.markSeen()` 是 per-host 的 `lastSeen` | 新机制只管 Pal,Palo 保持不变 |
| 一个窗口一个 Palo 球 | 现在球在标题里(`FloatingTitleOrb`),PRD 要球在侧栏 | A6 才动,改动集中在 `ChatView` 头部 |

## 5. 风险与待确认

### 风险

1. **Catalyst 的限制**:
   - 悬停:`onContinuousHover` 在 Catalyst 可用,但窗口最左边缘 1–2pt 常被系统窗口缩放热区吃掉,热区要至少 6–8pt,需要在真机上验证。
   - 浮动侧栏:系统 `NavigationSplitView` 在 Catalyst 里不支持 overlay 样式,收起模式要自己做 overlay。`MacWindowChrome` 现在装了 `NSToolbar`(见 `MacToolbarInstaller`),要检查它和自绘的胶囊不冲突。
   - Glass:`glassEffect` 在 Catalyst 已经被 `MacPageStrip` 使用,可行。多个 glass 叠加会有性能问题,每格 2–3 个已经不少,需要在 6 格情况下真机看帧率。
   - 拖放:SwiftUI `.draggable`/`.dropDestination` 在 Catalyst 可用,但跨 `WKWebView`、跨 `ScrollView` 的命中有坑。分隔线拖动不用 DnD,用 `DragGesture`;标题胶囊拖到别的格用 `UIDragInteraction`/`UIDropInteraction` 作备选。
2. **沉浸式聊天与 `ChatScroll` 坐标器**:`ChatScrollCoordinator.swift`(1163 行)读 `ScrollGeometry.contentInsets`,Mac 上已经是 `safeAreaBar`(顶)加 `safeAreaInset`(底),这个模式可以直接推广到 iPhone/iPad。风险是:
   - 一个窗口内有多个坐标器实例(多格),`ChatScroll.lastDistance`、`debugDistance`、`uiScrollView` 是 `static` 单例,只用于日志和 DEBUG,不影响功能,但日志会混。
   - `FloatingTitleOrb` 用 `.global` 坐标,格内会错位,所以格内必须关掉它(`voiceStyle: .tile`)。
   - 不要改坐标器本身,只通过 inset 与参数影响它。
3. **每格一个 `AppStore`**:`palStore(id)` 做了缓存,6 格没问题。但 `reloadPalHistory` 会在创建时拉历史,同时开多格会并发多次 `pals.history`,可接受。
4. **语音多格**:`VoiceInputController` 是单实例,多格要路由到活动格(见 1.10)。
5. **iPad 两格上限**:要在 A3 中把「放不下」判断做成纯函数,可测试。
6. **推送**:PRD 要求任何会话变成「等你」都推送,`pushWaiting` 已有,但需确认已走 `router.proactive`,且对 owner 创建的会话也触发(未核实是否只针对 palo 创建的)。
7. **Bento 拷贝的许可和依赖**:`LayoutTree` 等 import 了 `BentoFoundation/BentoUI`,拷贝时必须逐个去依赖,先 `grep` 实际用了什么。

### 待确认的问题

1. `MAX_AWAKE` 提到多少?工作区成员是否永不睡眠?
2. 电脑上别的 Claude Code 会话(`OtherSessionRow`、`pals.adopt`)放哪里?
3. 「交还终端」保留吗?
4. 新会话没有 duty 和每日上限,要不要给 owner 创建的会话一个默认的花费上限?
5. 自动收起的「几天没动」按 `lastUsedAt` 还是按 transcript 最后修改时间?我建议 `lastUsedAt`。

## 6. 「真正新写」的清单(尽量短)

1. host:`pals.create`(放宽的创建)、`state/seen/doneAt`、`earlier/end`。
2. host:Pal 的 `setModel/effort`、上下文、后台任务描述和 `stopTask`、`reveal`。
3. host:`workbench.ts`(工作区加标签持久化)。
4. app:`TiledWorkspaceView`(SwiftUI 宿主,逻辑取自 Bento)。
5. app:`TitleCapsule` 和 `AgentDetailView` 的外壳(内容全部复用)。
6. app:`NewSessionPanel`(最近文件夹加搜索)。
7. app:右侧栏标签栏(`WKWebView` 保活逻辑取自 Bento)。
8. app:收起后的玻璃胶囊和边缘悬浮侧栏。

其余全部是 **R** 或 **R+**。

### Critical Files for Implementation
- host/src/pals.ts
- host/src/palSession.ts
- host/src/rpc.ts
- ios/App/Sources/App/RootView.swift
- ios/App/Sources/Home/ConversationList.swift

## 7. 产品决定（2026-10-18，裁定第 4、5 节的冲突和待确认问题）

1. **「在终端里打开」只开一个普通 shell**，cd 到这个文件夹，不 resume 会话；会话照常由主机托管。和单写者保护没有冲突。
2. **界面上只留「结束这个会话」**（= `pals.end`，进「以前的」，可以接着聊）。「交还终端」从界面上去掉；`pals.release` 这个 RPC 保留，不删。
3. **电脑上别的 Claude Code 会话**（`OtherSessionRow`、`pals.adopt`）不在侧栏单独占一节。侧栏 ＋ 菜单加第三项「从终端搬进来…」，进入现在的接管流程，用来一次性搬家。
4. **醒着的上限**：`MAX_AWAKE` 调到 8，并做成配置项。工作区里正在显示的格不参与睡眠挑选。其余仍按 20 分钟空闲就睡。
5. **主人自己新建的会话不设每日花费上限**，和在终端里用一样。Palo 提议开的会话，仍然沿用现有的预算。
6. **自动收起按 `lastUsedAt` 计算**，默认 3 天。
7. **「做完了」不推送**，只有「等你」推送。推送对主人新建的会话也要生效，要核实。
8. **新会话的内部名**用 `session-<短id>`，界面显示「新会话」；第一轮结束后，用 `readTitle` 自动起名，重名加数字。
9. **「它」页**：完整页面保留，作为「查看全部」的入口；Palo 的详情里放三块的精简版。
10. **改叫法**：界面文案、推送、host 给主人看的提示里，「帮手」「Pals」统一改成「会话」。给模型看的工具名（`pal_send`、`pal_propose` 等）不改。
11. **布局树和标签状态由主机保存**，以最后一次写入为准，客户端写入节流 500ms。

## 8. 总原则（主人要求）

复用或复制现有的东西。已经布局好、反复打磨过的部分不要重写：
- 对话：`ChatView`、`MessageRow`、`ReplyText`、`SelectableMarkdown`，以及 `ChatScroll` 一整套；
- 输入：`ComposerView` 和长按说话、提问和批准卡片；
- 文件和成果：文件预览、文件树、成果；
- 数据：`AppStore` 和 RPC 层。

新布局只是外壳，里面放现有视图。只在 PRD 真的需要新行为的地方改旧代码，而且改动尽量小。Bento 里有的直接复制。
