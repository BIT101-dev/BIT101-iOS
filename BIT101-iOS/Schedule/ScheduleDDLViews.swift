//
//  ScheduleDDLViews.swift
//  BIT101-iOS
//
//  Split from ScheduleRootView.swift.
//

import SwiftUI


/// DDL 分页。
///
/// DDL 页当前走最原生的 `List(.insetGrouped)`，与成绩和空教室保持一致。
struct DDLScheduleTabView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var selectedEvent: DDLEventRecord?
    @State private var draft = DDLDraft()
    @State private var editingEventID: String?
    @State private var isShowingEditor = false
    @State private var settingsRoute: SettingsRoute?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)

            Group {
                if !viewModel.hasLexueCalendarURL {
                    VStack(spacing: 16) {
                        Button {
                            Task {
                                await viewModel.refreshLexueCalendarURL(showSuccessNotice: false)
                                await viewModel.syncDDL()
                            }
                        } label: {
                            HStack {
                                if viewModel.isSyncingDDL {
                                    ProgressView()
                                }
                                Text("获取乐学日程")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isSyncingDDL)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if viewModel.visibleDDLEvents.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "暂无 DDL",
                                    systemImage: "list.bullet.clipboard",
                                    description: Text("先获取乐学日程，或手动添加一条。")
                                )
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            Section {
                                ForEach(viewModel.visibleDDLEvents) { event in
                                    DDLEventCard(
                                        event: event,
                                        remainText: viewModel.ddlRemainingText(for: event),
                                        dueText: viewModel.ddlDueText(for: event),
                                        tint: color(for: event),
                                        onToggleDone: { viewModel.toggleDDLDone(event) },
                                        onOpenDetail: { selectedEvent = event }
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }

            VStack(spacing: 10) {
                CourseScheduleFAB(systemImage: "plus") {
                    editingEventID = nil
                    draft = DDLDraft()
                    isShowingEditor = true
                }

                CourseScheduleFAB(systemImage: "gearshape") {
                    settingsRoute = .ddl
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .sheet(item: $selectedEvent) { event in
            DDLEventDetailSheet(
                event: event,
                remainText: viewModel.ddlRemainingText(for: event),
                onEdit: {
                    editingEventID = event.id
                    draft = viewModel.ddlDraft(for: event)
                    isShowingEditor = true
                },
                onDelete: {
                    viewModel.deleteDDL(id: event.id)
                    selectedEvent = nil
                }
            )
        }
        .sheet(isPresented: $isShowingEditor) {
            DDLEditSheet(
                draft: $draft,
                isEditing: editingEventID != nil,
                onSubmit: {
                    do {
                        if let editingEventID {
                            try viewModel.updateDDL(id: editingEventID, draft: draft)
                        } else {
                            try viewModel.addDDL(draft)
                        }
                        isShowingEditor = false
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                    }
                },
                onDismiss: { isShowingEditor = false }
            )
        }
        .sheet(item: $settingsRoute) { route in
            NavigationStack {
                SettingsRootView(initialRoute: route, studentID: "", onLogout: {}, showsCloseButton: true)
            }
        }
    }

    private func color(for event: DDLEventRecord) -> Color {
        switch viewModel.ddlTint(for: event) {
        case "red":
            return .red
        case "orange":
            return .orange
        case "gray":
            return .gray
        default:
            return .green
        }
    }
}

/// DDL 列表卡片。
///
/// DDL 虽然放在 `List` 里，但单条仍保留卡片式内容区，以便容纳剩余时间、详情摘要和完成按钮。
private struct DDLEventCard: View {
    let event: DDLEventRecord
    let remainText: String
    let dueText: String
    let tint: Color
    let onToggleDone: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggleDone) {
                Image(systemName: event.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(event.title)
                    .font(.headline)
                    .strikethrough(event.done)

                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text(remainText)
                    .font(.subheadline)
                    .foregroundStyle(tint)

                Text(dueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpenDetail)
    }

    private var displayText: String {
        event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// DDL 详情页。
///
/// 乐学同步项只允许查看，不允许编辑和删除；手动项才会出现编辑/删除按钮。
private struct DDLEventDetailSheet: View {
    let event: DDLEventRecord
    let remainText: String
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title)
                        .font(.headline)
                        .strikethrough(event.done)
                    Text(ScheduleDateCodec.formatDateTime(event.dueAt))
                        .foregroundStyle(.secondary)
                    Text(event.group == "lexue" ? "乐学" : "自定义")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("详情") {
                    Text(remainText)
                    Text(detailText.isEmpty ? "无详情" : detailText)
                }

                if event.group != "lexue" {
                    Section {
                        Button("编辑") {
                            dismiss()
                            onEdit()
                        }
                        Button("删除", role: .destructive) {
                            onDelete()
                        }
                    }
                }
            }
            .navigationTitle("DDL 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var detailText: String {
        event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 自定义 DDL 编辑页。
///
/// 这里同时服务新增和编辑两种场景，仅靠 `isEditing` 调整标题文案。
private struct DDLEditSheet: View {
    @Binding var draft: DDLDraft
    let isEditing: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $draft.title)
                    DatePicker("时间", selection: $draft.dueAt, displayedComponents: [.date, .hourAndMinute])
                    TextField("详情", text: $draft.text, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                }
            }
            .navigationTitle(isEditing ? "编辑 DDL" : "添加 DDL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
