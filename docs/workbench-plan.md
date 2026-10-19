# 工作台 PRD 实施计划

说明：下面的路径和标识符都在仓库里查过。三处没有读完：设计稿 HTML、`AssistantView` 各标签页的内容、`TiledPaneHost_macOS.swift` 的具体实现（只读了文件头）。凡是从代码里推断出来、需要实现时再确认的，我标了「待确认」。

## 0. 先说结论

1. **host 缺的是「能力」，不是「管道」。** Pal 已经是 SDK 常驻会话，有历史、流式输出、审批卡片、重命名、停止、回退、睡眠和唤醒、花费统计。以下几项是真空白：
   - 主人直接在任意文件夹新建会话；
   - 每个 Pal 的模型和思考深度；
   - 上下文用量和压缩；
   - 后台任务和子 agent 的列表与单独停止；
   - 工作区；
   - 「做完了」状态和已读同步；
   - 自动收起；
   - 结束会话。
2. **app 最大的新东西有三块。**
   - 平铺工作区：把 Bento 的 `LayoutTree` 纯模型原样搬进 PaloAllyKit，视图用 SwiftUI 重写。
   - 右侧栏浏览器：现在是 `.inspector` 加 `LibraryPanel`/`FilesPanel`，要换成按 agent 记忆标签的容器。
   - 浮动玻璃侧栏：现在的 `NavigationSplitView` 做不到「盖在内容上」，Mac 和 iPad 要换成自己的容器，iPhone 保留。
3. **已有的好底子。**
   - `AppStore.palStore(id)` 是每个 Pal 一个作用域 store，多格并排可以直接复用。
   - `FileScope.pal(id)` 和 `files.list` 已支持 Pal 文件夹的文件树。
   - `ChatView` 已有 `pageTop`/`MacPageStrip`/`safeAreaBar` 这套浮动标题。
4. **并行方式。** 先冻结一份 RPC 契约（Phase 0），之后 host agent 只碰 `host/`，app agent 只碰 `ios/`。app 先用 `PaloAllyKit/Sources/PaloAllyKit/Demo` 的 DemoHost 做假数据，不等 host。

## 1. PRD 各节对照：已有与缺失

### 1.1 会话（§2、§3、§6 详情）

