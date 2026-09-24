# 0007 — 在 app 内清理 Chat Session（唯一破坏性能力）

app 新增**唯一一项破坏性能力**：按显式的 Retention Policy 删除 `~/.kimi-code/sessions` 下的 Chat Session，并顺带回收它们的孤儿产物。删除**只能**经 Cleanup Preview 显式确认后发生，机制是直接删文件系统——不走 kimi-code 的本地 HTTP 删除接口（[0002](0002-credentials-from-config-toml.md) 已排除该来源），也不 shell-out 任何外部进程。

## Status

已采纳（Accepted）。

## Context

- 用户要求把 `~/play/kimi-sessions-cleanup.py` 的能力集成进 app：菜单加一项触发，偏好设置暴露两个参数，点击后先给 dry-run 预览、确认才真删，删完报告结果。
- 这个 app 在此之前是**纯只读观察者**：生产代码零写入、零删除，唯一的持久化是 UserDefaults。本 ADR 记录的就是打破这一点的取舍。
- **一个 Chat Session 不是一个目录。** 实测它有 4 处产物，删一处会留下孤儿：
  1. `sessions/<Workspace Bucket>/<Chat Session>/` —— 主体（实测 19 个 / 64M，占 `~/.kimi-code` 的 76%）；
  2. `server/events/<Chat Session>.jsonl` —— 该 Chat Session 的事件流（实测 20 个文件 / 17M，另有 `__global__.jsonl` 是全局流，**不属于任何 Chat Session**）；
  3. `session_index.jsonl` —— 追加式索引，每行 `{sessionId, sessionDir, workDir}`（实测 19 行）；
  4. `file-history/<Workspace Bucket>` —— 按 Chat Session id 记账的账本（实测 4 个文件 / 16K）。
- 这 4 处的自愈能力**完全不同**，这是本 ADR 的核心事实：
  - `session_index.jsonl`：kimi-code 自己会在**每次启动**压缩重写，但门槛是**僵尸行 ≥16 条且占比 ≥20%**（实测代码）。当前 19 行，删掉 5 个也触发不了 —— 僵尸行会长期堆积，而该文件在启动时会被 merge 进 `workspaces.json`。
  - `file-history/<Bucket>`：**永不**因 Chat Session 目录消失而自愈。它只在「单个 Workspace 超过 30 条」时按 `touchedAt` 淘汰。实测 17 条里已有 **9 条是僵尸**（正是用户早先那次脚本 `--apply` 留下的）。
  - `sessions/.index-cache/scan.json` 与 `sessions/.index-dirty/`：**纯派生缓存，确定自愈**（按目录列举重建并整体覆写，解析失败即全量重扫）。因此**本功能绝不碰这两个**。
- 脚本的判定语义是**合取**：`排名 ≥ keep` **且** `最后更新早于 days 天` 才删，另加固定 30 分钟的活跃保护，且「每个 Workspace 永远保留最新 1 个」。`days = 0` 表示不限天数。
- 单个 Chat Session「此刻是否活跃」在磁盘上**没有**可靠信号：`state.json` 没有 busy 字段，Chat Session 目录里没有锁文件，活跃状态只存在于 wire 协议与内存里。唯一近似是「目录内最新文件的 mtime 距现在很近」——这正是 30 分钟保护存在的理由，也是它无法被取消的理由。
- 「kimi-code 是否在运行」**可以**判：桌面版 bundle id 是 `com.kimi.code.desktop`（helper 是 `…desktop.helper` / `…helper.Renderer`），`NSWorkspace` 精确匹配即可，不必碰被 0002 排除的 `server/instances/*.json`。但该判据**只能覆盖桌面版**，覆盖不了终端里的 CLI —— 所以它只能是警告，不能是防线。
- 官方删除接口确实存在（`POST /api/v1/sessions/{id}:delete`，会一并维护目录、索引、file-history 与事件流），但需要 `server/instances/*.json` 拿端口 + `server.token` 拿凭据 —— 二者正是 0002 明文排除的路径，且要求 kimi-code 正在运行。
- 实测一个反直觉的后果：**纯时间门槛在当前数据上无效**。用户那次脚本 `--apply` 已经删掉 38 个 Chat Session，现存 19 个里最老的只有 1.8 天 —— 默认 `days = 7` 会一个都不删。真正能回收空间的是 Keep Count（单个最大的 Chat Session 就占 33%）。

## Considered Options

1. **走 kimi-code 官方本地 HTTP 删除接口**（否决）：语义最正统，索引 / 账本 / 事件流 / 内存态都由 kimi-code 自己维护，本 app 一行都不用写。但代价是推翻 [0002](0002-credentials-from-config-toml.md) 确立的「不碰本地 server」边界，并要求 kimi-code 正在运行 —— 而「kimi-code 正在运行」恰恰是需要谨慎的时刻。为了省掉 4 处文件维护而引入这条运行时依赖与暴露面，不划算。
2. **shell-out 调 `kimi-sessions-cleanup.py`**（否决）：实现成本最低、行为与用户已验证的脚本完全一致。但这会让 app 首次依赖外部 python 解释器，与「纯 Swift in-process、零外部进程」的既有形态冲突；而且脚本本身在索引写入上有已知缺陷（见下）。
3. **把清理做成独立工具，不集成进 app**（否决）：能保住 app 的纯只读定位。但用户要的就是「菜单里点一下」——清理需要周期性地做，独立工具的摩擦会让它不被执行，而它要解决的问题（磁盘增长）正是渐进性的。
4. **删除时移入废纸篓而不是直接删**（否决）：`NSFileManager.trashItem` 能提供撤销。但空间要等用户手动清空废纸篓才真正回收 —— 预览里承诺的「释放 X」会变成空话，与清理的唯一目的（回收空间）直接冲突。
5. **直接删文件系统，一次点击清完 4 处产物**（选定）：与既有架构一致（零外部进程、不碰 server 目录），已被用户的脚本实测验证可行，且不依赖 kimi-code 是否在运行。

