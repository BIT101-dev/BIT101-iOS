#if os(iOS)
import CommunityUI
import CommunityCore
import CommunityTransport
import MediaKit
import DesignSystemKit
import SwiftUI
import Observation
import TransportCore
import os

/// 文章发布与编辑页；富文本正文沿用原始块结构。
struct PaperComposerView: View {
    @Environment(PaperDependencies.self) private var dependencies
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void
    @State private var model: PaperComposerViewModel
    @State private var submitTask: Task<Void, Never>?
    @State private var isConfirmingDiscard = false
    @State private var pendingDraft: PaperComposerDraftSnapshot?
    @State private var isConfirmingRestore = false
    @State private var needsDraftRecovery = false
    @State private var isConfirmingDraftRecovery = false
    @State private var draftRecovery: ComposerDraftCleanup?
    @State private var isManagingDrafts = false
    @State private var didLoadDraft = false
    private var isBusy: Bool { model.isSubmitting || submitTask != nil }

    init(editingPaper: PaperDetail? = nil, initialContent: String,
         currentIdentity: @escaping () -> CommunitySessionIdentity, onCreated: @escaping () -> Void) {
        self.onCreated = onCreated
        _model = State(initialValue: PaperComposerViewModel(editingPaper: editingPaper,
            initialContent: initialContent, currentIdentity: currentIdentity))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("内容") {
                TextField("", text: $model.title, prompt: AppInputPrompt.text("标题"))
                    .font(AppDesignSystem.Typography.body)
                    .accessibilityLabel("标题")
                    .accessibilityIdentifier("paper.editor.title")
                TextField("", text: $model.intro, prompt: AppInputPrompt.text("简介"), axis: .vertical)
                    .font(AppDesignSystem.Typography.body)
                    .lineLimit(3, reservesSpace: true)
                    .accessibilityLabel("简介")
                    .accessibilityIdentifier("paper.editor.intro")
                if model.canEditBody {
                    TextField("", text: $model.content, prompt: AppInputPrompt.text("正文"), axis: .vertical)
                        .font(AppDesignSystem.Typography.body)
                        .lineLimit(10, reservesSpace: true)
                        .accessibilityLabel("正文")
                        .accessibilityIdentifier("paper.editor.content")
                } else {
                    Text("正文请在网页编辑，标题和简介可在此修改。")
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
            }
            Section("发布设置") {
                Toggle("匿名发布", isOn: $model.anonymous)
                    .appSelectionFeedback(trigger: model.anonymous)
                    .appInteractiveListRow()
                    .accessibilityIdentifier("ui.paper-composer-view.匿名发布")
            }
            CommunityPublicationReviewSection(state: model.publicationReview,
                destination: AnyView(PaperSearchView(dependencies: dependencies, media: media, initialQuery: model.publicationReview.searchTitle))) {
                guard submitTask == nil else { return }
                submitTask = Task {
                    defer { submitTask = nil }
                    await model.acknowledgePublicationReview(drafts: dependencies.drafts)
                }
            }
            if let latest = model.conflictingPaper {
                Section("核对文章更新") {
                    Text("当前编辑内容已保留。确认覆盖后，保存会提交当前标题、简介、正文和匿名设置。")
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    NavigationLink("查看最新文章") {
                        PaperDetailView(dependencies: dependencies, media: media,
                            initialPaper: .init(id: latest.id, title: latest.title, intro: latest.intro,
                                likeNum: latest.likeNum, commentNum: latest.commentNum, updateTime: latest.updateTime), onChanged: {})
                    }
                    .appInteractiveListRow()
                    .accessibilityIdentifier("paper.edit.review-latest")
                    Button("使用当前内容覆盖此版本") { model.confirmEditVersion() }
                        .appInteractiveListRow()
                        .accessibilityIdentifier("paper.edit.confirm-version")
                }
            }
            Section("文章草稿") {
                Button("管理文章草稿") { isManagingDrafts = true }
                    .appInteractiveListRow()
                    .accessibilityIdentifier("paper.drafts.manage")
            }
        }
        .disabled(isBusy)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(model.editingPaper == nil ? "发布文章" : "编辑文章")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.hasUnsavedChanges || isBusy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    if model.hasUnsavedChanges { isConfirmingDiscard = true }
                    else { dismiss() }
                }
                    .disabled(isBusy)
                    .accessibilityIdentifier("ui.paper-composer-view.cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if needsDraftRecovery {
                    Button("恢复草稿存储") { isConfirmingDraftRecovery = true }
                        .disabled(isBusy)
                        .accessibilityIdentifier("paper.draft.recovery")
                } else {
                    Button("暂存", action: saveDraftAndDismiss)
                        .disabled(isBusy || !model.hasUnsavedChanges)
                        .accessibilityIdentifier("ui.paper-composer-view.save-draft")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSubmitting ? "保存中…" : model.editingPaper == nil ? "发布" : "保存") {
                    guard submitTask == nil else { return }
                    submitTask = Task {
                        defer { submitTask = nil }
                        if await model.submit(service: dependencies.composer, drafts: dependencies.drafts), !Task.isCancelled {
                            onCreated()
                            dismiss()
                        }
                    }
                }
                .disabled(isBusy || model.publicationReview.needsReview || model.conflictingPaper != nil)
                .accessibilityIdentifier("ui.paper-composer-view.submit")
            }
        }
        .interactiveDismissDisabled(isBusy || model.hasUnsavedChanges)
        .confirmationDialog("放弃文章修改？", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("暂存并离开", action: saveDraftAndDismiss)
            Button("放弃修改", role: .destructive) {
                guard submitTask == nil else { return }
                submitTask = Task {
                    defer { submitTask = nil }
                    guard model.isCurrentOwner else { return }
                    let cleanup = await dependencies.drafts.capturePaperCleanup(matching: model.restoredDraft)
                    guard model.isCurrentOwner else { return }
                    if await cleanup(), model.isCurrentOwner { dismiss() }
                    else if model.isCurrentOwner { model.alert = .informational(title: "草稿清理遇到问题", message: "当前编辑内容已保留，请重试。") }
                }
            }
            Button("取消", role: .cancel) {}.accessibilityIdentifier("paper.editor.cancel-discard")
        }
        .task {
            guard !didLoadDraft else { return }
            await loadDraft()
            if model.isCurrentOwner { didLoadDraft = true }
        }
        .alert("恢复文章草稿？", isPresented: $isConfirmingRestore) {
            Button("恢复草稿") {
                if let pendingDraft { model.restoreDraft(pendingDraft) }
                pendingDraft = nil
            }
            Button("继续当前编辑", role: .cancel) { pendingDraft = nil }
        }
        .alert("恢复文章草稿存储？", isPresented: $isConfirmingDraftRecovery) {
            Button("恢复", role: .destructive, action: recoverDraftStorage)
                .accessibilityIdentifier("paper.draft.recovery.confirm")
            Button("继续当前编辑", role: .cancel) {}
                .accessibilityIdentifier("paper.draft.recovery.cancel")
        } message: {
            Text("可读取的文章草稿将保留，损坏条目和其余原文件内容会清除。当前编辑内容保留。")
        }
        .onDisappear { submitTask?.cancel() }
        .sheet(isPresented: $isManagingDrafts) {
            NavigationStack { PaperDraftsView(isCurrentOwner: { model.isCurrentOwner }) }
        }
        .diagnosticAlert(item: $model.alert)
    }

    private func loadDraft() async {
        await model.refreshPublicationReview(drafts: dependencies.drafts)
        guard model.isCurrentOwner else { return }
        let recovery = await dependencies.drafts.capturePaperRecovery()
        guard model.isCurrentOwner else { return }
        let result = await dependencies.drafts.loadPaper(paperID: model.editingPaper?.id)
        guard model.isCurrentOwner else { return }
        if let draft = result.snapshot { pendingDraft = draft; isConfirmingRestore = true }
        else if case .unreadable = result {
            draftRecovery = recovery
            needsDraftRecovery = true
            isConfirmingDraftRecovery = true
        }
        else if !result.allowsWrite {
            model.alert = .informational(title: "草稿版本需要更新", message: "原始草稿已保留，请使用支持当前草稿格式的 App 版本后重试恢复。")
        }
    }

    private func recoverDraftStorage() {
        guard submitTask == nil, model.isCurrentOwner, let recovery = draftRecovery else { return }
        submitTask = Task {
            defer { submitTask = nil }
            guard model.isCurrentOwner else { return }
            let recovered = await recovery()
            guard model.isCurrentOwner else { return }
            if recovered { needsDraftRecovery = false; await loadDraft() }
            else { model.alert = .informational(title: "草稿恢复遇到问题", message: "原始草稿和当前编辑内容已保留，请检查本机存储与 App 版本后重试。") }
        }
    }

    private func saveDraftAndDismiss() {
        guard submitTask == nil, model.isCurrentOwner else { return }
        let snapshot = model.draftSnapshot
        submitTask = Task {
            defer { submitTask = nil }
            guard model.isCurrentOwner else { return }
            let saved = await dependencies.drafts.savePaper(snapshot)
            guard model.isCurrentOwner else { return }
            if saved { dismiss() }
            else { model.alert = .informational(title: "文章暂存遇到问题", message: "当前编辑内容已保留。请核对已保存的文章草稿与本机可用空间，再重试暂存。") }
        }
    }
}

