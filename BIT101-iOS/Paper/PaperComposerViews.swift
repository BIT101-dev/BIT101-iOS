//
//  PaperComposerViews.swift
//  BIT101-iOS
//
//  Split from PaperRootView.swift.
//

import SwiftUI

/// 文章发布页。
///
/// 当前先提供最小原生编辑器：标题、简介、正文、匿名开关。
/// 正文会在提交前包装成最小 Editor.js JSON，避免和网页端内容格式割裂。
struct PaperComposerView: View {
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var intro = ""
    @State private var content = ""
    @State private var anonymous = false
    @State private var isSubmitting = false
    @State private var alert: AppAlert?

    private let service = PaperService()

    var body: some View {
        Form {
            Section("内容") {
                TextField("标题", text: $title)
                TextField("简介", text: $intro, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                TextField("正文", text: $content, axis: .vertical)
                    .lineLimit(10, reservesSpace: true)
            }

            Section("发布设置") {
                Toggle("匿名发布", isOn: $anonymous)
                    .appSelectionFeedback(trigger: anonymous)
            }
        }
        .navigationTitle("发布文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "发布中…" : "发布") {
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
            alert = AppAlert(title: "发布失败", message: "标题、简介和正文都不能为空。")
            return
        }

        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await service.createPaper(
                title: trimmedTitle,
                intro: trimmedIntro,
                content: PaperEditorContentBuilder.editorJSON(from: trimmedContent),
                anonymous: anonymous
            )
            onCreated()
            dismiss()
        } catch {
            alert = AppAlert(title: "发布失败", message: error.localizedDescription)
        }
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
        VStack(spacing: 0) {
            List {
                AppCommentComposerContentSection(title: target.title, anonymous: $anonymous) {
                    TextEditor(text: $text)
                        .frame(minHeight: AppDesignSystem.Size.content.multilineEditorMinimumHeight)
                }
            }
            .appGroupedListStyle()
        }
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

private struct PaperActionPillButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, AppDesignSystem.Spacing.container)
            .padding(.vertical, AppDesignSystem.Spacing.control)
            .background(AppDesignSystem.Palette.secondaryGroupedBackground, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
