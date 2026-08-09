//
//  GalleryFeedViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GalleryFeedView: View {
    let feedState: GalleryFeedState
    let feedIdentity: String
    let prefetchTriggerThreshold: Int
    let onRefresh: () -> Void
    let onPrefetch: (GalleryPoster?) -> Void
    let onLoadMore: (GalleryPoster?) -> Void
    @ObservedObject private var settings = AppSettingsStore.shared
    private let reportService = CommunityReportService()
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var reportContext: GalleryReportContext?
    @State private var deletedPosterIDs: Set<Int> = []
    @State private var currentTopPosterID: Int?
    @State private var pendingRestorePosterID: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isInitialLoading {
                    galleryPlaceholderContainer {
                        ProgressView("正在加载话廊")
                    }
                } else if case let .failed(message) = feedState.status, feedState.posters.isEmpty {
                    galleryPlaceholderContainer {
                        ContentUnavailableView {
                            Label("加载失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("重试") {
                                onRefresh()
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            VStack(spacing: 0) {
                                GalleryPosterCard(
                                    poster: poster,
                                    onOpenPoster: { selectedPoster = poster },
                                    onOpenImage: { index, images in
                                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                    },
                                    onReport: { action in
                                        reportContext = GalleryReportContext(poster: poster, action: action)
                                    },
                                    onDelete: nil
                                )

                                if index != visiblePosters.count - 1 {
                                    Divider()
                                        .padding(.leading, 14)
                                }
                            }
                            .id(poster.id)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: GalleryVisiblePosterOffsetPreferenceKey.self,
                                        value: [poster.id: geometry.frame(in: .named(feedScrollSpaceName)).minY]
                                    )
                                }
                            )
                            .onAppear {
                                if prefetchTriggerPosterIDs.contains(poster.id) {
                                    onPrefetch(poster)
                                }
                                guard poster.id == visiblePosters.last?.id else { return }
                                onLoadMore(poster)
                            }
                        }

                        if feedState.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .coordinateSpace(name: feedScrollSpaceName)
            .background(Color(.systemGroupedBackground))
            .id(feedIdentity)
            .refreshable {
                pendingRestorePosterID = currentTopPosterID ?? visiblePosters.first?.id
                onRefresh()
            }
            .onPreferenceChange(GalleryVisiblePosterOffsetPreferenceKey.self) { offsets in
                currentTopPosterID = topVisiblePosterID(from: offsets)
            }
            .onChange(of: visiblePosterIDs) { _, newIDs in
                restoreScrollPositionIfNeeded(with: proxy, availableIDs: newIDs)
            }
            .background(Color(.systemGroupedBackground))
            .navigationDestination(item: $selectedPoster) { poster in
                GalleryPosterDetailView(
                    poster: poster,
                    onReport: { _ in },
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        onRefresh()
                    }
                )
            }
            .fullScreenCover(item: $imageViewer) { viewer in
                GalleryImageViewer(viewer: viewer)
            }
            .sheet(item: $reportContext) { context in
                CommunityReportSheet(context: context) { type, note in
                    applyReport(context, type: type, note: note)
                }
            }
        }
    }

    /// 加载中和失败空态也放进统一滚动容器里，保证始终可以下拉刷新。
    @ViewBuilder
    private func galleryPlaceholderContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 120)
            content()
            Spacer(minLength: 240)
        }
        .frame(maxWidth: .infinity)
    }

    /// 首屏空态下是否应该显示中央加载指示器。
    private var isInitialLoading: Bool {
        switch feedState.status {
        case .idle, .loading:
            return visiblePosters.isEmpty
        default:
            return false
        }
    }

    /// 当前真正可见的帖子列表。
    ///
    /// 删帖成功后会先做本地移除，再等待上层刷新；因此这里要叠加一层
    /// `deletedPosterIDs` 过滤，保证体感上帖子会立刻消失。
    private var visiblePosters: [GalleryPoster] {
        feedState.posters.filter { !deletedPosterIDs.contains($0.id) }
    }

    private var visiblePosterIDs: [Int] {
        visiblePosters.map(\.id)
    }

    /// 进入可见列表尾部若干条时触发的预取集合。
    ///
    /// 预取只负责后台准备下一页，不直接把数据拼到列表里，这样可以降低滚动条比例
    /// 和当前位置突然变化带来的“跳走”感。
    private var prefetchTriggerPosterIDs: Set<Int> {
        guard prefetchTriggerThreshold > 0 else { return [] }
        return Set(visiblePosters.suffix(prefetchTriggerThreshold).map(\.id))
    }

    /// 当前 feed 独立的滚动坐标空间名称。
    private var feedScrollSpaceName: String {
        "GalleryFeedScroll-\(feedIdentity)"
    }

    /// 根据偏移字典推断当前位于屏幕顶部附近的帖子。
    ///
    /// 算法选择“距离 0 最近的 minY”，这样不需要真正知道可见区域高度，
    /// 也能粗略定位用户当时正在阅读哪一条。
    private func topVisiblePosterID(from offsets: [Int: CGFloat]) -> Int? {
        guard !offsets.isEmpty else { return currentTopPosterID }

        return offsets.min { lhs, rhs in
            let lhsDistance = abs(lhs.value)
            let rhsDistance = abs(rhs.value)
            if lhsDistance == rhsDistance {
                return lhs.value < rhs.value
            }
            return lhsDistance < rhsDistance
        }?.key
    }

    /// 刷新完成后，把滚动位置尽量恢复到刷新前的顶部帖子。
    ///
    /// 如果原帖子还在，就精确恢复；如果已经不在当前列表里，则退回到当前列表第一条，
    /// 至少避免页面直接跳到完全不可预期的位置。
    private func restoreScrollPositionIfNeeded(with proxy: ScrollViewProxy, availableIDs: [Int]) {
        guard let pendingRestorePosterID else { return }

        if availableIDs.contains(pendingRestorePosterID) {
            DispatchQueue.main.async {
                scrollToTopPoster(pendingRestorePosterID, with: proxy)
                self.pendingRestorePosterID = nil
            }
        } else if let fallbackID = availableIDs.first {
            DispatchQueue.main.async {
                scrollToTopPoster(fallbackID, with: proxy)
                self.pendingRestorePosterID = nil
            }
        } else {
            self.pendingRestorePosterID = nil
        }
    }

    /// 无动画滚回指定帖子顶部。
    ///
    /// 这里禁用动画是有意的：刷新完成后的补位应该尽量“静默”，否则用户会明显感知到
    /// 页面被强行滚动。
    private func scrollToTopPoster(_ posterID: Int, with proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(posterID, anchor: .top)
        }
    }

    /// 应用“举报并隐藏 / 举报并屏蔽用户”的本地治理动作，再异步上报。
    private func applyReport(_ context: GalleryReportContext, type: CommunityReportType, note: String) {
        applyGalleryModerationAction(context, type: type, note: note, settings: settings, reportService: reportService)
    }
}

