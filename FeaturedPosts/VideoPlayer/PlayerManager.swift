//单例复用播放器与 playerLayer ，负责切换 item 和清理 observer
import UIKit
import AVFoundation

final class PlayerManager: NSObject {
    static let shared = PlayerManager()
    
    let player = AVPlayer()
    let playerLayer = AVPlayerLayer()
    
    var onReady: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onPlaying: (() -> Void)?
    var onFailure: ((Error?) -> Void)?
    
    private weak var hostView: UIView?
    private weak var session: PlaybackSession?
    
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var layerReadyObservation: NSKeyValueObservation?
    
    private var stallObserver: NSObjectProtocol?
    private var accessLogObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    
    private var didCallPlay = false
    private var didMarkFirstFrame = false
    
    private override init() {
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.clear.cgColor
    }
    
    func attach(to view: UIView) {
        hostView = view
        if playerLayer.superlayer !== view.layer {
            playerLayer.removeFromSuperlayer()
            playerLayer.frame = view.bounds
            view.layer.addSublayer(playerLayer)
        }
    }
    
    func updateLayout() {
        guard let hostView else { return }
        playerLayer.frame = hostView.bounds
    }
    
    
    func detach() {
        playerLayer.removeFromSuperlayer()
        hostView = nil
    }
    
    func prepare(video: VideoItem, session: PlaybackSession) {
        cleanupCurrentItem(keepLayer: true, resetCallbacks: false)
        
        self.session = session
        self.didCallPlay = false
        self.didMarkFirstFrame = false
        
        player.pause()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        
        let item = PreloadService.shared.makeItem(for: video)
        item.preferredForwardBufferDuration = 0.8
        
        observe(item: item)
        observerLayer()
        
        player.replaceCurrentItem(with: item)
    }
    
    func stop() {
        cleanupCurrentItem(keepLayer: false, resetCallbacks: true)
    }
    
    private func observe(item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.session?.markReady()
                self.onReady?()
                self.playIfNeeded(reason: "readyToPlay")
            case .failed:
                self.session?.log("itemFailed", extra: ["error": item.error?.localizedDescription ?? "-"])
                self.onFailure?(item.error)
            case .unknown:
                self.session?.log("itemStatusUnknown")
            @unknown default:
                break
            }
        }
        
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                self.session?.markPlayStart()
                self.onPlaying?()
            case .waitingToPlayAtSpecifiedRate:
                self.session?.log("timeControlWaiting", extra: [
                    "reason": player.reasonForWaitingToPlay?.rawValue ?? "-"
                ])
            case .paused:
                self.session?.log("timeControlPaused")
            @unknown default:
                break
            }
        }
        
        loadedTimeRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return }
            let buffered = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
            self.session?.log("loadedTimeRanges", extra: ["bufferedSec": String(format: "%.2f", buffered)])
        }
        
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            self?.session?.log("isPlaybackLikelyToKeepUp", extra: ["value": item.isPlaybackLikelyToKeepUp])
        }
        
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.session?.log("playbackStalled")
        }
        
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let event = item.accessLog()?.events.last else { return }
            self?.session?.log("accessLog", extra: [
                "observedBitrate": Int(event.observedBitrate),
                "indicatedBitrate": Int(event.indicatedBitrate)
            ])
        }
        
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let event = item.errorLog()?.events.last else { return }
            self?.session?.log("errorLog", extra: [
                "statusCode": event.errorStatusCode,
                "domain": event.errorDomain
            ])
        }
    }
    
    private func observerLayer() {
        layerReadyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard let self else { return }
            if layer.isReadyForDisplay {
                self.handleFirstFrame()
            }
        }
    }
    
    private func handleFirstFrame() {
        guard didMarkFirstFrame == false else { return }
        didMarkFirstFrame = true
        player.isMuted = false
        session?.markFirstFrame()
        onFirstFrame?()
    }
    
    private func playIfNeeded(reason: String) {
        guard didCallPlay == false else { return }
        guard player.currentItem?.status == .readyToPlay else { return }
        didCallPlay = true
        session?.log("issuePlay", extra: ["reason": reason])
        player.playImmediately(atRate: 1.0)
    }
    
    private func cleanupCurrentItem(keepLayer: Bool, resetCallbacks: Bool) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.isMuted = false
        
        itemStatusObservation = nil
        timeControlObservation = nil
        loadedTimeRangesObservation = nil
        keepUpObservation = nil
        layerReadyObservation = nil
        
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        if let accessLogObserver {
            NotificationCenter.default.removeObserver(accessLogObserver)
            self.accessLogObserver = nil
        }
        if let errorLogObserver {
            NotificationCenter.default.removeObserver(errorLogObserver)
            self.errorLogObserver = nil
        }
        
        if resetCallbacks {
            onReady = nil
            onFirstFrame = nil
            onPlaying = nil
            onFailure = nil
        }
        if keepLayer == false {
            detach()
        }
        
    }
}
