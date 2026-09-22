# Changelog

## Unreleased

### 新增特性

- macOS 菜单栏常驻 app，`LSUIElement`，无 Dock 图标；菜单栏展示选中 Provider 的余额 / 配额，左侧渲染该 Provider 的品牌 logo（template 图，跟随菜单栏明暗自动着色；未知 Provider 不借用别家 logo，只显示文字）。
- 支持两个 Provider：`DeepSeek`（`GET <base_url>/user/balance`，账户 CNY 余额，状态栏形如 `¥65.92`）与 `OpenCode Go`（`GET <base_url>/usage`，5h 滚动 / 7d / 月度三窗口已用百分比，状态栏形如 `16%`）。
- 凭据只读 `~/.kimi-code/config.toml` 的 `[providers.<段名>].api_key`，本 app 不新增凭据存储、不读 Keychain、不解析 `api_key_env`（决策见 `docs/adr/0002-credentials-from-config-toml.md`）。
- 下拉菜单按 Provider 分区（固定顺序 DeepSeek → OpenCode Go，两个 section 永远都在）：DeepSeek 段为余额行 + 今日 / 近 5h 用量；OpenCode Go 段为三窗口进度条行（各自重置倒计时）+ 今日 / 近 5h 用量。
- 未匹配任何受支持 Provider 的用量落到菜单尾行「其他」而非被丢弃（决策见 `docs/adr/0003-usage-attribution-by-model-prefix.md`）。
- 「菜单栏显示 ▸」子菜单切换菜单栏展示的 Provider，选择持久化到 UserDefaults；首次运行由 `default_model` 前缀推导一次初值，此后用户选择优先，采集失败不自动切换（决策见 `docs/adr/0005-menubar-provider-is-explicit.md`）。
- 用量来源：`~/.kimi-code/sessions/<workspace>/<session>/agents/<agent>/wire.jsonl` 的 `usage.record` 行；归属只看 `model` 的 `<Provider>/` 前缀（`llm.request.provider` 恒为协议类型 `"openai"`，不可用于归属）；12 个滑动小时桶 + 今日聚合，去重键为 `(相对路径, 行偏移)`。
- wire 日志增量读取：进程内 Read Cursor（偏移 / 大小 / mtime / 文件身份 / 未成行尾部字节）+ mtime 预筛，每次只读追加字节，不落盘；保留窗口为 `min(当日零点, now − 12h)`（决策见 `docs/adr/0004-wire-log-read-cursor.md`）。
- 移植「阻止系统休眠」守护：基于 IOPMAssertion 同时阻止系统与显示器空闲睡眠，30 / 60 / 120 分钟三档可重复覆盖启动，到期或取消自动释放，进程退出静默释放；守护期间菜单栏变咖啡色胶囊并在余额右侧追加 ` ☕`，倒计时只在菜单打开期间按秒走动，到期释放由一次性定时器触发而非轮询。
- 错误降级永不空白：`config.toml` 不可读 / 非法时菜单栏显示 `?kimi`；单个 Provider 的段缺失、`api_key` 为空、使用 `api_key_env` 或远端失败时显示 `⚠︎配置` / `⚠︎凭据`，下拉菜单给出可照抄去改配置的中文说明；抓取失败但存在旧值时保留旧值并标注「旧值」。
- SwiftUI 偏好面板：刷新间隔三档（30 / 60 / 120 秒，默认 60 秒），存量非法值自动回退默认档并写回自愈。
- 一键构建：`./build.sh`（编译 + 复制 `Resources/*.png` + 拼 `.app` bundle + ad-hoc 签名）。
- 自检入口：`swift run kimi-companion --self-check`，411 个断言覆盖格式化 / 响应解码 / 用量归属 / 增量读取契约 / tick 状态机 / 菜单与状态栏渲染 / 守护路径。
