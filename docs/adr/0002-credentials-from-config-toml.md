# 0002 — 凭据只读 `config.toml` 的内联 `api_key`

provider 凭据**只读** `~/.kimi-code/config.toml` 里 `[providers.<段名>].api_key`。本 app 不持有凭据存储：不写回该文件、不读 Keychain、不解析 `api_key_env`、不查 kimi-code 的本地 HTTP server。

## Status

已采纳（Accepted）。

## Context

- kimi-code 自己就在 `~/.kimi-code/config.toml` 里为每个 provider 段保存内联 `api_key`（`[providers.DeepSeek]`、`[providers."OpenCode Go"]`）。也就是说用户**已经配过一份**，而且是 kimi-code 正在用的那一份。
- 兄弟项目 omp-companion 走的是相反路线：provider key 由偏好面板配置、经 `SettingsStore` 存 UserDefaults。其 ADR-0008 自己把后果挑明为「**双份配置**」——宿主仍读 `.env`，于是同一个 key 需要两处各配一份；并且它明确写着「这不是迁移，是新增第二份配置」。
- 若本 app 同样做偏好面板凭据存储，就会把同一个 key 在 `config.toml` 与 UserDefaults 里各存一份：重复配置、两份都可能过期、用户在 kimi-code 里换了 key 而菜单栏还在用旧的。
- 另一个候选来源是 kimi-code 的本地 HTTP server：`~/.kimi-code/server/instances/*.json` + `server.token` 提供 `/api/v1/providers/{id}`，**确实会返回明文 key**。代价是要求 kimi-code 正在运行，且该端点可被本机任意进程访问（鉴权 token 就在同目录下可读）。
- `api_key_env` 是本 app 无法可靠解析的形式：Finder 启动的 GUI app 不继承用户 shell 环境，`getenv` 拿不到用户交互式 shell 里的变量。

## Considered Options

1. **偏好面板凭据存储**（否决）：兄弟项目的 ADR-0008 已记录为「双份配置」痛点——同一个 key 存两处。本 app 不重复这个取舍。
2. **查询 kimi-code 本地 HTTP server `/api/v1/providers/{id}`**（否决）：确实返回明文 key，但要求 kimi-code 在运行，且该端点本机任意进程可达、鉴权 token 与端点同目录可读。收益（省一次 TOML 解析）远小于新增的运行时依赖与暴露面。
3. **只读 `config.toml` 的内联 `api_key`**（选定）：复用用户已经配好、kimi-code 正在用的那一份，零额外配置。

## Decision

- `KimiConfigSource` 只读 `~/.kimi-code/config.toml`，取出 `default_model` 与 `[providers.*]` 段里的 `base_url` / `api_key`；段名逐字保留（`"OpenCode Go"` 含空格）。
- **空字符串（含全空白）等于「没有凭据」**：`apiKey` 归一化为 `nil`。
- **`api_key_env` 视为凭据不可解析**：本 app 不调用 `getenv`。段里只有 `api_key_env` 而没有内联 `api_key` 时报 `credentialEnv`，菜单里给出明确说明（「使用 api_key_env，本 app 只读内联 api_key」），而不是猜一个值或静默失败。
- **只读，绝不写回** `config.toml`；不读 Keychain；不读 kimi-code 本地 HTTP server（`server/instances/*.json`、`server.token`、`mcp.json` 一律不碰）。
- 凭据在每次 tick 重新从文件读取（`LiveBalanceSource.capture` 内调 `config.load()`）：用户在 kimi-code 里改了 key，下一个 tick 即生效，无需重启。
- 凭据来源抽象为 `CredentialSource`（`resolve(_ name: String) -> String?`，`name` 是段名逐字），由 `TomlCredentialSource` 实现；协议形状与 omp-companion 保持平行，使 `BalanceProvider` 的实现两边可以对照。
- 请求侧一律 `Authorization: Bearer <api_key>`，10 秒超时。

## Consequences

- 零额外配置：kimi-code 里配过就能用；换 key 只需改一处。
- 代价是 app 无法脱离 kimi-code 的配置独立工作——用户没配过 `config.toml` 时，菜单栏只能显示 `?kimi` / `⚠︎配置` / `⚠︎凭据`，没有应用内填 key 的入口。
- `api_key_env` 用户得到的是明确说明而非静默失败。
- 每次 tick 读一次文件并解析 TOML：文件很小，开销可忽略；换来的是无需重启即可跟上配置变化。
- 若将来 kimi-code 改变配置形状（例如移除内联 key、只留 OAuth 或只留环境变量），本 ADR 需要重审。
