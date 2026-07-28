import UIKit
import AVFoundation
import CryptoKit

enum VideoPlaybackState: Equatable {
    case idle
    case coverOnly(String)
    case loading
    case buffering
    case playing
    case paused
    case ended
    case replaying
    case failed(String)
}

struct VideoFeedItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coverURL: URL
    let videoURL: URL
}

enum MockVideoFeed {
    static let items: [VideoFeedItem] = [
        VideoFeedItem(
            id: "video_1",
            title: "海边日落",
            subtitle: "本地命中后直接播放，首次远程播放同时落盘缓存",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-1/720/1280")!,
            videoURL: URL(string: "https://samplelib.com/preview/mp4/sample-5s.mp4")!
        ),
        VideoFeedItem(
            id: "video_2",
            title: "山谷穿梭",
            subtitle: "主曝光自动播 + 预缓存下一个视频",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-2/720/1280")!,
            videoURL: URL(string: "https://samplelib.com/preview/mp4/sample-10s.mp4")!
        ),
        VideoFeedItem(
            id: "video_3",
            title: "城市夜景",
            subtitle: "首帧时间、失败率、弱网降级均可埋点",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-3/720/1280")!,
            videoURL: URL(string: "https://samplelib.com/preview/mp4/sample-15s.mp4")!
        ),
        VideoFeedItem(
            id: "video_4",
            title: "公路旅行",
            subtitle: "更完整状态机：buffering / ended / replay",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-4/720/1280")!,
            videoURL: URL(string: "https://filesamples.com/samples/video/mp4/sample_640x360.mp4")!
        ),
        VideoFeedItem(
            id: "video_5",
            title: "雨后森林",
            subtitle: "进后台自动暂停，回前台按状态恢复",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-5/720/1280")!,
            videoURL: URL(string: "https://filesamples.com/samples/video/mp4/sample_960x400_ocean_with_audio.mp4")!
        )
    ]
}

final class VideoCachePreloader {
    private let session: URLSession
    private let cacheDirectory: URL
    private let lock = NSLock()
    private var tasks: [URL: URLSessionDownloadTask] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = .shared
        session = URLSession(configuration: config)

        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = baseDirectory.appendingPathComponent("VideoPreloadCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func isCached(_ remoteURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: localFileURL(for: remoteURL).path)
    }

    func playbackURL(for remoteURL: URL) -> URL {
        let localURL = localFileURL(for: remoteURL)
        return FileManager.default.fileExists(atPath: localURL.path) ? localURL : remoteURL
    }

    func preload(url remoteURL: URL) {
        if isCached(remoteURL) { return }

        lock.lock()
        if tasks[remoteURL] != nil {
            lock.unlock()
            return
        }

        let request = URLRequest(url: remoteURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        let task = session.downloadTask(with: request) { [weak self] temporaryURL, _, error in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.tasks[remoteURL] = nil
                self.lock.unlock()
            }
            guard error == nil, let temporaryURL else { return }

            let destinationURL = self.localFileURL(for: remoteURL)
            try? FileManager.default.removeItem(at: destinationURL)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        tasks[remoteURL] = task
        lock.unlock()

        task.resume()
    }

    func cancel(url remoteURL: URL) {
        lock.lock()
        let task = tasks[remoteURL]
        tasks[remoteURL] = nil
        lock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let allTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        allTasks.forEach { $0.cancel() }
    }

    private func localFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        return cacheDirectory.appendingPathComponent(filename).appendingPathExtension(ext)
    }
}

final class VideoPlayerEngine {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private weak var currentContainerView: UIView?

    private var currentPlaybackURL: URL?
    private var currentPlaybackSource: String = "remote"
    private var currentState: VideoPlaybackState = .idle

    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var firstFrameObserver: Any?

    private var playStartedAt: Date?
    private var hasTrackedFirstFrame = false

