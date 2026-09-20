//
//  GalleryCommentViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI
import UIKit
import PhotosUI

struct GalleryPosterCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let selectedOrder: GalleryCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: (GalleryCommentOrder) -> Void
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onReportComment: (GalleryComment) -> Void
    let onDeleteComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void
    let onLoadMore: (GalleryComment?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.container) {
            AppCommentSectionHeader(count: totalCommentCount) {
                Picker("排序", selection: Binding(get: { selectedOrder }, set: onSelectOrder)) {
                    ForEach(GalleryCommentOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .appSelectionFeedback(trigger: selectedOrder)
                .pickerStyle(.menu)
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                AppInlineLoadingState("正在加载评论")
            case let .failed(message) where comments.isEmpty:
                AppFailureState(
                    title: "加载评论失败",
                    systemImage: "bubble.right.fill",
                    message: message
                )
            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(AppDesignSystem.Typography.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppDesignSystem.Spacing.section)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
                                GalleryCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment,
                                    onReportComment: onReportComment,
                                    onDeleteComment: onDeleteComment,
                                    onOpenImage: onOpenImage,
                                    onOpenUser: onOpenUser
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, AppDesignSystem.Comment.layout.dividerLeading)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                        if isLoadingMore {
                            AppInlineLoadingState()
                        }
                    }
                    .appCommentSectionStyle()
                }
            }
        }
    }
}

/// 评论回复目标。
///
/// `mainComment` 表示发评论接口真正要挂靠的主评论，
/// `targetComment` 表示当前 UI 上用户实际点中的那条评论。
struct GalleryCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

/// 单条评论及其子评论预览。
///
/// 主评论和子评论共用同一套气泡视图；这一层决定是否渲染嵌套结构。
private struct GalleryCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onReportComment: (GalleryComment) -> Void
    let onDeleteComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void
    @State private var pendingDeleteComment: GalleryComment?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        AppCommentThread(comment: comment, subcomments: flattenedSubcomments) { comment, isSubComment in
            commentBubble(comment, isSubComment: isSubComment)
        }
        .alert(
            "删除评论",
            isPresented: $isShowingDeleteConfirmation,
            presenting: pendingDeleteComment
        ) { comment in
            Button("取消", role: .cancel) {
                pendingDeleteComment = nil
            }
            Button("删除", role: .destructive) {
                pendingDeleteComment = nil
                onDeleteComment(comment)
            }
        } message: { _ in
            Text("确定删除这条评论吗？删除后无法恢复。")
        }
    }

    private var flattenedSubcomments: [GalleryComment] {
        comment.sub.flatMap { flattenedComments(from: $0) }
    }

    private func flattenedComments(from comment: GalleryComment) -> [GalleryComment] {
        [comment] + comment.sub.flatMap { flattenedComments(from: $0) }
    }

    private func commentAvatarURL(for comment: GalleryComment) -> URL? {
        let rawURL = comment.user.avatar.lowUrl.isEmpty
            ? comment.user.avatar.url
            : comment.user.avatar.lowUrl
        return URL(string: rawURL)
    }

    @ViewBuilder
    private func commentBubble(_ comment: GalleryComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppAvatarView(
                imageURL: comment.anonymous ? nil : commentAvatarURL(for: comment),
                size: isSubComment
                    ? AppDesignSystem.Size.control.compact
                    : AppDesignSystem.Comment.layout.avatarSize
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.anonymous ? "匿名用户" : comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.relativeText(from: comment.createTime, fallback: "未知时间"),
                onOpenProfile: canOpenUserProfile(comment) ? { onOpenUser(comment.user) } : nil
            )

            commentText(for: comment)

            if !comment.images.isEmpty {
                GalleryPosterImagesView(images: comment.images, onOpenImage: onOpenImage)
            }

            AppCommentActionBar(
                likeCount: comment.likeNum,
                isLiked: comment.like,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(GalleryCommentReplyTarget(mainComment: self.comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                }
            )
        }
        .contextMenu {
            Button("复制评论", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = comment.text
            }
            if comment.own {
                Button("删除评论", systemImage: "trash", role: .destructive) {
                    pendingDeleteComment = comment
                    isShowingDeleteConfirmation = true
                }
            }
            Button("举报评论", systemImage: "exclamationmark.bubble") {
                onReportComment(comment)
            }
        }
    }

    private func canOpenUserProfile(_ comment: GalleryComment) -> Bool {
        !comment.anonymous && comment.user.id > 0
    }

    /// 处理“回复某人”的前缀文本拼接。
    @ViewBuilder
    private func commentText(for comment: GalleryComment) -> some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(galleryLinkifiedText(comment.text))
            )
            .font(AppDesignSystem.Typography.body)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(galleryLinkifiedText(comment.text))
                .font(AppDesignSystem.Typography.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 评论发送弹层。
///
/// 评论输入放在独立 sheet 中，避免与 tab bar、抽屉详情和键盘安全区发生布局冲突。
struct GalleryCommentComposerSheet: View {
    let target: GalleryCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool, [GalleryImage]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var uploadedImages: [GalleryImage] = []
    @State private var isUploadingImages = false
    @State private var uploadError: String?
    @State private var imageViewer: GalleryImageViewerState?
    private let service = GalleryService()

    var body: some View {
        NavigationStack {
            Form {
                AppCommentComposerContentSection(anonymous: $anonymous) {
                    TextField("", text: $text, prompt: AppInputPrompt.text(target.placeholder), axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                }

                Section("图片") {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: max(1, 9 - uploadedImages.count),
                        matching: .images
                    ) {
                        Text(uploadedImages.count >= 9 ? "已达到图片上限" : "添加图片")
                    }
                    .disabled(isSubmitting || isUploadingImages || uploadedImages.count >= 9)
                    .accessibilityLabel("添加评论图片")
                    .accessibilityValue("\(uploadedImages.count) 张")

                    if isUploadingImages {
                        AppInlineLoadingState("上传中")
                    }
                    if let uploadError {
                        Text(uploadError)
                            .foregroundStyle(AppDesignSystem.Palette.danger)
                    }
                    if !uploadedImages.isEmpty {
                        Text("已添加 \(uploadedImages.count) 张图片")
                            .font(AppDesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                        GalleryPosterImagesView(images: uploadedImages) { index, images in
                            imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                        }
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppComposerToolbar(
                    isSubmitting: isSubmitting,
                    submitTitle: "发送",
                    isSubmitDisabled: isUploadingImages,
                    onCancel: {
                        dismiss()
                    },
                    onSubmit: {
                        onSubmit(text, anonymous, uploadedImages)
                    }
                )
            }
            .task(id: selectedPhotoItems) {
                guard !selectedPhotoItems.isEmpty else { return }
                await upload(items: selectedPhotoItems)
            }
            .gallerySystemImagePreview(item: $imageViewer)
        }
    }

    private func upload(items: [PhotosPickerItem]) async {
        isUploadingImages = true
        uploadError = nil
        defer {
            isUploadingImages = false
            selectedPhotoItems = []
        }
        for item in items {
            guard !Task.isCancelled, uploadedImages.count < 9 else { return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                guard !Task.isCancelled else { return }
                let image = try await service.uploadImage(data: data, filename: "comment-\(UUID().uuidString).jpg")
                uploadedImages.append(image)
            } catch {
                if TaskCancellation.matches(error) { return }
                uploadError = error.localizedDescription
            }
        }
    }
}