private struct PaperDraftsView: View {
    @Environment(PaperDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    let isCurrentOwner: () -> Bool
    @State private var drafts: [PaperComposerDraftSnapshot] = []
    @State private var selectedDraft: PaperComposerDraftSnapshot?
    @State private var operation: Task<Void, Never>?
    @State private var alert: AppAlert?
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading { AppInlineLoadingState("正在读取草稿") }
            else if drafts.isEmpty { Text("暂无文章草稿") }
            ForEach(drafts, id: \.paperID) { draft in
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                    Text(draft.title.isEmpty ? "未命名文章" : draft.title)
                    Text(draft.intro).font(AppDesignSystem.Typography.caption)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    Button("删除草稿", role: .destructive) { selectedDraft = draft }
                        .disabled(operation != nil)
                        .appInteractiveListRow(isDestructive: true)
                        .accessibilityIdentifier("paper.drafts.delete")
                }
            }
        }
        .accessibilityIdentifier("paper.drafts.list")
        .appGroupedListStyle()
        .navigationTitle("文章草稿")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("paper.drafts.done")
            }
        }
        .confirmationDialog("删除此文章草稿？", isPresented: Binding(get: { selectedDraft != nil }, set: { if !$0 { selectedDraft = nil } }), titleVisibility: .visible) {
            Button("删除草稿", role: .destructive) {
                guard operation == nil, let draft = selectedDraft else { return }
                operation = Task {
                    defer { operation = nil }
                    guard isCurrentOwner() else { return }
                    let cleanup = await dependencies.drafts.capturePaperCleanup(matching: draft)
                    guard isCurrentOwner() else { return }
                    let removed = await cleanup()
                    guard isCurrentOwner() else { return }
                    if removed { await loadDrafts() }
                    else { alert = .informational(title: "草稿清理遇到问题", message: "原始草稿和当前编辑内容已保留，请重试。") }
                }
            }
            Button("取消", role: .cancel) {}.accessibilityIdentifier("paper.drafts.cancel-delete")
        } message: { Text("当前编辑内容会保留。") }
        .task { await loadDrafts() }
        .onDisappear { operation?.cancel() }
        .diagnosticAlert(item: $alert)
    }

    private func loadDrafts() async {
        guard isCurrentOwner() else { return }
        let result = await dependencies.drafts.loadPaperDrafts()
        guard isCurrentOwner() else { return }
        isLoading = false
        if result.allowsWrite { drafts = result.snapshot ?? [] }
        else { alert = .informational(title: "草稿读取遇到问题", message: "原始草稿已保留，请检查本机存储与 App 版本后重试。") }
    }
}