    var onStateChanged: ((VideoPlaybackState) -> Void)?
    var onFirstFrame: ((TimeInterval, String) -> Void)?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateState(.ended)
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .paused:
                if self.currentState != .ended, self.currentState != .failed("") {
                    self.updateState(.paused)
                }
            case .waitingToPlayAtSpecifiedRate:
                let nextState: VideoPlaybackState = (self.player.currentItem?.status == .readyToPlay) ? .buffering : .loading
                self.updateState(nextState)
            case .playing:
                self.updateState(.playing)
            @unknown default:
                self.updateState(.idle)
            }
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let firstFrameObserver {
            player.removeTimeObserver(firstFrameObserver)
        }
    }

    func attach(to containerView: UIView) {
        currentContainerView = containerView
        if playerLayer.superlayer !== containerView.layer {
            playerLayer.removeFromSuperlayer()
            playerLayer.frame = containerView.bounds
            containerView.layer.addSublayer(playerLayer)
        } else {
            updateLayout()
        }
    }

    func updateLayout() {
        guard let currentContainerView else { return }
        playerLayer.frame = currentContainerView.bounds
    }

    func play(url: URL, source: String) {
        let item = makeItem(url: url)
        currentPlaybackURL = url
        currentPlaybackSource = source
        replaceCurrentItem(with: item)
        playStartedAt = Date()
        hasTrackedFirstFrame = false
        updateState(.loading)
        player.play()
    }

    func resume() {
        guard currentPlaybackURL != nil else { return }
        player.play()
    }

    func replay() {
        guard currentPlaybackURL != nil else { return }
        playStartedAt = Date()
        hasTrackedFirstFrame = false
        updateState(.replaying)
        player.seek(to: .zero)
        player.play()
    }

    func pause() {
        player.pause()
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    private func replaceCurrentItem(with item: AVPlayerItem) {
        if let firstFrameObserver {
            player.removeTimeObserver(firstFrameObserver)
            self.firstFrameObserver = nil
        }
        player.replaceCurrentItem(with: item)
        observe(item: item)
        firstFrameObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            guard let self else { return }
            guard self.hasTrackedFirstFrame == false else { return }
            self.hasTrackedFirstFrame = true
            if let playStartedAt = self.playStartedAt {
                self.onFirstFrame?(Date().timeIntervalSince(playStartedAt), self.currentPlaybackSource)
            }
            self.updateState(.playing)
        }
    }

    private func observe(item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                break
            case .failed:
                let message = item.error?.localizedDescription ?? "视频加载失败"
                self.updateState(.failed(message))
            case .unknown:
                self.updateState(.loading)
            @unknown default:
                self.updateState(.idle)
            }
        }
    }

    private func updateState(_ state: VideoPlaybackState) {
        if case .failed = currentState, case .paused = state {
            return
        }
        currentState = state
        onStateChanged?(state)
    }
}

final class VideoFeedCell: UITableViewCell {
    static let reuseIdentifier = "VideoFeedCell"

    let playerContainerView = UIView()

    private let coverImageView = UIImageView()
    private let gradientOverlay = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let centerStatusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let playHintButton = UIButton(type: .system)

    private var coverLoadToken: UUID?
    private var imageLoader: ImageLoading?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none
        backgroundColor = .black
        contentView.backgroundColor = .black

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = .secondarySystemBackground

