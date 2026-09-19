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
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var deletedPosterIDs: Set<Int> = []
    @State private var currentTopPosterID: Int?
    @State private var pendingRestorePosterID: Int?
    @State private var lastPrefetchTriggerPosterID: Int?
    @State private var reportTarget: GalleryReportTarget?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isInitialLoading {
                    galleryPlaceholderContainer {
                        AppInlineLoadingState("正在加载话廊")
                    }
                } else if case let .failed(message) = feedState.status, visiblePosters.isEmpty {
                    galleryPlaceholderContainer {
                        AppFailureState(
                            title: "加载失败",
                            systemImage: "exclamationmark.triangle",
                            message: message,
                            onRetry: onRefresh
                        )
                    }
                } else if visiblePosters.isEmpty {
                    galleryPlaceholderContainer {
                        AppEmptyState(
                            title: feedIdentity == "search" ? "没有找到相关话题" : "暂无话题",
                            systemImage: "bubble.left.and.bubble.right",
                            message: feedIdentity == "search" ? "换个关键词试试。" : "当前分区还没有可展示的话题。"
                        )
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            AppFeedRow(isLast: index == visiblePosters.count - 1) {
                                GalleryPosterCard(
                                    poster: poster,
                                    onOpenPoster: { selectedPoster = poster },
                                    onOpenImage: { index, images in
                                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                    },
                                    onDelete: nil,
                                    onReport: { reportTarget = .poster(poster.id) }
                                )
                            }
                            .id(poster.id)
                            .onAppear {
                                if poster.id == prefetchTriggerPosterID,
                                   lastPrefetchTriggerPosterID != poster.id {
                                    lastPrefetchTriggerPosterID = poster.id
                                    onPrefetch(poster)
                                }
                                guard poster.id == visiblePosters.last?.id else { return }
                                onLoadMore(poster)
                            }
                        }

                        if feedState.isLoadingMore {
                            AppInlineLoadingState()
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            // 系统滚动定位在顶部目标发生变化时更新一次；卡片复用统一定位状态。
            .scrollPosition(id: $currentTopPosterID, anchor: .top)
            .background(AppDesignSystem.Palette.groupedBackground)
            .id(feedIdentity)
            .refreshable {
                pendingRestorePosterID = currentTopPosterID ?? visiblePosters.first?.id
                onRefresh()
            }
            .onChange(of: visiblePosterIDs) { _, newIDs in
                restoreScrollPositionIfNeeded(with: proxy, availableIDs: newIDs)
            }
            .navigationDestination(item: $selectedPoster) { poster in
                GalleryPosterDetailView(
                    poster: poster,
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        onRefresh()
                    }
                )
            }
            .gallerySystemImagePreview(item: $imageViewer)
            .sheet(item: $reportTarget) { target in
                GalleryReportSheet(target: target) {}
            }
        }
    }

    /// 加载中和失败空态也放进统一滚动容器里，保证始终可以下拉刷新。
    @ViewBuilder
    private func galleryPlaceholderContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        AppScrollStateContainer(content: content)
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
    /// 预取负责后台准备下一页；列表追加由末尾触发，滚动条比例和当前位置保持稳定。
    private var prefetchTriggerPosterID: Int? {
        guard prefetchTriggerThreshold > 0, !visiblePosters.isEmpty else { return nil }
        return visiblePosters[max(visiblePosters.count - prefetchTriggerThreshold, 0)].id
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

}

