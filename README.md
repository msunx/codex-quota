<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Codex Quota：macOS 菜单栏里的额度、模型与扩展控制面">
</p>

<p align="center">
  原生 macOS 菜单栏工具：查看 Codex / DeepSeek 可用量，切换模型来源，并维护第三方 Skill 与插件。
</p>

<p align="center">
  <code>v0.2.6</code>
  <code>macOS 14+</code>
  <code>Apple Silicon</code>
  <code>AppKit</code>
</p>

<p align="center">
  <a href="#快速开始"><strong>快速开始</strong></a> ·
  <a href="#扩展管理"><strong>扩展管理</strong></a> ·
  <a href="#工作方式"><strong>工作方式</strong></a> ·
  <a href="#隐私边界"><strong>隐私边界</strong></a>
</p>

## 先看它实际做什么

<p align="center">
  <img src="./assets/readme/quota-panel.png" width="340" alt="Codex Quota 主面板，显示 Codex 额度窗口、模型来源开关和扩展入口">
  &nbsp;&nbsp;
  <img src="./assets/readme/extensions-panel.png" width="340" alt="Codex Quota 扩展管理页，显示飞书 Skill 套件、第三方 Skill 的说明、状态、更新、目录和卸载操作">
</p>

<p align="center">
  <sub>当前 AppKit 构建的预览界面 · 额度数据为模拟值 · 扩展列表来自本机只读扫描</sub>
</p>

Codex Quota 把原本分散在命令行、配置文件和多个扩展目录里的日常操作，收进一个不占 Dock 位置的菜单栏面板：

- **看额度**：显示 Codex 所有额度窗口、重置时间、剩余重置次数和可选的工作区余额；DeepSeek 模式显示官方接口返回的币种与余额。
- **切来源**：在 Codex 订阅、`deepseek-v4-flash` 与 `deepseek-v4-pro` 之间切换，自动备份和恢复 Codex 配置，API Key 保存到 macOS 钥匙串。
- **保留历史入口**：由 Codex Quota 重启 Codex 后，本机列表可以同时显示 `openai`、`deepseek` 和旧版 `custom` provider 的对话。
- **管扩展**：只列第三方和自建 Skill / 插件，展示用途说明，检查新版本，并提供更新、Finder 定位和 Skill 完整卸载操作。

## 快速开始

### 运行要求

- macOS 14 或更新版本
- Apple Silicon Mac
- ChatGPT App 或 Codex CLI
- Apple Command Line Tools

DeepSeek 模式需要 Codex `0.144.0` 或更新版本。如果尚未安装命令行工具：

```bash
xcode-select --install
```

### 下载应用

