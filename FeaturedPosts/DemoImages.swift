import UIKit
import ImageIO
import CryptoKit
import os

/// 线程安全的 LRU 内存缓存。
/// 通过双向链表维护最近访问顺序，超出 cost 上限时从尾部淘汰。
final class LRUCache<Key: Hashable, Value> {
    final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let totalCostLimit: Int
    private var totalCost: Int = 0
    private var dict: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let lock = NSLock()

    init(totalCostLimit: Int) {
        self.totalCostLimit = max(0, totalCostLimit)
    }

    func value(forKey key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let node = dict[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    func setValue(_ value: Value, forKey key: Key, cost: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let node = dict[key] {
            totalCost -= node.cost
            node.value = value
            node.cost = max(0, cost)
            totalCost += node.cost
            moveToHead(node)
        } else {
            let node = Node(key: key, value: value, cost: max(0, cost))
            dict[key] = node
            insertAtHead(node)
            totalCost += node.cost
        }

        evictIfNeeded()
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        dict.removeAll()
        head = nil
        tail = nil
        totalCost = 0
    }

    var currentCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        remove(node)
        insertAtHead(node)
    }

    private func remove(_ node: Node) {
        let p = node.prev
        let n = node.next
        if let p { p.next = n } else { head = n }
        if let n { n.prev = p } else { tail = p }
        node.prev = nil
        node.next = nil
    }

    private func evictIfNeeded() {
        while totalCostLimit > 0, totalCost > totalCostLimit, let tail {
            dict[tail.key] = nil
            totalCost -= tail.cost
            remove(tail)
        }
    }
}

/// 将较重但不要求立即执行的任务延后到主线程 RunLoop 空闲时触发，
/// 避免滚动/点击等高优先级交互期间抢占主线程时机。
final class RunLoopIdleWorkScheduler {
    static let shared = RunLoopIdleWorkScheduler()

    private let lock = NSLock()
    private var queue: [() -> Void] = []
    private var observer: CFRunLoopObserver?

    private init() {}

    func enqueue(_ work: @escaping () -> Void) {
        lock.lock()
        queue.append(work)
        lock.unlock()
        ensureObserver()
    }

    func removeAll() {
        lock.lock()
        queue.removeAll()
        lock.unlock()
    }

    private func ensureObserver() {
        guard observer == nil else { return }
        var context = CFRunLoopObserverContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let obs = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0,
            { _, _, info in
                guard let info else { return }
                let scheduler = Unmanaged<RunLoopIdleWorkScheduler>.fromOpaque(info).takeUnretainedValue()
                scheduler.drain(maxCount: 2)
            },
            &context
        )
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .defaultMode)
    }

    private func drain(maxCount: Int) {
        var works: [() -> Void] = []
        lock.lock()
        let n = min(maxCount, queue.count)
        if n > 0 {
            works = Array(queue.prefix(n))
            queue.removeFirst(n)
        }
        lock.unlock()

        for w in works { w() }
    }
}

enum ImageDownsampler {
    static func downsample(data: Data, to pixelSize: CGSize, scale: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        let maxPixel = max(pixelSize.width, pixelSize.height) * scale
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 为图片请求补充防盗链参数与请求头。
/// 当开关关闭时直接返回普通请求，便于本地调试与灰度切换。
struct ImageRequestSigner {
    static func signedRequest(for url: URL) -> URLRequest {
        guard FeatureFlagCenter.shared.bool(.imageAntiHotlinkEnabled) else {
            return URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let ts = Int(Date().timeIntervalSince1970)
        let secret = "demo_secret"
        let base = "\(url.path)|\(ts)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(base.utf8), using: key)
        let sigHex = sig.map { String(format: "%02x", $0) }.joined()

        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "ts", value: String(ts)))
        items.append(URLQueryItem(name: "sig", value: sigHex))
        components?.queryItems = items

        let finalURL = components?.url ?? url
        var req = URLRequest(url: finalURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        req.setValue("FeaturedPostsDemo/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://example.com", forHTTPHeaderField: "Referer")
        return req
    }
}

/// 图片加载器：负责内存缓存、请求去重、后台解码与主线程回调分发。
/// 同一 URL + 尺寸组合的并发请求会合并为一次网络请求，减少重复下载。
final class ImageLoader {
    static let shared = ImageLoader()

    let memoryCache = LRUCache<String, UIImage>(totalCostLimit: 120 * 1024 * 1024)

    private let session: URLSession
    private let decodeQueue = DispatchQueue(label: "ImageLoader.decode", qos: .userInitiated)
    private let lock = NSLock()

    private struct InFlight {
        var tokens: Set<UUID>
        var completions: [(Result<UIImage, Error>) -> Void]
        var task: URLSessionDataTask
    }

    private var tokenToKey: [UUID: String] = [:]
    private var inFlight: [String: InFlight] = [:]

    private let log = Logger(subsystem: "FeaturedPosts", category: "ImageLoader")

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = .shared
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    /// 加载指定尺寸的图片。
    /// 1. 先查内存缓存
    /// 2. 命中进行中的相同请求则复用任务
    /// 3. 下载完成后在后台降采样，再统一回到主线程分发结果
    @discardableResult
    func loadImage(url: URL, targetPixelSize: CGSize, completion: @escaping (Result<UIImage, Error>) -> Void) -> UUID {
        let token = UUID()
        let key = "\(url.absoluteString)|\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))"

        if let cached = memoryCache.value(forKey: key) {
            log.debug("memory cache hit key=\(key, privacy: .public)")
            AnalyticsTracker.shared.track(.imageCacheHit, properties: nil)
            completion(.success(cached))
            return token
        }

        lock.lock()
        tokenToKey[token] = key

        if var inflight = inFlight[key] {
            inflight.tokens.insert(token)
            inflight.completions.append(completion)
            inFlight[key] = inflight
            lock.unlock()
            return token
        }

        let request = ImageRequestSigner.signedRequest(for: url)
        let task = session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                self.finish(key: key, result: .failure(error))
                return
            }
            guard let data else {
                self.finish(key: key, result: .failure(NSError(domain: "ImageLoader", code: -1)))
                return
            }

            RunLoopIdleWorkScheduler.shared.enqueue { [weak self] in
                guard let self else { return }
                self.decodeQueue.async {
                    let image = ImageDownsampler.downsample(data: data, to: targetPixelSize, scale: UIScreen.main.scale)
                    if let image {
                        let cost = ImageLoader.approxCost(of: image)
                        self.memoryCache.setValue(image, forKey: key, cost: cost)
                        self.finish(key: key, result: .success(image))
                    } else {
                        self.finish(key: key, result: .failure(NSError(domain: "ImageLoader", code: -2)))
                    }
                }
            }
        }

        inFlight[key] = InFlight(tokens: [token], completions: [completion], task: task)
        lock.unlock()

        task.resume()
        return token
    }

