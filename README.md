<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Codex Quota：在 macOS 菜单栏查看 Codex 任务与额度、切换模型并维护本机扩展">
</p>

<p align="center">
  原生、轻量、本地优先的 macOS 菜单栏控制面。
</p>

<p align="center">
  <code>macOS 14+</code>
  <code>Apple Silicon</code>
  <code>AppKit</code>
  <code>Local-first</code>
</p>

<p align="center">
  <a href="#开始使用"><strong>开始使用</strong></a> ·
  <a href="#任务与菜单栏信号"><strong>任务信号</strong></a> ·
  <a href="#iphone-通知"><strong>iPhone 通知</strong></a> ·
  <a href="#模型来源"><strong>模型来源</strong></a> ·
  <a href="#扩展管理"><strong>扩展管理</strong></a> ·
  <a href="#数据与隐私"><strong>数据与隐私</strong></a>
</p>

## 一个入口，四类日常状态

<p align="center">
  <img src="./assets/readme/task-panel.png" width="360" alt="Codex Quota 当前主看板预览，包含模型来源、可用额度、任务动态和固定底部工具栏">
</p>

<p align="center">
  <sub>原生极简界面的 AppKit 预览 · 任务与额度均为模拟数据</sub>
</p>

Codex Quota 把经常散落在 Codex、终端和配置目录里的状态集中到一个 360pt 菜单栏面板：

- **盯任务**：菜单栏显示最高优先级任务摘要，运行时以环形短弧提示，任务数始终常亮；主看板只保留待审核、运行中和完成但尚未查看的任务。任务完成或需要审批时发送 macOS 系统通知，也可主动配置 Bark 同步提醒到 iPhone。
- **看额度**：菜单栏用代码括号图标与独立数字显示剩余额度，面板中展示全部 Codex 额度窗口、重置时间、剩余重置次数和可选的工作区额度。
- **切模型**：在 Codex 订阅、DeepSeek 与智谱 GLM 之间切换，同时保留原有配置的恢复路径。
- **管扩展**：识别第三方与自建 Skill / 插件，检查版本、更新、定位目录并完整卸载 Skill。

## 开始使用

### 下载稳定版

