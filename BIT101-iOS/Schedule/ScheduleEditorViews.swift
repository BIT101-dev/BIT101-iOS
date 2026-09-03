//
//  ScheduleEditorViews.swift
//  BIT101-iOS
//
//  Split from ScheduleRootView.swift.
//

import SwiftUI


/// 新增课程弹层。
///
/// 这是纯本地课程的补录入口，主要用于补一周里的临时课或手动修正课表。
struct AddCourseSheet: View {
    @Binding var draft: CourseDraft
    let mode: CourseEditorMode
    let timeTable: [TimeSlot]
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    private let weekdays = Array(1 ... 7)

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("课程名称", text: $draft.title)
                    TextField("教师", text: $draft.teacher)
                    TextField("教室", text: $draft.classroom)
                    if mode.locksWeeks, let fixedWeek = mode.fixedWeek {
                        LabeledContent("周次") {
                            Text("第\(fixedWeek)周")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("周次（如 1-16,18）", text: $draft.weeksText)
                    }
                }

                Section("时间") {
                    Picker("星期", selection: $draft.weekday) {
                        ForEach(weekdays, id: \.self) { weekday in
                            Text("周\(weekday)").tag(weekday)
                        }
                    }
                    .appSelectionFeedback(trigger: draft.weekday)

                    Picker("开始节次", selection: $draft.startSection) {
                        ForEach(timeTable) { slot in
                            Text("第\(slot.id)节  \(slot.start)").tag(slot.id)
                        }
                    }
                    .appSelectionFeedback(trigger: draft.startSection)

                    Picker("结束节次", selection: $draft.endSection) {
                        ForEach(timeTable.filter { $0.id >= draft.startSection }) { slot in
                            Text("第\(slot.id)节  \(slot.end)").tag(slot.id)
                        }
                    }
                    .appSelectionFeedback(trigger: draft.endSection)
                }

                Section {
                    Text(mode.footerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(mode.title)
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
    }
}

/// 新增 / 编辑自定义日程弹层。
///
/// 课表页和自定义日程列表页都共用这一套编辑器。
struct AddEditCustomScheduleSheet: View {
    @Binding var draft: CustomScheduleDraft
    let isEditing: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $draft.title)
                    TextField("副标题（通常为地点）", text: $draft.subtitle)
                    TextField("描述（详情页显示）", text: $draft.description, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }

                Section("时间") {
                    DatePicker("日期", selection: $draft.date, displayedComponents: .date)
                    DatePicker("开始时间", selection: $draft.beginTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: $draft.endTime, displayedComponents: .hourAndMinute)
                }

                Section {
                    Text("请不要把时间设在课间或极短时段，和其它日程冲突时会发生覆盖。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
          }
            .navigationTitle(isEditing ? "修改自定义日程" : "添加自定义日程")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: draft.beginTime) { _, newValue in
                guard draft.endTime <= newValue else { return }
                draft.endTime = Calendar.current.date(byAdding: .minute, value: 60, to: newValue) ?? newValue
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}

/// 时间表编辑器。
///
/// 这是一个偏工程化的入口，允许直接批量编辑整份节次表文本。
struct TimeTableEditorSheet: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("每行格式：开始时间, 结束时间")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                AppCard(variant: .compact) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                }

                Spacer()
            }
            .padding(16)
            .navigationTitle("设置时间表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}

/// 自定义日程列表页。
///
/// 从课表页右下角加号新增的是单条自定义日程；这张列表页则负责管理全部已有自定义日程。
struct CustomScheduleListSheet: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecord: CustomScheduleRecord?
    @State private var editingRecordID: String?
    @State private var draft = CustomScheduleDraft()
    @State private var isShowingEditor = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.cache.customSchedules.isEmpty {
                    ContentUnavailableView(
                        "还没有自定义日程",
                        systemImage: "calendar.badge.plus",
                        description: Text("点击右上角的加号可以先新增一个。")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(viewModel.cache.customSchedules) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title)
                                    .foregroundStyle(.primary)
                                Text(record.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("\(record.dateString)  \(record.beginTime)-\(record.endTime)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .appGroupedListStyle()
            .navigationTitle("自定义日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingRecordID = nil
                        draft = viewModel.customScheduleDraft(for: nil)
                        isShowingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $selectedRecord) { record in
                NavigationStack {
                    List {
                        Section {
                            Text(record.title).font(.headline)
                            if !record.subtitle.isEmpty {
                                Text(record.subtitle).foregroundStyle(.secondary)
                            }
                        }

                        Section("详情") {
                            Text(record.description.isEmpty ? "无描述" : record.description)
                            Text(record.dateString)
                            Text("\(record.beginTime) - \(record.endTime)")
                        }

                        Section {
                            Button("编辑") {
                                selectedRecord = nil
                                editingRecordID = record.id
                                draft = viewModel.customScheduleDraft(for: record)
                                isShowingEditor = true
                            }
                            Button("删除", role: .destructive) {
                                viewModel.deleteCustomSchedule(id: record.id)
                                selectedRecord = nil
                            }
                        }
                    }
                    .appGroupedListStyle()
                    .navigationTitle("自定义日程")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { selectedRecord = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingEditor) {
                AddEditCustomScheduleSheet(
                    draft: $draft,
                    isEditing: editingRecordID != nil,
                    onSubmit: {
                        do {
                            if let editingRecordID {
                                try viewModel.updateCustomSchedule(id: editingRecordID, draft: draft)
                            } else {
                                try viewModel.addCustomSchedule(draft)
                            }
                            isShowingEditor = false
                        } catch {
                            viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                        }
                    },
                    onDismiss: { isShowingEditor = false }
                )
            }
        }
    }
}
