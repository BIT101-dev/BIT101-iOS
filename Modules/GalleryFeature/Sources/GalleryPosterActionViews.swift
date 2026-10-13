#if os(iOS)
import CommunityUI
import TransportCore
import DesignSystemKit
//
//  GalleryPosterActionViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

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

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("举报类型") {
                    if model.isLoading {
                        ProgressView()
                    } else if model.reportTypes.isEmpty {
                        Text("暂无可用举报类型")
                            .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        Button("重新加载") { Task { await model.loadReportTypes() } }
                            .appInteractiveListRow()
                            .accessibilityIdentifier("ui.gallery-report-sheet.reload")
                    } else {
                        Picker("类型", selection: Binding(
                            get: { model.selectedTypeID ?? model.reportTypes.first?.id ?? 0 },
                            set: { model.selectedTypeID = $0 }
                        )) {
                            ForEach(model.reportTypes) { reportType in
                                Text(reportType.text).tag(reportType.id)
                            }
                        }
                        .appSelectionFeedback(trigger: model.selectedTypeID ?? 0)
                        .appInteractiveListRow()
                    }
                }

                Section("补充说明") {
                    TextField("", text: $model.text, prompt: AppInputPrompt.text("请描述举报原因"), axis: .vertical)
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

                Section {
                    Button(model.isSubmitting ? "提交中" : "提交举报") {
                        Task { await submit() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(model.isLoading || model.isSubmitting || model.resultNeedsReview || model.selectedTypeID == nil)
                    .appInteractiveListRow()
                        .accessibilityIdentifier("ui.gallery-report-sheet.submit")
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
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
        .onDisappear { model.cancel() }
    }

    private func submit() async {
        guard await model.submit(objectID: target.objectID) else { return }
        onFinished()
        isShowingSuccess = true
    }
}

#endif