@MainActor
@Observable
final class PaperComposerViewModel {
    private static let logger = Logger(subsystem: "BIT101", category: "PaperComposer")
    let editingPaper: PaperDetail?
    let canEditBody: Bool
    private let originalPlainContent: String
    private let initialContent: String
    private var expectedUpdatedAt: String?
    private var expectedPublicEdit: Bool
    private(set) var conflictingPaper: PaperDetail?
    private(set) var restoredDraft: PaperComposerDraftSnapshot?
    var title: String
    var intro: String
    var content: String
    var anonymous: Bool
    private(set) var isSubmitting = false
    private let owner: CommunitySessionIdentity
    private let currentIdentity: () -> CommunitySessionIdentity
    private(set) var publicationReview: ComposerPublicationReviewState = .ready
    var alert: AppAlert?

    init(editingPaper: PaperDetail?, initialContent: String, currentIdentity: @escaping () -> CommunitySessionIdentity) {
        self.currentIdentity = currentIdentity
        owner = currentIdentity()
        self.editingPaper = editingPaper
        canEditBody = editingPaper.map { PaperEditorContentBuilder.canEditAsPlainText($0.content) } ?? true
        originalPlainContent = initialContent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialContent = initialContent
        expectedUpdatedAt = editingPaper?.updateTime
        expectedPublicEdit = editingPaper?.publicEdit ?? true
        title = editingPaper?.title ?? ""
        intro = editingPaper?.intro ?? ""
        content = initialContent
        anonymous = editingPaper?.anonymous ?? false
    }