    func cancelLoad(_ token: UUID) {
        lock.lock()
        guard let key = tokenToKey[token] else {
            lock.unlock()
            return
        }
        tokenToKey[token] = nil
        if var inflight = inFlight[key] {
            inflight.tokens.remove(token)
            if inflight.tokens.isEmpty {
                inflight.task.cancel()
                inFlight[key] = nil
            } else {
                inFlight[key] = inflight
            }
        }
        lock.unlock()
    }

    @discardableResult
    func prefetch(urls: [URL], targetPixelSize: CGSize) -> [UUID] {
        guard !urls.isEmpty else { return [] }
        return urls.prefix(30).map {
            loadImage(url: $0, targetPixelSize: targetPixelSize) { _ in }
        }
    }

    func cancelAllLoads() {
        lock.lock()
        let tasks = inFlight.values.map(\.task)
        tokenToKey.removeAll()
        inFlight.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
        RunLoopIdleWorkScheduler.shared.removeAll()
    }

    var currentInFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.count
    }

    var currentCacheCost: Int {
        memoryCache.currentCost
    }

    /// 完成一次 in-flight 请求，清理 token 映射，并把结果派发给所有等待中的 completion。
    private func finish(key: String, result: Result<UIImage, Error>) {
        lock.lock()
        let inflight = inFlight[key]
        inFlight[key] = nil

        if let inflight {
            for token in inflight.tokens {
                tokenToKey[token] = nil
            }
        }
        lock.unlock()

        guard let inflight else { return }
        DispatchQueue.main.async {
            for c in inflight.completions {
                c(result)
            }
        }
    }

    private static func approxCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

/// 面向 UI/VM 暴露的图片加载抽象，方便依赖注入与测试替身替换。
protocol ImageLoading {
    @discardableResult
    func loadImage(url: URL, targetPixelSize: CGSize, completion: @escaping (Result<UIImage, Error>) -> Void) -> UUID
    func cancelLoad(_ token: UUID)
    @discardableResult
    func prefetch(urls: [URL], targetPixelSize: CGSize) -> [UUID]
}

extension ImageLoader: ImageLoading {}

protocol JPEGCompressing {
    func compressToJPEG(image: UIImage, maxByteSize: Int, targetMaxPixel: CGFloat) throws -> Data
}

extension ImageCompressor: JPEGCompressing {}

/// 图片压缩器：先按像素尺寸缩放，再逐步降低 JPEG 质量，必要时继续缩图，
/// 尽量在目标字节上限内保留可接受的清晰度。
struct ImageCompressor {
    enum CompressionError: Error {
        case jpegEncodeFailed
        case cannotMeetByteLimit
    }

    func compressToJPEG(image: UIImage, maxByteSize: Int, targetMaxPixel: CGFloat) throws -> Data {
        let resized = resizeIfNeeded(image: image, targetMaxPixel: targetMaxPixel)
        var quality: CGFloat = 0.9

        while quality >= 0.4 {
            if let data = resized.jpegData(compressionQuality: quality) {
                if data.count <= maxByteSize { return data }
            } else {
                throw CompressionError.jpegEncodeFailed
            }
            quality -= 0.1
        }

        var current = resized
        for _ in 0..<6 {
            current = scale(image: current, ratio: 0.85)
            if let data = current.jpegData(compressionQuality: 0.6), data.count <= maxByteSize {
                return data
            }
        }

        throw CompressionError.cannotMeetByteLimit
    }

    private func resizeIfNeeded(image: UIImage, targetMaxPixel: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > targetMaxPixel else { return image }
        let ratio = targetMaxPixel / maxSide
        return scale(image: image, ratio: ratio)
    }

    private func scale(image: UIImage, ratio: CGFloat) -> UIImage {
        let newSize = CGSize(width: max(1, floor(image.size.width * ratio)), height: max(1, floor(image.size.height * ratio)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
