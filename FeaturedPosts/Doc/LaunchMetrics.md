**TTID（Time To Initial Display）指标口径（P0 固化）**

**目标**
- 优化目标是 TTID（首帧可见），即尽快让用户看到“有画面”（允许骨架屏/占位 UI）
- TTID 不要求首屏数据完整，也不要求可交互（TTI 属于另一个指标）

**统计范围**
- 仅统计冷启动：App 进程不在内存（被系统杀/手动划掉）后启动
- 仅统计首个前台可见 Scene：多 Scene 场景只记录首个激活并可见的 Scene
- 排除后台启动：后台 fetch/静默 push 等非用户点击图标触发的启动不计入 TTID

**计时口径**
- TTID(post-main)（工程回归与治理主口径）
  - Start：`application(_:didFinishLaunchingWithOptions:)` 最开始
  - End：首帧到来（`CADisplayLink` 第一次 tick 近似）
  - 实现：`LaunchMetrics` signpost 区间 `TTID`，end 对应 `first_frame` 事件
- TTID(full)（全链路口径，用于对齐系统启动总耗时）
  - Start：进程启动（用户点击图标后系统拉起）
  - End：首帧到来
  - 采集：Instruments App Launch / MetricKit（不由业务代码实现）

**实现映射（FeaturedPosts）**
- Start：`LaunchMetrics.shared.appDidFinishLaunchingStart()`
- 关键里程碑：
  - `didFinishLaunching_end`
  - `scene_willConnect_start/end`
- End：`first_frame`（同时作为 TTID 区间 end）

**验收标准**
- Debug 控制台应至少出现：
  - `[Launch] didFinishLaunching_start ...`
  - `[Launch] first_frame ...`
- Instruments 中可见：
  - signpost 区间 `TTID`（begin/end 成对出现）
  - 事件点 `first_frame`
- 回归策略：
  - 同一设备连续多次冷启动取分布（至少关注 P50/P90），禁止只看单次