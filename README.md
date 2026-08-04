<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Codex Quota：在 macOS 菜单栏切换 Codex 订阅与 DeepSeek，并查看额度、余额和本机对话入口">
</p>

<p align="center">
  在一个轻量、原生的 macOS 菜单栏应用中管理 Codex 订阅与 DeepSeek API。
</p>

<p align="center">
  <code>macOS 14+</code>&nbsp;&nbsp;·&nbsp;&nbsp;
  <code>Apple Silicon</code>&nbsp;&nbsp;·&nbsp;&nbsp;
  <code>AppKit</code>&nbsp;&nbsp;·&nbsp;&nbsp;
  <code>无第三方依赖</code>
</p>

<p align="center">
  <img src="./assets/readme/panel-preview.png" width="428" alt="Codex Quota 的 Codex 订阅额度面板，显示额度窗口、进度条、重置时间和工作区余额">
</p>

<p align="center">
  <sub>真实 AppKit 界面 · Codex 订阅模式 · 截图使用模拟额度数据</sub>
</p>

## 模型、额度与历史，一起切换

Codex Quota 把“现在用哪个模型”和“还剩多少可用量”放在同一个入口里。菜单栏始终显示当前来源与最关键的额度信息，点开后再处理切换、模型和凭据。

- **Codex 订阅**：显示最低剩余百分比、所有额度窗口、重置时间、剩余重置次数和可选的工作区余额。
- **DeepSeek API**：当前启用 `deepseek-v4-flash`，显示官方余额接口返回的币种与剩余金额；`deepseek-v4-pro` 已预留但暂不可选。
- **安全切换**：切换前备份原有 Codex 配置，API Key 支持 `⌘V` 粘贴、macOS 钥匙串保存和随时更换，切回订阅时恢复原文件。
- **统一入口**：由 Codex Quota 重启 Codex 后，本地历史列表会同时包含 Codex、DeepSeek 和旧版 custom provider 的对话。
- **失败自愈**：额度事件实时更新并每 30 秒校准；Codex 额度接口瞬时失败时按 2、5、15、30、60 秒自动重试。
- **原生且克制**：AppKit + Catppuccin Macchiato，不创建主窗口，不显示 Dock 图标。

## 快速开始

### 运行要求

- macOS 14 或更新版本
- Apple Silicon Mac
- ChatGPT App 或 Codex CLI
- Apple Command Line Tools

DeepSeek 模式要求 Codex `0.144.0` 或更新版本。

如果尚未安装命令行工具：

```bash
xcode-select --install
```

### 从源码构建

```bash
git clone https://github.com/msunx/codex-quota.git
cd codex-quota
./scripts/build-app.sh
```

构建结果位于：

```text
dist/Codex Quota.app
```

将 `Codex Quota.app` 拖入 `/Applications` 后打开。应用启动时会依次查找：

1. 上次手动选择的 Codex；
2. ChatGPT / Codex App 内置的 `codex`；
3. Homebrew 常用路径与当前 `PATH`。

找不到时，可在面板中点击“选择 Codex”手动指定。

> [!NOTE]
> 构建只需要 Apple Command Line Tools，不依赖完整 Xcode，也不要求升级到 macOS 26。

### 第一次切换到 DeepSeek

1. 打开菜单栏面板，选择 **DeepSeek**；
2. 输入或使用 `⌘V` 粘贴 DeepSeek API Key；
3. 保持模型为 `deepseek-v4-flash`；
4. 配置写入成功后选择 **立即重启**。

重启由 Codex Quota 发起：它既让新会话应用 DeepSeek 配置，也为 Codex Desktop 注入本地历史兼容桥。切回 **Codex 订阅** 或更换 API Key 时，同样会询问是否立即重启。

> [!IMPORTANT]
> 如果完全退出 Codex 后直接从 Dock 手动打开，可能绕过历史兼容桥。此时通过 Codex Quota 再切换一次来源，并选择“立即重启”即可恢复统一历史列表；对话数据本身不会被删除。

## 工作方式

<p align="center">
  <img src="./assets/readme/architecture.svg" width="100%" alt="Codex 订阅额度与 DeepSeek 余额通过两条独立链路进入 Codex Quota，再同步到菜单栏、模型配置与统一的本机对话入口">
</p>

### Codex 订阅链路

Codex Quota 启动本机 `codex app-server --stdio` 子进程，完成 JSON-RPC 初始化后读取当前账号与额度：

- `account/read`：确认当前登录状态；
- `account/rateLimits/read`：读取全部额度窗口；
- `account/rateLimits/updated`：额度变化时实时更新；
- 30 秒轮询：在通知缺失时校准；
- 瞬时请求失败：按 2、5、15、30、60 秒自动重试；
- 打开面板、网络恢复或系统唤醒：立即刷新。

### DeepSeek API 链路

DeepSeek 模式遵循官方 Codex 接入方案：应用先备份当前 `~/.codex/config.toml` 和已有的 `models.json`，再写入 `deepseek-v4-flash`、DeepSeek Responses API provider 和模型目录。切回 Codex 订阅时会恢复原文件。

