//
//  ViewController.swift
//  FeaturedPosts
//
//  Created by maochengfang on 2026/6/24.
//

import UIKit

final class ViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateLabel = UILabel()
    private let viewModel: FeedViewModel
    private let imageLoader: ImageLoading
    private let featureFlags: FeatureFlagProviding
    private let analytics: AnalyticsTracking
    private var prefetchTokensByIndexPath: [IndexPath: [UUID]] = [:]
    private var currentEmptyMessage: String?

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

        emptyStateLabel.font = .systemFont(ofSize: 15)
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.isHidden = true

        view.addSubview(tableView)
        view.addSubview(emptyStateLabel)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
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
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.viewModel.posts.isEmpty { self.currentEmptyMessage = nil }
                self.prefetchTokensByIndexPath.removeAll()
                self.tableView.reloadData()
                self.updateEmptyState()
            }
        }

        viewModel.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.currentEmptyMessage = message
                self?.updateEmptyState()

                let alert = UIAlertController(title: "加载失败", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }

    private func updateEmptyState() {
        let shouldShowEmpty = viewModel.posts.isEmpty
        emptyStateLabel.isHidden = !shouldShowEmpty
        emptyStateLabel.text = currentEmptyMessage ?? "暂无内容"
        tableView.isHidden = shouldShowEmpty
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

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? FeedPostCell)?.cancelImageLoading()
        prefetchTokensByIndexPath.removeValue(forKey: indexPath)?.forEach { imageLoader.cancelLoad($0) }
    }
}

extension ViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // 图片预取：在系统预测用户即将滚动到的 indexPaths 上提前拉取图片，提升首屏命中率。
        // 可通过 FeatureFlag 快速开关，便于灰度与性能对比。
        guard featureFlags.bool(.imagePrefetchEnabled) else { return }

        // guard 用于避免预取回调发生时数据源已更新导致的越界访问。
        prefetchTokensByIndexPath.merge(
            indexPaths.reduce(into: [IndexPath: [UUID]]()) { partial, idx in
                guard idx.row < viewModel.posts.count else { return }
                partial[idx] = imageLoader.prefetch(
                    urls: viewModel.posts[idx.row].imageURLs,
                    targetPixelSize: CGSize(width: 360, height: 360)
                )
            },
            uniquingKeysWith: { _, new in new }
        )
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let tokens = prefetchTokensByIndexPath.removeValue(forKey: indexPath) else { continue }
            tokens.forEach { imageLoader.cancelLoad($0) }
        }
    }
}

