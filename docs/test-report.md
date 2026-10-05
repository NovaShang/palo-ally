> **快照**：这份报告记录的是 2026-10-04 上午 V1 首版的测试情况。之后安全机制改成全部交给 harness（PRD §6.5 修订），文中提到的 PreToolUse 闸门、自有规则、会话滚动、`acceptEdits` 默认值等都已移除；当前测试以 `bun test` / `swift test` 为准。

# PaloAlly V1 · 开发与测试报告（2026-10-04）

## 测试结果总览

| 套件 | 命令 | 结果 |
|---|---|---|
| host 单元 + 集成 | `cd host && bun test` | 76 通过 / 0 失败（另有 10 个 live 用例默认跳过） |
| host ↔ 真实 bento relay | 同上（需本地 `wrangler dev --port 8789`） | 4 通过：配对、E2E RPC、多设备、吊销、设备密钥固定 |
| host ↔ 真实 Claude Code | `PALOALLY_LIVE=1 bun test test/live.test.ts` | 7/7 通过（sonnet-5 主对话 + haiku 探针） |
| 浏览器 MCP | `PALOALLY_LIVE=1 PALOALLY_LIVE_BROWSER=1 …` | 1/1 通过（无头 Playwright + 专属 profile） |
| iOS 包 | `cd ios/PaloAllyKit && swift test` | 71/71 通过，含与 host 的 E2E 互通向量 |
| iOS / Mac Catalyst 构建 | `xcodebuild …` | 均通过 |
| 全链路 | 模拟器 App ⇄ 本地 relay ⇄ `paloally start`（真实 Claude） | 通过（见 `ios/screenshots/10-*`） |
| 安装脚本 | `HOME=<临时> ./install.sh` | 通过；未登录时给出三种认证方式的指引 |

## PRD 需求 → 实现 → 验证

| PRD | 实现 | 验证 |
|---|---|---|
| §6.1 单主对话、实时流式、2 秒反馈、语音 | `hub.ts` 串行轮次 + `chat.delta`；App 有反馈胶囊和听写 | hub 测试、live 测试；App 截图 |
| §6.1 会话模型：原生 session + resume、idle 关进程、可选滚动 + flush | `hub.ts` `onIdle` / `finishRoll` | hub 测试；live「关进程后 resume 仍记得 1275」；daemon 重启后同样记得 |
| §6.2 任务 harness 原生、`report_task` 权威、不漏、按 `parent_tool_use_id` 抓详情 | `tasks.ts`（Agent/Task 都识别；先报后派、先派后报都能合到一行） | tasks 测试 9 个；live：一行、有活动记录、收到/结果两条消息、推送 |
| §6.3 探针：小间隔、短上下文、便宜模型、自注册 watch、游标去重、免打扰与频率 | `probe.ts`、`watches.ts`、`router.ts` | probe 测试 12 个；live：触发后去重，每次约 $0.015，上下文约 2k tokens |
| §6.4 记忆：原生 auto memory，核心经 CLAUDE.md 注入，可见可改 | `memory.ts`、`home.ts` | library 测试；App 记忆 tab |
| §6.5 审批：canUseTool 卡片、多端先答先得、细粒度规则、不可逆永远单独确认、审计、急停、账号隔离 | `approvals.ts`（PreToolUse 闸 + canUseTool）、`audit.ts`、`kill` | approvals 测试 8 个、hub 安全测试 3 个；live：`rm` 被拦并拒绝、文件保留；全链路：CLI 批准后手机卡片同步消失 |
| §6.6 浏览器：注入 MCP + 专属 profile、敏感域名拒绝 | `hub.extraMcpServers`、`approvals.isSensitiveNavigation` | live 浏览器测试 |
| §6.7 Artifact：一物一夹 + meta、置顶/最近排序、任意格式、活产物刷新 | `artifacts.ts`；App 资料库用 QuickLook、markdown、断网 WebView | library 测试；live：写购物清单并登记 |
| §6.8 原生 / Liquid Glass / 无技术词 | SwiftUI `.glassEffect`；行为包禁用技术词；拒绝提示也不带内部词 | 截图 |
| §7.1 Relay 复用 bento（不改） | `channels/relay.ts` + `proto/e2e.ts` | 在真实 relay 代码上跑通 |
| §7.4 一个 CLI + onboarding + 常驻服务 | `cli.ts`、`setup.ts`、`service.ts`（launchd / systemd）、`install.sh` | daemon/CLI 测试；安装脚本试跑 |
| §7.5 微信限制：24h、≤10 条/轮、≤5 条/秒、非 E2E 只发提示 | `channels/wechat.ts`、`router.ts` | 用模拟 iLink 服务器测试 3 个 |
| §12 Phase 0 验收数据 | `paloally metrics`（`metrics.jsonl` + 历史） | daemon 测试 |

## 实测中发现并修掉的问题

1. 外壳自己的 MCP 工具（`report_task` 等）在 `default` 权限模式下也要审批，任务行因此卡住。现在闸门直接放行这些工具。
2. `default` 模式下每次写文件都要确认，太吵。默认改为 `acceptEdits`，不可逆动作仍由闸门强制确认。
3. 用 claude.ai 订阅登录时，探针会装入全部 claude.ai 连接器，每次约 100k tokens。现改为 `strictMcpConfig`，每次约 2k tokens；需要连接器时打开 `probeInheritConnectors`。
4. agent 常常先 `report_task` 再派子 agent，结果出现两行。现在两种顺序都能合成一行。
5. 审批消息原先是 system notice，App 不渲染卡片。现改为 assistant 消息；「同意 xxxx」只出现在微信提示里。
6. 拒绝提示带了「外壳」这类内部词，agent 原样转述给了主人。提示已改写。
7. 根目录很深时，unix socket 路径超过 104 字节，进程起不来。超长时改用 /tmp 下的哈希路径。
8. 一个未处理的 rejection 就能让 daemon 退出。现在只记日志。

## 没能在本机验证的（需要人或外部账号）

- **微信 iLink 实连**：要用你的微信扫码（`paloally wechat login`）。iLink 不是公开 API，字段按社区实现的协议写，测试只覆盖了模拟服务器。
- **APNs 真推送**：要 Apple 开发者 .p8 密钥和真机。JWT 与 HTTP/2 发送已用本地 HTTP/2 服务器测过。
- **App 真机 / 签名发布**：模拟器用 ad-hoc 签名跑通。真机要你的开发者证书。
- **第三方模型（GLM / Kimi 等）**：支持经 `config.env` 配 `ANTHROPIC_BASE_URL`，但没有对应密钥，未实测。
- **Phase 0 的两个核心问题**（任务会不会办偏、推送频率能不能忍）：要你连续用两周，用 `paloally metrics` 看数据。全链路测试里已经出现一次可能办偏的例子：「home 目录」被理解成了用户的主目录 `~`。