| 项 | 现状（路径） | 缺口 |
| --- | --- | --- |
| 在任意文件夹直接新建 | **不能。** `Pals.create()`（`pals.ts` 约 1190 行）是私有方法，只被 `decide()`（Palo 提议后主人点「开吧」）调用。主人自己只能 `pals.adopt` 已有 Claude Code 会话（`rpc.ts`）。`checkProposal` 强制要求 name、duty、dailyUsd，并拒绝 PaloAlly 自己的目录。 | 新增 `pals.create`，name、duty、预算都可选。先不起名，随第一句话自动起名；`readTitle`/`PalRecord.name` 已跟着 Claude Code 标题走，要补「首句生成标题」。文件夹选择可以用 `files.folders.browse`，以及 `DirectoryPickerPath.swift`/`FilePickers.swift`。 |
| 重命名 | 有：`pals.rename`、`Pals.rename`、app 的 `PalRenameAlert`。 | 只需改入口：胶囊详情里内联编辑。 |
| 模型和思考深度 | Palo 有（`model.get`/`model.set` → `hub.setModel` → `conversation.applyModel/applyEffort`）。harness 的 `MainSession.setModel/setEffort` 对 Pal 也可用（`SessionOptions` 有 `model`/`effort`）。**Pal 没有**：`PalSession` 只在 `init` 事件里记录 `rec.model`，没有 setter，没有 effort 字段，`PalRecord` 里也没有 effort。 | 新增 `pals.model.set`（model、effort）。`PalRecord` 加 `effort?`，`mapOptions`/启动参数带上。可选模型列表复用 harness 的 `models` 事件和 `hub.modelInfo`。app 端可复用 `ModelPicker.swift`/`ModelRow.swift`。 |
| 上下文用量与压缩 | Palo 有：`conversation.contextTokens`、runtime 里的 `contextTokens`、自动 `/compact`（`conversation.ts` 约 709 行）。**Pal 没有**：`result.contextTokens` 到了 `PalSession` 没存，`compact` 事件也没处理。 | `PalSession` 记录 `contextTokens`、`contextWindow`（取自模型）、`lastCompactAt`。新增 `pals.compact`，可直接 `send("/compact")`，要确认 `ownerOrigin` 下不当成用户消息显示（待确认）。 |
| 后台任务和子 agent | Palo 有：`tasks.ts`、`task.get`、`task.stop`、`hub.stopTask` → `conversation.stopTask` → `session.stopTask(sdkTaskId)`。Pal 只有 `bgTasks: Set<string>`（只用于判断是否空闲），**没有 `task_started` 和 `task_progress`** 的处理，所以没有标题，也没有活动。 | `PalSession` 维护 `Map<taskId, {title, kind(subagent/bg), startedAt, summary}>`。新增 `pals.tasks` 和 `pals.task.stop`，并随 `pals.updated` 一起推送。`harness/types.ts` 已有 `stopTask`。 |
| 每个 Pal 的用量 | 有：`PalRecord.costTotalUsd`、`lastWakeUsd`，`spentToday()`，`SpendMeter`（`ccSpend.ts`）。只是没有给 app。 | 把 `costTotalUsd`、`spentToday`、`contextTokens` 放进详情 payload。 |
| 结束会话与「以前的」 | 有两个近似的：`pals.release`（交还终端，返回 `resumeCommand`）和 `pals.remove`（移出，写入 `data.former`，最多 20 条，之后出现在 `pals.recent`）。`pals.recent` 是 SDK `listSessions`，30 天内、最多 50 条，`pals.adopt` 可接管。 | 新增 `pals.end` = remove + 记入 `ended`（保留名字、文件夹、结束时间、所属工作区）。「以前的」= 已结束 ∪ 自动收起 ∪ `pals.recent`。`former` 只留 20 条，不够用，要放宽或另存。 |
| 状态 | `PalSession.status()`：`stopped/starting/asleep/waiting/busy/idle`。Swift 的 `PalStatus` 是 `busy/idle/waiting/starting/stopped/asleep/unknown`。 | 没有「做完了（未看）」。新增 `Pal.attention: "working"\|"waiting"\|"done"\|"idle"`，由 host 算：`done` 当且仅当上一轮正常结束（`onTurnEnd`）且 `finishedAt > seenAt`。`PalRecord` 加 `finishedAt`、`seenAt`。新增 `pals.seen {id}`，并在 `pals.updated` 里广播以同步各设备。`asleep`/`starting`/`stopped` 在 UI 上并入「闲着」，`stopped` 另有提示。 |
| Palo 自己的状态 | `hub.status()` 有 busy、activity。 | Palo 的「N 个会话在等你」由 app 从 `pals.pending`/`attention` 汇总，不需要 host 改。 |
| 手机通知 | 有：`pushWaiting`（`pals.ts`，经 `router.proactive`），标题用 `pals.waitingTitle`。 | 只改文案：去掉「帮手/Pals」说法。「做完了」是否也要推送，PRD 没说，默认不推。 |
| Palo 转来的话 | `peerWrap`（`palSession.ts`），`toolSend`/`toolPaloSend`。 | 历史里是否带标记（`CCMessage.role: "peer"/"palo"`）要查 `palHistory.ts`（待确认），app 端 `MessageRow` 要加标签。 |

### 1.2 工作区、自动收起、已读（§2、§14）

整套都是新建。没有 `workspaces.ts`，`config.ts` 的 `Paths` 也没有对应文件。
- 持久化：新增 `paths.workspaces`（JSON，用 `readJson/writeJson`，同 `paths.pals`）。
- 自动收起（默认 3 天）：**算出来，不改记录**。`folded = !workspaceId && now - lastUsedAt > N 天`，N 来自 `settings.foldDays`。这样不用定时任务，也不会误删。
- 与现有睡眠机制无关：睡眠 20 分钟，只管进程；收起 3 天，只管列表。两者各自独立。

### 1.3 侧栏、分栏、选中（§4、§5、§8）

| 现有 | 缺口 |
| --- | --- |
| `RootView.swift` 的 `MainScreen`：`NavigationSplitView` + `ConversationList`（`List(selection: $model.selection)`）；`ConversationDetail` 用 `NavigationStack`；`AppModel.Conversation` 枚举只有 `palo/pal/ally/recent/session/devices`；`AppModel.columnVisibility`、`compactColumn`。 | 新增 `.workspace(id)`；`.recent` 改成内嵌区块；`.session`（电脑上其他活跃会话）去向待定（见开放问题）。侧栏分区改为 Palo、工作区、会话、Allies（`ConversationList` 重写）。 |
| `MacWindowChrome`/`MacToolbarInstaller`（`MacWindow.swift`）：系统侧栏按钮在红绿灯旁。 | 收起后的玻璃小胶囊、悬停浮出：见 §3 风险。 |
| `Pal` 行：`PalRow`、`PalTile`、`Copy.palStatusColor`。 | 换成统一的 `StatusDot`（青、橙、绿、灰），全 app 共用。 |