    var hasUnsavedChanges: Bool {
        title != (editingPaper?.title ?? "") || intro != (editingPaper?.intro ?? "")
            || content != initialContent || anonymous != (editingPaper?.anonymous ?? false)
    }

    var draftSnapshot: PaperComposerDraftSnapshot {
        .init(paperID: editingPaper?.id, baselineUpdatedAt: expectedUpdatedAt, title: title,
              intro: intro, content: content, anonymous: anonymous)
    }

    func restoreDraft(_ draft: PaperComposerDraftSnapshot) {
        guard isCurrentOwner, !isSubmitting, draft.paperID == editingPaper?.id else { return }
        title = draft.title; intro = draft.intro; content = draft.content; anonymous = draft.anonymous
        expectedUpdatedAt = draft.baselineUpdatedAt
        restoredDraft = draft
    }

    var isCurrentOwner: Bool { owner == currentIdentity() && !Task.isCancelled }

    func confirmEditVersion() {
        guard isCurrentOwner, !isSubmitting, let latest = conflictingPaper else { return }
        expectedUpdatedAt = latest.updateTime
        expectedPublicEdit = latest.publicEdit
        conflictingPaper = nil
    }

    func refreshPublicationReview(drafts: any ComposerPublicationStoring) async {
        guard editingPaper == nil, isCurrentOwner else { return }
        do {
            let pending = try await drafts.loadPublication(kind: .paper, owner: owner.accountIdentifier)
            guard isCurrentOwner else { return }
            publicationReview = pending.map(ComposerPublicationReviewState.pending) ?? .ready
        } catch {
            guard isCurrentOwner, !TaskCancellation.matches(error) else { return }
            publicationReview = .requiresRecovery
            alert = AppAlert(title: "发布记录读取受阻", error: error)
        }
    }

