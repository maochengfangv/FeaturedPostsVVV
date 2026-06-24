**无网络（含弱网/断网切换）**
- **首次进入无网络 + 本地有缓存**：应直接展示缓存列表；不弹“加载失败”打断操作；顶部可提示“离线展示缓存”。验证：开飞行模式 → 冷启动。
- **首次进入无网络 + 本地无缓存**：展示空态（离线文案 + 重试按钮）；点击刷新不应疯狂触发（RateLimiter 生效）。验证：清数据→飞行模式→启动→点刷新多次。
- **列表中途断网（已展示部分数据）**：保持现有列表可滚动；触底分页时静默失败或轻提示，不清空已有内容。验证：加载几屏后断网→继续滚动到底。
- **弱网降级开关开启**：离线时 `loadNextPageIfNeeded` 应直接 return；`refresh` 在 posts 为空时才触发 onError “离线降级仅展示本地缓存”。验证：FeatureFlag `.weakNetworkDegradeEnabled` ON + offline。
- **网络恢复**：允许手动刷新恢复在线数据；避免重复 append 同一页（`lastAppendPage` 防重复）。验证：断网→恢复→点刷新/滚动触底。

**空列表 / 空数据**
- **API 返回空数组**：table 0 行时应展示空态（现在只有空白）；刷新仍可用。建议：UI 层根据 `viewModel.posts.isEmpty` 显示 placeholder。验证：Mock API 改为返回 0。
- **缓存为空但磁盘缓存开关开**：`loadInitial` 读不到缓存也不应报错；继续走 refresh。验证：清数据 + `.diskPostCacheEnabled` ON。
- **错误提示策略**：当前任何 error 都弹 alert，可能频繁打断；边界建议：分页错误不弹，全量刷新错误才弹或 toast。验证：模拟 API 抛错 + 滚动触底触发。

**大量大图 / 高内存压力**
- **快速滚动 + 多图 cell 复用**：必须取消旧 token，避免错图/回调覆盖；你已有 `prepareForReuse` 取消 token，这是关键边界。验证：快速上下滚动，观察错图/闪烁。
- **大图解码卡顿**：已做 downsample + decodeQueue + idle scheduler；边界是“主线程是否仍被阻塞”。验证：Instruments Time Profiler + Core Animation FPS。
- **内存告警**：`MemoryGuard` 会清空 LRU cache；边界是告警后图片需可重新加载且不崩。验证：模拟 Memory Warning（Debug 菜单）→继续滚动。
- **缓存命中与成本控制**：LRU cost 估算依赖 cgImage bytes；边界是大量高清图导致 cost 高、频繁驱逐→重复下载。验证：抓包/日志，看同 URL 是否频繁请求。
- **并发下载上限**：URLSession `httpMaximumConnectionsPerHost=8`；边界是网络拥塞/队头阻塞。验证：弱网环境滚动，观察加载是否“越滑越慢”。

**权限异常（当前迭代主要是发布页选图）**
- **相册权限未授权/被拒绝**：`PHPickerViewController` 本身不需要传统 Photo 权限，但“限制访问照片”/系统策略可能导致选不到或返回空 results。边界：results 为空时应给出提示而不是静默。验证：设置里把照片权限设为“无/受限”。
- **选择完成但 provider 无法加载 UIImage**：`canLoadObject` 已过滤；边界是部分图片失败导致 selectedImages 少于 selectionLimit，应提示“部分图片加载失败”。验证：选 iCloud 未下载的图/受限资源。
- **多张选择 + 回调并发**：`loadObject` completion 可能并发；对 `selectedImages.append` 需要线程安全（你当前实现如果没加锁会有数据竞争）。验证：选 9 张，多次进入退出，检查数量是否稳定。
- **上传开关关闭（回滚）**：`.publishV2Enabled` OFF 时应阻止上传并提示；你已有 “已回滚：PublishV2 关闭”。验证：点回滚→点上传。
- **上传失败（随机失败/网络失败）**：应恢复按钮可点击、展示失败原因；并发上传需保证 semaphore 释放（已修）。验证：多次上传直到触发 simulatedFailure。

**建议的验收清单（最小落地）**
- 离线：有缓存/无缓存两种启动路径都可用且不崩、不无限弹窗。
- 空列表：可识别空态，不是“看起来像挂了”。
- 大图：快速滚动无错图、无明显掉帧，内存告警后可恢复。
- 权限/选图：权限受限或返回空 results 时有明确提示；选 9 张稳定不丢不乱；上传失败能正确恢复 UI 状态。