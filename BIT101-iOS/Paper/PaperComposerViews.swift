//
//  PaperComposerViews.swift
//  BIT101-iOS
import SwiftUI

/// 文章发布页。
///
/// 当前提供原生编辑器，支持标题、简介、正文和匿名开关。
/// 新正文按纯文本段落包装为 Editor.js JSON，已有正文在正文保持原样时沿用服务端内容。
struct PaperComposerView: View {
    let onCreated: () -> Void
    let editingPaper: PaperDetail?
    private let originalContent: String?
    private let originalPlainContent: String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var intro = ""
    @State private var content = ""
    @State private var anonymous = false
    @State private var isSubmitting = false
    @State private var alert: AppAlert?

    private let service = PaperService()

    init(editingPaper: PaperDetail? = nil, onCreated: @escaping () -> Void) {
        self.editingPaper = editingPaper
        self.onCreated = onCreated
        originalContent = editingPaper?.content
        originalPlainContent = editingPaper.map { PaperEditorContentBuilder.plainText(from: $0.content) }
        _title = State(initialValue: editingPaper?.title ?? "")
        _intro = State(initialValue: editingPaper?.intro ?? "")
        _content = State(initialValue: editingPaper.map { PaperEditorContentBuilder.plainText(from: $0.content) } ?? "")
        _anonymous = State(initialValue: editingPaper?.anonymous ?? false)
    }

    var body: some View {
        Form {
            Section("内容") {
                TextField("", text: $title, prompt: AppInputPrompt.text("标题"))
                    .font(AppDesignSystem.Typography.body)
                TextField("", text: $intro, prompt: AppInputPrompt.text("简介"), axis: .vertical)
                    .font(AppDesignSystem.Typography.body)
                    .lineLimit(3, reservesSpace: true)
                TextField("", text: $content, prompt: AppInputPrompt.text("正文"), axis: .vertical)
                    .font(AppDesignSystem.Typography.body)
                    .lineLimit(10, reservesSpace: true)
            }

            Section("发布设置") {
                Toggle("匿名发布", isOn: $anonymous)
                    .appSelectionFeedback(trigger: anonymous)
            }
        }
        .navigationTitle(editingPaper == nil ? "发布文章" : "编辑文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "保存中…" : editingPaper == nil ? "发布" : "保存") {
                    Task {
                        await submit()
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .diagnosticAlert(item: $alert)
    }

    private func submit() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIntro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, !trimmedIntro.isEmpty, !trimmedContent.isEmpty else {
            alert = AppAlert.userInput(title: "发布失败", message: "标题、简介和正文都不能为空。")
            return
        }

        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if let editingPaper {
                try await service.updatePaper(
                    id: editingPaper.id,
                    title: trimmedTitle,
                    intro: trimmedIntro,
                    content: editorContent(from: trimmedContent),
                    anonymous: anonymous,
                    publicEdit: editingPaper.publicEdit
                )
            } else {
                _ = try await service.createPaper(
                    title: trimmedTitle,
                    intro: trimmedIntro,
                    content: PaperEditorContentBuilder.editorJSON(from: trimmedContent),
                    anonymous: anonymous
                )
            }
            onCreated()
            dismiss()
        } catch {
            alert = AppAlert(title: "发布失败", message: error.localizedDescription)
        }
    }

    private func editorContent(from trimmedContent: String) -> String {
        guard let originalContent,
              let originalPlainContent,
              trimmedContent == originalPlainContent.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return PaperEditorContentBuilder.editorJSON(from: trimmedContent)
        }
        return originalContent
    }
}

struct PaperCommentComposerSheet: View {
    let target: PaperCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false

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
                .frame(minHeight: AppDesignSystem.Size.content.multilineEditorMinimumHeight)
                .accessibilityLabel(target.placeholder)
            }
        }
        .appGroupedListStyle()
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppComposerToolbar(
                isSubmitting: isSubmitting,
                submitTitle: "发布",
                isSubmitDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: {
                    dismiss()
                },
                onSubmit: {
                    onSubmit(text, anonymous)
                }
            )
        }
    }
}
