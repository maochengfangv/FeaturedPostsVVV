//
//  AppDelegate.swift
//  FeaturedPosts
//
//  Created by maochengfang on 2026/6/24.
//

import UIKit
import os

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
       URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024, diskPath: "urlcache")

        FeatureFlagCenter.shared.registerDefaults([
            .imagePrefetchEnabled: true,
            .weakNetworkDegradeEnabled: true,
            .diskPostCacheEnabled: true,
            .analyticsEnabled: true,
            .publishV2Enabled: true,
            .imageAntiHotlinkEnabled: true
        ])

        AnalyticsTracker.shared.start()
        CrashReporter.shared.start()
        MemoryGuard.shared.start(imageCache: ImageLoader.shared.memoryCache)

        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

final class CrashReporter {
    static let shared = CrashReporter()

    private init() {}

    func start() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? ""
            let stacks = exception.callStackSymbols.joined(separator: "\n")
            CrashReporter.shared.persist("UncaughtException: \(name)\n\(reason)\n\(stacks)")
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    @objc private func didReceiveMemoryWarning() {
        persist("MemoryWarning")
    }

    private func persist(_ message: String) {
        let text = "\(Date())\n\(message)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crash_report.log")
        if let data = text.data(using: .utf8) {
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
}

final class MemoryGuard {
    static let shared = MemoryGuard()

    private weak var imageCache: LRUCache<String, UIImage>?
    private let log = Logger(subsystem: "FeaturedPosts", category: "MemoryGuard")

    private init() {}

    func start(imageCache: LRUCache<String, UIImage>) {
        self.imageCache = imageCache
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    @objc private func didReceiveMemoryWarning() {
        let cacheCost = ImageLoader.shared.currentCacheCost
        let inFlightCount = ImageLoader.shared.currentInFlightCount
        log.warning("memory warning cache_cost=\(cacheCost, privacy: .public) inflight=\(inFlightCount, privacy: .public)")
        AnalyticsTracker.shared.track(.memoryWarning, properties: ["cache_cost": cacheCost, "inflight": inFlightCount])

        FeatureFlagCenter.shared.set(false, for: .imagePrefetchEnabled)
        imageCache?.removeAll()
        ImageLoader.shared.cancelAllLoads()
    }
}

