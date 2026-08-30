# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

主要用户是已经在 macOS 上使用 Codex 或 ChatGPT Codex 的个人开发者。他们希望在不中断当前工作的情况下，随时看到当前模型来源和额度，并能在 Codex 默认订阅、DeepSeek API 与智谱 GLM 之间切换。

## Product Purpose

Codex Quota 是一个仅驻留在 macOS 菜单栏的轻量工具。Codex 模式通过本机 App Server 读取订阅额度；DeepSeek 模式通过官方余额 API 读取剩余金额；GLM 模式通过智谱 Responses 端点接入。外部模型模式统一管理 Codex 所需的模型配置。

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
- 菜单栏弹窗在本次运行期间记住最后访问的额度页或扩展页，失去焦点再打开时不重置页面。
- 有明确上游来源的扩展才参与自动版本判断；没有来源元数据的自建 Skill 只展示为本地维护，不自动覆盖。
- 登录时启动由用户主动开启，默认关闭。
- 目标为 macOS 14+、Apple Silicon、个人本机安装。
- 不包含多账号、Mac App Store、应用自身自动更新、公证或内置 Codex 二进制。

## Brand Commitments

- 产品名称：Codex Quota。
- 界面语言：简体中文，协议和必要技术名称保留英文。
- 视觉主题固定为参考图风格的暖灰浅色体系，使用白色内容面、近黑正文、黑色主操作和蓝 / 紫 / 橙 / 玫红数据色。
- 界面必须简洁、克制、流畅，不采用网页式仪表盘堆卡片布局。

## Evidence on Hand

- 官方 Codex App Server 提供 `account/rateLimits/read` 和 `account/rateLimits/updated`。
- 当前机器已安装 ChatGPT App 内置 Codex。
- 仓库从零开始，没有需要继承的旧界面或品牌资产。

## Product Principles

1. 最紧张的额度永远最先被看见。
2. 新鲜度和错误状态必须明确，绝不把旧数据伪装成实时数据。
3. 只使用官方本地接口，不接触或持久化认证凭据。
4. 动效用于解释状态变化，不制造持续的视觉噪音。
5. 后台资源占用必须与一个菜单栏工具相称。

## Accessibility & Inclusion

支持 VoiceOver、键盘焦点、高对比度文本，并尊重 macOS 的“减少动态效果”设置。
