//记录并打印 TTFF 链路日志
import Foundation
import QuartzCore

final class PlaybackSession {
    let sessionId = UUID().uuidString
    let videoId: String
    
    private var clickBase: CFTimeInterval?
    
    private(set) var clickTime: CFTimeInterval?
    private(set) var pageAppearTime: CFTimeInterval?
    private(set) var readyTime: CFTimeInterval?
    private(set) var firstFrameTime: CFTimeInterval?
    private(set) var playStartTime: CFTimeInterval?
    
    init(videoId: String) {
        self.videoId = videoId
    }
    
    func markClick() {
        clickBase = CACurrentMediaTime()
        clickTime = 0
        log("pageAppear")
    }
    func markPageAppear() {
        if pageAppearTime == nil {
            pageAppearTime = now()
            log("pageAppear")
        }
    }
    
    func markReady() {
        if readyTime == nil {
            readyTime = now()
            log("ready")
        }
    }
    
    func markFirstFrame() {
        if firstFrameTime == nil {
            firstFrameTime = now()
            log("firstFrame", extra: ["ttffMs": ms(firstFrameTime)])
        }
    }
    
    func markPlayStart() {
        if playStartTime == nil {
            playStartTime = now()
            log("playStart")
        }
    }
    func log(_ event: String, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "videoId": videoId,
            "event": event,
            "clickMs": ms(clickTime),
            "pageAppearMs": ms(pageAppearTime),
            "readyMs": ms(readyTime),
            "firstFrameMs": ms(firstFrameTime),
            "playStartMs": ms(playStartTime)
        ]
        extra.forEach { payload[$0.key] = $0.value }
        print("[PlaybackSession] \(payload)")
    }
    private func now() -> CFTimeInterval? {
        guard let clickBase else { return nil }
        return CACurrentMediaTime() - clickBase
    }
    
    private func ms(_ time: CFTimeInterval?) -> String {
        guard let time else { return "-" }
        return String(format: "%.0f", time * 1000)
    }
}
