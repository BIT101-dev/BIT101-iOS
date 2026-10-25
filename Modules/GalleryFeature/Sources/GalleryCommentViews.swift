#if os(iOS)
import CommunityUI
import TransportCore
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  GalleryCommentViews.swift
//  BIT101-iOS
//
//

import SwiftUI
import UIKit
import PhotosUI

struct GalleryPosterCommentsSection: View {
    let comments: [CommunityComment]
    let totalCommentCount: Int
    let status: CommunityLoadStatus
    let isLoadingMore: Bool
    let paginationError: String?
    let canContinue: Bool
    let selectedOrder: CommunityCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: @MainActor (CommunityCommentOrder) -> Void
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (CommunityComment) -> Void
    let onReportComment: (CommunityComment) -> Void
    let onDeleteComment: (CommunityComment) -> Void
    let onOpenImage: (Int, [CommunityImage]) -> Void
    let onOpenUser: (CommunityUser) -> Void
    let onLoadMore: (CommunityComment?) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            AppCommentSectionHeader(count: totalCommentCount) {
                CommunityCommentSortPicker(order: Binding(get: { selectedOrder }, set: onSelectOrder))
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                AppInlineLoadingState("正在加载评论")
            case let .failed(message) where comments.isEmpty:
                AppFailureState(
                    title: "加载评论失败",
                    systemImage: "bubble.right.fill",
                    message: message,
                    onRetry: onRetry
                )
            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(AppDesignSystem.Typography.body)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppDesignSystem.Spacing.section)
                } else {
                    LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: AppDesignSystem.Spacing.none) {
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
                                        .padding(.leading, AppDesignSystem.Comment.replyInset)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                    }
                    .appCommentSectionStyle()
                }
                CommunityPaginationFooter(isLoading: isLoadingMore, errorMessage: paginationError,
                    showsContinuation: canContinue) { onLoadMore(comments.last) }
            }
        }
    }
}

/// 评论回复目标。
///
/// `mainComment` 表示发评论接口真正要挂靠的主评论，
/// `targetComment` 表示当前 UI 上用户实际点中的那条评论。
struct GalleryCommentReplyTarget {
    let mainComment: CommunityComment
    let targetComment: CommunityComment
}

/// 单条评论及其子评论预览。
///
/// 主评论和子评论共用同一套气泡视图；组件决定嵌套结构的呈现方式。
private struct GalleryCommentRow: View {
    let comment: CommunityComment
    let likingCommentIDs: Set<Int>
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (CommunityComment) -> Void
    let onReportComment: (CommunityComment) -> Void
    let onDeleteComment: (CommunityComment) -> Void
    let onOpenImage: (Int, [CommunityImage]) -> Void
    let onOpenUser: (CommunityUser) -> Void
    @State private var pendingDeleteComment: CommunityComment?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        AppCommentThread(comment: comment, subcomments: comment.flattenedReplies) { comment, isSubComment in
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
                .accessibilityIdentifier("ui.gallery-comment-row.cancel")
            Button("删除", role: .destructive) {
                pendingDeleteComment = nil
                onDeleteComment(comment)
            }
                .accessibilityIdentifier("ui.gallery-comment-row.delete")
        } message: { _ in
            Text("确定删除这条评论吗？删除后无法恢复。")
        }
    }

    @ViewBuilder
    private func commentBubble(_ comment: CommunityComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppAvatarView(
                imageURL: comment.anonymous ? nil : comment.user.avatar.thumbnailURL,
                fallbackImageURL: comment.anonymous ? nil : comment.user.avatar.originalURL,
                size: isSubComment
                    ? AppDesignSystem.Size.Control.compact
                    : AppDesignSystem.Size.Avatar.standard,
                anonymous: comment.anonymous
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.anonymous ? AppUserPresentation.anonymousName : comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.relativeText(from: comment.createTime, fallback: "未知时间"),
                onOpenProfile: canOpenUserProfile(comment) ? { onOpenUser(comment.user) } : nil
            )

            CommunityCommentBody(comment: comment, onOpenImage: onOpenImage)

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
        .accessibilityIdentifier("gallery.comment-menu.\(comment.id)")
    }

    private func canOpenUserProfile(_ comment: CommunityComment) -> Bool {
        !comment.anonymous && comment.user.id > 0
    }

}

/// 评论发送弹层。
///
/// 评论输入放在独立 sheet 中，避免与 tab bar、抽屉详情和键盘安全区发生布局冲突。
struct GalleryCommentComposerSheet: View {
    @Environment(MediaEnvironment.self) private var media
    let target: CommunityCommentComposerTarget
    let isSubmitting: Bool
    let review: CommunityCommentReviewActions
    let onSubmit: (String, Bool, [CommunityImage]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    @State private var isSubmissionRequested = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @StateObject private var imageUploads: ComposerImageUploads
    private var uploadedImages: [CommunityImage] { imageUploads.uploadedImages }
    private var isUploadingImages: Bool { imageUploads.isAddingImages || imageUploads.hasUploadingImages }
    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || anonymous || !imageUploads.drafts.isEmpty || isUploadingImages
    }
    @State private var imageViewer: ImagePreviewRequest?