        playerContainerView.backgroundColor = .black
        gradientOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.32)

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = .white
        subtitleLabel.numberOfLines = 2

        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badgeLabel.layer.cornerRadius = 12
        badgeLabel.layer.masksToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.text = "AUTO PLAY"

        centerStatusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        centerStatusLabel.textColor = .white
        centerStatusLabel.textAlignment = .center
        centerStatusLabel.numberOfLines = 2
        centerStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        centerStatusLabel.layer.cornerRadius = 18
        centerStatusLabel.layer.masksToBounds = true
        centerStatusLabel.isHidden = true

        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true

        playHintButton.setTitle("点击播放", for: .normal)
        playHintButton.setTitleColor(.white, for: .normal)
        playHintButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        playHintButton.layer.cornerRadius = 22
        playHintButton.layer.masksToBounds = true
        playHintButton.isUserInteractionEnabled = false
        playHintButton.isHidden = true

        [coverImageView, playerContainerView, gradientOverlay, titleLabel, subtitleLabel, badgeLabel, centerStatusLabel, activityIndicator, playHintButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            playerContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            gradientOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            gradientOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            gradientOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            gradientOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -10),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -40),

            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 18),
            badgeLabel.widthAnchor.constraint(equalToConstant: 92),
            badgeLabel.heightAnchor.constraint(equalToConstant: 24),

            centerStatusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            centerStatusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            centerStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            centerStatusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            activityIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            playHintButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playHintButton.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -18),
            playHintButton.widthAnchor.constraint(equalToConstant: 128),
            playHintButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelCoverLoading()
        coverImageView.image = nil
    }

    func configure(item: VideoFeedItem, imageLoader: ImageLoading) {
        self.imageLoader = imageLoader
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        coverImageView.image = nil
        cancelCoverLoading()

        coverLoadToken = imageLoader.loadImage(
            url: item.coverURL,
            targetPixelSize: CGSize(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
        ) { [weak self] result in
            guard let self else { return }
            if case let .success(image) = result {
                self.coverImageView.image = image
            }
        }
    }

    func apply(state: VideoPlaybackState, isActive: Bool) {
        switch state {
        case .idle:
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = !isActive
            playHintButton.setTitle("点击播放", for: .normal)
        case let .coverOnly(message):
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = false
            centerStatusLabel.text = "  \(message)  "
            playHintButton.isHidden = true
        case .loading:
            activityIndicator.startAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = true
        case .buffering:
            activityIndicator.startAnimating()
            centerStatusLabel.isHidden = false
            centerStatusLabel.text = "  缓冲中…  "
            playHintButton.isHidden = true
        case .playing:
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = true
        case .paused:
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = !isActive
            playHintButton.setTitle("点击继续", for: .normal)
        case .ended:
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = false
            centerStatusLabel.text = "  播放结束  "
            playHintButton.isHidden = !isActive
            playHintButton.setTitle("点击重播", for: .normal)
        case .replaying:
            activityIndicator.startAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = true
        case let .failed(message):
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = false
            centerStatusLabel.text = "  \(message)  "
            playHintButton.isHidden = !isActive
            playHintButton.setTitle("点击重试", for: .normal)
        }

        badgeLabel.text = isActive ? "ACTIVE" : "AUTO PLAY"
        coverImageView.alpha = (state == .playing || state == .buffering || state == .replaying) ? 0.12 : 1.0
    }

    func cancelCoverLoading() {
        if let coverLoadToken, let imageLoader {
            imageLoader.cancelLoad(coverLoadToken)
        }
        coverLoadToken = nil
    }
}

