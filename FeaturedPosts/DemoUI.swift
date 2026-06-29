import UIKit
import PhotosUI

/// Feed 列表单元格。
/// 负责帖子文案与最多 3 张图片的展示，并在复用时取消旧图片任务避免错图。
final class FeedPostCell: UITableViewCell {
    static let reuseIdentifier = "FeedPostCell"

    private let authorLabel = UILabel()
    private let bodyLabel = UILabel()
    private let stackView = UIStackView()

    private var stackViewHeightConstraint: NSLayoutConstraint?

    private var imageViews: [UIImageView] = []
    private var loadTokens: [UUID] = []
    private var imageLoader: ImageLoading?
    private var lastPostID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none

        authorLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        authorLabel.textColor = .label

        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.distribution = .fillEqually
        stackView.alignment = .fill
        stackView.isHidden = true

        stackViewHeightConstraint = stackView.heightAnchor.constraint(equalToConstant: 120)
        stackViewHeightConstraint?.isActive = false

        let container = UIStackView(arrangedSubviews: [authorLabel, bodyLabel, stackView])
        container.axis = .vertical
        container.spacing = 10

        contentView.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Cell 复用前清理旧的加载任务与图片内容，避免异步回调把旧图刷到新 cell 上。
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelImageLoading()
        imageViews.forEach { $0.image = nil }
        lastPostID = nil
    }

    func cancelImageLoading() {
        if let loader = imageLoader {
            for t in loadTokens {
                loader.cancelLoad(t)
            }
        }
        loadTokens.removeAll()
    }

    /// 绑定帖子数据并触发图片加载。
    /// 图片成功/失败都会记录埋点，用于观察加载质量。
    func configure(postID: String, author: String, text: String, imageURLs: [URL], imageLoader: ImageLoading, analytics: AnalyticsTracking) {
        self.imageLoader = imageLoader
        authorLabel.text = author
        bodyLabel.text = text

        if lastPostID != postID {
            lastPostID = postID
            analytics.track(.feedImpression, properties: ["post_id": postID])
        }

        let urls = Array(imageURLs.prefix(3))
        ensureImageViews(count: urls.count)

        for (idx, url) in urls.enumerated() {
            let iv = imageViews[idx]
            iv.image = nil

            let token = imageLoader.loadImage(url: url, targetPixelSize: CGSize(width: 360, height: 360)) { [weak iv] result in
                guard let iv else { return }
                switch result {
                case let .success(img):
                    iv.image = img
                    analytics.track(.imageLoadSuccess, properties: ["post_id": postID])
                case .failure:
                    analytics.track(.imageLoadFailure, properties: ["post_id": postID])
                }
            }
            loadTokens.append(token)
        }
    }

    private func ensureImageViews(count: Int) {
        if imageViews.count > count {
            for _ in count..<imageViews.count {
                let v = imageViews.removeLast()
                stackView.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
        } else if imageViews.count < count {
            for _ in imageViews.count..<count {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.backgroundColor = UIColor.secondarySystemBackground
                iv.layer.cornerRadius = 10
                iv.layer.masksToBounds = true
                iv.setContentHuggingPriority(.defaultLow, for: .vertical)
                iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                imageViews.append(iv)
                stackView.addArrangedSubview(iv)
            }
        }
        stackView.isHidden = (count == 0)
        stackViewHeightConstraint?.isActive = (count != 0)
    }
}

/// 发布页面的业务编排层。
/// 负责选图状态、发布开关、上传进度、文案校验与并发上传控制。
@MainActor
final class PublishViewModel {
    /// 面向 UI 的最小状态快照，避免 VC 直接读取内部业务字段。
    struct State {
        var selectedCount: Int
        var maxImages: Int
        var isPublishV2Enabled: Bool
        var isUploading: Bool
        var statusText: String

        var countText: String {
            "图片：\(selectedCount)/\(maxImages)  发布V2：\(isPublishV2Enabled ? "ON" : "OFF")"
        }
    }

    private let uploader: JPEGUploading
    private let compressor: JPEGCompressing
    private let validator: PublishValidator
    private let featureFlags: FeatureFlagProviding
    private let analytics: AnalyticsTracking

    private var selectedImages: [UIImage] = []

    var onStateChanged: ((State) -> Void)?

    private(set) var state: State {
        didSet { onStateChanged?(state) }
    }

    init(uploader: JPEGUploading, compressor: JPEGCompressing, validator: PublishValidator, featureFlags: FeatureFlagProviding, analytics: AnalyticsTracking) {
        self.uploader = uploader
        self.compressor = compressor
        self.validator = validator
        self.featureFlags = featureFlags
        self.analytics = analytics
        self.state = State(
            selectedCount: 0,
            maxImages: validator.maxImages,
            isPublishV2Enabled: featureFlags.bool(.publishV2Enabled),
            isUploading: false,
            statusText: ""
        )
    }

