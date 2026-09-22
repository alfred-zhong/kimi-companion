# kimi-companion

Kimi Code 配套工具：macOS 菜单栏常驻 app（`LSUIElement`，无 Dock 图标），展示 **kimi-code desktop 所用第三方 Provider 的余额 / 配额**，以及各 Provider 自己的 token 消耗。

## 功能

- 菜单栏右上角展示**选中 Provider** 的余额 / 配额，左侧带该 Provider 的品牌 logo：
  - DeepSeek → `¥65.92`（CNY 账户余额）
  - OpenCode Go → `16%`（5h 滚动窗口已用百分比）
- 弹出菜单（两个 Provider 的 section 永远都在，顺序固定）：
  - `DeepSeek`：余额行 + `今日 · ↑输入 · ↓输出 · ⚡缓存读取 · 🎯hit%` + `近5h · …`
  - `OpenCode Go`：5h / 7d / 月度三窗口进度条行（各自重置倒计时）+ 今日 / 近 5h 用量
  - `其他 · …`：未匹配任何受支持 Provider 的用量（有才显示）
  - `菜单栏显示 ▸`：切换菜单栏展示的 Provider
  - `阻止系统休眠 ▸`：30 / 60 / 120 分钟 + 倒计时行 + 取消守护
  - `偏好…` / `立即刷新` / `退出`
- 自动定时刷新，默认 60s，可在偏好面板调为 30 / 60 / 120s；每次刷新实时查询 Provider 并**增量**读取会话日志，无磁盘缓存。
- 错误降级永不空白：`config.toml` 不可读 / 非法时菜单栏显示 `?kimi`；单个 Provider 缺配置、缺凭据或请求失败时显示 `⚠︎配置` / `⚠︎凭据`，下拉菜单给出可照抄去改配置的中文说明。

## 支持的 Provider

| Provider | 展示内容 | 端点 |
|---|---|---|
| `DeepSeek` | 账户余额（CNY，形如 `¥65.92`） | `GET https://api.deepseek.com/user/balance` |
| `OpenCode Go` | 5h / 7d / 月度窗口已用百分比 | `GET https://opencode.ai/zen/go/v1/usage` |

两者都用 `Authorization: Bearer <api_key>`。`base_url` 若在 `config.toml` 里配了则以它为准（去掉尾部 `/` 后拼接路径）；非 HTTPS 或不带 host 的值会被忽略并回退到上表的官方默认地址。

## 凭据

凭据**只读** kimi-code 自己的 `~/.kimi-code/config.toml`，取 `[providers.<段名>]` 段里的内联 `api_key`；本 app 没有自己的凭据存储，不写回该文件、不读 Keychain、不解析 `api_key_env`。

```toml
default_model = "OpenCode Go/deepseek-v4.1-flash"

[providers.DeepSeek]
base_url = "https://api.deepseek.com"
api_key = "sk-..."

[providers."OpenCode Go"]     # 段名含空格，TOML 里需要加引号
base_url = "https://opencode.ai/zen/go/v1"
api_key = "sk-..."
```

- 段名逐字使用（`DeepSeek`、`OpenCode Go`），它同时是配置键、用量归属的前缀、菜单 section 的标题。
- `api_key` 为空 / 全空白视为没有凭据；段里只写了 `api_key_env` 时视为凭据不可解析（菜单里会说明原因）——Finder 启动的 GUI app 不继承用户 shell 环境，读环境变量不可靠。
- 该文件不存在、无权限或 TOML 非法时，菜单栏降级为 `?kimi`。

## 用量数据来源

token 消耗来自 kimi-code 的会话记录：`~/.kimi-code/sessions/<workspace>/<session>/agents/<agent>/wire.jsonl` 里的 `usage.record` 行。

- 归属按记录的 `model` 字段 `<Provider>/<model>` 前缀逐字匹配 Provider 名（`llm.request.provider` 恒为 wire 协议类型 `"openai"`，两个 Provider 都是它，不能用来判归属）。
- 每条 `usage.record` 是**单次调用的增量**，直接求和，不做差分。
- 读取是增量的：进程内维护每个文件的读取游标，每次只读自上次以来追加的字节；保留窗口为 `min(当日零点, now − 12h)`。游标不落盘，进程重启后首次刷新做一次全量。
- 聚合出「今日」与「近 5h」（后 5 个滑动小时桶的并集），未匹配任何 Provider 的用量归入「其他」。

## 编译与运行

```bash
# 编译 + 复制 Resources + 拼 .app + ad-hoc 签名
./build.sh

# 启动
open build/kimi-companion.app

# 或：直接跑可执行文件
./build/kimi-companion.app/Contents/MacOS/kimi-companion
```

`make build` / `make run` / `make test`（跑自检）/ `make clean` 也可用。需要 debug 编译：`CONFIG=debug make build`。

## 自检

```bash
swift run kimi-companion --self-check
```

输出 `[self-check] OK (全部通过)` 即表示全部断言通过（余额与配额的响应解码、格式化、用量归属与去重、增量读取契约、tick 状态机、菜单与状态栏渲染、休眠守护路径）。**不做任何真实网络请求**，也不触碰真实 UI。

## 切换菜单栏展示的 Provider

打开下拉菜单 →「菜单栏显示 ▸」→ 选中 `DeepSeek` 或 `OpenCode Go`（当前项带 ✓）。

- 选择会持久化到 UserDefaults，重启后保持。
- **首次运行**时按 `config.toml` 的 `default_model` 前缀推导一次初值（推导不出则用 `DeepSeek`）；此后只有你的显式选择能改变它。
- 某个 Provider 抓取失败**不会**把菜单栏自动切到另一个；菜单栏只会显示失败短标签，另一个 Provider 的 section 仍然正常显示自己的数据。

## 已知限制

- **没有成本 / 消费数据**：本地只有 token 计数（输入、输出、缓存创建、缓存读取）与 DeepSeek 的账户余额，没有任何价格表或账单数据，因此菜单里不显示「花了多少钱」。
- **first-party kimi-code 账号有意不支持**：`managed:kimi-code` 段的 `api_key` 恒为空、走 OAuth，且本地 `oauth/usage` 端点只覆盖该账号本身，产品上已排除。
- **runtime 覆盖不可见**：菜单栏展示的是用户显式选定的 Provider，不跟随会话内的临时模型切换。
- **不做开机自启**：没有 LaunchAgent，也不写 `~/Library/LaunchAgents/*.plist`。
- **仅本机 ad-hoc 签名**（`codesign --force --deep --sign -`），未做 Developer ID 公证，不适合分发。
- **构建环境是 Command Line Tools only**：`xcodebuild` 不可用；SwiftUI 视图状态用 `ObservableObject` + `@ObservedObject`（`@State` 等宏展开的 property wrapper 在缺少 `libSwiftUIMacros.dylib` 的 CLT 环境下编不过）。
- **日志时间戳依赖时钟**：系统时钟被回拨时，增量读取会丢弃全部游标状态并退化为一次全量重扫。

## 架构

术语表见 `CONTEXT.md`，决策记录见 `docs/adr/`：

- `0001-standalone-menubar-app.md` — 为什么必须是独立菜单栏 app（kimi-code 没有 UI 扩展点）
- `0002-credentials-from-config-toml.md` — 为什么凭据只读 `config.toml`，不做偏好面板凭据存储
- `0003-usage-attribution-by-model-prefix.md` — 为什么按 `model` 前缀归属用量
- `0004-wire-log-read-cursor.md` — wire 日志的增量读取与 Read Cursor
- `0005-menubar-provider-is-explicit.md` — 为什么菜单栏 Provider 是显式选择