/// 单个帖子卡片。
///
/// 帖子点击进入详情，图片点击进入全屏看图，二者需要显式拆开避免手势冲突。
struct GalleryPosterCard: View {
    let poster: GalleryPoster
    let onOpenPoster: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onDelete: (() -> Void)?
    let onReport: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.control) {
            Text(poster.title)
                .font(AppDesignSystem.Typography.headline)
                .foregroundStyle(AppDesignSystem.Palette.highlight)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppDesignSystem.Spacing.control) {
                AppAvatarView(imageURL: URL(string: poster.user.avatar.lowUrl.isEmpty ? poster.user.avatar.url : poster.user.avatar.lowUrl))

                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                    HStack(spacing: AppDesignSystem.Spacing.tight) {
                        Text(poster.user.nickname)
                            .font(AppDesignSystem.Typography.bodyEmphasis)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !poster.user.identity.text.isEmpty {
                            Text(poster.user.identity.text)
                                .font(AppDesignSystem.Typography.caption2Medium)
                                .padding(.horizontal, AppDesignSystem.Spacing.tight)
                                .padding(.vertical, AppDesignSystem.Spacing.micro)
                                .background(identityColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(identityColor)
                        }
                    }

                    if !poster.user.motto.isEmpty {
                        Text(poster.user.motto)
                            .font(AppDesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if onDelete != nil || onReport != nil {
                    GalleryPosterActionMenu(
                        onDelete: onDelete,
                        onReport: onReport
                    )
                    // 右上角菜单需要吞掉点击，避免父卡片的 onTapGesture 同时触发进详情。
                    .contentShape(Rectangle())
                    .onTapGesture { }
                }
            }

            Text(galleryLinkifiedText(poster.text))
                .font(AppDesignSystem.Typography.body)
                .lineLimit(poster.images.count <= 2 ? 4 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !poster.images.isEmpty {
                GalleryPosterImagesView(images: poster.images, onOpenImage: onOpenImage)
            }

            HStack(spacing: AppDesignSystem.Spacing.control) {
                Label("\(poster.likeNum)", systemImage: "hand.thumbsup")
                Label("\(poster.commentNum)", systemImage: "bubble.right")

                if !poster.public {
                    Label("仅自己可见", systemImage: "eye.slash")
                }

                Spacer()

                Text(relativeTimeText(poster.editTime))
            }
            .font(AppDesignSystem.Typography.caption)
            .foregroundStyle(.secondary)

            if !poster.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        ForEach(poster.tags, id: \.self) { tag in
                            AppTagChip(title: tag, variant: .display)
                        }
                    }
                }
            }
        }
        .appFeedCardStyle()
        .onTapGesture(perform: onOpenPoster)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开帖子")
    }

    private var identityColor: Color {
        Color(hex: poster.user.identity.color) ?? AppDesignSystem.Palette.highlight
    }

    /// 把后端时间文本转成相对时间文案。
    private func relativeTimeText(_ string: String) -> String {
        AppDateText.relativeText(from: string, fallback: "未知")
    }
}

/// 帖子图片网格。
///
/// 图片组使用单行比例格带，基础格保持竖向 1:√2。
struct GalleryPosterImagesView: View {
    private struct Allocation: Identifiable {
        let index: Int
        let width: CGFloat

        var id: Int { index }
    }

    private struct LayoutPlan {
        let allocations: [Allocation]
        let hiddenImageCount: Int
    }

    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void
    @State private var imageAspectRatios: [Int: CGFloat] = [:]

