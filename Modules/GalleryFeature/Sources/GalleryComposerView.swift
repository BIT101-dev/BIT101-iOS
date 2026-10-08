#if os(iOS)
import CommunityUI
import CommunityCore
import DesignSystemKit
import PhotosUI
import SwiftUI
import UIKit

/// 发帖入口按所选依赖实例创建编辑场景。
struct GalleryComposerView: View {
    @Environment(GalleryDependencies.self) private var dependencies
    let onCreated: () -> Void
    let editingPoster: GalleryPosterDetail?

    init(editingPoster: GalleryPosterDetail? = nil, onCreated: @escaping () -> Void) {
        self.editingPoster = editingPoster
        self.onCreated = onCreated
    }

    var body: some View {
        GalleryComposerScene(dependencies: dependencies, editingPoster: editingPoster, onCreated: onCreated)
            .id(ObjectIdentifier(dependencies))
    }
}

private struct GalleryComposerScene: View {
    @StateObject private var viewModel: GalleryComposerViewModel
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isShowingDraftAlert = false
    @State private var isShowingDraftRestoreAlert = false
    @Environment(\.dismiss) private var dismiss
    let editingPoster: GalleryPosterDetail?
    let onCreated: () -> Void

    init(dependencies: GalleryDependencies, editingPoster: GalleryPosterDetail?, onCreated: @escaping () -> Void) {
        self.editingPoster = editingPoster
        self.onCreated = onCreated
        let imagePreparer = ComposerImagePreparer()
        _viewModel = StateObject(wrappedValue: GalleryComposerViewModel(editingPoster: editingPoster,
            service: dependencies.composer, images: dependencies.images, drafts: dependencies.drafts,
            currentIdentity: { dependencies.session.currentCredentials.identity },
            prepareImageData: { try? await imagePreparer.prepare($0) }))
    }

    /// 内置的推荐标签。
    ///
    /// 这些常用场景标签帮助用户快速编辑帖子。
    private static let suggestedTags = [
        "水",
        "活动",
        "表白",
        "树洞",
        "求助",
        "聊天",
        "抽象"
    ]

    /// 发帖表单主体。
    ///
    /// 表单结构参考网页端，交互采用原生 `Form`。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("", text: $viewModel.title, prompt: AppInputPrompt.text("标题"))
                        .accessibilityLabel("标题")
                        .accessibilityIdentifier("gallery.editor.title")
                    TextField("", text: $viewModel.text, prompt: AppInputPrompt.text("正文"), axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                        .accessibilityLabel("正文")
                        .accessibilityIdentifier("gallery.editor.content")
                }

