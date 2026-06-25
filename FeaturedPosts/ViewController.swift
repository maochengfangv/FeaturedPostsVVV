//
//  ViewController.swift
//  FeaturedPosts
//
//  Created by maochengfang on 2026/6/24.
//

import UIKit

final class ViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let viewModel: FeedViewModel
    private let imageLoader: ImageLoading
    private let featureFlags: FeatureFlagProviding
    private let analytics: AnalyticsTracking

    init(viewModel: FeedViewModel, imageLoader: ImageLoading, featureFlags: FeatureFlagProviding, analytics: AnalyticsTracking) {
        self.viewModel = viewModel
        self.imageLoader = imageLoader
        self.featureFlags = featureFlags
        self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "精选"

        view.backgroundColor = .systemBackground

        tableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 180
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(didTapRefresh))

        bindViewModel()
        Task { await viewModel.loadInitial() }
    }

    @objc private func didTapRefresh() {
        analytics.track(.feedRefreshTap, properties: nil)
        Task { await viewModel.refresh() }
    }

    private func bindViewModel() {
        viewModel.onStateChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.tableView.reloadData() }
        }

        viewModel.onError = { [weak self] message in
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "加载失败", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }
}

extension ViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.posts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as? FeedPostCell else {
            return UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        }

        let post = viewModel.posts[indexPath.row]
        cell.configure(
            postID: post.id,
            author: post.author,
            text: post.text,
            imageURLs: post.imageURLs,
            imageLoader: imageLoader,
            analytics: analytics
        )
        return cell
    }
}

extension ViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // 触底分页：当即将展示到接近尾部的 cell 时，请求下一页。
        // 具体“是否需要拉取/是否重复请求”的判断由 ViewModel 内部处理。
        Task { await viewModel.loadNextPageIfNeeded(currentIndex: indexPath.row) }
    }
}

extension ViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // 图片预取：在系统预测用户即将滚动到的 indexPaths 上提前拉取图片，提升首屏命中率。
        // 可通过 FeatureFlag 快速开关，便于灰度与性能对比。
        guard featureFlags.bool(.imagePrefetchEnabled) else { return }

        // 将待预取的 indexPaths 映射为对应的 Post，并展开成需要预取的图片 URL 列表。
        // guard 用于避免预取回调发生时数据源已更新导致的越界访问。
        let urls = indexPaths
            .compactMap { idx -> Post? in
                guard idx.row < viewModel.posts.count else { return nil }
                return viewModel.posts[idx.row]
            }
            .flatMap { $0.imageURLs }

        imageLoader.prefetch(urls: urls, targetPixelSize: CGSize(width: 240, height: 240))
    }
}

