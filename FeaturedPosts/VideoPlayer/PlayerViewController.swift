//播放页，负责封面兜底、首帧切换、超时重试
import UIKit

final class PlayerViewController: UIViewController {
    private let video: VideoItem
    private let session: PlaybackSession

    private let playerHostView = UIView()
    private let coverImageView = UIImageView()
    private let loadingView = UIActivityIndicatorView(style: .large)
    private let hintLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    private var timeoutWorkItem: DispatchWorkItem?
    private var firstFrameRendered = false

    init(video: VideoItem, session: PlaybackSession) {
        self.video = video
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = video.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timeoutWorkItem?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        startPlay()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.markPageAppear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        PlayerManager.shared.attach(to: playerHostView)
        PlayerManager.shared.updateLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            timeoutWorkItem?.cancel()
            PlayerManager.shared.stop()
        }
    }

    private func setupUI() {
        playerHostView.translatesAutoresizingMaskIntoConstraints = false
        playerHostView.backgroundColor = .clear

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.image = video.coverImage()

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.color = .white

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.text = "正在准备首帧…"

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.88)
        retryButton.layer.cornerRadius = 22
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryPlay), for: .touchUpInside)

        view.addSubview(playerHostView)
        view.addSubview(coverImageView)
        view.addSubview(loadingView)
        view.addSubview(hintLabel)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            playerHostView.topAnchor.constraint(equalTo: view.topAnchor),
            playerHostView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerHostView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerHostView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            coverImageView.topAnchor.constraint(equalTo: view.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: loadingView.bottomAnchor, constant: 16),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            retryButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 18),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func startPlay() {
        firstFrameRendered = false
        timeoutWorkItem?.cancel()

        coverImageView.isHidden = false
        coverImageView.alpha = 1
        loadingView.startAnimating()
        retryButton.isHidden = true
        hintLabel.isHidden = false
        hintLabel.text = "正在准备首帧…"

        let manager = PlayerManager.shared
        manager.attach(to: playerHostView)
        manager.updateLayout()

        manager.onReady = { [weak self] in
            self?.hintLabel.text = "播放器 ready，等待首帧上屏…"
        }

        manager.onPlaying = { [weak self] in
            if self?.firstFrameRendered == false {
                self?.hintLabel.text = "已开始播放，等待画面显示…"
            }
        }

        manager.onFirstFrame = { [weak self] in
            guard let self else { return }
            self.firstFrameRendered = true
            self.timeoutWorkItem?.cancel()
            self.loadingView.stopAnimating()
            self.hintLabel.isHidden = true
            UIView.animate(withDuration: 0.18, animations: {
                self.coverImageView.alpha = 0
            }, completion: { _ in
                self.coverImageView.isHidden = true
            })
        }

        manager.onFailure = { [weak self] error in
            self?.showRetry(text: error?.localizedDescription ?? "播放失败")
        }

        manager.prepare(video: video, session: session)
        scheduleTimeout()
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.firstFrameRendered == false else { return }
            self.session.log("firstFrameTimeout", extra: ["thresholdMs": 1500])
            self.showRetry(text: "1500ms 内无首帧，已保留封面避免黑屏")
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + VideoDemoConfig.firstFrameTimeout, execute: work)
    }

    private func showRetry(text: String) {
        loadingView.stopAnimating()
        hintLabel.isHidden = false
        hintLabel.text = text
        retryButton.isHidden = false
        coverImageView.isHidden = false
        coverImageView.alpha = 1
    }

    @objc private func retryPlay() {
        PreloadService.shared.preload(video)
        startPlay()
    }
}
