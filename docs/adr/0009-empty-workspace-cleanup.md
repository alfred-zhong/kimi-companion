# 0009 — 清理空工作区（受控写入 `workspaces.json`）

清理 Chat Session 时，允许把「每个工作区保留数」设为 `0`；一次清理结束后，凡是已经没有任何 Chat Session 的**注册工作区**，一并从 kimi-code desktop 的工作区列表里注销，并回收它的空 bucket 与空 `file-history` 账本。这是 [0007](0007-session-cleanup-in-app.md) 的补充：`workspaces.json` 从「绝不触碰」变成**唯一受控写入的元数据文件**。

## Status

已采纳（Accepted）。取代 [0007](0007-session-cleanup-in-app.md) 中「绝不触碰 `workspaces.json`」与「Keep Count 下限 1」两条决策；0007 的其余部分继续有效。

## Context

- 用户要求把「工作区保留数」调到 `0`，表示清理时这个工作区不需要保留任何 session。
- 用户还要求：清理后某个工作区已经没有了任何 session，就把它从 UI 里清掉。
- 实测 kimi-code desktop（1.1.0，bundle id `com.kimi.code.desktop`）的工作区列表**不会**因为 session 数为 0 而自动隐藏。数据源是 `~/.kimi-code/workspaces.json`：
  - 顶层 `{ version, workspaces: { <id>: { root, name, created_at, last_opened_at } }, deleted_workspace_ids: [<id>] }`；
  - 启动时会把 `session_index.jsonl` 里的 `workDir` **增量补录**进 `workspaces`，但会跳过 `deleted_workspace_ids` 里的 id；
  - desktop 自己的「移除工作区」只做两件事：从 `workspaces` 移除同 root 的所有条目，把 id 与同 root 的 alias id 写进 `deleted_workspace_ids`；**不删 session、不删 bucket、不删账本**；
  - 重新打开该文件夹（`createOrTouch`）会清除对应 tombstone 并重新注册，所以注销是可逆的；
  - 外部改写 `workspaces.json` 只会让主进程清缓存，**不会推给 renderer**；renderer 只在启动加载与 session resync 时重新拉工作区列表。
- 本仓库的清理器此前完全不读写 `workspaces.json`，也没有 workspace 维度的执行结果。
- 工作区在清理器里的分组键是 `state.json.cwd`（缺失时退化为 bucket 名）；`workspaces.json` 里的条目按 id（通常等于 bucket 名）注册。同一个 root 可能有多个历史 alias id。
- Kimi Code desktop 运行时会对 `workspaces.json` 做整文件重写；外部写入存在竞态，且 renderer 不会立即刷新。

## Decision

- **Keep Count 允许为 0**：`RetentionPolicy.keepCount` 的下限从 `1` 改为 `0`，偏好面板范围 `0…20`，默认仍为 `3`。`0` 只取消「每工作区保留最近 N 个」这道名额门槛；30 分钟活跃保护与 Retention Days **仍然生效**。判定仍是合取：`rank ≥ keepCount` ∧ `age ≥ 30 分钟` ∧（`retentionDays == 0` ∨ `ageDays ≥ retentionDays`）。
- **空工作区的定义**：一个注册工作区在本次删除计划执行后，所有 alias bucket 里都没有任何 Chat Session 目录。判定以物理目录为准，不信任 `session_count`（它包含 archived，且来自 index counters）。同 root 的多个注册条目算**一个**工作区；注销时移除同 root 的全部条目。
- **存量空工作区同样处理**：扫描时已经 0 session 的注册工作区（包括 root 目录已不存在的）也进入移除清单。
- **alias id 一起写墓碑**：注册表里同 root 的 id、`session_index.jsonl` 里同 `workDir` 推导出的 bucket id、以及扫描时捕获的 alias id，全部写进 `deleted_workspace_ids`。只删 `workspaces` 条目而不写墓碑，index 里仍有 `workDir` 时会被 desktop 启动补录回来。
- **删除不存在的目录不算空工作区**：`root` 目录不存在也算空（用户明确要求清掉）；但预览会标注「目录已不存在」。
- **同一个 Cleanup Preview + 一次确认**：预览里单独列一节「空工作区」，只有用户点「确定」才执行；没有 session 可删但存在空工作区时，预览**仍然可确认**。
- **执行前重新读取、重新校验**：apply 不用扫描时的整份快照覆盖磁盘；只注销「此刻仍注册、且此刻仍为空」的工作区。预览到确认之间新建了 session 的工作区跳过，并在结果里计数。
- **写文件纪律**：只有真的有改动才写；写前备份为 `workspaces.json.bak-<yyyyMMddHHmmss>`（同一秒重复清理追加 `-2`、`-3`…）；先写 `.tmp` 再原子替换；保留顶层未知字段与每个条目内的未知字段。
- **Kimi Code desktop 运行时跳过全部工作区级动作**：session 照删、索引与账本照常修剪，但不写 `workspaces.json`、不删空 bucket、不删空账本；预览与结果都明确说明「退出后再次清理即可」。
- **注册表缺失 / 损坏 / 不可写**：跳过工作区移除并在结果里给出原因；session 删除与索引修剪照常。**绝不重建或覆盖**损坏文件。
- **空 bucket / 空账本**：只处理「有身份」的 bucket——本次注销工作区的 alias id，以及 `deleted_workspace_ids` 里仍留在磁盘上的空 bucket；未知孤儿目录不碰。bucket 里只剩隐藏文件（如 `.DS_Store`）也算空；`file-history/<bucket>` 仅在能解析且 `sessions` 为空时删除，解析失败一律不动。
- **不碰 `workspace-trust/`**：它是安全相关状态，不属于 session 清理语义。
- **文档落点**：本篇 + 同步 `AGENTS.md` / `README.md` / `CHANGELOG.md` / `CONTEXT.md`；0007 保留原文，只在状态里标注被本篇取代的两条。

## Consequences

- **`workspaces.json` 不再是绝对的「绝不触碰」清单成员**：它是 cleanup 的受控写入对象，规则见上。任何新的写入点都必须复用同一套备份 / 原子写 / 复审纪律。
- **UI 不会立即消失**：desktop 的 renderer 只在启动加载或 session resync 时重新拉工作区列表。清理后可能需要重启 Kimi Code 才能看到空工作区从侧边栏消失；这一点必须在预览/结果文案里说清，否则用户会以为没生效。
- **desktop 运行中功能减半**：为了不和 desktop 的整文件重写竞争，运行中只清 session，不注销工作区。用户需要退出 desktop 后再清理一次。
- **注销可逆**：重新打开该文件夹会重新注册（tombstone 被 `createOrTouch` 清除），但 `last_opened_at` / `created_at` 会重置。
- **Keep Count = 0 是危险组合**：配合 `Retention Days = 0`，除 30 分钟内活跃的 session 外全部可删，空工作区也会被逐个注销。预览会完整列出，删除仍不可撤销。
- **alias 覆盖不完整时的保守性**：若某个 alias bucket 既不在注册表、也没有可解析的 `session_index` 行，且 session 缺 `state.json`，清理器无法把它关联到 root；此时可能把工作区判为空。这是「缺 `state.json` + index 损坏」的叠加边缘，正常写入路径不会出现。
