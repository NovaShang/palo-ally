# PaloAlly · PRD v2

2026-10-03 深夜重写。相对 v1 的核心变化：任务改为 harness 原生、不自管；主动性改为短上下文探针 + agent 自注册 watch；记忆与会话吸收 Muse/Dots 理念但用 CC 原生落地、不自建搜索；新增安全一节；绑定关系说诚实、修正 SDK/CLI 混淆；微信隐私如实区分；给出两周 dogfood 最小版。

贯穿原则：**吸收理念，不复制机制。** 我们骑在 Claude Code 上，不重造 Muse 的 Hatch / 每请求上下文组装器 / VM。能用 harness 原生的就用原生，外壳只做 harness 做不到的事。

---

## 1. 定位

**一句话**：PaloAlly 把用户已经在用的编程 agent（V1 = Claude Code）变成常驻、会主动找你、记得你的私人助理。手机 + 微信入口，数据和模型留在用户自己机器上。

**目标用户**：每天用 Claude Code 的开发者，尤其是用第三方模型（GLM / Kimi / DeepSeek / opencode Go / 按量 API）、因此用不了 Muse / Dots 的人（人群 B）；有 claude.ai 订阅的人（人群 A）兼容但非主攻。

**定位尺度（已定）**：自用 + 开源就绪，不是商业化 launch。护城河浅（见 §11），所以按个人工具 + 开源做，不按有壁垒的产品尺度做。

---

## 2. 设计理念（吸收自 Muse / Dots）

1. **线程不等于上下文**。对话线程只是存档，模型每轮看到的是一份有界的、被挑选过的内容。Muse 明确区分 History（全量存档）与 Current context（这次请求实际装入的）。
2. **连续是 UX，不是一根无限长的线**。用户感觉在跟同一个助理持续对话，底层是分段、压缩、靠记忆维持连续，不是让线程无限增长。
3. **记忆 = 小核心常驻 + 按需取回 + 任务后固化**，存浓缩笔记不是全文。Muse 的「Stored / Searchable / Loaded 是三种不同状态」，Dots 的「condensed notes, not transcripts」。
4. **干活下沉**。重活交给子 agent（短、有界的独立会话），主对话只留轻量来回和一句话摘要，所以主对话涨得慢。
5. **后台任务的执行、交回、用户收到是三件独立的事**。一个成功的后台任务不代表用户收到了结果。
6. **能力靠 harness 与其生态**。现代 agent 通过内置工具 / 插件机制几乎无所不能；外壳不跟它抢能力，只补它做不到的（常驻、触达手机、可视化、把 harness 的确认请求送到人手上）。安全判断、上下文与压缩、斜杠命令、模型切换都交给 harness（2026-10-04 修订）。

---

## 3. 目标与非目标

### V1 目标
1. 一个主对话，手机随时说话；要干活的转成后台任务，主对话只回「收到」和结果。
2. 到点或有新情况时主动找我，只在值得打扰时。
3. 需要拍板（审批）或接手（登录 / 付款）时能处理。
4. 产出沉淀成 artifact，可反复看、可自动更新。
5. 记忆是用户可见可编辑的文件。
6. **安全**：全部依赖 harness 的权限机制（见 §6.5 修订），外壳只负责把确认请求送到人手上、一键停下。

### V1 非目标
1. 不支持 Claude Code 以外的 agent（内部留驱动层，不对外承诺平移）。
2. 不做 Android。桌面端 host 只提供一个 CLI 程序，不做桌面 GUI；Mac 上的客户端是 iOS App 经 Mac Catalyst 复用。
3. 不做托管、多用户、团队。
4. 不自建记忆搜索引擎、不自建上下文组装器、不自建压缩、不做向量库。
5. 不自管子 agent / 任务引擎。
6. 不做全屏 computer use；不做跨设备浏览器同步 / 镜像 / 串流。
7. 不做支付通道、不做产物对外分享。

---

