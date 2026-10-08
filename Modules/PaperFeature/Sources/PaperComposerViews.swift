#if os(iOS)
import CommunityUI
import DesignSystemKit
//
//  PaperComposerViews.swift
//  BIT101-iOS
import SwiftUI
import Observation
import TransportCore

/// 文章发布与编辑页；富文本正文沿用原始块结构。
struct PaperComposerView: View {
    @Environment(PaperDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void
    @State private var model: PaperComposerViewModel
    @State private var submitTask: Task<Void, Never>?

    init(editingPaper: PaperDetail? = nil, initialContent: String, onCreated: @escaping () -> Void) {
        self.onCreated = onCreated
        _model = State(initialValue: PaperComposerViewModel(editingPaper: editingPaper, initialContent: initialContent))
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
                    Text("正文包含图片或格式，标题和摘要可在此修改。")
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
            }
            Section("发布设置") {
                Toggle("匿名发布", isOn: $model.anonymous)
                    .appSelectionFeedback(trigger: model.anonymous)
                    .appInteractiveListRow()
                    .accessibilityIdentifier("ui.paper-composer-view.匿名发布")
            }
        }
        .disabled(model.isSubmitting)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(model.editingPaper == nil ? "发布文章" : "编辑文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .disabled(model.isSubmitting)
                    .accessibilityIdentifier("ui.paper-composer-view.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSubmitting ? "保存中…" : model.editingPaper == nil ? "发布" : "保存") {
                    guard submitTask == nil else { return }
                    submitTask = Task {
                        defer { submitTask = nil }
                        if await model.submit(service: dependencies.composer), !Task.isCancelled {
                            onCreated()
                            dismiss()
                        }
                    }
                }
                .disabled(model.isSubmitting)
                .accessibilityIdentifier("ui.paper-composer-view.submit")
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
        .onDisappear { submitTask?.cancel() }
        .diagnosticAlert(item: $model.alert)
    }
}

@MainActor
@Observable
final class PaperComposerViewModel {
    let editingPaper: PaperDetail?
    let canEditBody: Bool
    private let originalPlainContent: String
    var title: String
    var intro: String
    var content: String
    var anonymous: Bool
    private(set) var isSubmitting = false
    var alert: AppAlert?

    init(editingPaper: PaperDetail?, initialContent: String) {
        self.editingPaper = editingPaper
        canEditBody = editingPaper.map { PaperEditorContentBuilder.canEditAsPlainText($0.content) } ?? true
        originalPlainContent = initialContent.trimmingCharacters(in: .whitespacesAndNewlines)
        title = editingPaper?.title ?? ""
        intro = editingPaper?.intro ?? ""
        content = initialContent
        anonymous = editingPaper?.anonymous ?? false
    }

    func submit(service: any PaperComposerServicing) async -> Bool {
        guard !isSubmitting, !Task.isCancelled else { return false }
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
        }
        guard !title.isEmpty, !intro.isEmpty, !serializedBody.isEmpty else {
            alert = AppAlert.userInput(title: "发布失败", message: "请填写标题、简介和正文。")
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if let editingPaper {
                try await service.updatePaper(id: editingPaper.id, title: title, intro: intro,
                    content: serializedBody, anonymous: anonymous, publicEdit: editingPaper.publicEdit,
                    lastUpdatedAt: editingPaper.updateTime)
            } else {
                _ = try await service.createPaper(title: title, intro: intro, content: serializedBody,
                    anonymous: anonymous, publicEdit: true)
            }
            try Task.checkCancellation()
            return true
        } catch {
            if Task.isCancelled || TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "发布失败", message: error.localizedDescription)
            return false
        }
    }
}

struct PaperCommentComposerSheet: View {
    let target: PaperCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    @State private var isSubmissionRequested = false

    var body: some View {
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
        }
        .appGroupedListStyle()
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
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
