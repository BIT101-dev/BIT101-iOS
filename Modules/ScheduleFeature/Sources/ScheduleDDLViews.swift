#if os(iOS)
import ScheduleDomain
import DesignSystemKit
//
//  ScheduleDDLViews.swift
//  BIT101-iOS
//
//

import SwiftUI
import PhotosUI
import MediaKit
import TransportCore
import UIKit

/// DDL 分页。
///
/// 待办沿分组列表呈现，横屏与课表并排。
struct DDLScheduleTabView: View {
    @Environment(\.scheduleCurrentDate) private var currentDate
    @Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: ScheduleDDLViewModel
    @State private var imageViewer: ImagePreviewRequest?
    @State private var selectedEvent: DDLEventRecord?
    @State private var draft = DDLDraft()
    @State private var editingEventID: String?
    @State private var isShowingSheet = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppDesignSystem.Palette.Background.grouped
                .ignoresSafeArea(edges: .bottom)

            eventList


            AppFloatingActionStack {
                AppFloatingActionButton(systemImage: "plus", accessibilityLabel: "添加待办") {
                    selectedEvent = nil
                    editingEventID = nil
                    draft = DDLDraft()
                    isShowingSheet = true
                }
                .disabled(!viewModel.isCacheWritable)

            }
        }
        .sheet(isPresented: $isShowingSheet) {
            if let event = selectedEvent {
                DDLEventDetailSheet(event: event, isEditable: viewModel.isCacheWritable,
                    remainText: { viewModel.ddlRemainingText(for: event, now: $0) },
                    onEdit: {
                        editingEventID = event.id
                        draft = viewModel.ddlDraft(for: event)
                        selectedEvent = nil
                    },
                    onDelete: {
                        do {
                            try viewModel.deleteDDL(id: event.id)
                            isShowingSheet = false
                        } catch {
                            viewModel.notice = ScheduleNotice.userInput(title: "删除失败", message: error.localizedDescription)
                        }
                    })
            } else {
                DDLEditSheet(draft: $draft, isEditing: editingEventID != nil,
                    onSubmit: {
                        do {
                            if let editingEventID { try viewModel.updateDDL(id: editingEventID, draft: draft) }
                            else { try viewModel.addDDL(draft) }
                            isShowingSheet = false
                        } catch {
                            viewModel.notice = ScheduleNotice.userInput(title: "保存失败", message: error.localizedDescription)
                        }
                    }, onDismiss: { isShowingSheet = false })
            }
        }
        .onChange(of: isShowingSheet) { _, visible in
            if !visible { editingEventID = nil; selectedEvent = nil }
        }
        .systemImagePreview(item: $imageViewer)
    }

    private var eventList: some View {
        List {
            Section { refreshRow }

            if viewModel.visibleDDLEvents(at: currentDate).isEmpty {
                Section {
                    AppEmptyState(
                        title: "暂无 DDL",
                        systemImage: "list.bullet.clipboard",
                        message: viewModel.ddlEmptyStateMessage
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(viewModel.visibleDDLEvents(at: currentDate)) { event in
                    Section {
                        eventRow(event)
                        .appListRowInsets()
                    }
                }
            }
        }
        .accessibilityIdentifier("interaction.DDLScheduleTabView.list")
        .appGroupedListStyle()
        .scrollContentBackground(.hidden)
    }

    private var refreshRow: some View { DDLRefreshStatusRow(viewModel: viewModel) }

    private func eventRow(_ event: DDLEventRecord) -> some View {
        DDLEventRow(
            event: event,
            remainText: viewModel.ddlRemainingText(for: event, now: currentDate),
            dueText: viewModel.ddlDueText(for: event),
            tint: color(for: event),
            isEditable: viewModel.isCacheWritable,
            onPreview: { imageViewer = $0 },
            onToggleDone: { viewModel.toggleDDLDone(event) },
            onOpen: {
                if let url = event.browserURL { openURL(url) }
                else { selectedEvent = event; isShowingSheet = true }
            }
        )
    }


    private func color(for event: DDLEventRecord) -> Color {
        switch viewModel.ddlTint(for: event, now: currentDate) {
        case "red":
            return AppDesignSystem.Palette.Status.danger
        case "orange":
            return AppDesignSystem.Palette.Highlight.primary
        case "gray":
            return AppDesignSystem.Palette.Status.neutral
        default:
            return AppDesignSystem.Palette.Status.success
        }
    }
}

/// 每条 DDL 使用独立分组卡片，沿系统背景展示剩余时间、详情摘要和完成按钮。
private struct DDLEventRow: View {
    let event: DDLEventRecord
    let remainText: String
    let dueText: String
    let tint: Color
    let isEditable: Bool
    let onPreview: (ImagePreviewRequest) -> Void
    let onToggleDone: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            eventContent
            if let images = event.images, !images.isEmpty { DDLImageStrip(images: images, onPreview: onPreview) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ddl.event.\(event.id)")
        .accessibilityAction(named: event.browserURL == nil ? "打开详情" : "在浏览器打开", onOpen)
    }

    private var eventContent: some View {
        HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
            Button(action: onOpen) {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                Text(event.displayTitle)
                    .font(AppDesignSystem.Typography.title)
                    .strikethrough(event.done)

                if !displayText.isEmpty {
                    Text(displayText)
                        .font(AppDesignSystem.Typography.body)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        .lineLimit(3)
                        .accessibilityIdentifier("ddl.preview.\(event.id)")
                }

                Text(remainText)
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(tint)

                HStack(alignment: .firstTextBaseline, spacing: AppDesignSystem.Spacing.regular) {
                    Text(dueText)
                        .accessibilityIdentifier("ddl.due.\(event.id)")
                    Text(event.sourceTitle)
                        .accessibilityIdentifier("ddl.source.\(event.id)")
                }
                .font(AppDesignSystem.Typography.body)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
            }

            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ddl.open.\(event.id)")

            Button(action: onToggleDone) {
                Image(systemName: event.done ? "checkmark.circle.fill" : "circle")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(tint)
                    .frame(width: AppDesignSystem.Size.Control.touchTarget, height: AppDesignSystem.Size.Control.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
            .appSelectionFeedback(trigger: event.done)
            .accessibilityLabel(event.done ? "标记为未完成" : "标记为已完成")
            .accessibilityValue(event.done ? "已完成" : "未完成")
            .accessibilityIdentifier("ddl.done.\(event.id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ddl.content.\(event.id)")
    }

    private var displayText: String {
        event.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct DDLRefreshStatusRow: View {
    @ObservedObject var viewModel: ScheduleDDLViewModel
    var body: some View {
        AppRefreshStatusRow(isRefreshing: viewModel.isSyncingDDL, refreshingText: "正在刷新 DDL",
            lastUpdatedText: viewModel.ddlLastUpdatedText, actionTitle: "刷新",
            onRefresh: { Task { await viewModel.refreshFromUser() } })
    }
}

/// DDL 详情页。
///
/// 学校同步项展示详情；手动项提供编辑和删除按钮。
private struct DDLEventDetailSheet: View {
    @Environment(\.scheduleCurrentDate) private var currentDate
    let event: DDLEventRecord
    let isEditable: Bool
    let remainText: (Date) -> String
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var imageViewer: ImagePreviewRequest?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.displayTitle)
                        .font(AppDesignSystem.Typography.title)
                        .strikethrough(event.done)
                    Text(ScheduleDateCodec.formatDateTime(event.dueAt))
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    Text(event.sourceTitle)
                        .font(AppDesignSystem.Typography.subheadline)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }

                Section("详情") {
                    Text(remainText(currentDate))
                    Text(detailText.isEmpty ? "无详情" : detailText)
                }

                if let images = event.images, !images.isEmpty {
                    Section("图片") { DDLImageStrip(images: images, onPreview: { imageViewer = $0 }) }
                }

                if !event.isSchoolSynced && isEditable {
                    Section {
                        Button("编辑") {
                            onEdit()
                        }
                        .appInteractiveListRow()
                            .accessibilityIdentifier("ui.ddl-event-detail-sheet.edit")
                        Button("删除", role: .destructive) {
                            onDelete()
                        }
                        .appInteractiveListRow(isDestructive: true)
                            .accessibilityIdentifier("ui.ddl-event-detail-sheet.delete")
                    }
                }
            }
            .accessibilityIdentifier("interaction.DDLEventDetailSheet.list")
            .appGroupedListStyle()
            .navigationTitle("DDL 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("ui.ddl-event-detail-sheet.cancel")
                }
            }
        }
        .systemImagePreview(item: $imageViewer)
    }

    private var detailText: String {
        event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 自定义 DDL 编辑页。
///
/// 新增和编辑共用此页面；`isEditing` 决定标题文案。
private struct DDLEditSheet: View {
    @Binding var draft: DDLDraft
    let isEditing: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @Environment(MediaEnvironment.self) private var media
    @State private var imageViewer: ImagePreviewRequest?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importError: String?
    @State private var initialDraft: DDLDraft?
    private var hasChanges: Bool { initialDraft.map { $0 != draft } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("", text: $draft.title, prompt: AppInputPrompt.text("标题"))
                        .accessibilityIdentifier("ddl.editor.title")
                    DatePicker("时间", selection: $draft.dueAt, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.calendar, ScheduleDateCodec.calendar)
                        .environment(\.timeZone, ScheduleDateCodec.calendar.timeZone)
                        .accessibilityIdentifier("ddl.editor.date")
                    .appInteractiveListRow()
                    TextField("", text: $draft.text, prompt: AppInputPrompt.text("详情"), axis: .vertical)
                        .accessibilityIdentifier("ddl.editor.details")
                        .lineLimit(4, reservesSpace: true)
                }
                Section("图片") {
                    if !draft.images.isEmpty {
                        DDLImageStrip(images: draft.images, onRemove: { id in draft.images.removeAll { $0.id == id } },
                            onPreview: { imageViewer = $0 })
                    }
                    if draft.images.count < DDLImagePolicy.maximumImageCount {
                        PhotosPicker(selection: $selectedPhotos,
                            maxSelectionCount: DDLImagePolicy.maximumImageCount - draft.images.count, matching: .images) {
                            Text("添加图片")
                        }
                        .disabled(isImporting)
                        .appInteractiveListRow()
                        .accessibilityIdentifier("ddl.editor.photos")
                    }
                    if isImporting { AppInlineLoadingState("正在处理图片") }
                    if let importError { Text(importError).foregroundStyle(AppDesignSystem.Palette.Status.danger) }
                }
            }
            .navigationTitle(isEditing ? "编辑 DDL" : "添加 DDL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppCancelEditingButton(confirmDiscard: hasChanges || isImporting || !selectedPhotos.isEmpty, onCancel: onDismiss)
                        .accessibilityIdentifier("ui.ddl-edit-sheet.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                        .disabled(isImporting || !selectedPhotos.isEmpty)
                        .accessibilityIdentifier("ddl.editor.save")
                }
            }
        }
        .systemImagePreview(item: $imageViewer)
        .task(id: selectedPhotos) { await importPhotos() }
        .onAppear { if initialDraft == nil { initialDraft = draft } }
        .interactiveDismissDisabled(hasChanges || isImporting || !selectedPhotos.isEmpty)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func importPhotos() async {
        guard !selectedPhotos.isEmpty else { return }
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            for item in selectedPhotos {
                try Task.checkCancellation()
                guard let data = try await media.loadBoundedImageData(from: item) else { throw CocoaError(.fileReadCorruptFile) }
                let prepared = try await ImageDataCompressor.prepare(data, maximumBytes: DDLImagePolicy.maximumImageBytes)
                try Task.checkCancellation()
                draft.images.append(DDLImageAttachment(data: prepared))
            }
        } catch {
            guard !TaskCancellation.matches(error) else { return }
            importError = "图片处理失败：\(error.localizedDescription)"
        }
        selectedPhotos = []
    }
}

private struct DDLImageStrip: View {
    let images: [DDLImageAttachment]
    var onRemove: ((UUID) -> Void)? = nil
    let onPreview: (ImagePreviewRequest) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: AppDesignSystem.Spacing.regular) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    LocalImageTile(data: image.data, identifier: "ddl.image.\(image.id)",
                        pointSize: onRemove == nil ? AppDesignSystem.Size.Media.attachment : AppDesignSystem.Size.Media.draft,
                        onOpen: { onPreview(ImagePreviewRequest(localImageData: images.map(\.data), initialIndex: index)) },
                        onRemove: onRemove.map { remove in { remove(image.id) } }, previewLabel: "预览 DDL 图片")
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("interaction.DDLImageStrip.scroll")
    }
}

#endif