### 1.4 右侧栏与文件（§7）

| 现有 | 缺口 |
| --- | --- |
| `LibraryInspector`（`.inspector`）+ `LibraryPanel`（`LibraryView`，`NavigationStack(path: libraryPath)`）或 `FilesPanel(scope:)`（`model.filesPanel`）。`model.inspectorShown` 是全局的。`FileTreeView.swift`、`FilePage.swift`、`ArtifactDetailView.swift`、`PaloAllyFilePreview` 包（`FilePreviewWebView`、`QuickLookRouting`）。 | 缺：网页标签、标签栏、每个 agent 一组标签和开关、切换不重新加载。新增 `RightPane` 容器，标签模型 `[PaneTab]`（`.files(scope)`、`.library`、`.preview(path)`、`.web(url)`）。预览内容复用现有视图。标签状态由 host 保存（PRD §14）。 |
| 「在访达里打开」「在终端里打开」 | **host 没有这类 RPC。** 新增 `pals.reveal {id, kind: "finder"\|"terminal"}`。终端见 §3 冲突。 |

### 1.5 沉浸感与语音（§10、§11）

| 现有 | 缺口 |
| --- | --- |
| `ChatView` 用 `safeAreaInset(edge: .bottom)` 放输入框，`MacPageStrip` 用 `safeAreaBar` 浮动标题；`ChatScroll.Metrics` 读 `contentInsets.bottom/top`。`glassEffect` 已在 `MacPageStrip` 里用。 | 做成更彻底的「内容通到顶和底」，见 §3 风险。 |
| 语音：`VoiceInputController` 是全局环境对象（`MainScreen` 创建）；`VoiceInputOverlay.swift`（843 行）；`FloatingTitleOrb`/`OrbPresence`（`TitleOrb.swift`、`OrbPresence.swift`）；`ComposerPressGesture`。 | 目前一个窗口一个控制器、一个球位。PRD 要「按住所在格接收」和「对 Palo 说话球才出现」：控制器要带 `target`（`.palo` / `.pane(id)`），Overlay 拆成「球层」和「格内层」。球的起点和终点要读侧栏 Palo 行的 frame（现在用 `TitleOrbSlot.frame`，同机制）。 |

### 1.6 「它」页（Palo 详情，§6）

`AssistantView.swift` 里有 `AssistantTab`（`watches` 目标优先）、`WatchesSection`、`MemorySection`、`TasksSection`、`ModelPicker`、`IdentityEditor`。RPC 已有：`watch.*`、`memory.list/read/write`、`task.*`、`model.*`。「履历」大概对应 tasks 或 `chat.search`（待确认）。所以只是把这些 section 搬进 Palo 的胶囊详情，**不需要新 RPC**。

## 2. 阶段计划

每阶段 3–8 AI 小时。H 是 host，A 是 app。同一行上的 H 和 A 可并行，且文件互不重叠。

### Phase 0（0.5–1h）：契约先行

输出一份 `docs/workbench-rpc.md`，写明下面各阶段的方法名、参数、返回、事件和 JSON 示例。两边都以它为准。app 的 DemoHost 按它造假数据。

### Phase 1-H：会话能力（host，约 6h）

**文件**：
- 改：`host/src/pals.ts`、`palSession.ts`、`types.ts`（`Pal` 加字段）、`rpc.ts`（`RPC_METHODS` 与分发）、`config.ts`（`settings.foldDays`）、`hub.ts`、`i18n/{zh,en}`。
- 新增：无。

**RPC**：
| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `pals.create` | `{cwd, name?, text?, workspaceId?}` | `{pal}` |
| `pals.detail` | `{id}` | `{pal, contextTokens, contextWindow, costTotalUsd, spentToday, model, effort, models[], tasks[{id,title,kind,startedAt,summary?}], lastCompactAt?}` |
| `pals.model.set` | `{id, model?, effort?}` | `{pal}` |
| `pals.compact` | `{id}` | `{}` |
| `pals.task.stop` | `{id, taskId}` | `{}` |
| `pals.seen` | `{id}` | `{pal}` |
| `pals.end` | `{id}` | `{earlier: EarlierItem}` |
| `pals.reveal` | `{id, kind}` | `{}` |

`Pal` 新增字段：`attention`、`finishedAt`、`seenAt`、`contextPct`、`workspaceId`、`effort`。

**持久化**：`PalRecord` 加 `effort?`、`finishedAt?`、`seenAt?`、`workspaceId?`。`PalFile` 加 `ended: {sessionId, cwd, name, endedAt, workspaceId?}[]`，上限 200。

