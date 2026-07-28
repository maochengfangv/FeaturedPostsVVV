import UIKit
import AVFoundation

enum VideoPlaybackState: Equatable {
    case idle
    case coverOnly(String)
    case loading
    case playing
    case paused
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
            subtitle: "单播放器复用 + 封面优先显示",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-1/720/1280")!,
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
        ),
        VideoFeedItem(
            id: "video_2",
            title: "山谷穿梭",
            subtitle: "主曝光 cell 自动播放",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-2/720/1280")!,
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!
        ),
        VideoFeedItem(
            id: "video_3",
            title: "城市夜景",
            subtitle: "预热下一个 AVPlayerItem",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-3/720/1280")!,
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!
        ),
        VideoFeedItem(
            id: "video_4",
            title: "公路旅行",
            subtitle: "滚动停止后再判定切换",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-4/720/1280")!,
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4")!
        ),
        VideoFeedItem(
            id: "video_5",
            title: "雨后森林",
            subtitle: "离屏立即取消封面任务",
            coverURL: URL(string: "https://picsum.photos/seed/video-cover-5/720/1280")!,
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!
        )
    ]
}

final class VideoPlayerEngine {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private weak var currentContainerView: UIView?
    private var currentItemURL: URL?
    private var warmedItems: [URL: AVPlayerItem] = [:]
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    var onStateChanged: ((VideoPlaybackState) -> Void)?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            switch player.timeControlStatus {
            case .paused:
                self?.onStateChanged?(.paused)
            case .waitingToPlayAtSpecifiedRate:
                self?.onStateChanged?(.loading)
            case .playing:
                self?.onStateChanged?(.playing)
            @unknown default:
                self?.onStateChanged?(.idle)
            }
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
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

    func play(url: URL) {
        if currentItemURL != url {
            let item = warmedItems.removeValue(forKey: url) ?? AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            currentItemURL = url
            observe(item: item)
        }
        onStateChanged?(.loading)
        player.play()
    }

    func preload(url: URL) {
        guard warmedItems[url] == nil, currentItemURL != url else { return }
        warmedItems[url] = AVPlayerItem(url: url)
    }

    func pause() {
        player.pause()
    }

    private func observe(item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                if self?.player.timeControlStatus == .paused {
                    self?.onStateChanged?(.paused)
                }
            case .failed:
                let message = item.error?.localizedDescription ?? "视频加载失败"
                self?.onStateChanged?(.failed(message))
            case .unknown:
                self?.onStateChanged?(.loading)
            @unknown default:
                self?.onStateChanged?(.idle)
            }
        }
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
            centerStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            centerStatusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            activityIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            playHintButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playHintButton.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -18),
            playHintButton.widthAnchor.constraint(equalToConstant: 120),
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
        case let .coverOnly(message):
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = false
            centerStatusLabel.text = "  \(message)  "
            playHintButton.isHidden = true
        case .loading:
            activityIndicator.startAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = true
        case .playing:
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = true
        case .paused:
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = true
            playHintButton.isHidden = !isActive
        case let .failed(message):
            activityIndicator.stopAnimating()
            centerStatusLabel.isHidden = false
            centerStatusLabel.text = "  \(message)  "
            playHintButton.isHidden = !isActive
        }

        badgeLabel.text = isActive ? "ACTIVE" : "AUTO PLAY"
        coverImageView.alpha = (state == .playing) ? 0.12 : 1.0
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
    private let items: [VideoFeedItem]
    private let playerEngine = VideoPlayerEngine()

    private var currentPlayingIndexPath: IndexPath?
    private var autoplayWorkItem: DispatchWorkItem?
    private var prefetchTokensByIndexPath: [IndexPath: [UUID]] = [:]
    private var cellStates: [IndexPath: VideoPlaybackState] = [:]

    init(items: [VideoFeedItem], imageLoader: ImageLoading, networkMonitor: NetworkMonitoring, featureFlags: FeatureFlagProviding) {
        self.items = items
        self.imageLoader = imageLoader
        self.networkMonitor = networkMonitor
        self.featureFlags = featureFlags
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "视频"
        view.backgroundColor = .black

        playerEngine.onStateChanged = { [weak self] state in
            self?.applyState(state, for: self?.currentPlayingIndexPath)
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
            applyState(.coverOnly("弱网/离线，仅展示封面"), for: indexPath)
            return
        }

        guard currentPlayingIndexPath != indexPath else {
            if let cell = tableView.cellForRow(at: indexPath) as? VideoFeedCell {
                playerEngine.attach(to: cell.playerContainerView)
            }
            playerEngine.play(url: items[indexPath.row].videoURL)
            return
        }

        currentPlayingIndexPath = indexPath
        let item = items[indexPath.row]
        guard let cell = tableView.cellForRow(at: indexPath) as? VideoFeedCell else { return }
        playerEngine.attach(to: cell.playerContainerView)
        applyState(.loading, for: indexPath)
        playerEngine.play(url: item.videoURL)

        let nextIndex = indexPath.row + 1
        if nextIndex < items.count {
            playerEngine.preload(url: items[nextIndex].videoURL)
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
        currentPlayingIndexPath = indexPath
        if shouldAutoplay {
            if let cell = tableView.cellForRow(at: indexPath) as? VideoFeedCell {
                playerEngine.attach(to: cell.playerContainerView)
            }
            applyState(.loading, for: indexPath)
            playerEngine.play(url: items[indexPath.row].videoURL)
        } else {
            applyState(.coverOnly("弱网/离线，仅展示封面"), for: indexPath)
        }
        refreshVisibleCellStates()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? VideoFeedCell)?.cancelCoverLoading()
        prefetchTokensByIndexPath.removeValue(forKey: indexPath)?.forEach { imageLoader.cancelLoad($0) }
        if currentPlayingIndexPath == indexPath {
            playerEngine.pause()
            cellStates[indexPath] = .paused
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
            },
            uniquingKeysWith: { _, new in new }
        )
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let tokens = prefetchTokensByIndexPath.removeValue(forKey: indexPath) else { continue }
            tokens.forEach { imageLoader.cancelLoad($0) }
        }
    }
}