/// 单个帖子卡片。
///
/// 帖子点击进入详情，图片点击进入全屏看图，二者需要显式拆开避免手势冲突。
struct GalleryPosterCard: View {
    let poster: GalleryPoster
    let onOpenPoster: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onReport: ((CommunityReportAction) -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(poster.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                GalleryAvatarView(imageURL: URL(string: poster.user.avatar.lowUrl.isEmpty ? poster.user.avatar.url : poster.user.avatar.lowUrl))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(poster.user.nickname)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !poster.user.identity.text.isEmpty {
                            Text(poster.user.identity.text)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(identityColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(identityColor)
                        }
                    }

                    if !poster.user.motto.isEmpty {
                        Text(poster.user.motto)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if onReport != nil || onDelete != nil {
                    GalleryPosterActionMenu(
                        onSelectAction: onReport,
                        onDelete: onDelete
                    )
                    // 右上角菜单需要吞掉点击，避免父卡片的 onTapGesture 同时触发进详情。
                    .contentShape(Rectangle())
                    .onTapGesture { }
                }
            }

            Text(poster.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(poster.images.count <= 2 ? 4 : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !poster.images.isEmpty {
                GalleryPosterImagesView(images: poster.images, onOpenImage: onOpenImage)
            }

            HStack(spacing: 10) {
                Label("\(poster.likeNum)", systemImage: "hand.thumbsup")
                Label("\(poster.commentNum)", systemImage: "bubble.right")

                if !poster.public {
                    Label("仅自己可见", systemImage: "eye.slash")
                }

                Spacer()

                Text(relativeTimeText(poster.editTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !poster.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(poster.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenPoster)
    }

    private var identityColor: Color {
        Color(hex: poster.user.identity.color) ?? .orange
    }

    /// 把后端时间文本转成相对时间文案。
    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知")
    }
}

/// 帖子作者头像。
///
/// 头像统一走 `CachedRemoteImage`，避免频繁出现在信息流里的用户头像每次冷启动都重新下载。
struct GalleryAvatarView: View {
    let imageURL: URL?

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "person.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.bold))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }
}

/// 帖子图片网格。
///
/// 这里故意按图片数量做三套布局，而不是一律九宫格：
/// - 1 张图时尽量给更大的阅读空间
/// - 2 张图时用并排双列
/// - 3 张及以上再退回网格
struct GalleryPosterImagesView: View {
    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void

    var body: some View {
        let displayedImages = images.count <= 2 ? images : Array(images.prefix(images.count == 3 ? 3 : 4))

        if displayedImages.count == 1 {
            thumbnailButton(image: displayedImages[0], index: 0, width: 180, maxHeight: 220, aspectRatio: 1)
        } else if displayedImages.count == 2 {
            HStack(spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 150, aspectRatio: 1)
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(displayedImages.count, 4)), spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 78, aspectRatio: 1)
                }
            }
        }
    }

    private func thumbnailButton(image: GalleryImage, index: Int, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) -> some View {
        Button {
            onOpenImage(index, images)
        } label: {
            GalleryPosterThumbnail(
                image: image,
                width: width,
                maxHeight: maxHeight,
                aspectRatio: aspectRatio
            )
        }
        .buttonStyle(.plain)
    }
}

/// 单张帖子图片缩略图。
struct GalleryPosterThumbnail: View {
    let image: GalleryImage
    let width: CGFloat?
    let maxHeight: CGFloat?
    let aspectRatio: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)) { phase in
            switch phase {
            case let .success(renderedImage):
                renderedImage
                    .resizable()
                    .scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.orange)
                    }
            }
        }
        .frame(maxWidth: width == nil ? .infinity : width)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 帖子详情页。
///
/// 详情页是一个相对完整的“二级页面壳层”：
/// - 顶部帖子正文和互动按钮
/// - 评论列表与排序
/// - 举报、删帖、看图、评论输入
/// - 点击作者或评论作者跳到用户主页