**新建会话的细节**：不传 duty 时不 `send`，等第一句话。名字先空，显示「新会话」，首句进来后用现有 `readTitle` 取标题，取不到就用首句前若干字。

**测试**：在 `host/test/pals.test.ts` 加：
- 新建后 `rec.cwd` 正确，不要求 name；
- `setModel` 调用了 fake 的 `setModel/setEffort` 且持久化；
- `result` 事件更新 `contextTokens`；
- `compact` 事件更新 `lastCompactAt`；
- `task_started` 到 `task_notification` 的生命周期，`stopTask` 被调用；
- `attention` 状态机：busy → done → seen → idle，waiting 优先；
- `end` 之后进入 `ended`，`pals.recent` 不重复列出。

`host/test/fakeDriver.ts` 要补 `setModel/setEffort/stopTask` 与 `task_started` 事件（待确认它是否已有）。`host/test/protocol.test.ts` 要覆盖每个新方法，样本写入 Swift 的 `Tests/PaloAllyKitTests/Fixtures`。`bun test` 即可，无需 Xcode。

**真机检查**：用真 Claude Code 跑一遍 `pals.live.test.ts` 同类的 live 测试：切模型是否生效、`/compact` 是否真压缩、子 agent 能否停。

### Phase 1-A：数据层与状态点（app，约 5h，与 1-H 并行）

**文件**：
- 改：`PaloAllyKit/.../Models/Pals.swift`（`Pal` 加字段，`TolerantStringEnum` 容错）、`RPCTypes.swift`（`RPCMethod`、`RPCMethod.pals` 列表）、`Store/AppStore+Pals.swift`、`Demo/*`。
- 新增：`Models/PalDetail.swift`、`Store/AppStore+PalDetail.swift`。
- 新增 app：`ios/App/Sources/Support/StatusDot.swift`。

**行为**：
- `AttentionState` 枚举，含 `Copy.attentionColor`；
- 全 app 把原来用 `Copy.palStatusColor` 的地方换成 `StatusDot`；
- 乐观标记已看：点开会话时 `seen`，并在 `AppModel.markSeen` 旁加挂钩。

**测试**：`ModelDecodingTests`、`PalsTests`、`ProtocolContractTests` 加新样本；`AttentionState` 的映射表。

**真机检查**：Demo 模式下，列表圆点四种颜色和「带一圈淡光」的青色。

### Phase 2-H：工作区存储（host，约 4h）

**新增**：`host/src/workspaces.ts`、`host/test/workspaces.test.ts`。**改**：`config.ts`（`Paths.workspaces`）、`hub.ts`（构造并持有）、`rpc.ts`、`pals.ts`（`end/remove` 时从工作区摘掉）。

**数据**：
```
Workspace { id, name, memberIds: string[], layout: LayoutTreeJSON | null,
            tabs: PaneTab[], rightOpen: boolean, createdAt, updatedAt }
```
另有每个 Palo/会话的 `rightPane: {tabs, open}`，存 `paneState[agentId]`，同在这个文件里。

**RPC**：`workspaces.list`、`workspaces.create {name?, memberIds[]}`、`workspaces.update {id, name?, layout?, tabs?, rightOpen?}`、`workspaces.members {id, add?[], remove?[]}`（保证一个会话只属于一个工作区，服务端强制）、`workspaces.delete`、`pane.state.set {agentId, tabs, open}`、`pane.state.get`。事件：`workspaces.updated`。`sync` 的返回里顺带 `workspaces` 与 `paneStates`。

**自动收起**：`pals.list` 的返回加 `folded: boolean`，并新增 `pals.earlier {limit}` = ended ∪ folded ∪ recent，每项带 `{kind: "ended"\|"folded"\|"recent", id/sessionId, name, cwd, at}`；继续聊用 `pals.wake`（folded）或 `pals.adopt`（ended/recent）。

**测试**：创建、成员迁移互斥、删除后成员变回普通会话、`LayoutTree` JSON 往返、结束会话后工作区成员自动摘除、3 天折叠的边界（用 `now` 注入）。

### Phase 2-A：侧栏树与 iPhone 首页（约 6h，与 2-H 并行，用假数据）

**重写**：`Home/ConversationList.swift`（拆成 `SidebarTree`，Palo 大项、工作区可展开、会话、「以前的 N」、Allies、底部 ＋/设置）。**改**：`AppModel.swift`（`Conversation` 加 `.workspace`、`.earlier`）、`RootView.swift`（`ConversationDetail` 的分支）、`Pals/PalCopy.swift`、所有「Pals/帮手」文案（`Localizable` 与 `LocalizationTests`）。

