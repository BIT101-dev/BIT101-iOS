import SwiftUI
import UIKit

struct GalleryImageViewerState: Identifiable {
    let id = UUID()
    let images: [GalleryImage]
    let initialIndex: Int
}

/// 全屏图片查看器。
///
/// 负责多图左右切换、沉浸式背景和关闭按钮。
struct GalleryImageViewer: View {
    let viewer: GalleryImageViewerState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(Array(viewer.images.enumerated()), id: \.element.id) { index, image in
                    GalleryZoomableImage(url: URL(string: image.url.isEmpty ? image.lowUrl : image.url))
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                    .padding(20)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            selectedIndex = min(max(viewer.initialIndex, 0), max(viewer.images.count - 1, 0))
        }
    }
}

/// 单张内存图片的全屏查看器。
///
/// 可信成绩单等不应写入远程图片缓存的敏感图片也可以复用话题图片相同的缩放容器。
struct GalleryLocalImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GalleryZoomableImage(image: image)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                    .padding(20)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 基于 `UIScrollView` 的可缩放图片，支持远程 URL 或已在内存中的 `UIImage`。
///
/// SwiftUI 原生 `AsyncImage` 不适合处理缩放和内容居中，这里用 UIKit 桥一层。
struct GalleryZoomableImage: UIViewRepresentable {
    private let url: URL?
    private let image: UIImage?

    init(url: URL?) {
        self.url = url
        image = nil
    }

    init(image: UIImage) {
        url = nil
        self.image = image
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutAwareScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.clipsToBounds = true
        context.coordinator.install(on: scrollView)
        scrollView.onLayout = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let coordinator else { return }
            coordinator.layoutAfterBoundsChange(in: scrollView)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.update(url: url, image: image, in: scrollView)
    }

    /// 本地图片会在 SwiftUI 尚未给出最终尺寸时同步传入；监听 UIKit 布局后再补一次正确排版。
    private final class LayoutAwareScrollView: UIScrollView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        private let imageView = UIImageView()
        private let spinner = UIActivityIndicatorView(style: .large)
        private var currentURL: URL?
        private var task: URLSessionDataTask?
        private var lastLayoutBoundsSize: CGSize = .zero

        /// 安装 UIKit 子视图层级。
        func install(on scrollView: UIScrollView) {
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .clear
            scrollView.addSubview(imageView)

            spinner.color = .white
            spinner.hidesWhenStopped = true
            scrollView.addSubview(spinner)
        }

        func update(url: URL?, image: UIImage?, in scrollView: UIScrollView) {
            spinner.center = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)

            if let image {
                task?.cancel()
                task = nil
                currentURL = nil
                spinner.stopAnimating()
                if imageView.image !== image {
                    imageView.image = image
                    layoutImage(in: scrollView)
                } else if lastLayoutBoundsSize != scrollView.bounds.size {
                    layoutImage(in: scrollView)
                }
                return
            }

            if currentURL != url {
                currentURL = url
                imageView.image = nil
                task?.cancel()
                loadImage(from: url, in: scrollView)
            } else if imageView.image != nil, lastLayoutBoundsSize != scrollView.bounds.size {
                layoutImage(in: scrollView)
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        /// 首次布局及旋转后，用真实的容器尺寸重新计算本地图片 frame。
        func layoutAfterBoundsChange(in scrollView: UIScrollView) {
            guard imageView.image != nil,
                  scrollView.bounds.width > 0,
                  scrollView.bounds.height > 0,
                  lastLayoutBoundsSize != scrollView.bounds.size
            else { return }
            layoutImage(in: scrollView)
        }

        /// 下载远程大图并回填到缩放容器。
        private func loadImage(from url: URL?, in scrollView: UIScrollView) {
            guard let url else { return }
            spinner.startAnimating()

            task = URLSession.shared.dataTask(with: url) { [weak self, weak scrollView] data, _, _ in
                guard let self, let scrollView else { return }
                let image = data.flatMap(UIImage.init(data:))
                DispatchQueue.main.async {
                    self.spinner.stopAnimating()
                    self.imageView.image = image
                    self.layoutImage(in: scrollView)
                }
            }
            task?.resume()
        }

        /// 根据当前图片和容器尺寸重算初始 frame 与 contentSize。
        private func layoutImage(in scrollView: UIScrollView) {
            lastLayoutBoundsSize = scrollView.bounds.size
            scrollView.zoomScale = 1

            guard let image = imageView.image else {
                imageView.frame = scrollView.bounds
                scrollView.contentSize = scrollView.bounds.size
                return
            }

            let boundsSize = scrollView.bounds.size
            let fitSize = aspectFitSize(for: image.size, in: boundsSize)
            imageView.frame = CGRect(origin: .zero, size: fitSize)
            scrollView.contentSize = fitSize
            centerImage(in: scrollView)
        }

        /// 在缩放或容器尺寸变化后重新把图片居中。
        private func centerImage(in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame

            frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) / 2 : 0
            frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) / 2 : 0

            imageView.frame = frame
        }

        /// 计算图片在当前容器中的 aspect-fit 尺寸。
        private func aspectFitSize(for imageSize: CGSize, in boundsSize: CGSize) -> CGSize {
            guard imageSize.width > 0, imageSize.height > 0, boundsSize.width > 0, boundsSize.height > 0 else {
                return boundsSize
            }

            let widthRatio = boundsSize.width / imageSize.width
            let heightRatio = boundsSize.height / imageSize.height
            let scale = min(widthRatio, heightRatio)

            return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }
    }
}

/// 帖子时间文本格式化工具。
///
/// 服务端历史上使用过多种时间格式，这里集中做兼容，避免每个视图各自维护
/// 一套 `DateFormatter`。
enum GalleryDateDecoder {
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return iso8601Formatter.date(from: string)
    }

    static func relativeText(from string: String, fallback: String) -> String {
        guard let date = date(from: string) else {
            return fallback
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}

/// 兼容服务端返回的十六进制颜色字符串。
extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
