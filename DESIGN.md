# Codex Quota 设计约束

## 产品形态

- 这是常驻菜单栏的单用途工具，不创建主窗口，不显示 Dock 图标。
- 菜单栏只表达最重要的信息：仪表图标、当前模型来源，以及 Codex 最低剩余百分比或 DeepSeek 剩余金额。
- 弹窗固定宽 360pt、最大高 500pt；信息过多时只滚动内容区，操作区保持可见。

## 视觉语言

- 固定使用 Catppuccin Macchiato 深色主题。
- Base `#24273A`，Mantle `#1E2030`，Surface `#363A4F`，Text `#CAD3F5`，Lavender `#B7BDF8`。
- 主强调色使用 Purple `#C59FF7`；警告和紧张额度分别使用 Yellow `#EED49F`、Red `#ED8796`。
- 使用平面分区与 1pt 分隔线，不把每项信息包装成独立卡片。
- 文字使用系统字体，数字使用等宽数字；图标仅使用 SF Symbols。

## 交互与动效

- 面板打开时立即刷新；后台以事件更新为主、30 秒轮询为辅。
- 额度进度条复用现有视图并从旧值平滑过渡，使用 350ms ease-in-out；普通刷新不对整个额度区做闪烁式淡入。
- 开启“减少动态效果”时禁用上述动画，不运行持续装饰动画。
- 所有状态必须提供文字，不只依赖颜色；菜单栏图标保持模板单色。
- 底部操作区始终包含刷新、登录（需要时）、选择 Codex、退出和登录项开关。
- 面板顶部提供 Codex 订阅 / DeepSeek 分段开关；DeepSeek 模式显示具体模型、余额和更换 API Key 操作，Pro 选项保持可见但禁用。
- API Key 安全输入框支持标准 `⌘V` 粘贴快捷键；模型配置写入成功后询问是否立即重启 Codex。

## 数据与隐私

- Codex 模式只与本机 `codex app-server --stdio` 通信；DeepSeek 模式只请求官方 `/user/balance`。
- 从应用重启 Codex 时注入本地历史兼容桥，只改写 `thread/list` 的 provider 过滤条件，不记录或改写任何对话内容与会话数据库。
- 不读取 `auth.json`，不持久化 Codex 登录令牌，不记录登录 URL 或完整服务响应。
- DeepSeek API Key 按官方接入要求写入 Codex 配置，并额外保存到 macOS 钥匙串；不写日志、不在界面回显。
- 工作区额度仅在服务端明确返回 credits 字段时显示。