**同时**：保留 `RecentConversationsPage` 改为「以前的」展开页；iPhone 首页用同一棵树。

**测试**：`PaloAllyKitTests` 里加 `SidebarModel`（纯函数：从 pals + workspaces + folded 算出分区），覆盖排序、汇总「N 等你」。

**真机检查**：Mac、iPad、iPhone 三种窗口宽度；展开箭头；右键菜单；多选；VoiceOver。

### Phase 3-A：标题胶囊与详情（约 6h）

**新增**：`ios/App/Sources/Agent/AgentCapsule.swift`、`AgentDetailView.swift`（内容按 §6 列出的分块）、`ModelEffortPicker`（复用 `ModelPicker`）。**改**：`PalPage.swift`（删 `PageMenu` 里的「交还终端/移出 Pals」，换成详情）、`ChatView.swift`（`pageTop`）、`MacPageStrip.swift`（支持胶囊）、`AssistantView`（Palo 的目标、履历、记忆三块并入详情）。

**呈现**：Mac/iPad 用 `.popover`（Catalyst 上是原生 popover，再套 `glassEffect`；待在 Catalyst 实测）；iPhone 用 `.sheet` + `presentationDetents([.medium])`。

**输入框**：`ComposerView` 在忙时麦克风换成停止键（`store.isBusy`/`pal.inTurn`），此时说话或输入进入排队；先确认 `pals.send` 在忙时是排队还是并入当前轮（`PalSession.send` 的 `pendingUuids`、`answering` 处理说明是排队，已支持）。

**工具步骤收起**：`MessageRow.swift` 现状待确认，若已有折叠则只调默认值。

**后台任务一条**：对话里插入「后台任务」行，点开进入详情的那一块。

### Phase 4-A：新建会话与新建工作区（约 5h）

**新增**：`NewSessionSheet.swift`（最近文件夹、搜索、当前会话文件夹排第一、⌘↩ 作为新一格；候选来自 `pals` 的 `cwd` 去重加 `pals.recent`，选「其他文件夹」时用 `files.folders.browse`）、`NewWorkspaceSheet.swift`（勾选）、`WorkspaceMenus`（五个入口，含「并排…」「移到…」「右键」「⌘⇧N」「拖到另一会话上」）。**键盘**：`HardwareKeyboard.swift` 里先查现有快捷键有无 ⌘N、⌘⇧N、⌃⌘S 冲突（待确认）。

### Phase 5-A：平铺工作区（约 8h，是最大风险项）

1. **纯模型进 PaloAllyKit（可单测，无 UI）**：把 Bento 的 `LayoutTree.swift`（567 行，依赖 `BentoFoundation/BentoUI` 只是 import，要去掉）、`PaneDropZone.swift`、`WorkspaceViewModel.swift` 里与布局相关的部分搬到 `PaloAllyKit/.../Workbench/`。重命名 Pane 为 Tile；`id: Int` 改成会话 id 的映射表，因为 host 存的是 JSON。
2. **视图**：`ios/App/Sources/Workbench/TiledWorkspaceView.swift`，用 `GeometryReader` 递归渲染 `Node`；分隔线是 `DragGesture` 的细条；每格是一个 `ChatView` 实例，环境里注入对应的 `palStore(id)`。
3. **拖动交换和停靠**：`.draggable` + `.dropDestination`，落点用 `PaneDropZone` 的区域计算。
4. **活动格**：边框用主题色，`model.activeTile`；语音和输入都进它。
5. **iPad 窄屏**：最多两格，其余收进标题栏切换（`columns <= 2` 的策略放在纯模型里，可测）。

**测试**：把 Bento 的 `LayoutTree` 测试一并搬来（`find ~/code/bento -name "*LayoutTree*Tests*"`，待确认存在）。拆分、关闭、交换、停靠、持久化往返、最小占比。

**真机检查**：Catalyst 下拖分隔线的光标（见风险）；拖标题胶囊换位；四格和六格的性能（每格一个 `ChatScrollCoordinator`）；格内输入框焦点；缩放窗口。

### Phase 6-A：右侧栏浏览器（约 6h）

**新增**：`ios/App/Sources/RightPane/RightPane.swift`、`PaneTabBar.swift`、`WebTab.swift`（`WKWebView` 放进 `ZStack` 保活，切标签只是 `opacity/allowsHitTesting`，对应 Bento 的 `PreviewDock_macOS`）。**改**：`RootView.swift` 去掉 `LibraryInspector`，换成自己的右栏；`AppModel` 的 `inspectorShown/libraryPath/filesPanel` 并入新的按 agent 记忆的状态；`FileLinks.swift`/`FilesNavigation.swift`（点链接、点文件自动弹出右栏并开预览标签）。同步到 host：`pane.state.set`，节流 500ms。

