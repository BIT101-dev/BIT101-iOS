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
                    TextField("", text: $draft.title, prompt: AppInputPrompt.text("课程名称"))
                    TextField("", text: $draft.teacher, prompt: AppInputPrompt.text("教师"))
                    TextField("", text: $draft.classroom, prompt: AppInputPrompt.text("教室"))
                    TextField("", text: $draft.weeksText, prompt: AppInputPrompt.text("周次（如 1-16,18）"))
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

/// 一门课程的多项时间安排编辑页。
struct CourseArrangementEditorSheet: View {
    @Binding var arrangements: [CourseArrangementDraft]
    let timeTable: [TimeSlot]
    let buildings: [BuildingRecord]
    let mode: CourseArrangementEditorMode
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                ForEach($arrangements) { $arrangement in
                    Section(arrangement.title) {
                        LabeledContent("名称", value: arrangement.original.title)
                        LabeledContent("地点", value: arrangement.original.classroom)
                        LabeledContent("周次", value: "\(arrangement.original.weeksText)周")
                        LabeledContent("星期", value: weekdayText(arrangement.original.weekday))
                        LabeledContent(
                            "节次",
                            value: "第\(arrangement.original.startSection)-\(arrangement.original.endSection)节"
                        )
                    }

                    Section {
                        Picker("楼宇", selection: $arrangement.draft.buildingName) {
                            ForEach(buildings) { building in
                                Text(building.name).tag(building.name)
                            }
                        }
                        .appSelectionFeedback(trigger: arrangement.draft.buildingName)
                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            Text("房间号")
                            Spacer()
                            TextField("", text: $arrangement.draft.roomNumber, prompt: AppInputPrompt.text("房间号"))
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .foregroundStyle(AppDesignSystem.Palette.accent)
                                .tint(AppDesignSystem.Palette.accent)
                        }

                        NavigationLink {
                            ScheduleWeekSelectionSheet(
                                weeks: weekOptions(for: arrangement),
                                selectedWeeks: weekSelectionBinding(for: $arrangement)
                            )
                        } label: {
                            LabeledContent("周次", value: weeksText(for: arrangement.draft))
                        }

                        NavigationLink {
                            ScheduleWeekdaySelectionSheet(
                                selectedWeekday: Binding(
                                    get: { $arrangement.wrappedValue.draft.weekday },
                                    set: { $arrangement.wrappedValue.draft.weekday = $0 }
                                )
                            )
                        } label: {
                            LabeledContent("星期", value: weekdayText(arrangement.draft.weekday))
                        }

                        NavigationLink {
                            ScheduleSectionSelectionSheet(
                                timeTable: timeTable,
                                selectedSections: sectionSelectionBinding(for: $arrangement)
                            )
                        } label: {
                            LabeledContent("节次", value: sectionsText(for: arrangement.draft))
                        }
                    }
                }
            }
            .appGroupedListStyle()
            .tint(AppDesignSystem.Palette.accent)
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

    private func weekSelectionBinding(
        for arrangement: Binding<CourseArrangementDraft>
    ) -> Binding<[Int]> {
        Binding(
            get: {
                (try? ScheduleCourseEditor.parseWeeks(arrangement.wrappedValue.draft.weeksText)) ?? []
            },
            set: { weeks in
                arrangement.wrappedValue.draft.weeksText = ScheduleCourseEditor.formatWeeks(weeks)
            }
        )
    }

    private func sectionSelectionBinding(
        for arrangement: Binding<CourseArrangementDraft>
    ) -> Binding<[Int]> {
        Binding(
            get: {
                let draft = arrangement.wrappedValue.draft
                return draft.selectedSections.isEmpty
                    ? Array(draft.startSection ... draft.endSection)
                    : draft.selectedSections
            },
            set: { sections in
                let sorted = Array(Set(sections)).sorted()
                arrangement.wrappedValue.draft.selectedSections = sorted
                if let first = sorted.first, let last = sorted.last {
                    arrangement.wrappedValue.draft.startSection = first
                    arrangement.wrappedValue.draft.endSection = last
                }
            }
        )
    }

    private func weekOptions(for arrangement: CourseArrangementDraft) -> [Int] {
        Array(-3 ... 16).filter { $0 != 0 }
    }

    private func weeksText(for draft: CourseDraft) -> String {
        let text = draft.weeksText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "请选择" : "\(text)周"
    }

    private func sectionsText(for draft: CourseDraft) -> String {
        let sections = draft.selectedSections.isEmpty
            ? Array(draft.startSection ... draft.endSection)
            : draft.selectedSections.sorted()
        guard let first = sections.first, let last = sections.last else { return "请选择" }
        return sections == Array(first ... last)
            ? "第\(first)-\(last)节"
            : sections.map(String.init).joined(separator: "、") + "节"
    }

    private func weekdayText(_ weekday: Int) -> String {
        let titles = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return titles.indices.contains(weekday) ? titles[weekday] : "请选择"
    }
}

