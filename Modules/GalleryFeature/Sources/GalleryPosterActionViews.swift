#if os(iOS)
import CommunityUI
import TransportCore
import DesignSystemKit
import SwiftUI

struct GalleryReportSheet: View {
    let target: GalleryReportTarget
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: GalleryReportViewModel
    @State private var isShowingSuccess = false

    init(
        target: GalleryReportTarget,
        service: any GalleryReportServicing,
        onFinished: @escaping () -> Void
    ) {
        self.target = target
        _model = State(initialValue: GalleryReportViewModel(service: service))
        self.onFinished = onFinished
    }

    private var selectedTypeBinding: Binding<Int> {
        Binding(
            get: { model.selectedTypeID ?? model.reportTypes.first?.id ?? 0 },
            set: { model.selectedTypeID = $0 }
        )
    }

    @ViewBuilder
    private var reportTypePicker: some View {
        Picker("类型", selection: selectedTypeBinding) {
            ForEach(model.reportTypes) { reportType in
                Text(reportType.text).tag(reportType.id)
            }
        }
        .appSelectionFeedback(trigger: model.selectedTypeID ?? 0)
        .appInteractiveListRow()
    }

    @ViewBuilder
    private var reportTypeContent: some View {
        if model.isLoading {
            ProgressView()
        } else if model.reportTypes.isEmpty {
            Text("暂无可用举报类型")
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
            Button("重新加载", action: reloadReportTypes)
                .appInteractiveListRow()
                .accessibilityIdentifier("ui.gallery-report-sheet.reload")
        } else {
            reportTypePicker
        }
    }

    @ViewBuilder
    private var submitSection: some View {
        Section {
            Button(model.isSubmitting ? "提交中" : "提交举报", action: handleSubmitAction)
                .frame(maxWidth: .infinity)
                .disabled(
                    model.isLoading || model.isSubmitting || model.resultNeedsReview
                        || model.selectedTypeID == nil
                )
                .appInteractiveListRow()
                .accessibilityIdentifier("ui.gallery-report-sheet.submit")
        }
    }

    private func reloadReportTypes() {
        Task { await model.loadReportTypes() }
    }

    private func handleSubmitAction() {
        Task { await submit() }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("举报类型") {
                    reportTypeContent
                }

                Section("补充说明") {
                    TextField(
                        "", text: $model.text, prompt: AppInputPrompt.text("请描述举报原因"),
                        axis: .vertical
                    )
                    .lineLimit(4, reservesSpace: true)
                    .accessibilityLabel("请描述举报原因")
                    .accessibilityIdentifier("gallery.report.reason")
                }

                if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(AppDesignSystem.Palette.Status.danger)
                    }
                }

                submitSection
            }
            .disabled(model.isSubmitting || model.resultNeedsReview)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    AppCancelEditingButton(confirmDiscard: model.hasChanges) { dismiss() }
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier("ui.gallery-report-sheet.cancel")
                }
            }
            .task { await model.loadReportTypes() }
            .alert("举报已提交", isPresented: $isShowingSuccess) {
                Button("知道了") { dismiss() }
                    .accessibilityIdentifier("ui.gallery-report-sheet.知道了")
            } message: {
                Text("感谢你的反馈，社区将继续处理这条举报。")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isSubmitting || model.hasChanges)
        .onDisappear { model.cancel() }
    }

    private func submit() async {
        guard await model.submit(objectID: target.objectID) else { return }
        onFinished()
        isShowingSuccess = true
    }
}

#endif