    var body: some View {
        GeometryReader { proxy in
            let spacing = AppDesignSystem.Spacing.tight
            let plan = layoutPlan(in: proxy.size, spacing: spacing)

            HStack(spacing: spacing) {
                ForEach(plan.allocations) { allocation in
                    Button {
                        onOpenImage(allocation.index, images)
                    } label: {
                        ZStack {
                            GalleryPosterThumbnail(
                                image: images[allocation.index],
                                contentMode: .fill,
                                onAspectRatioResolved: { ratio in
                                    guard ratio > 0, imageAspectRatios[allocation.index] != ratio else { return }
                                    imageAspectRatios[allocation.index] = ratio
                                }
                            )

                            if allocation.index == plan.allocations.last?.index,
                               plan.hiddenImageCount > 0 {
                                Color.black.opacity(AppDesignSystem.Gallery.overflowOverlayOpacity)
                                Text("+\(plan.hiddenImageCount)")
                                    .font(AppDesignSystem.Typography.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: allocation.width, height: proxy.size.height)
                        .clipped()
                        .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看第\(allocation.index + 1)张图片")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(
            .vertical,
            count: AppDesignSystem.Gallery.thumbnailHeightContainerCount,
            spacing: AppDesignSystem.Spacing.none
        )
        .onChange(of: images) { _, _ in
            imageAspectRatios = [:]
        }
    }

    private func layoutPlan(in size: CGSize, spacing: CGFloat) -> LayoutPlan {
        guard !images.isEmpty, size.width > 0, size.height > 0 else {
            return LayoutPlan(allocations: [], hiddenImageCount: 0)
        }

        let targetRatio = AppDesignSystem.Gallery.thumbnailPortraitAspectRatio
        let targetWidth = size.height * targetRatio
        let estimatedCount = max((size.width + spacing) / max(targetWidth + spacing, 1), 1)
        let lowerCount = max(Int(floor(estimatedCount)), 1)
        let upperCount = max(Int(ceil(estimatedCount)), 1)
        let candidateCounts = lowerCount == upperCount ? [lowerCount] : [lowerCount, upperCount]
        let divisionCount = candidateCounts.min { lhs, rhs in
            divisionError(
                count: lhs,
                width: size.width,
                height: size.height,
                spacing: spacing,
                targetRatio: targetRatio
            ) < divisionError(
                count: rhs,
                width: size.width,
                height: size.height,
                spacing: spacing,
                targetRatio: targetRatio
            )
        } ?? 1
        let cellWidth = max(
            (size.width - CGFloat(divisionCount - 1) * spacing) / CGFloat(divisionCount),
            1
        )

        var remainingCells = divisionCount
        var allocations: [Allocation] = []
        for index in images.indices where remainingCells > 0 {
            let imageRatio = imageAspectRatios[index] ?? targetRatio
            let span = (1 ... remainingCells).min { lhs, rhs in
                spanError(
                    span: lhs,
                    imageRatio: imageRatio,
                    cellWidth: cellWidth,
                    height: size.height,
                    spacing: spacing
                ) < spanError(
                    span: rhs,
                    imageRatio: imageRatio,
                    cellWidth: cellWidth,
                    height: size.height,
                    spacing: spacing
                )
            } ?? 1
            let width = CGFloat(span) * cellWidth + CGFloat(span - 1) * spacing
            allocations.append(Allocation(index: index, width: width))
            remainingCells -= span
        }

        return LayoutPlan(
            allocations: allocations,
            hiddenImageCount: max(images.count - allocations.count, 0)
        )
    }

    private func divisionError(
        count: Int,
        width: CGFloat,
        height: CGFloat,
        spacing: CGFloat,
        targetRatio: CGFloat
    ) -> CGFloat {
        let cellWidth = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
        let ratio = max(cellWidth / height, 0.001)
        return abs(log(ratio / targetRatio))
    }

    private func spanError(
        span: Int,
        imageRatio: CGFloat,
        cellWidth: CGFloat,
        height: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let occupiedWidth = CGFloat(span) * cellWidth + CGFloat(span - 1) * spacing
        let occupiedRatio = max(occupiedWidth / height, 0.001)
        return abs(log(occupiedRatio / max(imageRatio, 0.001)))
    }
}

/// 单张帖子图片缩略图。
struct GalleryPosterThumbnail: View {
    let image: GalleryImage
    private let width: CGFloat?
    private let maxHeight: CGFloat?
    private let aspectRatio: CGFloat?
    private let contentMode: ContentMode
    private let loadsOriginal: Bool
    private let onAspectRatioResolved: ((CGFloat) -> Void)?

    init(
        image: GalleryImage,
        contentMode: ContentMode = .fit,
        loadsOriginal: Bool = false,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    ) {
        self.image = image
        width = nil
        maxHeight = nil
        aspectRatio = nil
        self.contentMode = contentMode
        self.loadsOriginal = loadsOriginal
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    /// 保留课程评论原有尺寸语义；话廊图片使用上面的自适应初始化器。
    init(image: GalleryImage, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) {
        self.image = image
        self.width = width
        self.maxHeight = maxHeight
        self.aspectRatio = aspectRatio
        contentMode = .fit
        loadsOriginal = false
        onAspectRatioResolved = nil
    }

    var body: some View {
        if let aspectRatio {
            thumbnailContent
                .frame(maxWidth: width == nil ? .infinity : width)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(width: width)
                .frame(maxHeight: maxHeight)
                .clipped()
        } else {
            thumbnailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        Group {
            if let animatedURL {
                GalleryAutoplayingImage(url: animatedURL, contentMode: contentMode)
            } else if loadsOriginal, let originalURL {
                GalleryProgressiveStillImage(
                    thumbnailURL: thumbnailURL,
                    originalURL: originalURL,
                    contentMode: contentMode,
                    onAspectRatioResolved: onAspectRatioResolved
                )
            } else {
                GalleryCachedStillImage(
                    url: thumbnailURL,
                    contentMode: contentMode,
                    onAspectRatioResolved: onAspectRatioResolved
                )
            }
        }
    }

    private var thumbnailURL: URL? {
        URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)
    }

    private var originalURL: URL? {
        URL(string: image.url.isEmpty ? image.lowUrl : image.url)
    }

    /// 动图必须读取原文件；服务端生成的 lowUrl 通常只是静态缩略图。
    private var animatedURL: URL? {
        guard let url = URL(string: image.url), url.pathExtension.lowercased() == "gif" else {
            return nil
        }
        return url
    }

}