**iPhone**：右上角按钮打开整页，复用同一个 `RightPane` 视图。

### Phase 7-A：侧栏收起、悬停浮出、顶部胶囊（约 5h）

**新增**：`FloatingSidebar.swift`、`SidebarCapsule.swift`（侧栏按钮、小 Palo 球、「N 等你 · N 做完」，点开弹列表）。**改**：Mac/iPad 的 `MainScreen` 用自己的 `ZStack` 容器代替 `NavigationSplitView`（iPhone 仍用它）；`MacWindow.swift`（⌃⌘S、隐藏系统侧栏按钮）。

**行为**：窗口最左 4–6pt 的透明热区 `onContinuousHover`，进入后 150ms 延迟浮出，离开 300ms 收回。iPad 用 `UIScreenEdgePanGestureRecognizer`（UIKit 包装）。侧栏开关存 `UserDefaults`（本机，PRD §14）。

### Phase 8-A：沉浸式对话与语音改造（约 6–8h，建议最后做）

- 内容通到最上和最下，工具栏、胶囊、输入框都用 `glassEffect`，去掉实心背景；
- `VoiceInputController` 加 `target`，拆 `VoiceInputOverlay` 成「球层」和「格内层」；
- 对 Palo 说话时球从侧栏的 Palo 行（收起时从胶囊）飞出；
- 在某格或会话页说话：这一格变暗，胶囊上的圆点变音量条，边框随声音发光；
- 需要 `ComposerPressGesture` 与多格并存时的手势隔离。

### Phase 9：收尾（约 3h）

iPad 两格策略复查；iPhone 详情半屏面板；通知点击跳转到对应会话或工作区格（`AppModel.handleNotification/openCard`）；英文 `Localizable` 对齐；删旧入口。

### 并行排布

```
时间 →   P0   | P1-H ────────── | P2-H ──────────── |           | 各阶段的 live 复核
              | P1-A ────────── | P2-A ──── | P3-A ──── | P4-A ── | P5-A ───── | P6-A ──── | P7-A ── | P8-A ──
```
P1-H 与 P1-A、P2-H 与 P2-A 各自并行；P3 起只有 app，host 只做小修。文件冲突热点只有两处：`rpc.ts`（host agent 独占）和 `RPCTypes.swift`（app agent 独占），中间靠 P0 的契约文档对齐。

## 3. 风险与开放问题

### 3.1 Catalyst 限制

| 项 | 判断 |
| --- | --- |
| 悬停 | `onContinuousHover`、`.onHover` 在 Catalyst 可用。但窗口最左边缘落在窗口 resize 区域，热区要往里缩几 pt，实测。 |
| 浮动侧栏 | `NavigationSplitView` 做不到覆盖式。要自己做容器，但会丢掉系统侧栏的切换动画和 `compactColumn` 逻辑，`AppModel.compactColumn`/`columnVisibility`、`MacToolbarInstaller` 都要重接。 |
| 红绿灯旁放控件 | 现在 `MacToolbarInstaller` 用 AppKit bridging 装 `NSToolbar`。要把标题栏做成透明并且内容延伸进去（`MacPageStrip` 已经是这个思路），胶囊要避开红绿灯，位置用常量，要在全屏下复查。 |
| Liquid Glass | `glassEffect` 已在用，但「玻璃里再放玻璃」和 `GlassEffectContainer` 的合并行为要实测。 |
| 分隔线光标 | `.pointerStyle` 在 Catalyst 上不一定可用，保险做法是 `UIPointerInteraction` 的 UIViewRepresentable。 |
| 拖放 | SwiftUI `.draggable/.dropDestination` 在 Catalyst 可用，但会话行同时要 `List` 选择、多选、拖动，手势可能互相抢。「拖会话到另一会话上」PRD 已标为熟练用户的快捷方式，放最后。 |
| 多选 | `List(selection: Set)` 在 Catalyst 的 ⌘ 点击可用，右键菜单作用在选中集上，要实测。 |
| Bento 的 AppKit | `TiledPaneHost_macOS` 用了 `NSView`/`NSHostingView`/`NSCursor`，不能搬，只搬算法和交互。`NewPaneDirectoryPanel_macOS` 的 `NSOpenSavePanel` 在 Catalyst 里换成 `UIDocumentPickerViewController`，或者沿用 host 的 `files.folders.browse`（更好：iPhone 也能用，不需要本机路径）。 |