## 4. 用户与场景（JTBD）
1. 离开电脑后手机交代一件事，它后台办完再告诉我结果。
2. 到点或有新情况它主动找我，但只在值得打扰时。
3. 它需要我拍板或接手时，我一键处理。
4. 我能看到它在办哪些事、到哪了、做过什么、产出了什么。

---

## 5. 产品形态与信息架构

### 5.1 核心减法（学 Muse）
1. 只有一个主对话，无会话管理。
2. 要干活的都变任务，细节藏起来，主对话只出现「收到」和摘要。
3. 人的介入集中处理，不散在对话里。
4. 界面不出现技术词（agent / session / host）。

### 5.2 两层
- **门面层**：主对话 + artifact 资料库（这是用户主要待的地方；artifact 比五个 tab 高一层，学 Muse）。
- **内部层**：助理详情页里的若干 tab（任务、审批、定时、记忆），偶尔进去看。

---

## 6. 功能需求

### 6.1 主对话与会话模型
1. 文字 + 语音输入；收到 2 秒内有反馈；markdown 渲染；轮内每段文字实时到达（已在 wechat-agent 验证）。
2. **会话模型（吸收理念、原生落地）**：
   - 用 CC 原生 session + resume，不自造每请求上下文组装器。
   - 不让主会话无限长：重活下沉子 agent（§6.2）；上下文与压缩全部交给 harness（2026-10-04 修订：不自己做滚动换会话）。
   - 外壳只在空闲时关掉 CLI 进程省资源，下条消息 resume 同一会话。
   - 连续感来自客户端始终一个对话 + 记忆，不来自一根不断长的线。
3. 待核实（§7.6）：CC SDK 对每轮上下文的控制边界，决定我们能向 Muse 靠多近。

### 6.2 任务（harness 原生，外壳不自管）
1. 干活由 harness 自己原生派子 agent（Claude Code 的 Agent/Task 能力）；生命周期、上下文、给子 agent 喂什么，全是 harness 的事。外壳不提供 create_task、不开任务会话、不做状态机。
2. **列表那一行**：外壳给主 agent 一个工具 `report_task(id, 一句话, 状态)`，由主 agent 主动写。这是列表的权威来源（模型写的、语义准、便宜）。它一物多用：同时驱动列表展示、主对话「收到 / 结果」两条消息、完成推送内容。不另设进度上报。
3. **不漏**：外壳在事件流里检测到子 agent 被派出就自动建一行占位，`report_task` 再往上填。检测保证完整，工具保证质量。
4. **详情（点进去）**：外壳尽力从事件流抓子 agent 内部活动，按 `parent_tool_use_id` 把完整消息分组还原（调了哪些工具、输入、结果）。已核实：只有完整消息带 `parent_tool_use_id`，子 agent 的 token 级增量不转发；所以详情按「完整消息」粒度更新，没有逐字实时。另注：Task 工具在 CC v2.1.63 改名 Agent，但 init 工具列表 / 权限拒绝里仍叫 Task，要兼容；个别版本 `parent_tool_use_id` 偶发缺失，所以详情抓取当尽力而为，列表始终以 `report_task` 为准。

### 6.3 主动性
1. **现状（如实）**：现有心跳是「定时打招呼」。每天固定两次（8:30 / 22:30）+ 3 个随机时段，湾区时间；45 分钟内聊过就跳过；触发时直接往主会话塞一句「看看待办，没事回 [skip]」。即低频、跑在主 agent 上、带完整上下文，重。这不是目标形态。
2. **目标形态**：小间隔、短上下文，跑一个轻量**探针 agent**（不是主 agent）。绝大多数 tick 没事可做，直接结束、没有下一步、主 agent 不参与。少数情况探针发现有事，把摘要反馈给主 agent，触发主 agent 一轮。便宜（短上下文 + 便宜模型，可跑得勤），且不打扰主会话。原来的定时打招呼退化成探针里的一条 watch。
3. **事件触发（不自建 Gmail/日历轮询）**：靠 harness 自己的能力。外壳提供 `register_watch(盯什么, 怎么查, 间隔)` 工具，由 agent 按自己的能力范围决定盯什么、用什么工具查。watch 列表由外壳持久化。探针每 tick 读 watch 列表，用 harness 现有工具逐条查，返回「没事」或「这几条触发了 + 摘要」。
4. **要处理的坑**：每条 watch 要存游标做去重（触发过别每 tick 重复触发）；间隔与成本的平衡（便宜模型 + 短上下文压住）；探针要能用到和主 agent 一样的工具但上下文要短。
5. 用户可调打扰频率、免打扰时段。