从 [GitHub Releases](https://github.com/msunx/codex-quota/releases/latest) 下载 `Codex-Quota-v0.2.6-macos-arm64.zip`，解压后将 **Codex Quota.app** 拖入 `/Applications`。Release 同时提供 SHA-256 校验文件。

应用使用 ad-hoc 签名且未公证；首次打开如被 macOS 拦截，请在“系统设置 → 隐私与安全性”中确认打开。

### 从源码构建

```bash
git clone https://github.com/msunx/codex-quota.git
cd codex-quota
./scripts/build-app.sh
```

应用生成在：

```text
dist/Codex Quota.app
```

将它拖入 `/Applications` 后打开。构建只需要 Apple Command Line Tools，不依赖完整 Xcode，也不要求升级到 macOS 26。

应用会依次查找上次手动选择的 Codex、ChatGPT / Codex App 内置的 `codex`、Homebrew 常用路径和当前 `PATH`；如果仍未找到，可在面板中手动指定。

### 第一次切换到 DeepSeek

1. 在菜单栏面板选择 **DeepSeek**；
2. 输入或用 `⌘V` 粘贴 DeepSeek API Key；
3. 按需要选择 `deepseek-v4-flash` 或 `deepseek-v4-pro`；
4. 配置写入成功后选择 **立即重启**。

切回 Codex 订阅时，应用会恢复切换前的配置。更换 API Key 或切换来源后选择“立即重启”，可以同时应用新模型配置和本机历史兼容桥。

## 扩展管理

扩展页过滤 `system` scope、Codex 内置市场和插件随附的重复 Skill。说明文本保持单行截断，悬停时显示完整换行内容；关闭弹窗、切换到其他程序再回来，也会停留在上次打开的页面。

| 来源 | 如何识别 | 可执行操作 |
| --- | --- | --- |
| GitHub Skill | 安装锁中的来源信息与上游 Git tree 哈希 | 检查更新、更新、打开目录、卸载 |
| Well-known Skill | 上游 `SKILL.md` 校验结果 | 检查更新、更新、打开目录、卸载 |
| 自建 / 无来源 Skill | 标记为“本地维护”，不猜测上游版本 | 打开目录、卸载 |
| 飞书官方 Skills | 将全部 `lark-*` Skill 聚合为“飞书 CLI Skills”套件 | 整组检查、更新、打开目录、卸载 |
| Codex 插件 | App Server 返回的本地版本与市场版本 | 检查更新、一键更新 |

更新检查每 6 小时在后台执行一次，也可以手动触发。只有确认存在新版本的条目才会启用“更新”按钮：独立 Skill 通过 `npx skills` 更新，插件通过 Codex App Server 更新，飞书套件执行：

```bash
lark-cli update
```

未安装飞书 CLI 时，可运行：

```bash
npx @larksuite/cli@latest install
```

具体安装与授权方式见[飞书 CLI 官方文档](https://www.feishu.cn/feishu-cli)。

卸载仅对 Skill 开放。应用会删除该 Skill 的全部已发现安装目录，并同步清理 `~/.agents/.skill-lock.json` 中的对应记录；任一步骤失败都会给出具体原因，避免把部分完成伪装成成功。飞书套件会移除整组 Skills，但保留 `lark-cli` 程序。

> [!NOTE]
> 扩展管理依赖 Codex App Server 的 `skills/list`、`plugin/list` 和 `plugin/install`。如果旧版 Codex 尚不支持插件接口，Skill 仍会保留在列表中，插件错误会单独显示；更新 ChatGPT App 或 Codex CLI 后再检查即可。

## 工作方式

<p align="center">
  <img src="./assets/readme/architecture.svg" width="100%" alt="Codex App Server、DeepSeek API 和本机扩展来源进入 Codex Quota，再驱动菜单栏、Codex Desktop 和扩展目录操作">
</p>

### Codex 订阅额度

应用启动本机 `codex app-server --stdio`，通过 JSON-RPC 读取当前账号与全部额度窗口。额度事件实时更新，并每 30 秒校准一次；瞬时失败时按 2、5、15、30、60 秒退避重试，打开面板、网络恢复或系统唤醒时会立即刷新。

### DeepSeek 配置与余额

切换前会备份 `~/.codex/config.toml` 和已有的 `models.json`，再写入包含 `deepseek-v4-flash` 与 `deepseek-v4-pro` 的 DeepSeek Responses API provider 和模型目录。余额只请求 DeepSeek 官方 `/user/balance`，API Key 同时按 Codex 接入要求写入配置，并保存到 macOS 钥匙串供再次切换使用。

### 本机历史兼容桥

随应用打包的 `CodexQuotaHistoryBridge` 只在 `thread/list` 没有显式 provider 条件时补充 `openai`、`deepseek` 和 `custom`。它不修改 SQLite 会话库或 JSONL 内容，不复制对话，也不会改变每条对话原有的 provider。

> [!IMPORTANT]
> 如果完全退出 Codex 后直接从 Dock 手动打开，可能绕过历史兼容桥。通过 Codex Quota 再切换一次来源并选择“立即重启”即可恢复统一列表；对话数据不会被删除。

## 隐私边界

- Codex 订阅模式只与本机 App Server 通信，不读取 `~/.codex/auth.json`，不保存登录 URL 或认证令牌。
- DeepSeek 余额只请求官方 API；API Key 不写日志、不在界面回显，并额外保存在 macOS 钥匙串。
- 历史兼容桥只透传并补充 `thread/list` 的过滤条件，不读取或记录对话正文，不改写会话数据库。
- 扩展检查会按安装来源访问 GitHub、Well-known Skill 站点、npm 或 Codex 插件市场；只有用户点击“更新”或确认卸载后才会写入本机目录。

## 当前限制

- 仅构建 arm64 版本，当前版本为 `0.2.6`；
- 不支持多账号切换；
- 不包含应用自身自动更新、Mac App Store 分发或内置 Codex；
- 没有来源元数据的本地 Skill 无法自动判断新版本；
- 本地构建使用 ad-hoc 签名且未公证，适合个人本机使用。

## 常见问题

<details>
<summary><strong>切换到 DeepSeek 后为什么只看到 DeepSeek 对话？</strong></summary>

确认切换完成时选择了“立即重启”。兼容桥只会注入由 Codex Quota 发起的新 Codex 进程。

</details>

<details>
<summary><strong>“统一历史”会修改或合并旧对话吗？</strong></summary>

不会。统一的只是列表入口；Codex、DeepSeek 和 custom 对话仍保留各自原始 provider 和内容。

</details>

<details>
<summary><strong>为什么无法开启“登录时启动”？</strong></summary>

请先将 `Codex Quota.app` 移入 `/Applications`，重新打开后再启用。

</details>

<details>
<summary><strong>全屏时为什么看不到额度？</strong></summary>

macOS 全屏模式可能自动隐藏整条菜单栏。将鼠标移到屏幕顶部，或在系统设置中关闭菜单栏自动隐藏。

</details>

## 开发

```text
Sources/CodexQuota/    AppKit 界面、额度、配置与扩展管理
Sources/HistoryBridge/ 本机历史列表兼容桥
Resources/             App Bundle 配置
scripts/               构建与图标生成脚本
```

产品边界见 [PRODUCT.md](./PRODUCT.md)，视觉与交互约束见 [DESIGN.md](./DESIGN.md)。欢迎通过 Issue 报告问题或提出改进建议。