### 3.2 沉浸式全幅对话与 ChatScroll

- `ChatScroll.Metrics` 靠 `ScrollGeometry.contentInsets.bottom/top` 算「离底部多远」，`ChatScrollCoordinator`（1163 行）围绕它跟随、脱离、跳转。**只要浮层仍通过 `safeAreaInset`/`safeAreaBar` 提供，inset 就继续被系统计入**。把输入框改成 `overlay`（不占位）会使 `bottomInset` 为 0，跟随判断会错。所以保持 `safeAreaInset`，只改它的背景。
- 多格同时存在：每格一个 `ChatView`，coordinator 是否有全局单例或静态变量要查：`ChatScroll.lastDistance`、`debugDistance`、`uiScrollView` 都是 `static` 变量，**多实例会互相覆盖**，只是日志用途，但要确认没有逻辑依赖。
- `ChatView` 里读了 `AppModel` 的 `focusMessageSeq`、`composerUnfocusRequests`、`orbPresence`、`drafts[current]`，这些都是单会话假设，平铺时要按格路由。
- 宽度变化：`Reading` 有 `width`，窄格里换行会变，已有 `ChatScrollMachineTests`，要加窄宽度用例。
- 每个 `palStore` 一直在内存里，6 格同时流式输出的渲染压力要测。

### 3.3 PRD 与现有行为的冲突

1. **「在终端里打开」vs「同一份记录不能被两个进程写」。** `PalSession` 的 guard（`pals.guard`、`HeldElsewhere`）不允许终端和 host 同时持有一个会话。必须先做 `release`/`sleep` 再开终端，等于结束托管。方案：「在终端里打开」先让该 Pal 进入睡眠，终端 `claude --resume` 后 host 看到 holder 就保持 asleep；回到 app 说话时再唤醒（会遇到 `HeldElsewhere`，要给提示）。需要产品确认。
2. **「结束这个会话」vs 现有两个动作。** PRD 详情里只有「结束」，没有「交还终端」。我建议：结束 = `pals.end`（等同 remove，进「以前的」，可继续聊）；交还终端并入「在终端里打开」。
3. **「做完了」vs 现有 `idle`。** 现有没有未读概念，要新增 `finishedAt/seenAt`。多设备同步靠 `pals.seen` 和 `pals.updated`。注意：host 重启后不应把所有 Pal 重新变成「做完了」，所以 `finishedAt` 只在真实一轮正常结束时写。
4. **自动收起 3 天 vs `MAX_AWAKE=5`/睡眠 20 分钟。** 没有冲突，但「工作区里的会话不会自动收起」意味着工作区成员可能很多（上限 `MAX_PALS=50`），打开一个工作区会逐个唤醒；要限制：只有被显示的格才唤醒，且 5 个醒着的上限仍然有效，第 6 格显示的是睡眠态，说话时才唤醒并让另一个睡去。
5. **电脑上的其他活跃会话（`otherSessions`/`OtherSessionRow`/`SessionPage`、`pals.adopt` 的「等终端退出」流程）。** PRD 没提。我的默认：折进「以前的」之上的一个「电脑上的」小节，只在非空时出现。需要确认。
6. **「界面上不再出现帮手、Pals」。** 影响面很大：`Localizable` 字符串、host `i18n`（`pals.*` 键）、推送标题、`PalCopy.swift`、`RecentConversationsPage`。Palo 的系统提示与工具名（`pal_send`、`pal_propose`）是给模型看的，可保留，但 Palo 对主人说话时的措辞来自提示词，也要改（`PAL_PROMPT`、`conversation.ts` 的系统提示）。
7. **新会话「先不起名」。** `PalRecord.name` 现在是必填且全局唯一，`SendMessage` 靠名字找到它（`pals.get(key)`）。空名字要给一个内部稳定名（如 `session-<短id>`），显示层再用「新会话」；首句自动起名后走 `rename` 的重名加数字逻辑。
8. **右侧栏「不放详情」vs 现在的 `ManagementSheet`。** Palo 的管理页从 sheet 改成胶囊详情，iPhone 现在是 push 的 `AssistantView`，要改成半屏面板。
9. **工作区持久化「由主机保存」，但布局树是纯 UI 数据。** 多设备同时拖分隔线会频繁写；约定节流，且以「最后写入者为准」，不做合并。
10. **「每个会话最多一个工作区」** 要在 host 端强制，app 只是乐观更新。

### 3.4 其他开放问题（按 PRD 默认先做）

