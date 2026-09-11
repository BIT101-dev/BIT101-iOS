//
//  GalleryPosterActionViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

/// 帖子卡片右上角的更多操作菜单提供作者删除入口。
///
/// 菜单按当前帖子场景条件显示删除入口。
struct GalleryPosterActionMenu: View {
    let onDelete: (() -> Void)?
    let onReport: (() -> Void)?
    @State private var isPresentingFallbackActions = false

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                Menu {
                    menuActions
                } label: {
                    menuLabel
                }
            } else {
                Button {
                    isPresentingFallbackActions = true
                } label: {
                    menuLabel
                }
                .confirmationDialog("", isPresented: $isPresentingFallbackActions, titleVisibility: .hidden) {
                    menuActions
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menuActions: some View {
        if let onReport {
            Button("举报帖子", systemImage: "exclamationmark.bubble") {
                onReport()
            }
        }
        if let onDelete {
            Button("删除帖子", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: AppDesignSystem.Size.control.detailActionButton, height: AppDesignSystem.Size.control.detailActionButton)
    }
}

struct GalleryReportSheet: View {
    let target: GalleryReportTarget
    let service: any GalleryReportServicing
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reportTypes: [GalleryReportType] = []
    @State private var selectedTypeID: Int?
    @State private var text = ""
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isShowingSuccess = false

    init(
        target: GalleryReportTarget,
        service: any GalleryReportServicing = GalleryService(),
        onFinished: @escaping () -> Void
    ) {
        self.target = target
        self.service = service
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("举报类型") {
                    if isLoading {
                        ProgressView()
                    } else if reportTypes.isEmpty {
                        Text("暂无可用举报类型")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("类型", selection: Binding(
                            get: { selectedTypeID ?? reportTypes.first?.id ?? 0 },
                            set: { selectedTypeID = $0 }
                        )) {
                            ForEach(reportTypes) { reportType in
                                Text(reportType.text).tag(reportType.id)
                            }
                        }
                        .appSelectionFeedback(trigger: selectedTypeID ?? 0)
                    }
                }

                Section("补充说明") {
                    TextField("请描述举报原因", text: $text, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(AppDesignSystem.Palette.danger)
                    }
                }

                Section {
                    Button(isSubmitting ? "提交中" : "提交举报") {
                        Task { await submit() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isLoading || isSubmitting || selectedTypeID == nil)
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .task { await loadReportTypes() }
            .alert("举报已提交", isPresented: $isShowingSuccess) {
                Button("知道了") { dismiss() }
            } message: {
                Text("感谢你的反馈，社区将继续处理这条举报。")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadReportTypes() async {
        do {
            let remoteTypes = try await service.fetchReportTypes()
            reportTypes = remoteTypes.isEmpty ? GalleryReportType.fallback : remoteTypes
            selectedTypeID = reportTypes.first?.id
        } catch {
            reportTypes = GalleryReportType.fallback
            selectedTypeID = reportTypes.first?.id
        }
        isLoading = false
    }

    private func submit() async {
        guard let selectedTypeID else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await service.report(
                objectID: target.objectID,
                typeID: selectedTypeID,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onFinished()
            isShowingSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}
