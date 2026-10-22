# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

主要用户是已经在 macOS 上使用 Codex 或 ChatGPT Codex 的个人开发者。他们希望在不中断当前工作的情况下，随时看到当前模型来源和额度，并能在 Codex 默认订阅、DeepSeek API 与智谱 GLM 之间切换。

## Product Purpose

Codex Quota 是一个仅驻留在 macOS 菜单栏的轻量工具。Codex 模式通过本机 App Server 读取订阅额度；DeepSeek 模式通过官方余额 API 读取剩余金额；GLM 模式通过智谱 Responses 端点接入。外部模型模式统一管理 Codex 所需的模型配置。

任务需要审批或完成时提供 macOS 本地通知，并允许用户主动配置 Bark，将简短任务摘要同步到 iPhone。

成功意味着：额度信息足够及时、状态可信、出现问题时能自解释，同时应用在后台几乎不打扰用户。

## Positioning

Codex 模式直接复用本机官方登录与 App Server 协议。DeepSeek 与 GLM 模式仅在用户主动切换时要求各自的 API Key，并备份、恢复用户原有 Codex 配置。

## Operating Context

- 用户已经安装 ChatGPT App 或 Codex CLI。
- 应用通常随工作日长时间运行，并在菜单栏中提供一眼可读的剩余百分比。
- 详细面板只在用户点击菜单栏项目时出现。
- 第一版仅跟随当前活动的 Codex/ChatGPT 账号和工作区。

## Capabilities and Constraints

- 支持 App Server 的多额度窗口、重置时间、可用重置次数及可选工作区余额。
- 使用事件通知更新，并以 30 秒轮询兜底。
- 自动发现 Codex 可执行文件，找不到时允许手动选择。
- 支持官方 ChatGPT 浏览器登录流程。
- 支持 Codex 默认订阅、DeepSeek 与智谱 GLM 之间切换；GLM 可选择 `glm-5.3-flash` 或 `glm-5.3`。
- 支持 DeepSeek 和 GLM API Key 首次输入、独立钥匙串保存和随时更换；DeepSeek 额外显示官方余额接口返回的币种与剩余金额。
- 模型来源切换完成后询问是否立即重启 Codex；切换外部模型时保留现有 ChatGPT 登录身份，并通过本地兼容桥统一显示 Codex、DeepSeek、GLM 与旧版 custom provider 的会话入口。
- 提供第三方与自建 Skill / 插件管理页，排除系统自带扩展；每 6 小时自动检查更新，并允许用户打开本机安装目录、逐项一键更新或彻底卸载 Skill。
- 每个 Skill 展示用途说明；飞书官方 `lark-*` Skills 聚合为一个“飞书 CLI Skills”套件，并统一通过 `lark-cli update` 更新。
- 菜单栏弹窗在本次运行期间记住最后访问的额度页、扩展页或通知设置页，失去焦点再打开时不重置页面。
- 有明确上游来源的扩展才参与自动版本判断；没有来源元数据的自建 Skill 只展示为本地维护，不自动覆盖。
- 登录时启动由用户主动开启，默认关闭。
- 任务完成或获得明确的审批等待信号时发送 macOS 本地系统通知，点击通知或任务行可打开 Codex 并跳转到对应会话；通知权限和展示方式遵循系统设置。
- 主面板底部齿轮进入独立通知设置页。Bark 默认未配置、未启用；用户粘贴以设备 key 结尾、不含查询参数或片段的 HTTPS JSON 推送链接，点击“保存并启用”即可同步待审批与任务完成两类通知；支持官方和自托管 HTTPS Bark 服务。新启用时不补发旧完成提醒。
- 测试推送使用当前草稿链接，允许保存前测试，且不会保存设置。关闭开关后保存可暂停同步并保留链接；移除会关闭同步并从 macOS 钥匙串删除链接。
- Bark 链接仅存于 macOS 钥匙串，不写入日志；开关与去重元数据存于应用偏好。启用后仅将状态标题、任务标题和项目名发送到配置的 Bark 服务，使用 `Codex Quota` 分组与幂等 ID，不发送对话正文、完整工作目录、命令或文件内容。
- Bark 通道独立于 macOS 桌面通知权限，要求 Codex Quota 保持运行；暂时的网络或服务故障最多自动重试两次，失败状态在通知设置页就地显示。
- 待审批状态通过本机 Codex Desktop IPC 订阅运行中任务的明确审批标记和待处理审批请求；连接中断后自动重连，协议不兼容时回退为运行中，不猜测审批状态。
- Codex 实时状态明确为空闲且没有待处理请求时，移除数据库中残留的运行中任务；保留原始数据库记录，不将残留状态伪造为新完成事件。
- 目标为 macOS 14+、Apple Silicon、个人本机安装。
- 不包含多账号、Mac App Store、应用自身自动更新、公证或内置 Codex 二进制。

## Brand Commitments

- 产品名称：Codex Quota。
- 界面语言：简体中文，协议和必要技术名称保留英文。
- 视觉主题为原生极简浅色体系：统一近白底板、浅灰工具栏、近黑正文和蓝色常规额度线，仅在任务状态、紧张额度与错误中使用语义颜色。
- 界面必须简洁、克制、流畅，不采用网页式仪表盘堆卡片布局。

## Evidence on Hand

- 官方 Codex App Server 提供 `account/rateLimits/read` 和 `account/rateLimits/updated`。
- 当前机器已安装 ChatGPT App 内置 Codex。
- 现有 AppKit 实现和预览资产均在仓库内；本次改版延续产品名称、360pt 菜单栏面板和既有功能。
- Bark 设置页已验证 360×340 与 360×320 布局；本机模拟端点已验证 JSON POST、错误响应及链接校验。真实 iPhone 推送尚未验证，仍需实际设备 key。

## Product Principles

1. 最紧张的额度永远最先被看见。
2. 新鲜度和错误状态必须明确，绝不把旧数据伪装成实时数据。
3. 额度使用官方本地接口；审批状态兼容本机 Codex Desktop 内部 IPC 协议。不接触或持久化 Codex 登录凭据；Bark 任务摘要仅在用户主动启用后发往所配置的服务。
4. 动效用于解释状态变化，不制造持续的视觉噪音。
5. 后台资源占用必须与一个菜单栏工具相称。

## Accessibility & Inclusion

支持 VoiceOver、键盘焦点、高对比度文本，并尊重 macOS 的“减少动态效果”设置。