### 6.4 记忆（全用 CC 原生 auto memory，不自建）
1. 已核实：CC 原生 auto memory = 记忆目录有 MEMORY.md 索引（每次会话加载）+ 一条记忆一个主题文件 + Claude 全程按需读写、靠索引知道存在哪 + 原生 Grep/Read 搜索。这正是本项目在用的机制，覆盖了「索引常驻 + 按需取回」。它不做语义 / 向量搜索（v1 也不需要）。
2. **所以不自建 memory_search**。搜索召回全靠原生。
3. 外壳在记忆上只剩两件：
   - 维护小而精的核心（user.md / soul），通过 CLAUDE.md 注入（注意：只走一条注入路，避免和 CC 自动加载重复）。
4. 纪律（Hermes 教训）：核心文件小。啰嗦的进可搜索的记忆文件，不全注入，保证开局便宜、吃 prefix cache。（现 user.md 约 1.9 万字节，偏大，需瘦身。）

### 6.5 审批与安全（2026-10-04 修订：全部依赖 harness）
1. **原则**：安全判断全部交给 harness（Claude Code），外壳不自建拦截、不自建规则、不自建分类。harness 的能力比我们自己造的强得多。
2. **由 harness 负责**：权限模式 `auto`（Claude Code 的分类器判断每个操作安不安全，拿不准才问）；它自己的 allow / deny 规则；对危险操作的 `defaultToNo` 标记；提示注入防护。
3. **外壳只做转发**：把 harness 的确认请求（`canUseTool`）转成卡片，送到 App / 微信 / 终端，多端先答先得；「以后都允许」直接把 harness 给的建议规则交回给它，由它写进自己的设置。文字批准必须带编号（如「同意 3f2a」）。
4. **停下**：调用 harness 的 interrupt / stopTask，停掉手上的事；之后不留阻塞状态。
5. **探针**：无人值守，用 harness 的 `auto` 模式加 `permissionPrompts: none`（拿不准的直接拒绝，不等人）。
6. **想屏蔽某些网站或操作**：写进 Claude Code 自己的 deny 规则（`/permissions`），由 harness 执行。

### 6.6 浏览器 / computer use

> 2026-10-04 修订：有 claude.ai 订阅的用户（人群 A），助理直接与主人**共用平常用的 Chrome**（harness 的 Claude in Chrome，`--chrome`），登录状态共享，判断交给 harness。下面第 2、3 条的专属 profile 方案保留给没有订阅的用户（人群 B），配置 `browser.mode = "dedicated"`。

1. 已核实：Claude in Chrome 要 claude.ai 付费订阅；CC 内置 computer use 要 Pro/Max、仅 macOS/Windows、无 Linux、研究预览、不支持 API key。所以人群 B 用不了官方那套，不能依赖。
2. 浏览器就活在 host 上，一个持久化专属 profile 的真实 Chrome，用户登录一次长期有效，用户随时可自己打开管理（桌面本机 / server 走已有 RDP/SSH）。这正是相对 Muse 的便宜之处：环境是用户自己的，不用我们造远程操控。
3. 能力通过注入 MCP 提供：优先用现成的 CDP / 无障碍树类浏览器 MCP（Playwright MCP / Chrome DevTools MCP），对任何模型 / harness 可用、不要 claude.ai 账号。A、B 类统一走这套。
4. 行为包约定：遇到登录 / 验证码 / 付款就停，提示用户去那台机器自己操作。
5. V1 不做：全屏 computer use；跨设备同步 / DOM 镜像 / 像素串流（偶尔接手用现成远程桌面；手机 App V1 可无浏览器界面）。computer use 待 CC 转正 + 支持 Linux + 放开 API key 后，按同样「注入 MCP」方式接。

