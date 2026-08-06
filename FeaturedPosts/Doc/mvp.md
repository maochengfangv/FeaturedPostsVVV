播放首帧最小优化方案

- 复用单例 AVPlayer + AVPlayerLayer ，避免每次进播放页都重新创建播放器，减少冷启动损耗。
- 列表页做轻量预热：提前创建 AVURLAsset ，并用 Range 预取首包 300KB ，点击后即使预热未完成也能直接继续。
- 播放页永远先显示封面，只有检测到 AVPlayerLayer.isReadyForDisplay 后才淡出封面，基本避免黑屏/白屏。
- 切换视频前统一暂停、清理旧 item 、移除 KVO/通知/observer`，减少串音、旧画面闪现、状态串线。
- 内置 TTFF 日志，直接看 click -> ready -> firstFrame -> playing 是否改善。