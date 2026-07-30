import UIKit
import os
import os.signpost
import QuartzCore

final class LaunchMetrics {
    static let shared = LaunchMetrics()

    private let log = OSLog(subsystem: "FeaturedPosts", category: "Launch")
    private let logger = Logger(subsystem: "FeaturedPosts", category: "Launch")
    private lazy var ttidID = OSSignpostID(log: log)

    private let t0 = ProcessInfo.processInfo.systemUptime
    private var ttidBegan = false
    private var firstFrameRecorded = false
    private var displayLink: CADisplayLink?

    private init() {}

    private func emit(_ name: String) {
        let ms = Int64((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        logger.info("launch \(name, privacy: .public) t=\(ms, privacy: .public)ms")
        #if DEBUG
        print("[Launch] \(name) t=\(ms)ms")
        #endif
    }

    func appDidFinishLaunchingStart() {
        guard !ttidBegan else { return }
        ttidBegan = true
        emit("didFinishLaunching_start")
        os_signpost(.begin, log: log, name: "TTID", signpostID: ttidID)
        os_signpost(.event, log: log, name: "didFinishLaunching_start")
    }

    func appDidFinishLaunchingEnd() {
        emit("didFinishLaunching_end")
        os_signpost(.event, log: log, name: "didFinishLaunching_end")
    }

    func sceneWillConnectStart() {
        emit("scene_willConnect_start")
        os_signpost(.event, log: log, name: "scene_willConnect_start")
    }

    func sceneWillConnectEnd() {
        emit("scene_willConnect_end")
        os_signpost(.event, log: log, name: "scene_willConnect_end")
    }

    func startFirstFrameTracking() {
        guard displayLink == nil, !firstFrameRecorded else { return }
        emit("firstFrame_tracking_start")
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLink() {
        guard !firstFrameRecorded else { return }
        firstFrameRecorded = true
        displayLink?.invalidate()
        displayLink = nil

        emit("first_frame")
        os_signpost(.event, log: log, name: "first_frame")
        os_signpost(.end, log: log, name: "TTID", signpostID: ttidID)
    }
}