final class VideoFeedViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let imageLoader: ImageLoading
    private let networkMonitor: NetworkMonitoring
    private let featureFlags: FeatureFlagProviding
    private let analytics: AnalyticsTracking
    private let items: [VideoFeedItem]
    private let playerEngine = VideoPlayerEngine()
    private let cachePreloader = VideoCachePreloader()

    private var currentPlayingIndexPath: IndexPath?
    private var currentPlaybackState: VideoPlaybackState = .idle
    private var autoplayWorkItem: DispatchWorkItem?
    private var prefetchTokensByIndexPath: [IndexPath: [UUID]] = [:]
    private var cellStates: [IndexPath: VideoPlaybackState] = [:]
    private var pendingAutoplayIndexPath: IndexPath?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var shouldResumeAfterForeground = false

    init(items: [VideoFeedItem], imageLoader: ImageLoading, networkMonitor: NetworkMonitoring, featureFlags: FeatureFlagProviding, analytics: AnalyticsTracking) {
        self.items = items
        self.imageLoader = imageLoader
        self.networkMonitor = networkMonitor
        self.featureFlags = featureFlags
        self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        cachePreloader.cancelAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "视频"
        view.backgroundColor = .black

        playerEngine.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.applyState(state, for: self.currentPlayingIndexPath)
        }
        playerEngine.onFirstFrame = { [weak self] duration, source in
            guard let self, let indexPath = self.currentPlayingIndexPath else { return }
            let item = self.items[indexPath.row]
            self.analytics.track(.videoFirstFrame, properties: [
                "video_id": item.id,
                "duration_ms": Int(duration * 1000),
                "source": source
            ])
            if self.pendingAutoplayIndexPath == indexPath {
                self.pendingAutoplayIndexPath = nil
                self.analytics.track(.videoAutoplayHit, properties: ["video_id": item.id])
            }
        }

        tableView.register(VideoFeedCell.self, forCellReuseIdentifier: VideoFeedCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.decelerationRate = .fast
        tableView.rowHeight = view.bounds.height - tabBarHeight()
        tableView.isPagingEnabled = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.backgroundColor = .black

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        observeAppLifecycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleAutoplayUpdate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.rowHeight = view.bounds.height - tabBarHeight()
        playerEngine.updateLayout()
    }

    private func observeAppLifecycle() {
        let enterBackground = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.shouldResumeAfterForeground = (self.currentPlayingIndexPath != nil && self.shouldAutoplay)
            self.playerEngine.pause()
            self.applyState(.paused, for: self.currentPlayingIndexPath)
        }

        let enterForeground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.shouldResumeAfterForeground else { return }
            self.shouldResumeAfterForeground = false
            self.scheduleAutoplayUpdate()
        }

        lifecycleObservers = [enterBackground, enterForeground]
    }

    private func tabBarHeight() -> CGFloat {
        tabBarController?.tabBar.frame.height ?? 0
    }

    private func scheduleAutoplayUpdate() {
        autoplayWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateAutoplayTarget()
        }
        autoplayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func updateAutoplayTarget() {
        guard let indexPath = currentBestVisibleIndexPath() else { return }
        guard shouldAutoplay else {
            currentPlayingIndexPath = indexPath
            playerEngine.pause()
            let fallback = VideoPlaybackState.coverOnly("弱网/离线，仅展示封面")
            if cellStates[indexPath] != fallback {
                analytics.track(.videoWeakNetworkFallback, properties: ["video_id": items[indexPath.row].id])
            }
            applyState(fallback, for: indexPath)
            return
        }

        if currentPlayingIndexPath == indexPath {
            if let cell = tableView.cellForRow(at: indexPath) as? VideoFeedCell {
                playerEngine.attach(to: cell.playerContainerView)
            }
            if currentPlaybackState == .paused {
                playerEngine.resume()
            }
            refreshVisibleCellStates()
            return
        }

        playItem(at: indexPath, autoplay: true, replay: false)
    }

    private func playItem(at indexPath: IndexPath, autoplay: Bool, replay: Bool) {
        currentPlayingIndexPath = indexPath
        let item = items[indexPath.row]

        if let cell = tableView.cellForRow(at: indexPath) as? VideoFeedCell {
            playerEngine.attach(to: cell.playerContainerView)
        }

        cachePreloader.preload(url: item.videoURL)
        if cachePreloader.isCached(item.videoURL) {
            analytics.track(.videoCacheHit, properties: ["video_id": item.id])
        }

        let playbackURL = cachePreloader.playbackURL(for: item.videoURL)
        let source = cachePreloader.isCached(item.videoURL) ? "disk" : "remote"

        if autoplay {
            pendingAutoplayIndexPath = indexPath
            analytics.track(.videoAutoplayAttempt, properties: ["video_id": item.id])
        } else {
            pendingAutoplayIndexPath = nil
        }

        applyState(replay ? .replaying : .loading, for: indexPath)
        playerEngine.play(url: playbackURL, source: source)

        let nextIndex = indexPath.row + 1
        if nextIndex < items.count {
            cachePreloader.preload(url: items[nextIndex].videoURL)
        }
    }

    private func currentBestVisibleIndexPath() -> IndexPath? {
        let visiblePaths = tableView.indexPathsForVisibleRows ?? []
        let tableVisibleRect = CGRect(origin: tableView.contentOffset, size: tableView.bounds.size)

        return visiblePaths
            .compactMap { indexPath -> (IndexPath, CGFloat)? in
                guard let cell = tableView.cellForRow(at: indexPath) else { return nil }
                let intersection = tableVisibleRect.intersection(cell.frame)
                guard !intersection.isNull, cell.frame.height > 0 else { return nil }
                let ratio = intersection.height / cell.frame.height
                return ratio >= 0.6 ? (indexPath, ratio) : nil
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private var shouldAutoplay: Bool {
        !(featureFlags.bool(.weakNetworkDegradeEnabled) && networkMonitor.isOnline == false)
    }

    private func applyState(_ state: VideoPlaybackState, for indexPath: IndexPath?) {
        guard let indexPath else { return }
        cellStates[indexPath] = state
        if currentPlayingIndexPath == indexPath {
            currentPlaybackState = state
        }

        switch state {
        case .failed:
            analytics.track(.videoPlaybackFailure, properties: ["video_id": items[indexPath.row].id])
        default:
            break
        }

        if let cell = tableView.cellForRow(at: indexPath) as? VideoFeedCell {
            cell.apply(state: state, isActive: currentPlayingIndexPath == indexPath)
        }
    }

    private func refreshVisibleCellStates() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            let state = cellStates[indexPath] ?? .idle
            (tableView.cellForRow(at: indexPath) as? VideoFeedCell)?.apply(state: state, isActive: currentPlayingIndexPath == indexPath)
        }
    }
}

