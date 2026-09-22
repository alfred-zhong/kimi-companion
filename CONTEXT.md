# kimi-companion

macOS 菜单栏常驻 app，展示 kimi-code desktop 所用第三方 Provider 的余额 / 配额与各 Provider 自己的 token 消耗。

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
`[providers.<name>]` 的段名，逐字使用（`DeepSeek`、`OpenCode Go`，后者含空格）；它同时是配置键、用量归属的前缀、菜单 section 的标题。
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
Wire Log 里一条 `usage.record` 行：单次 LLM 调用的**增量**（不是累计快照），携带模型前缀与四个 token 计数。
_Avoid_: 用量快照、累计用量

**Daily Usage**:
当日（本地零点至此刻）全部会话的 token 聚合，按 Provider 归属分组。
_Avoid_: 今天用量、今日统计

**Last-5h Usage**:
后 5 个小时桶的并集，等价于 `[now − 5h, now]`。
_Avoid_: 近五小时、5 小时用量

**Token Stats**:
一段窗口的 token 四元组：输入（非缓存）、输出、缓存创建、缓存读取。
_Avoid_: 用量统计、token 数

**Cache Hit Rate**:
缓存读取占全部输入 token 的比例，分母为输入 + 缓存创建 + 缓存读取。
_Avoid_: 命中率、缓存率

**Usage Attribution**:
把一条用量记录按模型标识的 `<Provider>/` 前缀归到某个 Provider；前缀逐字匹配 Provider Name。
_Avoid_: 归属映射、分组、路由

**Unmatched Usage**:
未匹配任何受支持 Provider 的用量；落到「其他」桶并在菜单尾行展示，不丢弃。
_Avoid_: 未知用量、遗留用量、兜底桶

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
