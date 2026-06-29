import Foundation
import Network
import os

/// 帖子领域模型。
/// 作为 Feed 列表在网络层、持久层、UI 层之间传递的统一数据结构。
struct Post: Codable, Equatable, Identifiable {
    let id: String
    let author: String
    let text: String
    let imageURLs: [URL]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case text
        case imageURLs
        case createdAt
    }

    init(id: String, author: String, text: String, imageURLs: [URL], createdAt: Date) {
        self.id = id
        self.author = author
        self.text = text
        self.imageURLs = imageURLs
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        author = try c.decode(String.self, forKey: .author)
        text = try c.decode(String.self, forKey: .text)
        let urlStrings = try c.decode([String].self, forKey: .imageURLs)
        imageURLs = urlStrings.compactMap(URL.init(string:))
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(author, forKey: .author)
        try c.encode(text, forKey: .text)
        try c.encode(imageURLs.map { $0.absoluteString }, forKey: .imageURLs)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// Feed 数据源抽象，屏蔽真实网络 / Mock 实现差异。
protocol FeedAPI {
    func fetchFeed(page: Int, pageSize: Int) async throws -> [Post]
}

struct MockFeedAPI: FeedAPI {
    func fetchFeed(page: Int, pageSize: Int) async throws -> [Post] {
        try await Task.sleep(nanoseconds: 250_000_000)
        let base = page * pageSize
        let now = Date()
        return (0..<pageSize).map { i in
            let id = "post_\(base + i)"
            let imageCount = [1, 2, 3].randomElement() ?? 1
            let urls: [URL] = (0..<imageCount).compactMap { j in
                let seed = (base + i) * 10 + j + 1
                return URL(string: "https://picsum.photos/seed/\(seed)/800/800")
            }
            return Post(
                id: id,
                author: ["小鹿", "阿南", "一只猫", "River", "Momo"].randomElement() ?? "作者",
                text: "第 \(base + i + 1) 条：多图混排 + 弱网降级 + 预加载 + LRU 内存缓存",
                imageURLs: urls,
                createdAt: now.addingTimeInterval(TimeInterval(-(base + i) * 60))
            )
        }
    }
}

/// 帖子持久化抽象，供 VM 读取缓存与落盘，不感知底层是 SQLite 还是其他存储。
protocol PostStoring {
    func save(posts: [Post]) throws
    func fetchLatest(limit: Int) throws -> [Post]
}

enum FeatureFlagKey: String, CaseIterable {
    case imagePrefetchEnabled
    case weakNetworkDegradeEnabled
    case diskPostCacheEnabled
    case analyticsEnabled
    case publishV2Enabled
    case imageAntiHotlinkEnabled

    var description: String {
        switch self {
        case .imagePrefetchEnabled:
            "列表图片预取开关"
        case .weakNetworkDegradeEnabled:
            "弱网/离线降级策略开关"
        case .diskPostCacheEnabled:
            "帖子磁盘缓存（SQLite）开关"
        case .analyticsEnabled:
            "埋点开关"
        case .publishV2Enabled:
            "发布流程 V2 开关"
        case .imageAntiHotlinkEnabled:
            "图片防盗链签名开关"
        }
    }
}

/// 特性开关中心。
/// 统一管理灰度开关、降级开关与实验开关，避免业务代码直接读写 UserDefaults。
final class FeatureFlagCenter {
    static let shared = FeatureFlagCenter(userDefaults: .standard)

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func registerDefaults(_ defaults: [FeatureFlagKey: Bool]) {
        var dict: [String: Any] = [:]
        for (k, v) in defaults {
            dict[k.rawValue] = v
        }
        userDefaults.register(defaults: dict)
    }

    func bool(_ key: FeatureFlagKey) -> Bool {
        userDefaults.bool(forKey: key.rawValue)
    }

    func set(_ value: Bool, for key: FeatureFlagKey) {
        userDefaults.set(value, forKey: key.rawValue)
    }
}

protocol FeatureFlagProviding {
    func bool(_ key: FeatureFlagKey) -> Bool
    func set(_ value: Bool, for key: FeatureFlagKey)
}

extension FeatureFlagCenter: FeatureFlagProviding {}

/// 网络状态监听器。
/// 基于 NWPathMonitor 持续感知在线状态，供业务层做弱网降级判断。
final class NetworkStateMonitor {
    static let shared = NetworkStateMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkStateMonitor.queue")
    private var _isOnline: Bool = true
    private let lock = NSLock()

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = (path.status == .satisfied)
            self.lock.lock()
            self._isOnline = online
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}

protocol NetworkMonitoring {
    var isOnline: Bool { get }
}

extension NetworkStateMonitor: NetworkMonitoring {}

/// 令牌桶限流器。
/// 用于抑制短时间内的重复刷新/重复分页请求，避免接口被高频触发。
final class RateLimiter {
    private let maxTokens: Int
    private let refillInterval: TimeInterval

    private var tokens: Int
    private var lastRefill: TimeInterval
    private let lock = NSLock()

    init(maxTokens: Int, refillInterval: TimeInterval) {
        self.maxTokens = maxTokens
        self.refillInterval = refillInterval
        self.tokens = maxTokens
        self.lastRefill = CFAbsoluteTimeGetCurrent()
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        refillIfNeeded(now: CFAbsoluteTimeGetCurrent())
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }

    private func refillIfNeeded(now: TimeInterval) {
        // 距离上次补充令牌经过的时间。
        let elapsed = now - lastRefill

        // 未到一个补充周期则不做任何处理。
        guard elapsed >= refillInterval else { return }

        // 只结算“完整周期”的补充次数，避免把不足一个周期的时间提前消耗掉。
        let intervals = Int(elapsed / refillInterval)
        if intervals > 0 {
            // 令牌补充到桶容量上限。
            tokens = min(maxTokens, tokens + intervals)

            // lastRefill 只推进已结算的整周期时间，保留余量给下次计算，避免长期漂移。
            lastRefill += TimeInterval(intervals) * refillInterval
        }
    }
}

/// Feed 页面业务编排层。
/// 负责首屏加载、分页、离线降级、缓存回填与错误输出；不直接依赖 UIKit。
@MainActor
final class FeedViewModel {
    private let api: FeedAPI
    private let store: PostStoring
    private let networkMonitor: NetworkMonitoring
    private let featureFlags: FeatureFlagProviding
    private let analytics: AnalyticsTracking

    private let pageSize = 20
    private var page = 0
    private var isLoading = false
    private let limiter = RateLimiter(maxTokens: 2, refillInterval: 1.0)
    private var lastAppendPage: Int = -1

    private(set) var posts: [Post] = []

    var onStateChanged: ((FeedViewModel) -> Void)?
    var onError: ((String) -> Void)?

    init(api: FeedAPI, store: PostStoring, networkMonitor: NetworkMonitoring, featureFlags: FeatureFlagProviding, analytics: AnalyticsTracking) {
        self.api = api
        self.store = store
        self.networkMonitor = networkMonitor
        self.featureFlags = featureFlags
        self.analytics = analytics
    }

    /// 首次加载：优先尝试读取本地缓存，再继续发起线上刷新。
    func loadInitial() async {
        if featureFlags.bool(.diskPostCacheEnabled) {
            if let cached = try? store.fetchLatest(limit: 50), !cached.isEmpty {
                posts = cached
                analytics.track(.feedCacheHit, properties: ["count": cached.count])
                onStateChanged?(self)
            }
        }
        await refresh()
    }

    /// 下拉刷新：受限流器保护，并在离线且无内容时输出降级提示。
    func refresh() async {
        guard !isLoading else { return }
        guard limiter.tryAcquire() else { return }

        if featureFlags.bool(.weakNetworkDegradeEnabled), networkMonitor.isOnline == false {
            if posts.isEmpty {
                onError?("当前离线，已降级仅展示本地缓存")
            }
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            page = 0
            lastAppendPage = -1
            let newPosts = try await api.fetchFeed(page: page, pageSize: pageSize)
            posts = newPosts
            onStateChanged?(self)

            if featureFlags.bool(.diskPostCacheEnabled) {
                try? store.save(posts: newPosts)
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// 触底分页：接近列表尾部时触发，避免重复追加同一页。
    func loadNextPageIfNeeded(currentIndex: Int) async {
        guard currentIndex >= posts.count - 6 else { return }
        guard !isLoading else { return }
        guard limiter.tryAcquire() else { return }

        if featureFlags.bool(.weakNetworkDegradeEnabled), networkMonitor.isOnline == false {
            return
        }

        let next = page + 1
        guard next != lastAppendPage else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            page = next
            let more = try await api.fetchFeed(page: page, pageSize: pageSize)
            posts.append(contentsOf: more)
            lastAppendPage = page
            onStateChanged?(self)

            if featureFlags.bool(.diskPostCacheEnabled) {
                try? store.save(posts: posts.prefix(80).map { $0 })
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }
}

/// 发布前校验器，集中封装文案与图片数量规则。
struct PublishValidator {
    let maxImages: Int
    let maxTextLength: Int

    enum ValidationError: LocalizedError {
        case emptyText
        case emptyImages
        case tooManyImages
        case textTooLong

        var errorDescription: String? {
            switch self {
            case .emptyText: return "文案不能为空"
            case .emptyImages: return "至少选择 1 张图片"
            case .tooManyImages: return "图片数量超限"
            case .textTooLong: return "文案过长"
            }
        }
    }

    func validate(text: String, imagesCount: Int) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError.emptyText }
        if imagesCount <= 0 { throw ValidationError.emptyImages }
        if imagesCount > maxImages { throw ValidationError.tooManyImages }
        if text.count > maxTextLength { throw ValidationError.textTooLong }
    }
}

/// 基于 actor 的轻量异步信号量，用于限制并发上传数量。
actor AsyncSemaphore {
    private var value: Int
    init(value: Int) { self.value = value }

    func wait() async {
        while value <= 0 { await Task.yield() }
        value -= 1
    }

    func signal() {
        value += 1
    }
}

protocol JPEGUploading {
    func uploadJPEG(_ data: Data, filename: String) async throws -> URL
}

/// 上传服务抽象实现。
/// 当前为 mock 上传，后续可无缝替换为真实上传接口。
final class UploadService: JPEGUploading {
    static let shared = UploadService()

    private init() {}

    enum UploadError: Error {
        case simulatedFailure
    }

    func uploadJPEG(_ data: Data, filename: String) async throws -> URL {
        try await Task.sleep(nanoseconds: 250_000_000)
        if Int.random(in: 0..<25) == 0 { throw UploadError.simulatedFailure }
        return URL(string: "https://cdn.example.com/\(UUID().uuidString)/\(filename)")!
    }
}

enum AnalyticsEvent: String {
    case feedRefreshTap
    case feedImpression
    case feedCacheHit
    case imageCacheHit
    case imageLoadSuccess
    case imageLoadFailure
    case memoryWarning
    case publishPickImages
    case publishTapUpload
    case publishUploadSuccess
    case publishUploadFailure
    case publishRollbackDisabled
}

/// 埋点追踪器。
/// 统一收口业务事件，异步写日志并支持通过特性开关整体关闭。
final class AnalyticsTracker {
    static let shared = AnalyticsTracker()

    private let log = Logger(subsystem: "FeaturedPosts", category: "Analytics")
    private let queue = DispatchQueue(label: "AnalyticsTracker.queue")

    private init() {}

    func start() {}

    func track(_ event: AnalyticsEvent, properties: [String: Any]?) {
        guard FeatureFlagCenter.shared.bool(.analyticsEnabled) else { return }

        queue.async {
            let payload = properties?.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&") ?? ""
            self.log.info("\(event.rawValue, privacy: .public) \(payload, privacy: .public)")
            self.persist("\(event.rawValue) \(payload)")
        }
    }

    private func persist(_ line: String) {
        let text = "\(Date()) \(line)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analytics.log")
        guard let data = text.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

protocol AnalyticsTracking {
    func track(_ event: AnalyticsEvent, properties: [String: Any]?)
}

extension AnalyticsTracker: AnalyticsTracking {}