### 6.7 Artifact
1. 产出统一写到 home 目录 `artifacts/`，一物一文件夹 + 元数据（标题 / 类型 / 更新时间 / 置顶）。
2. 客户端资料库按置顶和最近更新排序。
3. **产物类型不限于 markdown / html**：可以是 PDF、图片、表格、文档等任意文件。预览走苹果原生预览（QuickLook / 系统文件预览），不自己为每种格式写查看器；markdown 原生渲染、html 放沙箱 WebView 默认断网，其余交给系统。
4. 活的产物：定时任务覆写同一 artifact（每日晨报 / 每周财务快照），客户端检测变化即刷新。「定时 + 写文件」即组合出 Muse 的追踪表。
5. V1 简化：dogfood 阶段 artifact 就是文件夹里的 markdown，终端 / 微信直接读，不做查看器。

### 6.8 UI 风格
1. **原生优先**：iOS 原生，尽可能用 SwiftUI；Mac 经 Mac Catalyst 复用同一套。
2. **参考 Muse 的 UI 设计**：单主对话为中心、消费级观感、术语隐形、卡片式审批、活动 / 产物一眼可见。
3. **Liquid Glass 风格**：用系统的半透明 / 材质感（iOS 的 liquid glass / 材质模糊），轻盈通透，不自绘厚重 UI。
4. **简单、原生、友好**：少即是多，用系统组件和系统默认交互，别做花哨自定义；气质要暖、不装、不极客，和产品名 PaloAlly 一致。

---

## 7. 技术架构

### 7.1 组件
```
Apple 原生 App ─┐                      ┌── Host（用户常开的机器）= 一个 CLI 程序
(iOS + Mac      ├─ Relay(无状态,E2E) ─┤   ├─ 托管 harness 进程 / 探针调度 / watch 持久化 / 审批与审计 / 输出路由 / 推送
 Catalyst)      │      + APNs          │   ├─ Harness 运行时（V1：Claude Code，SDK 驱动）
微信 ───────────┘                      │   ├─ 浏览器 MCP + 专属 Chrome profile
                                       │   └─ Home 目录（CLAUDE.md / user.md / soul / 原生 auto memory / artifacts / watches）
```

说明：
- **Relay**：直接复用现有 bento 项目的 relay（Cloudflare Worker，每个 daemon 一个 Durable Object 做配对槽 + 把 host 的 WSS 桥接到各客户端 WSS，含每 IP 限流，零依赖），不重写。
- **桌面 host**：只有一个 CLI 程序，安装方式类似 Claude Code（一行命令）。它本身就是 daemon + onboarding，不做桌面 GUI。
- **客户端**：Apple 原生，主力开发 iOS，Mac 端经 Mac Catalyst 复用同一套代码。

### 7.2 绑定 Claude Code（诚实版）
1. V1 深度绑定 Claude Code。不讲「ACP-ready / 优雅降级」，因为最值钱那层（主动、审批、推送、切模型）全长在 CC 专有机制上，不在 ACP 规范内，换 ACP 不是小重构。
2. 内部可留一层 ACP 形状的驱动接口，但只对自己承诺，不对外宣称能平移体验。
3. **必须先定清、逐条核实的 SDK vs CLI 区别**：`canUseTool` 是 SDK 原语（wechat-agent 已验证可用）；`PushNotification`、`CronCreate` 是 Claude Code 的 harness/CLI 级工具，不是 SDK 原语，且 CronCreate 仅会话内存、7 天过期、仅空闲触发。到底是「SDK 驱动 CLI」还是「基于 SDK 自建」，能力集不同，开工前必须定并逐条验证（见 §7.6）。

### 7.3 PaloAlly 三件事 + 能力归属
外壳只做三件 harness 做不到的事：**活着**（常驻托管进程、崩溃重启、恢复会话、空闲关进程、探针调度、watch 持久化）、**够得着人**（Relay + APNs + 微信）、**看得见**（客户端 + 对 harness 状态的只读投影 + 把 harness 的确认请求送到人手上）。