    func toggleRollback() {
        let enabled = featureFlags.bool(.publishV2Enabled)
        featureFlags.set(!enabled, for: .publishV2Enabled)
        state.isPublishV2Enabled = featureFlags.bool(.publishV2Enabled)
    }

    func setSelectedImages(_ images: [UIImage]) {
        selectedImages = images
        state.selectedCount = images.count
        state.statusText = "已选择 \(images.count) 张"
    }

    func didTapPickImages() {
        analytics.track(.publishPickImages, properties: nil)
    }

    /// 执行发布：先做开关与参数校验，再并发压缩上传，并持续回写进度状态。
    func upload(text: String) async {
        analytics.track(.publishTapUpload, properties: ["count": selectedImages.count])

        guard featureFlags.bool(.publishV2Enabled) else {
            analytics.track(.publishRollbackDisabled, properties: nil)
            state.statusText = "已回滚：PublishV2 关闭"
            return
        }

        do {
            try validator.validate(text: text, imagesCount: selectedImages.count)
        } catch {
            state.statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        state.isUploading = true
        state.statusText = "压缩中…"

        do {
            let semaphore = AsyncSemaphore(value: 3)
            var uploaded: [URL] = []

            try await withThrowingTaskGroup(of: URL.self) { group in
                for (idx, img) in selectedImages.enumerated() {
                    group.addTask { [uploader, compressor] in
                        await semaphore.wait()
                        do {
                            let jpeg = try compressor.compressToJPEG(image: img, maxByteSize: 300 * 1024, targetMaxPixel: 1600)
                            let url = try await uploader.uploadJPEG(jpeg, filename: "img_\(idx).jpg")
                            await semaphore.signal()
                            return url
                        } catch {
                            await semaphore.signal()
                            throw error
                        }
                    }
                }

                for try await u in group {
                    uploaded.append(u)
                    state.statusText = "上传中… \(uploaded.count)/\(selectedImages.count)"
                }
            }

            state.isUploading = false
            state.statusText = "上传成功：\(uploaded.count) 张"
            analytics.track(.publishUploadSuccess, properties: ["count": uploaded.count])
        } catch {
            state.isUploading = false
            state.statusText = "上传失败：\(error.localizedDescription)"
            analytics.track(.publishUploadFailure, properties: nil)
        }
    }
}

/// 发布页控制器。
/// 只负责 UIKit 视图搭建、用户交互转发与 ViewModel 状态绑定，不承载具体业务逻辑。
final class NotePublishViewController: UIViewController {
    private let viewModel: PublishViewModel

    private let textView = UITextView()
    private let countLabel = UILabel()
    private let pickButton = UIButton(type: .system)
    private let uploadButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    init(viewModel: PublishViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "发布"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "回滚", style: .plain, target: self, action: #selector(toggleRollback))

        textView.font = .systemFont(ofSize: 16)
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.cornerRadius = 10
        textView.text = "写点什么吧…"

        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabel

        pickButton.setTitle("选择图片", for: .normal)
        pickButton.addTarget(self, action: #selector(pickImages), for: .touchUpInside)

        uploadButton.setTitle("开始上传", for: .normal)
        uploadButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        uploadButton.addTarget(self, action: #selector(uploadTapped), for: .touchUpInside)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        let vstack = UIStackView(arrangedSubviews: [textView, countLabel, pickButton, uploadButton, statusLabel])
        vstack.axis = .vertical
        vstack.spacing = 12

        view.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            vstack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            vstack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.heightAnchor.constraint(equalToConstant: 180)
        ])

        bindViewModel()
        apply(state: viewModel.state)
    }

    private func bindViewModel() {
        viewModel.onStateChanged = { [weak self] state in
            self?.apply(state: state)
        }
    }

    /// 将 VM 输出状态映射到界面控件。
    private func apply(state: PublishViewModel.State) {
        countLabel.text = state.countText
        statusLabel.text = state.statusText
        uploadButton.isEnabled = !state.isUploading
    }

    @objc private func toggleRollback() {
        viewModel.toggleRollback()
    }

    @objc private func pickImages() {
        viewModel.didTapPickImages()

        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = viewModel.state.maxImages
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func uploadTapped() {
        let text = textView.text ?? ""
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.upload(text: text)
        }
    }
}

/// 处理系统照片选择器回调。
/// 多个 provider 的回调可能并发返回，因此使用锁保护临时数组写入。
extension NotePublishViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)

        let providers = results.map(\.itemProvider)
        guard !providers.isEmpty else { return }

        var images: [UIImage] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for p in providers {
            guard p.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            _ = p.loadObject(ofClass: UIImage.self) { obj, _ in
                defer { group.leave() }
                if let img = obj as? UIImage {
                    lock.lock()
                    images.append(img)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.viewModel.setSelectedImages(images)
        }
    }
}

