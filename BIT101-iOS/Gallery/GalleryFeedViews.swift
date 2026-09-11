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
                .font(.headline)
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
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, AppDesignSystem.Spacing.tight)
                                .padding(.vertical, AppDesignSystem.Spacing.micro)
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
            .font(.caption)
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
/// 首页最多展示四张图，图片组使用等高横向布局；单图根据原图比例在整行或半行宽度中
/// 选择裁切利用率更高的尺寸。
///
/// 多图时各图片等宽排列，每张图中心裁切填满格子；原始比例仍由点开后的系统预览完整呈现。
struct GalleryPosterImagesView: View {
    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void
    @State private var singleImageAspectRatio: CGFloat?

    var body: some View {
        let displayedImages = Array(images.prefix(4))

        GeometryReader { proxy in
            let spacing = AppDesignSystem.Spacing.tight
            let count = max(displayedImages.count, 1)
            let totalSpacing = spacing * CGFloat(count - 1)
            let equalItemWidth = max((proxy.size.width - totalSpacing) / CGFloat(count), 0)
            let itemWidth = displayedImages.count == 1
                ? preferredSingleImageWidth(in: proxy.size)
                : equalItemWidth

            HStack(spacing: spacing) {
                // 同一帖子内的图片 `mid` 偶尔可能为空或重复，不能拿它作为拼贴格子的
                // SwiftUI 身份，否则双图会被合并成一个视图。索引在当前前四张内稳定且唯一。
                ForEach(Array(displayedImages.enumerated()), id: \.offset) { index, image in
                    thumbnailButton(
                        image: image,
                        index: index,
                        reportsAspectRatio: displayedImages.count == 1
                    )
                        .frame(width: itemWidth, height: proxy.size.height)
                        // 必须在最终格子尺寸确定后裁切。若先裁切再设宽度，图片内容仍会
                        // 按自身理想尺寸绘制到相邻格子，表现为多图互相覆盖。
                        .clipped()
                        .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        // 图片组横向铺满卡片，高度占外层容器的四分之一。
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical, count: 4, spacing: AppDesignSystem.Spacing.none)
    }

    /// 单图在“整行”和“双图单格”两种常用尺寸中选择裁切利用率更高的一种。
    /// 利用率表示中心裁切后仍能保留的原图面积比例，范围为 0...1。
    private func preferredSingleImageWidth(in size: CGSize) -> CGFloat {
        guard let imageRatio = singleImageAspectRatio, size.height > 0 else {
            return size.width
        }

        let spacing = AppDesignSystem.Spacing.tight
        let fullWidth = size.width
        let halfWidth = max((size.width - spacing) / 2, 0)
        let fullUtilization = cropUtilization(imageRatio: imageRatio, containerRatio: fullWidth / size.height)
        let halfUtilization = cropUtilization(imageRatio: imageRatio, containerRatio: halfWidth / size.height)
        return halfUtilization > fullUtilization ? halfWidth : fullWidth
    }

    private func cropUtilization(imageRatio: CGFloat, containerRatio: CGFloat) -> CGFloat {
        guard imageRatio > 0, containerRatio > 0 else { return 0 }
        return min(imageRatio / containerRatio, containerRatio / imageRatio)
    }

    private func thumbnailButton(image: GalleryImage, index: Int, reportsAspectRatio: Bool) -> some View {
        Button {
            onOpenImage(index, images)
        } label: {
            GalleryPosterThumbnail(
                image: image,
                contentMode: .fill,
                onAspectRatioResolved: reportsAspectRatio ? { ratio in
                    guard singleImageAspectRatio != ratio else { return }
                    singleImageAspectRatio = ratio
                } : nil
            )
        }
        .buttonStyle(.plain)
    }
}

/// 单张帖子图片缩略图。
struct GalleryPosterThumbnail: View {
    let image: GalleryImage
    private let width: CGFloat?
    private let maxHeight: CGFloat?
    private let aspectRatio: CGFloat?
    private let contentMode: ContentMode
    private let onAspectRatioResolved: ((CGFloat) -> Void)?

    init(
        image: GalleryImage,
        contentMode: ContentMode = .fit,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    ) {
        self.image = image
        width = nil
        maxHeight = nil
        aspectRatio = nil
        self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    /// 保留详情页和课程评论原有尺寸语义；主页拼贴使用上面的精简初始化器。
    init(image: GalleryImage, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) {
        self.image = image
        self.width = width
        self.maxHeight = maxHeight
        self.aspectRatio = aspectRatio
        contentMode = .fit
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

    /// 动图必须读取原文件；服务端生成的 lowUrl 通常只是静态缩略图。
    private var animatedURL: URL? {
        guard let url = URL(string: image.url), url.pathExtension.lowercased() == "gif" else {
            return nil
        }
        return url
    }

}