## Decision

- **触发**：菜单新增 `清理 session 文件…`（`立即刷新` 之后、独立成组、无快捷键）。菜单每次打开都会重建，因此这一项永远是最新的、无需失效通知。
- **流程**：点击 → 后台线程扫描 → **Cleanup Preview**（只列将被删除的 Chat Session，按 Workspace 分组）→ 用户「确定」才执行，「取消」什么都不做 → 执行完成后再弹结果。这是 app 的第一个 modal（`NSAlert` + 可滚动 accessory view）；因为是 `LSUIElement`，弹之前必须 `NSApp.activate(ignoringOtherApps: true)`。
- **Retention Policy 是合取**（照脚本，保守）：按 `state.json.cwd`（兜底桶目录名）分组，组内按 `updatedAt` 降序，第 `rank` 个在 `rank ≥ max(keepCount, 1)` **且** 距更新 ≥ 30 分钟 **且** `retentionDays == 0` 或 `ageDays ≥ retentionDays` 时才删除。`keepCount` 下限 1；`retentionDays = 0` 表示不限。
- **30 分钟活跃保护是写死的常量，不进偏好设置**：它是磁盘上唯一能近似「这个 Chat Session 正在被写」的信号，不该允许用户关掉。
- **偏好设置**只暴露两个参数：Keep Count（默认 3，范围 1…20）与 Retention Days（默认 7，范围 0…365，`0` 展示为「不限」）。
- **产物处理**（一次点击全做完，逐项 best-effort、失败计数上报，一个删不掉不毁整次清理）：
  1. 删 Chat Session 目录；
  2. 删**孤儿事件流**：`server/events/session_*.jsonl` 中不对应任何现存 Chat Session 的（删完目录后重新枚举，覆盖本次删除的与历史遗留的）。**`__global__.jsonl` 永不删**；不匹配 `session_*.jsonl` 的文件永不入选；
  3. 修剪 `session_index.jsonl`：**只移除「有 `sessionDir` 字段且该目录已不存在」的行**；无 `sessionDir` 字段的行（kimi-code 自己写的墓碑行 `{"sessionId":…,"deleted":true}`）与不可解析的行一律原样保留；
  4. 修剪 `file-history/<Bucket>`：摘掉「`<Bucket>/<id>` 目录已不存在」的条目（含历史遗留的僵尸条目）。
- **写文件的纪律**：一律原子写（先写 `.tmp` 再替换）；**只有真的有改动时才写**；`session_index.jsonl` 写前备份为 `session_index.jsonl.bak-<时间戳>` —— **不用脚本的固定 `.bak` 名**，因为它会被每次运行覆盖，销毁上一份历史备份（用户现存那份 61 行的备份就只剩这一份）。
- **绝不触碰**：`server/instances/`、`server.token`、`mcp.json`、`search-index/`、`sessions/.index-cache/`、`sessions/.index-dirty/`、`workspaces.json`、`config.toml`。
- **kimi-code 运行中不阻止**：检测到 `com.kimi.code.desktop` 时在预览里给一行建议退出的警告，但不禁用「确定」。
- **完成后触发一次完整刷新**（与「立即刷新」同路径），使菜单里的用量数字与被删掉的数据一致。
- **不接受残留风险**：一个 Chat Session 若 7 天没动但仍被 kimi-code 打开着（例如挂在标签页里），它会被判定为可删 —— 磁盘上没有任何信号能区分这种情况，只能靠上面的警告与 30 分钟保护缩小概率。

## Consequences

- **app 不再是纯只读观察者。** 这是本 ADR 存在的全部理由，也是后续任何 agent 读 `AGENTS.md` 时必须看到的例外条款：删除能力**只此一处**，且必须经 Cleanup Preview 显式确认。
- **删除不可撤销**：没有回收站、没有 undo，被删的 Chat Session 无法恢复（这是选项 4 被否决的直接代价）。
- **索引写入有赛跑窗口**：kimi-code 会向 `session_index.jsonl` 追加，本 app 会整体重写它。二者之间的窗口里丢一行追加是可能的。判断为可接受：目录列举才是 Chat Session 列表的权威来源，索引只是启动时的迁移辅助，丢一行的后果会自愈。
- **目录和事件流由本 app 自己维护**，因此若 kimi-code 将来改变这几处的形状（例如把 `file-history` 换成数据库、或给索引换 schema），本 ADR 需要重审。相反，`scan.json` / `.index-dirty` 这类派生缓存的形状变化对本功能无影响，因为我们不碰它们。
- **默认参数在当前数据上会删 0 个**：这是时间门槛的固有性质，不是 bug。为让「点了没反应」可诊断，Cleanup Preview 在删除数为 0 时**必须**给出诊断（现存个数 / 总体积 / 最老年龄），而不是只说「无需清理」。
- 删除的 Chat Session 会移走对应的 Wire Log，进而可能改变菜单里的用量数字。默认参数下被删的都远在保留窗口（今日 / 近 5h）之外，数字不变；`Retention Days = 0` 时可能变 —— 因此完成后强制刷新一次。
- 若将来要按 Provider / 模型拆开清理，或要支持 `KIMI_CODE_HOME`（需要引入 `getenv`，与 0002 的提交约束冲突），都需要重新决策。
