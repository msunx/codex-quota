# Codex Quota

一个原生 macOS 菜单栏应用，用于实时查看当前 Codex/ChatGPT 账号的剩余额度、重置时间、可用重置次数和工作区余额。

## 功能

- 菜单栏持续显示最紧张额度窗口的剩余百分比
- 展示 App Server 返回的全部额度窗口和重置时间
- 展示剩余重置次数和可选工作区余额
- 监听额度更新，并每 30 秒主动校准
- 自动发现 ChatGPT App 或 Codex CLI
- 支持官方 ChatGPT 浏览器登录
- 支持用户主动开启登录时启动
- Catppuccin Macchiato 原生 AppKit 界面

## 环境要求

- macOS 14 或更新版本
- Apple Silicon Mac
- Apple Command Line Tools（运行 `xcode-select --install` 即可）
- ChatGPT App 或 Codex CLI

确认命令行工具：

```bash
clang --version
```

## 构建

```bash
./scripts/build-app.sh
```

构建不依赖完整 Xcode，也不要求升级到 macOS 26。

构建结果位于：

```text
dist/Codex Quota.app
```

产物使用 ad-hoc 临时签名且未公证，定位是个人本机版本，不适合直接对外分发。

将应用拖入 `/Applications` 后打开。首次启动会自动寻找：

1. `/Applications/ChatGPT.app/Contents/Resources/codex`
2. `/Applications/Codex.app/Contents/Resources/codex`
3. Homebrew 与当前 `PATH` 中的 `codex`

找不到时，可在弹窗中点击“选择 Codex”手动指定。

## 隐私

Codex Quota 只通过本机 `codex app-server --stdio` 读取额度。应用不会读取 `~/.codex/auth.json`，不会保存登录令牌，也不会直接调用 ChatGPT 私有接口。

## 常见问题

### 出现 `~/.codex` 权限相关错误

检查当前用户是否拥有 `~/.codex` 的读写权限，并确认没有其他工具将该目录设为只读。

### 无法启用登录时启动

先把 `Codex Quota.app` 移入 `/Applications`，重新打开后再启用。

### 当前 Codex 版本不支持额度接口

更新 ChatGPT App 或 Codex CLI，然后点击“立即刷新”。
