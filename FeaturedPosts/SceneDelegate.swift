//
//  SceneDelegate.swift
//  FeaturedPosts
//
//  Created by maochengfang on 2026/6/24.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let featureFlags = FeatureFlagCenter.shared
        let analytics = AnalyticsTracker.shared

        let feedVM = FeedViewModel(
            api: MockFeedAPI(),
            store: SQLitePostStore(),
            networkMonitor: NetworkStateMonitor.shared,
            featureFlags: featureFlags,
            analytics: analytics
        )
        let feed = ViewController(viewModel: feedVM, imageLoader: ImageLoader.shared, featureFlags: featureFlags, analytics: analytics)
        feed.title = "Feed"
        let feedNav = UINavigationController(rootViewController: feed)
        feedNav.tabBarItem = UITabBarItem(title: "Feed", image: UIImage(systemName: "list.bullet"), tag: 0)

        let publishVM = PublishViewModel(
            uploader: UploadService.shared,
            compressor: ImageCompressor(),
            validator: PublishValidator(maxImages: 9, maxTextLength: 1000),
            featureFlags: featureFlags,
            analytics: analytics
        )
        let publish = NotePublishViewController(viewModel: publishVM)
        publish.title = "Publish"
        let publishNav = UINavigationController(rootViewController: publish)
        publishNav.tabBarItem = UITabBarItem(title: "Publish", image: UIImage(systemName: "square.and.arrow.up"), tag: 1)

        let tab = UITabBarController()
        tab.setViewControllers([feedNav, publishNav], animated: false)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = tab
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}

