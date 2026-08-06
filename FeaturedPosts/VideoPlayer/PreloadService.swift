//轻量预热 AVURLAsset + Range 首包，支持取消与并发限制
import Foundation
import AVFoundation

final class PreloadService {
    static let shared = PreloadService()
    private let stateQueue = DispatchQueue(label: "demo.preload.stat")
    
    private let operationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "demo.preload.queue"
        return q
    }()
    
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
    
    private var assetCache: [String: AVURLAsset] = [:]
    private var tasks: [String: URLSessionDataTask] = [:]
    
    private init() {}
    
    func preload(_ video: VideoItem) {
        stateQueue.async {
            if self.tasks[video.id] != nil { return }
            
            let asset = self.assetCache[video.id] ?? AVURLAsset(url: video.url)
            self.assetCache[video.id] = asset
            
            asset.loadValuesAsynchronously(forKeys: ["playable","tracks"]) {
                print("[PreloadService] assetPrepared videoId=\(video.id)")
            }
            
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self, let op, !op.isCancelled else { return }
                var request = URLRequest(url: video.url)
                request.timeoutInterval = 1.5
                request.setValue("bytes=0-\(VideoDemoConfig.preloadBytes - 1)", forHTTPHeaderField:  "Range")
                
                let semapthore = DispatchSemaphore(value: 0)
                var task : URLSessionDataTask?
                task = self.session.dataTask(with: request) { data, response, error in
                    defer { semapthore.signal() }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let bytes = data?.count ?? 0
                    if let error, (error as NSError).code != NSURLErrorCancelled {
                        print("[PreloadService] rangeWarmupFailed videoId=\(video.id) error=\(error.localizedDescription)")
                    }else {
                        print("[PreloadService] rangeWarmupDone videoId=\(video.id) code=\(code) bytes=\(bytes)")
                    }
                    
                    self.stateQueue.async {
                        if self.tasks[video.id] === task {
                            self.tasks.removeValue(forKey: video.id)
                        }
                    }
                }
                guard let task else { return }
                self.stateQueue.async {
                    self.tasks[video.id] = task
                }
                
                task.resume()
                _ = semapthore.wait(timeout: .now() + 2.0)
            }
            
            self.operationQueue.addOperation(op)
            print("[PreloadService] enqueue videoId=\(video.id)")
        }
    }
    
    func cancel(videoId: String) {
        stateQueue.async {
            self.tasks[videoId]?.cancel()
            self.tasks.removeValue(forKey: videoId)
            print("[PreloadService] cancel videoId=\(videoId)")
        }
    }
    
    func makeItem(for video: VideoItem) -> AVPlayerItem {
        let asset = stateQueue.sync {
            assetCache[video.id] ?? AVURLAsset(url: video.url)
        }
        return AVPlayerItem(asset: asset)
    }
}