struct ScheduleWeekSelectionSheet: View {
    let weeks: [Int]
    @Binding var selectedWeeks: [Int]

    var body: some View {
        AppMultiSelectionList(
            title: "周次",
            items: weeks,
            itemTitle: { "第\($0)周" },
            selectAllTitle: nil,
            showsCompletionButton: true,
            selectedItems: $selectedWeeks
        )
    }
}

struct ScheduleWeekdaySelectionSheet: View {
    @Binding var selectedWeekday: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(1 ... 7, id: \.self) { weekday in
                Button {
                    selectedWeekday = weekday
                    dismiss()
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text(weekdayText(weekday))
                        Spacer()
                        if selectedWeekday == weekday {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppDesignSystem.Palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("星期")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func weekdayText(_ weekday: Int) -> String {
        ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"][weekday]
    }
}

struct ScheduleSectionSelectionSheet: View {
    let timeTable: [TimeSlot]
    @Binding var selectedSections: [Int]

    var body: some View {
        AppMultiSelectionList(
            title: "节次",
            items: timeTable.map(\.id),
            itemTitle: { id in
                let slot = timeTable.first { $0.id == id }
                return "第\(id)节  \(slot?.start ?? "")-\(slot?.end ?? "")"
            },
            selectAllTitle: nil,
            showsCompletionButton: true,
            selectedItems: $selectedSections
        )
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
                    TextField("", text: $draft.title, prompt: AppInputPrompt.text("标题"))
                    TextField("", text: $draft.subtitle, prompt: AppInputPrompt.text("副标题（通常为地点）"))
                    TextField("", text: $draft.description, prompt: AppInputPrompt.text("描述（详情页显示）"), axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }

                Section("时间") {
                    DatePicker("日期", selection: $draft.date, displayedComponents: .date)
                    DatePicker("开始时间", selection: $draft.beginTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: $draft.endTime, displayedComponents: .hourAndMinute)
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
/// 支持直接批量编辑整份节次表文本。
struct TimeTableEditorSheet: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
                AppCard(variant: .compact) {
                    TextEditor(text: $text)
                        .font(AppDesignSystem.Typography.bodyMonospaced)
                        .frame(minHeight: AppDesignSystem.Size.Content.multilineEditorMinimumHeight)
                }

                Spacer()
            }
            .padding(AppDesignSystem.Spacing.section)
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
/// 课表页右下角加号创建单条自定义日程；此列表页管理全部已有自定义日程。
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
                    AppEmptyState(
                        title: "还没有自定义日程",
                        systemImage: "calendar.badge.plus",
                        message: "点击右上角的加号可以先新增一个。"
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(viewModel.cache.customSchedules) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                                Text(record.title)
                                    .foregroundStyle(.primary)
                                if !record.subtitle.isEmpty {
                                    Text(record.subtitle)
                                        .font(AppDesignSystem.Typography.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(record.dateString)  \(record.beginTime)-\(record.endTime)")
                                    .font(AppDesignSystem.Typography.caption)
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
                            Text(record.title).font(AppDesignSystem.Typography.headline)
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
                            viewModel.notice = ScheduleNotice.userInput(title: "保存失败", message: error.localizedDescription)
                        }
                    },
                    onDismiss: { isShowingEditor = false }
                )
            }
        }
    }
}