| 外壳（自己做） | Harness / 生态（复用） |
|---|---|
| 何时唤醒（探针 / watch 调度） | 推理、执行、工具调用、派子 agent |
| 任务的只读投影 + report_task | 子 agent 的创建与生命周期 |
| 确认请求的转达 / 停下按钮（调 harness 的 interrupt） | 全部权限判断（auto 分类器、规则、defaultToNo） |
| 输出路由（主对话 / 推送 / 微信） | 记忆的内容与搜索（原生 auto memory） |
| 空闲关进程、下次 resume | 会话内上下文与压缩 |
| home 核心文件（CLAUDE.md / user.md）维护 | 读写记忆、Grep 搜索 |
| 浏览器 / computer use 的 MCP 封装 + 专属 Chrome | 操作得好不好（吃模型） |
| artifact 约定与资料库界面 | 生产 artifact 内容 |
| 行为包（skills / hooks / 指令文件） | 执行这些行为 |

### 7.4 交付与安装
1. **桌面 host = 一个 CLI 程序**，安装方式对标 Claude Code（一行安装脚本 / 包管理器）。
2. **CLI 负责 onboarding**：即使机器上没有 bun、Claude Code 等依赖，也要能帮用户把一切装好配好（检测缺啥、装运行时、拉起 harness、生成 home 目录、引导配对与登录专属浏览器）。目标是「装完即用」，不要求用户懂终端。
3. **客户端 = Apple 原生**：针对 iOS 开发，Mac 经 Mac Catalyst 复用，不单独写 Mac 应用。
4. **Relay 复用 bento**：不新写。

### 7.5 已核实的硬约束
1. claude.ai connector 只在订阅登录时加载；API key / 第三方模型拿不到 → 人群 B 需自补核心连接器（Gmail / 日历）。
2. base URL 非官方时按需加载关闭，所有 MCP 工具定义塞进上下文 → 行为包挂的 MCP 要少而精。
3. Claude in Chrome 要订阅；computer use 要 Pro/Max、无 Linux、研究预览、不支持 API key → 不依赖，走自带 MCP。
4. 微信 iLink：context_token 24h 失效、每轮主动消息 ≤10 条、每秒 ≤5 条 → 微信只作「随手说话入口 + 结果回复」，主动推送走 App。
5. 微信路径必过腾讯服务器、非 E2E（§6 的 E2E 只覆盖 App↔Relay）→ 敏感内容不走微信；微信只发触发 + 非敏感回执。隐私说明要如实区分两条路径。
6. SDK 子 agent：完整消息带 `parent_tool_use_id`，token 级增量不转发；StreamEvent 的该字段恒为 null。
7. CC 原生 auto memory：MEMORY.md 索引每会话加载 + 主题文件按需读 + Grep；机器本地、按项目；无向量搜索。

### 7.6 开工前待核实
1. SDK 驱动下，`PushNotification` / `CronCreate` 等 harness 工具是否可用、行为如何；主动推送到底走哪条机制。
2. CC SDK 对每轮上下文的控制边界（能否影响注入 / 裁剪），决定会话模型能向 Muse 靠多近、要不要自建更薄的上下文层。
3. 探针 agent 如何以短上下文复用主 agent 的工具 / 连接器。
4. 空闲关进程 + resume 的连续性实测（resume 回放成本、断点体验）。

---

## 8. 边界（V1 in/out）

**IN**：Claude Code（SDK）单 harness；单 host 单用户；桌面 host = 一个 CLI 程序（含 onboarding）；复用 bento 的 relay；客户端 Apple 原生（iOS + Mac Catalyst）；主对话入口（微信 + CLI 先行，后续 App）；任务只读投影 + report_task；探针 + 自注册 watch 主动性；原生 auto memory + 核心文件维护；确认请求转达（安全判断交给 harness）+ 停下按钮；浏览器（订阅用户共用主人自己的 Chrome，经 Claude in Chrome；其他用户用专属 profile 的浏览器 MCP）；artifact 文件约定。

