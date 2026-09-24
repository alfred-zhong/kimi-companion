# kimi-companion

macOS 菜单栏常驻 app，展示 kimi-code desktop 所用第三方 Provider 的余额 / 配额，以及一份**合并的** token 消耗统计；另有一项清理 Chat Session 的能力——本 app 唯一的破坏性操作，只在用户看过 Cleanup Preview 并显式确认后发生（决策见 `docs/adr/0007-session-cleanup-in-app.md`）。

## Language

**Menu Bar App**:
常驻 macOS 右上角菜单栏的轻量 GUI 程序；用户与界面只通过顶部状态栏图标和弹出菜单交互，无 Dock 图标、无主窗口。
_Avoid_: 状态栏 app、系统托盘 app、后台服务

**Status Item**:
`NSStatusItem` 在系统菜单栏中占据的一个槽位及其图标；kimi-companion 只占用一个槽位。
_Avoid_: 状态栏图标、托盘图标

**Provider**:
kimi-code 经 `config.toml` 的 `[providers.*]` 段配置的第三方模型服务商或订阅网关；每个 Provider 暴露一个查询余额 / 配额的 HTTPS 端点与一份内联凭据。本 app 只支持两个：DeepSeek（账户余额）与 OpenCode Go（订阅配额）。
_Avoid_: 服务商、模型提供方、平台

**Provider Name**:
`[providers.<name>]` 的段名，逐字使用（`DeepSeek`、`OpenCode Go`，后者含空格）；它同时是配置键与菜单 section 的标题。
_Avoid_: provider id、provider key、显示名

**Balance**:
DeepSeek 账户的可用金额（CNY），取自余额端点的总额字段；不等同于 token 用量、订阅额度或充值记录。
_Avoid_: 额度、积分、充值余额

**Quota Window**:
OpenCode Go 订阅的一个额度窗口；每窗口由已用百分比、服务端状态串与重置时刻组成。
_Avoid_: 配额、额度段、时段

**Rolling Window**:
OpenCode Go 的 5 小时滚动窗口；也是菜单栏主窗口——状态栏展示的百分比来自它。
_Avoid_: 短窗、会话窗、主窗口

**Weekly Window**:
OpenCode Go 的 7 天窗口。
_Avoid_: 周窗、周配额

**Monthly Window**:
OpenCode Go 的月度窗口，按订阅周年重置。
_Avoid_: 月窗、自然月窗口

**Used Percent**:
窗口已用百分比（0–100），服务端原样返回，展示层不换算、不取反。
_Avoid_: 使用率、占用率、剩余百分比

**Reset Time**:
窗口下次重置的时刻；界面展示为剩余时长倒计时（≥24h 用 `XdYh`）。
_Avoid_: 过期时间、刷新时间、周期

**Snapshot**:
一次「瞬时」余额 / 配额采集结果，是菜单栏文案与弹出菜单的最小可显示单元。
_Avoid_: 取样、点查、读数

**Stale Value**:
采集失败后保留的上一次成功余额；菜单里标注「旧值」，表示金额仍是真数据但本轮没有更新。
_Avoid_: 缓存值、过期值、回退值

**Retained Window**:
增量读取时仍被计入的时间范围，下界为 `min(当日零点, now − 12h)`；窗口外的事件被淘汰。
_Avoid_: 缓存窗口、保留期、TTL

**Hour Bucket**:
以当前时刻为右端、向前 1h 为步长切出的滑动区间，索引 0 最旧、末位最新；共 12 桶；区间左开右闭；末桶永远是完整一小时。
_Avoid_: 小时柱、时段桶

**Read Cursor**:
增量读取时对单个会话日志文件持有的读取位置与指纹（偏移、大小、修改时间、文件身份、未成行的尾部字节）；只在进程内，不落盘。
_Avoid_: 缓存、checkpoint、游标文件

**Wire Log**:
kimi-code 按 agent 追加写入的会话记录文件（`wire.jsonl`）；用量记录以 epoch 毫秒时间戳按时间序追加，各文件之间零重复。
_Avoid_: 会话日志、transcript、日志文件

**Usage Record**:
Wire Log 里一条 `usage.record` 行：单次 LLM 调用的**增量**（不是累计快照），携带四个 token 计数。其中的 `model` 字段**不被读取**——用量不按模型或 Provider 区分。
_Avoid_: 用量快照、累计用量

**Daily Usage**:
当日（本地零点至此刻）全部会话的 token 合计，**一份合并**的数字，不按 Provider 或模型区分。
_Avoid_: 今天用量、今日统计

**Last-5h Usage**:
后 5 个小时桶的并集，等价于 `[now − 5h, now]`；与 Daily Usage 同为合并口径。
_Avoid_: 近五小时、5 小时用量

**Token Stats**:
一段窗口（合并统计，不区分 Provider / 模型）的 token 四元组：输入（非缓存）、输出、缓存创建、缓存读取。
_Avoid_: 用量统计、token 数