    func acknowledgePublicationReview(drafts: any ComposerPublicationStoring) async {
        guard isCurrentOwner, !isSubmitting, publicationReview.needsReview else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch publicationReview {
            case .ready: return
            case .pending(let attempt): _ = try await drafts.finishPublication(attempt)
            case .requiresRecovery: try await drafts.resetPublicationsAfterReview(owner: owner.accountIdentifier)
            }
            await refreshPublicationReview(drafts: drafts)
        } catch {
            guard isCurrentOwner, !TaskCancellation.matches(error) else { return }
            publicationReview = .requiresRecovery
            alert = AppAlert(title: "发布记录保存受阻", error: error)
        }
    }

    func submit(service: any PaperComposerServicing,
                drafts: any PaperComposerDraftStoring & ComposerPublicationStoring) async -> Bool {
        guard !isSubmitting, isCurrentOwner, conflictingPaper == nil else { return false }
        guard !publicationReview.needsReview else {
            alert = AppAlert(title: "发布结果待确认", message: CommunityCreateOutcomeUnknown.reviewMessage)
            return false
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let serializedBody: String
        if let editingPaper, !canEditBody || body == originalPlainContent {
            serializedBody = editingPaper.content
        } else {
            guard !body.isEmpty else {
                alert = AppAlert.userInput(title: "发布失败", message: "请填写正文。")
                return false
            }
            serializedBody = PaperEditorContentBuilder.editorJSON(from: body)
            guard PaperEditorContentBuilder.canEditAsPlainText(serializedBody) else {
                alert = AppAlert.userInput(title: "发布失败", message: "正文过长，请缩短段落或减少正文内容。")
                return false
            }
        }
        guard !title.isEmpty, !intro.isEmpty, !serializedBody.isEmpty else {
            alert = AppAlert.userInput(title: "发布失败", message: "请填写标题、简介和正文。")
            return false
        }
        let anonymous = anonymous
        isSubmitting = true
        defer { isSubmitting = false }
        let cleanup = await drafts.capturePaperCleanup(matching: restoredDraft)
        guard isCurrentOwner else { return false }
        var publication: ComposerPublicationAttempt?
        do {
            if let editingPaper {
                try await service.updatePaper(id: editingPaper.id, title: title, intro: intro,
                    content: serializedBody, anonymous: anonymous, publicEdit: expectedPublicEdit,
                    lastUpdatedAt: expectedUpdatedAt ?? editingPaper.updateTime)
            } else {
                let started = try await drafts.beginPublication(.paper(title: title, intro: intro,
                    content: serializedBody, anonymous: anonymous), owner: owner.accountIdentifier)
                switch started {
                case .pending(let attempt):
                    guard isCurrentOwner else { return false }
                    publicationReview = .pending(attempt)
                    alert = AppAlert(title: "发布结果待确认", message: CommunityCreateOutcomeUnknown.reviewMessage)
                    return false
                case .started(let attempt): publication = attempt
                }
                guard isCurrentOwner else {
                    if let publication { _ = try await drafts.finishPublication(publication) }
                    return false
                }
                if let publication { publicationReview = .pending(publication) }
                _ = try await service.createPaper(title: title, intro: intro, content: serializedBody,
                    anonymous: anonymous, publicEdit: true)
            }
            guard isCurrentOwner else { return false }
            if await cleanup() {
                if let publication {
                    do { _ = try await drafts.finishPublication(publication) }
                    catch { Self.logger.error("清理已发布事务受阻：\(String(describing: error), privacy: .private)") }
                }
            } else { Self.logger.error("已发布文章的草稿清理受阻，原始草稿已保留。") }
            return isCurrentOwner
        } catch {
            guard isCurrentOwner else { return false }
            if let conflict = error as? PaperEditConflict {
                conflictingPaper = conflict.latest
                alert = .informational(title: "文章已有更新", message: conflict.localizedDescription)
                return false
            }
            if error is CommunityCreateOutcomeUnknown {
                alert = AppAlert(title: "发布结果待确认", error: error)
                return false
            }
            if TaskCancellation.matches(error) { return false }
            if editingPaper == nil {
                if let publication {
                    do {
                        _ = try await drafts.finishPublication(publication)
                        await refreshPublicationReview(drafts: drafts)
                    } catch {
                        guard isCurrentOwner else { return false }
                        publicationReview = .requiresRecovery
                        Self.logger.error("结束失败发布的事务受阻：\(String(describing: error), privacy: .private)")
                    }
                } else { publicationReview = .requiresRecovery }
            }
            guard isCurrentOwner else { return false }
            alert = AppAlert(title: "发布失败", error: error)
            return false
        }
    }
}

struct PaperCommentComposerSheet: View {
    let target: CommunityCommentComposerTarget
    let isSubmitting: Bool
    let review: CommunityCommentReviewActions
    let onSubmit: (String, Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    @State private var isSubmissionRequested = false
    private var hasDraftContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || anonymous }

    var body: some View {
        let submission = CommunityCommentSubmission(objectID: target.objectID, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            anonymous: anonymous, replyObjectID: target.replyObjectID, replyUID: target.replyUID)
        List {
            AppCommentComposerContentSection(title: target.title, anonymous: $anonymous) {
                TextField(
                    "",
                    text: $text,
                    prompt: AppInputPrompt.text(target.placeholder),
                    axis: .vertical
                )
                .font(AppDesignSystem.Typography.body)
                .lineLimit(12, reservesSpace: true)
                .frame(minHeight: AppDesignSystem.Size.Editor.multilineMinimumHeight)
                .accessibilityLabel(target.placeholder)
                    .accessibilityIdentifier("ui.paper-comment-composer-sheet.input")
            }
                CommunityCommentReviewSection(submission: submission, actions: review) { isSubmissionRequested = true }
        }
        .disabled(isSubmitting || isSubmissionRequested)
        .accessibilityIdentifier("interaction.PaperCommentComposerSheet.list")
        .appGroupedListStyle()
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(hasDraftContent || isSubmitting || isSubmissionRequested)
        .task(id: isSubmissionRequested) {
            guard isSubmissionRequested else { return }
            let submitted = await onSubmit(text, anonymous)
            guard !Task.isCancelled else { return }
            isSubmissionRequested = false
            if submitted { dismiss() }
        }
        .toolbar {
            AppComposerToolbar(
                isSubmitting: isSubmitting || isSubmissionRequested,
                submitTitle: "发布",
                isSubmitDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                confirmDiscard: hasDraftContent,
                onCancel: {
                    dismiss()
                },
                onSubmit: {
                    isSubmissionRequested = true
                }
            )
        }
    }
}

#endif