    init(dependencies: GalleryDependencies, target: CommunityCommentComposerTarget, isSubmitting: Bool,
        review: CommunityCommentReviewActions, onSubmit: @escaping (String, Bool, [CommunityImage]) async -> Bool) {
        self.target = target; self.isSubmitting = isSubmitting; self.review = review; self.onSubmit = onSubmit
        let owner = dependencies.currentIdentity(), preparer = ComposerImagePreparer()
        _imageUploads = StateObject(wrappedValue: ComposerImageUploads(
            upload: { try await dependencies.images.uploadImage(data: $0, filename: $1) },
            prepare: { try await preparer.prepare($0) }, isCurrentSession: { dependencies.currentIdentity() == owner }))
    }

    var body: some View {
        let submission = CommunityCommentSubmission(objectID: target.objectID, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            anonymous: anonymous, replyObjectID: target.replyObjectID, replyUID: target.replyUID, imageMids: uploadedImages.map(\.mid))
        let imageCount = imageUploads.drafts.count
        NavigationStack {
            Form {
                AppCommentComposerContentSection(anonymous: $anonymous) {
                    TextField("", text: $text, prompt: AppInputPrompt.text(target.placeholder), axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .accessibilityIdentifier("ui.gallery-comment-composer-sheet.input")
                }

                CommunityCommentReviewSection(submission: submission, actions: review) { isSubmissionRequested = true }
                    .disabled(isUploadingImages)
                Section("图片") {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: max(1, ComposerDraftImagePolicy.maximumImageCount - imageCount),
                        matching: .images
                    ) {
                        Text(imageCount >= ComposerDraftImagePolicy.maximumImageCount ? "已达到图片上限" : "添加图片")
                    }
                    .disabled(isSubmitting || isUploadingImages || imageCount >= ComposerDraftImagePolicy.maximumImageCount)
                    .accessibilityLabel("添加评论图片")
                    .accessibilityValue("\(imageCount) 张")
                    .appInteractiveListRow()

                    if isUploadingImages {
                        AppInlineLoadingState("上传中")
                    }
                    if let uploadError = imageUploads.errorMessage {
                        Text(uploadError)
                            .foregroundStyle(AppDesignSystem.Palette.Status.danger)
                            .accessibilityIdentifier("comment.image-upload.error")
                    }
                    if imageCount > 0 {
                        Text("已添加 \(imageCount) 张图片")
                            .font(AppDesignSystem.Typography.caption)
                            .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        ScrollView(.horizontal) {
                            HStack(spacing: AppDesignSystem.Spacing.regular) {
                                ForEach(Array(imageUploads.drafts.enumerated()), id: \.element.id) { index, draft in
                                    ComposerImageTile(draft: draft,
                                        onRetry: { Task { await imageUploads.retry(id: draft.id) } },
                                        onRemove: { imageUploads.remove(id: draft.id) },
                                        onOpen: { openImage(id: draft.id) },
                                        previewAccessibilityLabel: "预览第\(index + 1)张评论图片",
                                        removeAccessibilityLabel: "移除第\(index + 1)张评论图片")
                                }
                            }
                        }
                        .accessibilityIdentifier("interaction.GalleryCommentComposerSheet.images")
                    }
                }
            }
            .disabled(isSubmitting || isSubmissionRequested)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: isSubmissionRequested) {
                guard isSubmissionRequested else { return }
                let submitted = await onSubmit(text, anonymous, uploadedImages)
                guard !Task.isCancelled else { return }
                isSubmissionRequested = false
                if submitted { dismiss() }
            }
            .toolbar {
                AppComposerToolbar(
                    isSubmitting: isSubmitting || isSubmissionRequested,
                    submitTitle: "发送",
                    isSubmitDisabled: !imageUploads.isReadyToSubmit || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && uploadedImages.isEmpty),
                    confirmDiscard: hasDraftContent,
                    onCancel: {
                        dismiss()
                    },
                    onSubmit: {
                        isSubmissionRequested = true
                    }
                )
            }
            .task(id: selectedPhotoItems) {
                guard !selectedPhotoItems.isEmpty else { return }
                let selected = selectedPhotoItems
                await imageUploads.addImages(from: selected.map { item in
                    { try await media.loadBoundedImageData(from: item) }
                })
                selectedPhotoItems = []
            }
            .systemImagePreview(item: $imageViewer)
            .onDisappear { imageUploads.cancel() }
        }
        .interactiveDismissDisabled(hasDraftContent || isSubmitting || isSubmissionRequested)
    }

    private func openImage(id: UUID) {
        guard let index = imageUploads.drafts.firstIndex(where: { $0.id == id }) else { return }
        let images = imageUploads.drafts.compactMap { UIImage(data: $0.previewData) }
        imageViewer = ImagePreviewRequest(localImages: images, initialIndex: index)
    }
}

#endif