                Section("标签") {
                    // 标签入口分开呈现预置标签按钮和自定义输入行，常用标签保持快捷选择。
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 64), spacing: AppDesignSystem.Spacing.regular)],
                        alignment: .leading,
                        spacing: AppDesignSystem.Spacing.regular
                    ) {
                        ForEach(Self.suggestedTags, id: \.self) { tag in
                            Button {
                                viewModel.toggleTag(tag)
                            } label: {
                                AppTagChip(
                                    title: tag,
                                    variant: .selection(isSelected: viewModel.selectedTags.contains(tag))
                                )
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .appInteractiveListRow()
                                .accessibilityIdentifier("ui.gallery-composer-scene.tag")
                        }

                        Button {
                            viewModel.addCustomTagDraft()
                        } label: {
                            AppTagChip(title: "自定义", variant: .selection(isSelected: false))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .appInteractiveListRow()
                            .accessibilityIdentifier("ui.gallery-composer-scene.add-tag")
                    }
                    .appSelectionFeedback(trigger: viewModel.selectedTags)

                    if !viewModel.customTagDrafts.isEmpty {
                        // 每条自定义标签使用独立输入行，输入和删除操作分开呈现。
                        ForEach($viewModel.customTagDrafts) { $draft in
                            HStack(spacing: AppDesignSystem.Spacing.regular) {
                                TextField("", text: $draft.text, prompt: AppInputPrompt.text("自定义标签"))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityLabel("自定义标签")
                                    .accessibilityIdentifier("gallery.editor.tag.\(draft.id)")

                                Button {
                                    viewModel.removeCustomTagDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                                        .font(AppDesignSystem.Typography.title)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除标签")
                                .appInteractiveListRow()
                            }
                        }
                    }
                }

                Section("发布设置") {
                    // 声明列表由服务端返回，页面与网页端保持一致。
                    Picker("声明", selection: $viewModel.selectedClaimID) {
                        ForEach(viewModel.claims) { claim in
                            Text(claim.text).tag(claim.id)
                        }
                    }
                    .appSelectionFeedback(trigger: viewModel.selectedClaimID)
                    .appInteractiveListRow()

                    Toggle("匿名发布", isOn: $viewModel.anonymous)
                        .appSelectionFeedback(trigger: viewModel.anonymous)
                    .appInteractiveListRow()
                        .accessibilityIdentifier("ui.gallery-composer-scene.匿名发布")
                    Toggle("公开显示", isOn: $viewModel.isPublic)
                        .appSelectionFeedback(trigger: viewModel.isPublic)
                    .appInteractiveListRow()
                }

                Section("图片") {
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: GalleryComposerViewModel.maximumImageCount, matching: .images) {
                        Text("插入图片")
                    }
                    .disabled(
                        viewModel.isSubmitting
                            || viewModel.isAddingImages
                            || viewModel.existingImages.count + viewModel.imageDrafts.count >= GalleryComposerViewModel.maximumImageCount
                    )
                    .appInteractiveListRow()
                        .accessibilityIdentifier("ui.gallery-composer-scene.插入图片")

                    if !viewModel.existingImages.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: AppDesignSystem.Size.Media.draft), spacing: AppDesignSystem.Spacing.regular)],
                            spacing: AppDesignSystem.Spacing.regular
                        ) {
                            ForEach(viewModel.existingImages) { image in
                                ZStack(alignment: .topTrailing) {
                                    CommunityImageThumbnail(image: image, contentMode: .fill)
                                        .frame(
                                            width: AppDesignSystem.Size.Media.draft,
                                            height: AppDesignSystem.Size.Media.draft
                                        )
                                        .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))

                                    Button {
                                        viewModel.removeExistingImage(id: image.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(AppDesignSystem.Typography.title)
                                            .foregroundStyle(AppDesignSystem.Palette.Media.foreground, AppDesignSystem.Palette.Media.controlOverlay)
                                    }
                                    .padding(AppDesignSystem.Spacing.tiny)
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("移除原有图片")
                                    .appInteractiveListRow()
                                }
                                .frame(
                                    width: AppDesignSystem.Size.Media.draft,
                                    height: AppDesignSystem.Size.Media.draft
                                )
                            }
                        }
                    }

                    if !viewModel.imageDrafts.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: AppDesignSystem.Size.Media.draft), spacing: AppDesignSystem.Spacing.regular)],
                            spacing: AppDesignSystem.Spacing.regular
                        ) {
                            ForEach(viewModel.imageDrafts) { draft in
                                ComposerImageTile(
                                    draft: draft,
                                    onRetry: {
                                        Task { await viewModel.retryImageUpload(id: draft.id) }
                                    },
                                    onRemove: {
                                        viewModel.removeImageDraft(id: draft.id)
                                    }
                                )
                            }
                        }
                    }

                    if viewModel.hasUploadingImages {
                        Text("图片上传中，上传完成后即可一并发布。")
                            .font(AppDesignSystem.Typography.footnote)
                            .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    }
                }
            }
            .disabled(viewModel.isSubmitting || viewModel.isSavingDraft)
            .navigationTitle(editingPoster == nil ? "发布帖子" : "编辑帖子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { requestDismiss() }
                        .accessibilityIdentifier("ui.gallery-composer-scene.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isSubmitting ? "保存中" : editingPoster == nil ? "发布" : "保存") {
                        Task {
                            if await viewModel.submit() { onCreated(); dismiss() }
                        }
                    }
                    .disabled(viewModel.isSubmitting)
                        .accessibilityIdentifier("ui.gallery-composer-scene.submit")
                }
            }
            .task { await viewModel.loadClaimsIfNeeded() }
            .onChange(of: selectedPhotoItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task {
                    await viewModel.addImages(from: newValue.map { item in
                        { try await item.loadTransferable(type: Data.self) }
                    })
                    if selectedPhotoItems == newValue { selectedPhotoItems = [] }
                }
            }
            .task { isShowingDraftRestoreAlert = await viewModel.checkDraftOnAppear() }
            .onDisappear { viewModel.cancelPendingOperations() }
            .alert("保存草稿？", isPresented: $isShowingDraftAlert) {
                Button("保存草稿") {
                    Task {
                        if await viewModel.saveDraft() {
                            dismiss()
                        }
                    }
                }
                Button("不保存") {
                    Task {
                        if await viewModel.discardDraft() { dismiss() }
                    }
                }
            } message: {
                Text("保存后下次打开时可以加载草稿。")
            }
            .alert("加载草稿？", isPresented: $isShowingDraftRestoreAlert) {
                Button("加载草稿") {
                    Task { await viewModel.restoreDraft() }
                }
                Button("不加载") {
                    Task { _ = await viewModel.discardDraft() }
                }
            } message: {
                Text("发现上次保存的发帖草稿。")
            }
            .diagnosticAlert(item: $viewModel.alert)
        }
    }

    private func requestDismiss() {
        guard !viewModel.isSubmitting, !viewModel.isSavingDraft else { return }
        if editingPoster != nil || !viewModel.hasDraftContent { dismiss() }
        else { isShowingDraftAlert = true }
    }
}
#endif
