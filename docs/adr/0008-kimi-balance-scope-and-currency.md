# 0008 — Kimi 只做开放平台余额：地址写死国内站，凭据取自内置工具服务段

新增第三个 provider `Kimi`（Moonshot / Kimi 开放平台账户可用余额，CNY）。两处刻意偏离既有约定：余额端点与币种**写死国内站** `api.moonshot.cn`（响应里根本没有 currency 字段，单位只由站点隐含），凭据来自 kimi-code 的内置工具服务段 `[services.moonshot_*]` 而不是 `[providers.<段名>]`。同时明确**不做** Kimi Code 订阅额度（其用量端点未公开文档化）。

## Status

已采纳（Accepted）。部分修订 [0002](0002-credentials-from-config-toml.md) 的凭据来源范围：`Kimi` 是唯一从 `[services.*]` 取凭据的 provider，其余 provider 不变。

## Context

- Kimi 有两套互不相通的体系，说「支持一下 kimi」时必须先选定一套：
  1. **开放平台账户**（`platform.kimi.com` / `platform.kimi.ai`）：key 形如 `sk-…`，`GET /v1/users/me/balance` 返回 `available_balance` / `voucher_balance` / `cash_balance`（金额）。官方文档公开；国内站单位人民币、国际站美元，且两站的 key 完全独立（混用返回 401）。
  2. **Kimi Code 订阅**（`managed:kimi-code`，OAuth）：额度是 5 小时滚动窗口 / 周 / 月的**百分比池**，官方没有公开任何用量 API；社区逆向出的 `GET /coding/v1/usages` 未文档化、随时可能变，其凭据要么是 OAuth token（该段 `api_key` 恒空，0002 已把该账号整体排除），要么是控制台另发的 `sk-kimi-…` key（与开放平台 key 不互通）。
- 用户要的是「展示方式基本参照 deepseek」，也就是**金额**，因此选第 1 套。
- 余额响应里**没有** currency 字段：单位只由站点隐含。想按响应自动判币种是不可能的。
- 用户明确要求「完全不动 config.toml」。而 0002 规定凭据只能来自 `[providers.<段名>].api_key`，用户的 config.toml 里却没有任何 moonshot 平台的 provider 段（只有 `managed:kimi-code`，其 `api_key` 恒空）。不放宽 0002，这个 provider 就无从取到凭据。config.toml 里唯一可用的 moonshot 平台 key 落在 `[services.moonshot_search]` 与 `[services.moonshot_fetch]`（kimi-code 内置搜索 / 抓取工具的服务段，实测两段是同一把 key）。
- 另有两个方向被否决：读 OAuth 的 `~/.kimi-code/credentials/kimi-code.json`（那是订阅体系的凭据，对开放平台余额端点会 401，且属于新的凭据存储）；让 app 自存 key（违背「本 app 没有自己的凭据存储」）。

## Considered Options

1. **按 `base_url` 的 host 推导币种，一个 case 覆盖国内 / 国际两站**（否决）：`base_url` 是用户可随意写的值；代理 / 内网网关场景下金额单位根本判不出来，会出现「显示 `$` 但金额是人民币」的静默错值。写死国内站换来的是「站点配错必然 401 报错」，而不是错值。
2. **国内站 / 国际站拆成两个 provider case**（否决）：需要两套凭据、菜单里两个 Kimi section，而用户只有国内站一套。
3. **币种开一个显式配置口子**（如 `currency = "CNY"`）（否决）：会让本 app 第一次读取 `api_key` 之外的配置字段，配置面变大，只为一个本可用 host 判定的场景。
4. **先不做，等用户愿意加 `[providers.Kimi]`**（否决）：用户要的正是「不动配置就能看到余额」，而 `[services.moonshot_*]` 里已经躺着一把可用的平台 key。
5. **地址写死国内站 + 凭据取内置工具服务段**（选定）。

## Decision

- `KimiProvider.balanceURL` 是常量 `https://api.moonshot.cn/v1/users/me/balance`：不读 `base_url`、不经 `normalizeBaseURL`、不做 host 推导；币种恒为 `.cny`。这是「新增 Provider 必须经 `normalizeBaseURL`」的**唯一刻意例外**。
- 凭据路径：`[services.moonshot_search].api_key`，缺失时退到 `[services.moonshot_fetch].api_key`。这是 0002「凭据只读 `[providers.<段名>].api_key`」的**唯一例外**，且只服务 `Kimi`：`KimiConfig` 因此多一张 `services` 表与一个 `credentialSection(_:)`（先查 provider 段、再解析 `services.` 前缀），`CredentialSource` 的 `name` 从「段名」放宽为「凭据路径」。
- 只读、绝不写回 config.toml；不读 `credentials/kimi-code.json`、不读 OAuth、不读 kimi-code 本地 HTTP server、不调用 `getenv` —— 0002 的这些边界一条都没有松动。
- `captureOne` 用穷尽 `switch` 区分凭据来源：`.kimi` 走服务段预检（不查 provider 段存在性，因此不会误报「config 中未找到 provider "Kimi"」），其余走各自的 `[providers.<段名>]`。**新增第四个 provider 必须在这个 switch 里声明自己的凭据来源。**
- 预检与取 key 同口径：候选段里**任一**带内联 key 就算可用；两段都不可用时，报第一个存在的那段的毛病（段名写进文案，用户能照抄去改）。
- 展示：`data.available_balance`（= 现金 + 代金券）单行 `余额 ¥X.XX`，与 DeepSeek 同构；`≤ 0` 时 `isAvailable = false`，复用 DeepSeek 那条 ` ⚠` 后缀。不做代金券 / 现金细分行。
- 解码 all-or-nothing：`code != 0` / `status != true` / `data` 缺失 / 三个余额字段任一不可解析 → `响应解析失败`，绝不展示凭空的 `¥0.00`。
- **不做**：Kimi Code 订阅额度（`/coding/v1/usages`，未文档化）、Kimi Code 的 `sk-kimi-…` key、`managed:kimi-code` OAuth 账号。

## Consequences

- 零配置：用户不动 config.toml 就能看到余额；换 key 只需改内置工具段，下一个 tick 生效。
- 代价一：**与 kimi-code 内置工具服务耦合**。改了或删了搜索 / 抓取工具的 key，余额就断 —— 断法是 `⚠︎凭据` 加一条写明段名的中文说明，不是静默失败。
- 代价二：**只支持国内站**。国际站 key 得到 `鉴权失败 (401)`。这是刻意的：与其猜币种，不如让站点错配直接报错。
- 代价三：这把 key 从此每 30 / 60 / 120 秒随一次余额查询发往 `api.moonshot.cn`（同一厂商、只读端点）。README 已写明。
- 展示的是**开放平台账户余额**，与 Kimi Code 会员额度是两套账：订阅用户看到 `¥0.00 ⚠` 属于正确结果，不是 bug。
- 若 kimi-code 改了内置工具段的形状（改名 / 去掉内联 key / 只留 `api_key_env`），或官方给 Kimi Code 发布了公开的用量 API，本 ADR 需要重审。