- `GET https://api.deepseek.com/user/balance`：读取币种与剩余金额；
- `experimental_bearer_token`：按 DeepSeek 官方接入方式向 Codex 提供 API Key；
- macOS 钥匙串：保存 API Key，供再次切换和余额查询使用；
- `models.json`：提供 `deepseek-v4-flash` 的模型元数据。

### 本机历史兼容桥

当前适配的 Codex Desktop 版本会按活动 provider 收窄本地历史列表。随应用打包的 `CodexQuotaHistoryBridge` 只在 `thread/list` 没有显式 provider 条件时补充 `openai`、`deepseek` 和 `custom`：

- 不修改 SQLite 会话库或 JSONL 对话内容；
- 不合并、复制或重写任何对话；
- 每条对话继续保留其原始 provider；
- DeepSeek 新对话只保存在本机，不会同步到 OpenAI 云端历史。

连接中显示 `…`，断开或离线时显示 `—`。超过两分钟没有成功更新时，详情面板会将数据标记为陈旧。

## 界面与状态

| 状态 | 表现 |
| --- | --- |
| 正常额度 | 使用 `#C59FF7` 显示剩余百分比与进度 |
| 额度偏低 | 使用黄色提示 |
| 额度紧张 | 使用红色提示 |
| 未登录 | 可发起官方 ChatGPT 浏览器登录 |
| 额度接口瞬时失败 | 保留当前状态并按 2、5、15、30、60 秒自动重试 |
| App Server 中断 | 按 2、5、15、30、60 秒退避重连 |
| DeepSeek 模式 | 显示当前模型、币种、余额与更换 API Key 操作 |
| 工作区未返回 credits | 不显示工作区额度区域 |

应用尊重 macOS“减少动态效果”设置，并为核心状态和控件提供文字及 VoiceOver 信息。

## 隐私边界

Codex 订阅模式的数据路径只发生在本机：

- 不读取 `~/.codex/auth.json`；
- 不持久化登录 URL 或认证令牌；
- 不直接请求 ChatGPT 私有接口；
- 不记录完整额度响应；
- 只跟随当前 Codex / ChatGPT 活动账号和工作区。

使用 DeepSeek 模式时，应用会把 API Key 写入 Codex 官方要求的 `experimental_bearer_token` 配置，并额外保存一份到 macOS 钥匙串用于下次切换；读取余额时只请求 DeepSeek 官方 API，不经由其他服务。

历史兼容桥在内存中透传 App Server 的 JSON-RPC 消息，只识别并补充 `thread/list` 的 provider 过滤条件；它不会记录请求，不会解析或记录对话正文，也不会改写 Codex 会话数据库。

## 当前限制

- 仅构建 arm64 版本；
- 当前版本为 `0.2.4`；
- 不支持多账号切换；
- 不包含自动更新、Mac App Store 分发或内置 Codex；
- 本地构建使用 ad-hoc 签名且未公证，适合个人本机使用。

## 常见问题

<details>
<summary><strong>切换到 DeepSeek 后为什么只看到 DeepSeek 对话？</strong></summary>

确认切换完成时选择了“立即重启”。兼容桥只会注入由 Codex Quota 发起的新 Codex 进程；它负责同时列出多种 provider 的本机历史，但不会修改历史内容。

</details>

<details>
<summary><strong>“统一历史”会把旧对话改成 DeepSeek 吗？</strong></summary>

不会。统一的是列表入口，不是对话内容或 provider。已有 Codex 对话仍保留 `openai`，DeepSeek 对话仍保留 `deepseek`。

</details>

<details>
<summary><strong>Codex 额度暂时无法刷新怎么办？</strong></summary>

应用会自动重试瞬时网络或服务错误。若持续失败，请确认 Codex Desktop 已登录、网络可访问 `chatgpt.com`，再点击“立即刷新”。

</details>

<details>
<summary><strong>为什么无法开启“登录时启动”？</strong></summary>

请先将 `Codex Quota.app` 移入 `/Applications`，重新打开后再启用。

</details>

<details>
<summary><strong>出现 ~/.codex 权限相关错误怎么办？</strong></summary>

确认当前用户拥有 `~/.codex` 的读写权限，并检查是否有其他工具将目录设为只读。

</details>

<details>
<summary><strong>当前 Codex 版本不支持额度接口怎么办？</strong></summary>

更新 ChatGPT App 或 Codex CLI，然后点击“立即刷新”。

</details>

<details>
<summary><strong>全屏时为什么看不到额度？</strong></summary>

macOS 全屏模式可能自动隐藏整条菜单栏。将鼠标移到屏幕顶部，或在系统设置中关闭菜单栏自动隐藏。

</details>

## 开发

```text
Sources/CodexQuota/   AppKit 界面、额度模型、App Server 客户端
Sources/HistoryBridge/ 本地历史列表兼容桥
Resources/            App Bundle 配置
scripts/              构建与图标生成脚本
```

产品边界见 [PRODUCT.md](./PRODUCT.md)，视觉和交互约束见 [DESIGN.md](./DESIGN.md)。

欢迎通过 Issue 报告问题或提出改进建议。