从 [GitHub Releases](https://github.com/msunx/codex-quota/releases/latest) 下载 `Codex-Quota-v0.3.0-macos-arm64.zip`，解压后将 **Codex Quota.app** 拖入 `/Applications`。

> [!NOTE]
> 最新稳定版为 `v0.3.0`，新增 Bark 通知同步到 iPhone，并提供独立通知设置页、链接显隐和测试推送。

应用使用 ad-hoc 签名且未公证。首次打开如被 macOS 拦截，请前往“系统设置 → 隐私与安全性”确认打开。

### 从源码构建

准备 macOS 14 或更新版本、Apple Silicon Mac，以及 Apple Command Line Tools：

```bash
xcode-select --install
git clone https://github.com/msunx/codex-quota.git
cd codex-quota
./scripts/build-app.sh
```

构建结果位于 `dist/Codex Quota.app`。整个过程只使用 Apple Clang，不依赖完整 Xcode。

应用会依次查找上次手动选择的 Codex、Codex App 内置 CLI、Homebrew 常见路径和当前 `PATH`；仍未找到时，可在面板底部手动选择可执行文件。

## 任务与菜单栏信号

应用每秒只读校准本机 Codex 主会话的 turn 状态，过滤子 agent 和内部辅助会话。同一个会话隔天继续执行时，也会根据当前会话日志校准最新一轮任务。菜单栏始终只显示优先级最高的一组摘要，避免多个任务同时占满菜单栏：

菜单栏左侧使用 24 × 22 pt「代码括号」图标，额度数字与图标分开展示，右侧显示任务状态和数量，不显示来源名称或模型型号。Codex 显示最低剩余百分比，DeepSeek 显示剩余金额；GLM 尚无额度数据时显示横线。

代码括号中的三根额度柱按同一个最低剩余比例填充：高于 50% 为绿色，20%～50% 为橙色，不高于 20% 为红色，0% 保留红色端点。颜色随菜单栏明暗外观调整。DeepSeek 余额可用时为满柱绿色、不可用时为红色端点；没有有效额度或未连接时使用中性轨道。

运行提示采用「环形流转」：右侧的亮蓝短弧沿 12 pt 圆环以 1.8 秒一圈匀速旋转，任务数与圆环并排显示。蓝色随菜单栏明暗外观调整，左侧图标、额度数字、中间分隔点和右侧任务数始终保持静止、常亮。

普通状态刷新或运行任务数变化时，短弧会继续旋转，不会重新起转。切换为待审核或完成摘要、没有运行任务或菜单栏内容隐藏时停止旋转；系统开启“减少动态效果”时，保留静态圆环与任务数。

| 信号 | 含义 | 行为 |
| --- | --- | --- |
| 🟠 `!` | 待审核 | 根据 Codex 实时审批标记或待处理的命令、文件、权限审批请求显示，处理后恢复运行状态 |
| 🟢 `✓` | 已完成、未查看 | Codex 切到前台后自动清除全部完成提醒 |
| 蓝色环形短弧 | 运行中 | 菜单栏显示旋转圆环与运行任务数；打开面板可查看任务标题、项目和运行时间 |

优先级固定为“待审核 → 未查看完成 → 运行中”。Codex 已在前台时完成的任务会直接视为已查看；手动点击任务或“全部已读”仍可作为兜底。

首次启动新版本时，macOS 会询问是否允许 Codex Quota 发送通知。任务首次进入“待审核”或“已完成”时会显示系统通知和提示音；点击通知或面板中的任务行，会自动打开 Codex 并跳转到对应会话。Codex 未运行时会先启动客户端；旧通知缺少会话 ID 时仅打开客户端，打开失败时会在面板中显示原因。相同事件会自动去重，通知展示方式可随时在“系统设置 → 通知 → Codex Quota”中调整。

> [!IMPORTANT]
> 审批状态通过本机 Codex Desktop IPC 通道同步，约每秒更新。该内部协议可能随 Codex 版本变化；客户端未运行、连接中断或协议不兼容时，会保守显示为“运行中”，不会根据持续时间猜测。自动审批若在两次采样之间完成，可能不会显示短暂的等待状态。

## iPhone 通知

Bark 推送默认未配置、未启用。配置后，可将待审批与任务完成两类通知同步到 iPhone：

<p align="center">
  <img src="./assets/readme/notification-settings.png" width="360" alt="独立通知设置页：Bark 开关、隐藏链接输入框、测试推送及保存操作">
</p>

<p align="center">
  <sub>从主面板底部齿轮进入 · 示例为空配置，不含真实设备链接</sub>
</p>

1. 在 iPhone 的 Bark App 中复制 JSON 推送链接，例如 `https://api.day.app/你的key`；链接必须使用 HTTPS、以设备 key 结尾，且不含查询参数或 `#` 片段，也支持自托管的 HTTPS Bark 服务。
2. 点击主面板底部的齿轮进入 **通知设置**，粘贴链接。
3. 可先点击 **测试推送** 检查当前输入的链接，再点击 **保存并启用** 开启同步。测试使用当前草稿链接，不会保存设置；链接可用输入框右侧的图标显示或隐藏。

启用后不会补发旧的完成提醒。已有配置可通过右上开关修改启用状态，点击 **保存** 后生效；点击地址旁的 **移除链接** 会关闭同步，并从 macOS 钥匙串删除已保存的链接。

Codex Quota 必须保持运行才能发送推送。Bark 通道不受 Mac 桌面通知权限影响；暂时的网络或服务故障最多自动重试两次，失败原因会在通知设置页中显示。

推送仅包含状态标题、任务标题和项目名，使用 `Codex Quota` 分组及幂等 ID，不包含对话正文、完整工作目录、命令或文件内容。启用后，这些摘要会发送到所配置的 Bark 服务。

## 模型来源

| 来源 | 凭据 | 可见状态 | 可选模型 |
| --- | --- | --- | --- |
| Codex 订阅 | 复用本机现有登录 | 额度窗口、重置时间、任务状态 | 当前 Codex 配置 |
| DeepSeek | DeepSeek API Key | 官方余额 | `deepseek-v4-flash`、`deepseek-v4-pro` |
| 智谱 GLM | 智谱 API Key | 配置状态 | `glm-5.3-flash`、`glm-5.3` |

切换外部来源时，应用会先备份 `~/.codex/config.toml` 和已有的 `models.json`，再写入新配置；切回 Codex 订阅时恢复备份。API Key 按 Codex 接入要求写入配置，并使用独立服务项额外保存在 macOS 钥匙串中。

第一次切换外部来源：

1. 在面板顶部选择 **DeepSeek** 或 **GLM**；
2. 输入或使用 `⌘V` 粘贴对应 API Key；
3. 选择模型；
4. 配置成功后选择 **立即重启**。

DeepSeek 模式需要 Codex `0.144.0` 或更新版本。GLM 使用智谱提供的 OpenAI Responses 端点 `https://open.bigmodel.cn/api/v1`。

> [!NOTE]
> 本机历史兼容桥只注入由 Codex Quota 发起的新 Codex 进程。若完全退出后从 Dock 手动打开 Codex，可能绕过兼容桥；重新切换一次来源并选择“立即重启”即可恢复统一入口，不会删除对话。

## 扩展管理

扩展页只展示第三方与自建扩展，过滤系统内置项和插件随附的重复 Skill。每个条目保留来源、作用域、用途与版本状态。

| 来源 | 版本依据 | 可执行操作 |
| --- | --- | --- |
| GitHub Skill | 安装记录中的上游地址与 Git tree 哈希 | 检查、更新、打开目录、卸载 |
| Well-known Skill | 上游 `SKILL.md` 校验结果 | 检查、更新、打开目录、卸载 |
| 自建 / 无来源 Skill | 标记为“本地维护”，不猜测版本 | 打开目录、卸载 |
| Codex 插件 | App Server 返回的本地与市场版本 | 检查、更新 |
| CLI Skill 套件 | 对应 CLI 的官方更新机制 | 整组检查、更新、定位、卸载 |

应用每 6 小时在后台检查一次，也可以手动触发。只有确认存在新版本的条目才会启用“更新”。卸载 Skill 前会明确提示范围；执行后同步清理已发现的安装目录和对应安装记录，失败时保留具体原因。

## 它如何工作

<p align="center">
  <img src="./assets/readme/architecture.svg" width="100%" alt="Codex Quota 本地架构：读取 Codex 额度与任务索引，管理模型配置和扩展，再输出到菜单栏与 Codex Desktop">
</p>

- **额度状态**：App Server 事件为主、30 秒轮询为辅；打开面板、网络恢复或系统唤醒时立即刷新。
- **任务状态**：只读查询本机主会话索引与 turn 状态数据库，并增量读取当前会话日志中的任务开始、完成和中断事件，每秒校准；会话恢复或日志换文件后，历史索引滞后也能识别新一轮任务。运行检测不受会话创建日期、最近会话数量或完成提醒的 7 天保留期限制。通过本机 IPC 订阅主会话的运行与审批状态，断开后自动重连。实时状态明确为空闲且没有待处理请求时，即使旧 turn 仍记为运行中，也会从运行列表移除，不修改 Codex 数据库、不补发完成通知；已查看记录只保存在应用偏好中。
- **系统通知**：任务完成或获得明确的审批等待信号时，通过 macOS 通知中心发送本地通知，不经过外部服务。
- **iPhone 通知**：用户主动开启 Bark 后，将待审批与任务完成摘要以 JSON POST 发送到配置的设备链接；使用独立去重记录，暂时失败最多自动重试两次。
- **模型配置**：只在用户主动切换时备份、写入或恢复配置，并询问是否重启 Codex。
- **历史兼容桥**：仅为 `thread/list` 补充本机 provider 过滤，不读取或改写会话内容。
- **扩展维护**：只读扫描来源与版本；更新、打开目录和卸载都由用户明确触发。

## 数据与隐私

> [!TIP]
> Codex Quota 不需要单独保存 Codex 登录令牌，不保存或上传对话正文。

- 不读取 `~/.codex/auth.json`，不保存登录 URL、认证令牌或完整服务响应。
- 任务检测只保留线程标题、工作目录、会话来源、日志路径、turn 标识、状态和时间，不修改 Codex SQLite 数据库或会话日志。日志读取只解析任务生命周期事件，随事件附带的正文立即丢弃；内存中缓存文件读取位置与生命周期元数据，不保存或上传对话正文。
- 审批订阅会接收 Codex 发出的会话快照与增量，只保留内存中的审批标记、请求类型和 turn 标识；随帧收到的对话正文、命令参数和文件改动会立即丢弃，不写入日志、不持久化、不上传，也不会代替用户批准请求。
- Bark 链接仅保存在 macOS 钥匙串，不写入日志；启用开关和去重元数据保存在应用偏好中。只有主动启用后，任务状态标题、任务标题和项目名才会发送到配置的 Bark 服务；测试推送仅发送固定测试内容。
- DeepSeek 余额只请求官方 `/user/balance`；DeepSeek 与 GLM API Key 不写日志、不在界面回显。
- 历史兼容桥不修改 SQLite 会话库或 JSONL 内容。
- 扩展检查只按安装来源访问对应上游，不上传本机 Skill 内容。
- 配置切换、扩展更新、Skill 卸载和登录时启动都需要用户主动操作。

## 兼容性与限制

- macOS 14+，当前只构建 arm64 版本；
- 需要 Codex App 或 Codex CLI；
- 当前稳定版为 `0.3.0`，不支持多账号切换；
- 不包含应用自身自动更新、Mac App Store 分发、公证或内置 Codex；
- 无来源元数据的本地 Skill 无法自动判断新版本；
- 登录时启动默认关闭。

## 常见问题

<details>
<summary><strong>切换到 DeepSeek 或 GLM 后为什么只看到当前来源的对话？</strong></summary>

确认切换完成时选择了“立即重启”。兼容桥只会注入由 Codex Quota 发起的新 Codex 进程。

</details>

<details>
<summary><strong>“统一历史”会修改或合并旧对话吗？</strong></summary>

不会。统一的只是列表入口；每条对话仍保留原始 provider 和内容。

</details>

<details>
<summary><strong>为什么无法开启“登录时启动”？</strong></summary>

请先将 `Codex Quota.app` 移入 `/Applications`，重新打开后再启用。

</details>

<details>
<summary><strong>全屏时为什么看不到菜单栏状态？</strong></summary>

macOS 全屏模式可能隐藏整条菜单栏。将鼠标移到屏幕顶部，或在系统设置中关闭菜单栏自动隐藏。

</details>

## 开发

```text
Sources/CodexQuota/    AppKit 界面、额度、任务状态、配置与扩展管理
Sources/HistoryBridge/ 本机历史列表兼容桥
Resources/             App Bundle 配置
scripts/               构建与图标生成脚本
```

产品边界见 [PRODUCT.md](./PRODUCT.md)，视觉与交互约束见 [DESIGN.md](./DESIGN.md)。欢迎通过 [Issue](https://github.com/msunx/codex-quota/issues) 报告问题或提出建议。