extension VideoFeedViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: VideoFeedCell.reuseIdentifier, for: indexPath) as? VideoFeedCell else {
            return UITableViewCell()
        }
        cell.configure(item: items[indexPath.row], imageLoader: imageLoader)
        cell.apply(state: cellStates[indexPath] ?? .idle, isActive: currentPlayingIndexPath == indexPath)
        return cell
    }
}

extension VideoFeedViewController: UITableViewDelegate {
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleAutoplayUpdate()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleAutoplayUpdate()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        playerEngine.updateLayout()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard shouldAutoplay else {
            analytics.track(.videoWeakNetworkFallback, properties: ["video_id": items[indexPath.row].id])
            currentPlayingIndexPath = indexPath
            applyState(.coverOnly("弱网/离线，仅展示封面"), for: indexPath)
            refreshVisibleCellStates()
            return
        }

        if currentPlayingIndexPath == indexPath {
            switch currentPlaybackState {
            case .ended:
                analytics.track(.videoReplay, properties: ["video_id": items[indexPath.row].id])
                playItem(at: indexPath, autoplay: false, replay: true)
            case .paused, .failed:
                playItem(at: indexPath, autoplay: false, replay: false)
            default:
                playerEngine.resume()
            }
        } else {
            playItem(at: indexPath, autoplay: false, replay: false)
        }
        refreshVisibleCellStates()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? VideoFeedCell)?.cancelCoverLoading()
        prefetchTokensByIndexPath.removeValue(forKey: indexPath)?.forEach { imageLoader.cancelLoad($0) }
        if currentPlayingIndexPath != indexPath {
            cachePreloader.cancel(url: items[indexPath.row].videoURL)
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? VideoFeedCell)?.apply(state: cellStates[indexPath] ?? .idle, isActive: currentPlayingIndexPath == indexPath)
    }
}

extension VideoFeedViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        let targetSize = CGSize(width: view.bounds.width, height: max(view.bounds.height, 1))
        prefetchTokensByIndexPath.merge(
            indexPaths.reduce(into: [IndexPath: [UUID]]()) { partial, indexPath in
                guard indexPath.row < items.count else { return }
                partial[indexPath] = imageLoader.prefetch(urls: [items[indexPath.row].coverURL], targetPixelSize: targetSize)
                cachePreloader.preload(url: items[indexPath.row].videoURL)
            },
            uniquingKeysWith: { _, new in new }
        )
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let tokens = prefetchTokensByIndexPath.removeValue(forKey: indexPath) else { continue }
            tokens.forEach { imageLoader.cancelLoad($0) }
            if indexPath != currentPlayingIndexPath {
                cachePreloader.cancel(url: items[indexPath.row].videoURL)
            }
        }
    }
}