**Cache Hit Rate**:
缓存读取占全部输入 token 的比例，分母为输入 + 缓存创建 + 缓存读取。
_Avoid_: 命中率、缓存率

**Selected Provider**:
菜单栏当前展示哪个 Provider 的值；由用户从下拉菜单显式选择并持久化，采集失败时不自动切换。
_Avoid_: 当前 Provider、默认 Provider、活跃 Provider

**Provider Failure**:
单个 Provider 一次采集失败的原因（配置不可读 / 段缺失 / 凭据为空 / 凭据来自环境变量 / 远端失败）；菜单栏以短标签 `⚠︎配置` / `⚠︎凭据` 呈现。
_Avoid_: 错误、异常、报错

**Config Missing**:
`config.toml` 不可读或非法导致的全局降级；菜单栏显示 `?kimi`。
_Avoid_: 无配置、配置错误

**Caffeinate Session**:
一次阻止系统休眠的守护实例：档位 + 开始时刻 + 结束时刻；同一时刻只有一个，到期或取消即释放，进程退出静默释放。
_Avoid_: 守护任务、唤醒锁

**Caffeinate Bucket**:
阻止休眠的预设档位：30 / 60 / 120 分钟；当前生效档位在菜单里标 ✓。区别于 Hour Bucket。
_Avoid_: 时长档

**Refresh Interval**:
定时刷新周期，固定三档 30 / 60 / 120 秒，默认 60 秒。
_Avoid_: 轮询间隔、刷新频率、TTL

**Refresh Outcome**:
一次刷新提交给界面的完整结果：每个 Provider 各自的状态 + 配置缺失标记 + 日用量快照或错误；任一 Outcome 唯一决定菜单栏可见内容。
_Avoid_: 单个字段更新、刷新结果

**Menu Bar Title**:
状态栏图标右侧的文字：Config Missing 时是 `?kimi`，否则是 Selected Provider 的 Balance 或 Provider Failure 短标签，尚未采集过时为 `···`。
_Avoid_: 标题、文案

**Usage Bar**:
percent 类型 Provider 在菜单里的用量行：窗口标签 + 轨道 + 紧贴条尾的已用百分比 + 重置倒计时；窗口状态非正常时轨道强制转红。
_Avoid_: 进度条、柱图

**Chat Session**:
kimi-code 的一次对话在磁盘上的记录目录，位于某个 Workspace Bucket 之下；内含 `state.json`、各 agent 的 Wire Log 与该对话自己的 file-history。区别于 Caffeinate Session。
_Avoid_: 会话、session（裸用）、对话、线程

**Workspace**:
Chat Session 的归属单位，取 `state.json` 的 `cwd`（绝对路径）；缺失时退化为 Workspace Bucket 的名字。同一 Workspace 的 Chat Session 共享一份 file-history 账本。
_Avoid_: 工作目录、项目、仓库

**Workspace Bucket**:
`sessions/` 下的一级目录（形如 `wd_<目录名>_<hash>`），是 Chat Session 的物理容器，也是 file-history 账本的文件名。
_Avoid_: 工作区分组、桶

**Retention Policy**:
判定一个 Chat Session 该不该被清理的规则：Keep Count、30 分钟活跃保护、Retention Days 三道门槛**全部**通过才删除。三道门槛是合取关系，不是任选其一。
_Avoid_: 保留策略、清理规则、TTL、Retained Window

**Keep Count**:
每个 Workspace 保留的最近 Chat Session 个数（默认 3，下限 1）；排名在名额内的 Chat Session 永远不删。
_Avoid_: 保留数、数量上限、保留份数

**Retention Days**:
只删除最后更新早于 N 天的 Chat Session（默认 7）；`0` 表示不限天数，此时唯一的时间门槛只剩 30 分钟活跃保护。
_Avoid_: 保留天数、保留期、过期天数、Retained Window

**Cleanup Plan**:
一次扫描的完整判定结果：每个 Chat Session 的保留 / 删除结论与原因、孤儿产物清单、可回收体积；纯数据，不产生任何副作用。
_Avoid_: 清理列表、dry-run 结果、删除清单

**Cleanup Preview**:
把 Cleanup Plan 呈现给用户并等待确认的弹窗，只列将被删除的 Chat Session；用户取消则什么都不做。删除**只能**从这里发生。
_Avoid_: 确认框、提示、预览页

**Protected Chat Session**:
因落在 Keep Count 名额内、或 30 分钟内活跃、或未满 Retention Days 而未被判定删除的 Chat Session。
_Avoid_: 跳过项、白名单、豁免项

**Orphan Event Journal**:
`server/events/` 下没有对应 Chat Session 的事件流文件；`__global__.jsonl` 是全局流，永远不属于此类，也永远不被清理。
_Avoid_: 垃圾文件、残留事件、孤立日志