**OUT**：ACP 与其他 agent；Android / 桌面主界面；托管 / 多用户；自建记忆搜索 / 上下文组装器 / 压缩 / 向量库；自管任务引擎；全屏 computer use；跨设备浏览器同步 / 镜像 / 串流；支付通道；产物分享；Relay 侧离线兜底执行。

---

## 9. 里程碑
- **Phase 0（两周 dogfood）**：见 §10。只验证两个最不确定点。
- **Phase 1（iOS App）**：主对话 + artifact 资料库 + 任务 / 审批 / 定时 / 记忆 tab + APNs；安全机制补齐。
- **Phase 2**：浏览器手机接手；核心连接器（Gmail / 日历）打包成自带 MCP（Google OAuth 审核以周计，尽早申请）；第二个 harness 驱动。

---

## 10. 两周 dogfood 最小版（Phase 0）

目标：只验证两件 PRD 自陈的未知。**①任务靠 report_task + 子 agent 会不会办偏 ②探针 + 主动推送频率能不能忍。** 其余全用现成能力兜底。

**IN**
1. 单主对话，复用现有 wechat-agent + CLI（已跑通，不重造）。
2. 「说一件事 → harness 原生派子 agent 办 → report_task 回摘要」。任务先不做完整状态机。
3. 探针：小间隔、短上下文、便宜模型；读一个手写的 watch 列表（先 1-2 条，如「盯 X 的邮件」「每天晨报」）；没事就结束。验证频率与打扰感。
4. 记忆：全用 CC 原生 auto memory，不动；核心 user.md 瘦身一次。
5. 会话：不做滚动，压缩交给 harness；观察一个长会话多久压缩一次、压缩损失多大。
6. artifact：往一个文件夹写 markdown，终端 / 微信直接读。
7. 安全：全部交给 harness（`auto` 模式），外壳只转达确认请求。

**OUT（本轮不做）**
iOS App / APNs / 全部 tab UI；浏览器 MCP + 专属 Chrome（整块推后）；自注册 watch 的完整机制（先手写列表）；Gmail/日历打包连接器（OAuth 审核塞不进两周）；ACP 驱动层。

一句话：Phase 0 从「验证 6 件事」收敛成「验证 2 件事」，其余现成兜底，两周可达。

---

## 11. 风险
1. **平台风险**：Anthropic 已有 Remote Control / PushNotification，可能自己补齐类 Muse 体验；护城河只剩第三方模型用户 + 国内生态 + 微信入口 + 减法界面，都浅、可抄。故按自用 + 开源做。
2. **条款风险**：SDK + 订阅凭证处灰色地带；第三方模型用户不受影响。
3. **任务办偏**（最大未验证点）：子 agent 上下文由 harness 喂，指代上文的个人请求可能办偏；Phase 0 头号验证项。
4. **成本**：探针每 tick、子 agent 每任务都是额外调用；要便宜模型做探针 / 门控、prompt caching、每日预算上限。对按量用户是硬成本。
5. **host 离线**：笔记本休眠 / 断网 → 任务停摆、推送丢失、用户收到的是沉默而非报错。V1 选常开机器部署，并补「我掉线过」的补发逻辑。
6. **失败模式**：任务卡死、工具死循环烧 token、第三方模型限流 / 宕机、微信 context_token 24h 过期后的重授权 UX，都要有兜底。
7. **范围膨胀**（历史教训）：每个 Phase 限时，做完即停、先用一段。

---

## 12. 验收标准（Phase 0，量化）
作者本人连续用，替代现有微信通道。量化目标（上线后按真实数据校准阈值）：
1. 任务办偏率低于某阈值（如每周 ≤X 次需要返工）。
2. 主动推送频率可接受（如每天 ≤Y 条，0 条该发没发的晨报 / deadline）。
3. 长会话稳定性：记录多久触发一次压缩、压缩后有无明显丢上下文，用于评估 harness 压缩是否够用。
4. 主观：30 天内是否真的替代了现有通道、是否愿意继续用。