- 「做完了」是否推送手机：默认不推。
- 「N 等你」的 Palo 一项：现有 `WaitingBadge` 的计数是否复用 `palPendingCount`（待确认）。
- 「履历」对应哪份数据：默认任务历史加对话搜索。
- 会话列表的活动排序用 `updatedAt`，而 `touch()` 在每个 `assistant_text` 都更新，工具运行期间不会动，符合预期。
- Allies 的区块不动。
- 多主机（`hasSeveralHosts`）：工作区和标签状态按 host 存，切换助理时整套换，`AppModel.stores` 已按 host 分。

## 4. 测试与验证总表

| 层 | 办法 |
| --- | --- |
| host 单元 | `bun test host/test/pals.test.ts workspaces.test.ts protocol.test.ts`，无需 Xcode |
| host 真实 | `*.live.test.ts` 同类：切模型、`/compact`、停子 agent、三轮睡眠唤醒 |
| 协议契约 | `protocol.test.ts` 写样本到 Swift Fixtures，`ProtocolContractTests` 严格解码；`RPC_METHODS` 与 `RPCMethod` 两份列表要同步（已有契约测试保证） |
| app 纯逻辑 | PaloAllyKit 的 `swift test`：`LayoutTree`、`SidebarModel`、`AttentionState`、标签状态 |
| app 屏幕 | DEBUG 的 `-demoWindow WxH`、`-demoSnapshot`、`-demoActions`（`RootView.swift` 里已有）出截图；要扩 `-demoActions` 加 `workspace`、`rightpane`、`capsule`。必须看真窗口：Mac 全屏与窗口、iPad 横竖屏、iPhone；深浅色；Liquid Glass 叠层；拖放；悬停浮出；语音按住 |

## 5. 建议的施工顺序

P0 → P1-H‖P1-A → P2-H‖P2-A → P3-A → P4-A → P5-A → P6-A → P7-A → P8-A → P9。最先交付的有价值版本是 P1+P2+P3（统一状态点、新建会话、胶囊详情、工作区列表），此时尚无平铺，但已满足「不写代码的用户」和 iPhone 的大部分需求。平铺（P5）风险最高，放在这之后，失败也不影响前面的发布。

### Critical Files for Implementation
- /Users/nova/code/palo-ally/host/src/pals.ts
- /Users/nova/code/palo-ally/host/src/palSession.ts
- /Users/nova/code/palo-ally/host/src/rpc.ts
- /Users/nova/code/palo-ally/ios/App/Sources/App/RootView.swift
- /Users/nova/code/palo-ally/ios/App/Sources/Chat/ChatView.swift

## 6. 产品决定（2026-10-18，对 §3.3 冲突的裁定）

1. **「在终端里打开」只开一个普通 shell，cd 到这个文件夹，不 resume 这个会话。** 它是「普通 shell 的出口」，不是把会话交回终端，所以和单写者保护没有冲突。会话照常由主机托管。
2. **界面上只留「结束这个会话」。** 结束 = `pals.end`（进「以前的」，可以接着聊）。「交还终端」从界面去掉，RPC 保留，不删。
3. **电脑上其他正在跑的 Claude Code 会话**（`otherSessions`、`adopt`）：侧栏不单独占一节。侧栏 ＋ 菜单里加第三项「从终端搬进来…」，点开就是现在的接管流程。这是一次性的搬家入口。
4. **工作区唤醒**：只有显示出来的格才唤醒，醒着的会话上限仍是 5 个。超出的格显示睡眠态，对它说话时才唤醒，同时让最久没动的那个睡去。
5. **「做完了」不推送手机**，只有「等你」推送。
6. **新会话的内部名**用 `session-<短id>`，界面显示「新会话」，第一句话之后自动起名（重名加数字）。
7. **改叫法**：界面文案、推送、host 给主人看的提示里，「帮手」「Pals」统一改成「会话」。给模型看的工具名（`pal_send`、`pal_propose` 等）不改。
8. **布局树和标签状态由主机保存**，按最后写入为准，客户端写入节流 500ms。

## 7. 总原则（主人要求）

复用或复制现有的东西。已经布局好、反复打磨过的部分不要重写：`ChatView`/`MessageRow`/`ReplyText`/`SelectableMarkdown`、`ChatScroll` 一整套、`ComposerView` 和长按说话、提问和批准卡片、文件预览和文件树、成果、`AppStore` 和 RPC 层。新布局只是外壳，里面放现有视图；只在 PRD 真的需要新行为的地方改旧代码，而且改动尽量小。Bento 里有的直接复制。
