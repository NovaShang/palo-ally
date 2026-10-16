# PaloAlly

[English](README.md) · 中文

PaloAlly 把你已经在用的编程 agent（目前是 Claude Code）变成一个常驻的私人助理：它一直在你的电脑上运行，有事时通过手机或微信找你，并且记得你。数据和模型留在你自己的机器上。

- 产品需求：[`docs/paloally-prd-v2.md`](docs/paloally-prd-v2.md)
- 实现设计和线协议：[`docs/design.md`](docs/design.md)

## 它是什么

你用 iPhone 或 Mac 的 App、微信或终端，跟一个助理（默认叫 Palo）说话。这是一段一直延续的对话。助理就是在你电脑上以服务方式运行的 Claude Code，外面加了一层手机需要的东西：推送通知、点一下就能回答的确认和提问卡片、它替你做出的文件的资料库、长期盯着的目标，以及晨报。

- **目标。**让它盯某件事（机票价格、一个邮箱、一个习惯），它会登记成目标。一个便宜的探针按时检查，只在值得时打扰你。
- **安全交给 Claude Code。**需要确认的操作由 Claude Code 决定，它问的时候问题会送到你手机上。它做的每件事都记在审计日志里。
- **花费。**用你自己的 Claude 登录或 API 密钥（也可以用第三方的 Anthropic 兼容模型）。探针和主对话每天的预算在 `config.json` 里。

### Pals

Pal 是这台电脑上由 PaloAlly 托管的一个 Claude Code 会话，适合要做好几天的项目：你在 App 里直接跟它说话，看它流式输出，在手机上回答它的确认和提问。助理可以为长期项目开一个 Pal（你点一下确认），给它派活、读它的回话；你也可以把电脑上以前的某个 Claude Code 对话接管成 Pal。闲着的 Pal 会睡下，需要时再叫醒。「交还终端」会给你一行 `claude --resume`，让你自己接着用。设计见 [`docs/pals-prd.md`](docs/pals-prd.md)。

### Allies

Ally 是另一个人的 PaloAlly（或你自己另一台电脑上的）。两个人当面扫码互加，之后两个助理可以互相传话，也可以对照日历约时间。每个 Ally 你可以选一档：每句回复都先拟成草稿等你点发送，或者让助理直接回答。两种情况下每句来往都留有记录，随时能翻。Ally 发来的话只当消息，不当指令；处理它的那一轮里，助理只能回话、看你的日历、查记忆。设计见 [`docs/allies-prd.md`](docs/allies-prd.md)。

### 隐私

- 助理、记忆、文件和聊天记录都在你电脑的 `~/.paloally` 下。模型调用发往你配置的 Claude（或兼容）接口。
- App 和主机之间经中继转接，端到端加密：中继看得到谁在连，看不到内容。Ally 之间的消息也是主机到主机端到端加密。
- 推送通知经 Apple 的推送服务，带一句短文字；微信经过腾讯的服务器，不是端到端加密，所以默认只发一句提示（不带内容），密码之类的内容绝不走微信。
- App 里的语音输入经中继转写，按安装有用量限制。
- 仓库是公开的，里面没有任何人或设备的信息。

### 语言

助理可以说中文或英文，设置项是 `language`（`zh` 或 `en`）。你没设过时，第一台连上来的设备会报告它的首选语言，主机就用它；没有设备报告时用 Mac 的系统语言。随时可以用 `paloally settings language zh`（或 `en`）或在 App 里改。助理的回复、通知、推送标题、命令行输出和初始的 `user.md`、`soul.md` 都跟着走；你改过的文件不会被重写。实现见 [`docs/design.md`](docs/design.md) 第 7 节。

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/NovaShang/palo-ally/main/install.sh | bash   # 或在检出的仓库里运行 ./install.sh
paloally service install
paloally pair           # 用 App 扫码配对
paloally wechat login   # 可选
```

安装脚本会在没有 Bun 时装上它，把代码放进 `~/.paloally/app`，把 `paloally` 链接到 `~/.local/bin`，并运行 `paloally setup`。你需要自己的 Claude 访问权限：在 Claude Code 里用 claude.ai 登录，或者一个 API 密钥。

`paloally setup` 做首次设置：创建 home 目录、写配置、检查模型连通，也可以配置第三方 Anthropic 兼容模型（GLM / Kimi / DeepSeek 等，用 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_AUTH_TOKEN`）。

Mac 版 App 可从最新发布下载 [PaloAlly.dmg](https://github.com/NovaShang/palo-ally/releases/latest/download/PaloAlly.dmg)（需要 macOS 26 或更高；已用 Developer ID 签名并公证）。iPhone 版还不在 App Store，用你自己的开发者团队从 `ios/` 构建，见 [`ios/README.md`](ios/README.md)。

## 日常使用

```sh
paloally chat                 # 在终端里说话
paloally status | tasks | approvals | watch | artifacts | memory | audit
paloally stop                 # 停下手上的事
paloally restart              # 空闲后重启（--now 立刻）
paloally update               # 立刻更新到最新发布（--check 只看看）
paloally doctor               # 体检
```

英文版的发布、更新、测试等说明见 [README.md](README.md)。

## 许可

MIT，见 [`LICENSE`](LICENSE)。
