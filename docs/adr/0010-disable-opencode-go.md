# 0010 — 默认停用 OpenCode Go：代码保留，不进菜单也不抓取

用户不再订阅 OpenCode Go（速度太慢），但它仍留在 `config.toml` 里。本 ADR 决定把 `OpenCode Go` 从 `ProviderID.supported` 摘掉，同时**保留**provider 实现、解码器、logo、进度条渲染与全部 `SelfCheck` 断言；恢复只需把它加回 `supported` 一行。

## Status

已采纳（Accepted）。缩小 [0005](0005-menubar-provider-is-explicit.md) 的候选集合，不改变其「显式选择、失败不自动切换」的原则；[0002](0002-credentials-from-config-toml.md) 与 [0008](0008-kimi-balance-scope-and-currency.md) 的凭据边界不变。

## Context

- 用户明确表示后续可能不再订阅 OpenCode Go，理由是速度慢；但当前订阅期内它仍可能被使用，配置段也还在。
- `OpenCode Go` 是唯一走 percent 路径的 provider：三窗口配额、进度条、重置倒计时、段色、条宽布局（见 [0006](0006-combined-usage.md) 之外的 UI 不变量）都只在它身上生效。删除它等于连带删除一整套通用能力。
- 所有生产路径（抓取循环、registry、菜单 section、「菜单栏显示」子菜单、`default_model` 前缀解析）都以 `ProviderID.supported` 为唯一来源，因此「停用」不需要改行为代码，只需要改这一个列表。
- 需要处理的迁移面只有一处：UserDefaults 里可能存着 `selectedProvider = "opencode-go"`。

## Considered Options

1. **彻底删除 provider**（否决）：代码、资源、测试全部清掉。仓库更干净，但用户只是「暂时不订阅」；以后恢复要从 git 历史里捞回一整套已验收的实现，且删除会连带删掉 percent 渲染能力。
2. **运行时开关**（UserDefaults 键 / 环境变量）（否决）：多出一条无 UI、无测试覆盖的配置路径，还要在每个读取点解释它和 `supported` 的关系；对自建自用的 app，改一行源码重新构建的成本更低。
3. **从 `supported` 摘掉，代码全部保留，注释 + ADR 表达休眠**（选定）。

## Decision

- `ProviderID.supported = [.deepseek, .kimi]`。`ProviderID.opencodeGo` 的 case、`configSectionName`（`"OpenCode Go"`）、`OpenCodeGoProvider`、`BalanceRegistry` 路由、`captureOne` 的凭据分支、logo 资源、解码 / URL / 凭据 / 进度条断言全部保留。
- 所有遍历 `supported` 的路径随之收敛：不抓取、不产生菜单 section、不进「菜单栏显示」子菜单、`default_model` 里的 `OpenCode Go/` 前缀解析为 `.unknown`，首启推导回退 `DeepSeek`。
- `config.toml` 里残留的 `[providers."OpenCode Go"]` 静默忽略；不为已停用 provider 增加迁移提示文案。
- 存量 `selectedProvider = "opencode-go"`（以及任何未知 rawValue）在 `SettingsStore.init` 里回落到 `default_model` 推导值 / `DeepSeek`，并**一次性写回** UserDefaults；键从未存在时不凭空创建。
- 为让 `SelfCheck` 继续覆盖休眠路径，`LiveBalanceSource.captureOne` 与 `StatusBarPresenter.valueItems` 从 `private` 放宽为 `internal`；生产调用点不变，仍只遍历 `supported`。
- 不提供运行时开关。恢复方式：把 `.opencodeGo` 加回 `ProviderID.supported`，重新构建。
- 面向用户的 README 只列当前生效的两个 provider；休眠状态与恢复方式记录在本 ADR 与 `AGENTS.md`。

## Consequences

- 菜单只剩两个 section、子菜单只有两个 radio 项；抓取请求从每 tick 三次降为两次。
- `default_model` 仍指向 `OpenCode Go/…` 的用户，升级后菜单栏落到 `DeepSeek`，菜单里没有任何提示（刻意不加迁移文案）。
- 休眠代码与协议存在漂移风险：`BalanceProvider` 协议或 `ProviderFailure` 分支变化时，编译器会通过穷尽 `switch` 提醒同步修改，但它不再有线上路径验证；重新启用前应先跑一遍 `SelfCheck`。
- OpenCode Go 的三窗口配额 / 进度条能力仍然存在且被断言覆盖，未来出现其他 percent 型 provider 时可直接复用。
- 若恢复订阅，把 `.opencodeGo` 加回 `supported` 即可，无需改配置、资源或测试。

## Amendments

### 2026-11-18 — 恢复启用

用户重新订阅 OpenCode Go，本 ADR 的「默认停用」结论不再成立，但**实现与断言自始至终都保留着**，因此恢复没有新增代码：

- `ProviderID.supported` 改回 `[.deepseek, .opencodeGo, .kimi]`，菜单顺序恢复为 DeepSeek → OpenCode Go → Kimi；抓取循环、菜单 section、「菜单栏显示」子菜单、`default_model` 前缀解析随之全部生效。
- `SettingsStore` 不再把 `opencode-go` 当作脏值：存量的 `selectedProvider = "opencode-go"` 原样保留，其余未知 rawValue 仍走一次性自愈写回。
- 停用期间唯一的语义变化是「休眠 provider 不渲染菜单 section」；`SelfCheck` 的菜单断言已改回三 section / 三 radio，并保留 `valueItems` 的 percent 映射断言。
- 启停仍是一行源码（把 `.opencodeGo` 从 `supported` 摘掉 / 加回），不引入运行时开关。若后续再次停订，重复本节即可。
