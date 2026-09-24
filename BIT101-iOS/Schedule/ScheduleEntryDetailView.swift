//
//  ScheduleEntryDetailView.swift
//  BIT101-iOS
//

import SwiftUI

/// 课表条目详情。
///
/// 课表块点击后的二级详情页，兼容课程、考试和自定义日程三种来源。
struct ScheduleEntryDetailSheet: View {
    let entry: ScheduleCalendarEntry
    let academicCourses: [CourseRecord]
    let currentWeek: Int
    let currentTerm: String
    let allowsCourseMutation: Bool
    let allowsCustomScheduleMutation: Bool
    let onOpenAcademicCourse: (CourseNavigationRequest) -> Void
    let onOpenCourseLocation: (CampusMapLocationRequest) -> Void
    let timeTable: [TimeSlot]
    let buildings: [BuildingRecord]
    let courseArrangementDraftsForCourse: (String) -> [CourseArrangementDraft]
    let courseArrangementDraftForOccurrence: (String, Int) -> CourseArrangementDraft?
    let onSaveCourseArrangements: ([CourseArrangementDraft], CourseArrangementEditorMode) -> Bool
    let onDeleteCourseOccurrence: (String, Int) -> Void
    let onDeleteCourse: (String) -> Void
    let onImportCourseOccurrence: (String, Int) -> Void
    let onImportCourse: (String) -> Void
    let onDeleteCalendarMarkers: (Set<String>, String) -> Void
    let onDeleteCalendarCourse: (String, String) -> Void
    let onImportExam: (String) -> Void
    let onImportCustomSchedule: (String) -> Void
    let onDeleteCalendarEntry: (String, String) -> Void
    let onEditCustomSchedule: () -> Void
    let onDeleteCustomSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCourseDeletion: PendingCourseDeletion?
    @State private var academicCourseAlert: AppAlert?
    @State private var courseArrangementDrafts: [CourseArrangementDraft] = []
    @State private var courseArrangementEditorMode: CourseArrangementEditorMode = .course
    @State private var isShowingCourseArrangementEditor = false

    private struct CourseAttributeRow: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    var body: some View {
        NavigationStack {
            List {
                if entry.kind == .course, !academicCourseGroups.isEmpty {
                    courseDetailSections
                } else {
                    Section {
                        Text(entry.title)
                            .font(AppDesignSystem.Typography.title)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !entry.detailLines.isEmpty {
                        Section("详情") {
                            ForEach(entry.detailLines, id: \.self) { line in
                                Text(line)
                            }
                        }
                    }

                    if entry.kind == .exam {
                        Section {
                            Button("导入考试到日历") {
                                onImportExam(entry.sourceID)
                            }
                            Button("移除考试日历事件", role: .destructive) {
                                onDeleteCalendarEntry("exam-\(entry.sourceID)", currentTerm)
                            }
                        }
                    }
                }

                if entry.kind == .custom, allowsCustomScheduleMutation {
                    Section {
                        Button("编辑") {
                            dismiss()
                            onEditCustomSchedule()
                        }
                        Button("删除", role: .destructive) {
                            dismiss()
                            onDeleteCustomSchedule()
                        }
                    }

                    Section {
                        Button("导入到系统日历") {
                            onImportCustomSchedule(entry.sourceID)
                        }
                        Button("移除日历事件", role: .destructive) {
                            onDeleteCalendarEntry("custom-\(entry.sourceID)", currentTerm)
                        }
                    }
                }
            }
            .appGroupedListStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingCourseArrangementEditor) {
                CourseArrangementEditorSheet(
                    arrangements: $courseArrangementDrafts,
                    timeTable: timeTable,
                    buildings: buildings,
                    mode: courseArrangementEditorMode,
                    onSubmit: {
                        if onSaveCourseArrangements(courseArrangementDrafts, courseArrangementEditorMode) {
                            courseArrangementDrafts = []
                            isShowingCourseArrangementEditor = false
                        }
                    },
                    onDismiss: {
                        courseArrangementDrafts = []
                        isShowingCourseArrangementEditor = false
                    }
                )
            }
            .alert(item: $pendingCourseDeletion) { target in
                Alert(
                    title: Text("确认删除"),
                    message: Text(target.message),
                    primaryButton: .destructive(Text("删除")) {
                        switch target {
                        case let .occurrence(_, _, week):
                            onDeleteCourseOccurrence(target.courseID, week)
                        case .wholeCourse:
                            onDeleteCourse(target.courseID)
                        }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .diagnosticAlert(item: $academicCourseAlert)
        }
    }

    private var title: String {
        switch entry.kind {
        case .course: return "课程详情"
        case .exam: return "考试详情"
        case .custom: return "自定义日程"
        }
    }

    private enum PendingCourseDeletion: Identifiable {
        case occurrence(courseID: String, courseName: String, week: Int)
        case wholeCourse(courseID: String, courseName: String)

        var id: String {
            switch self {
            case let .occurrence(courseID, _, _): return "occurrence-\(courseID)"
            case let .wholeCourse(courseID, _): return "whole-\(courseID)"
            }
        }

        var courseID: String {
            switch self {
            case let .occurrence(courseID, _, _), let .wholeCourse(courseID, _): return courseID
            }
        }

        var message: String {
            switch self {
            case let .occurrence(_, courseName, week):
                return "你要删除的是第\(week)周的一节课：\(courseName)"
            case let .wholeCourse(_, courseName):
                return "你要删除的是\(courseName)这门课的本学期所有课程"
            }
        }
    }

    @ViewBuilder
    private var courseDetailSections: some View {
        ForEach(academicCourseGroupsByCourse.indices, id: \.self) { index in
            let arrangements = academicCourseGroupsByCourse[index]
            let allCourses = arrangements.flatMap { $0 }
            let first = allCourses[0]
            let target = mutationTarget(for: allCourses)
            Section {
                ForEach(courseAttributeRows(for: allCourses), id: \.label) { row in
                    LabeledContent(row.label, value: row.value)
                }
                Text(arrangements.map(arrangementText).joined(separator: "\n"))
            }

            Section {
                academicCourseRow(for: allCourses)

                Button {
                    let places = mapPlaces(for: allCourses)
                    guard !places.isEmpty else {
                        academicCourseAlert = AppAlert.userInput(
                            title: "没有找到上课地点",
                            message: "这门课的教室暂时无法匹配到校园地图。"
                        )
                        return
                    }
                    dismiss()
                    onOpenCourseLocation(
                        CampusMapLocationRequest(
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name),
                            places: places
                        )
                    )
                } label: {
                    Text("查看上课地点")
                }
            }

            if allowsCourseMutation {
                Section {
                    Button("调这节课") {
                        guard let draft = courseArrangementDraftForOccurrence(target.course.id, target.week) else { return }
                        courseArrangementDrafts = [draft]
                        courseArrangementEditorMode = .occurrence(week: target.week)
                        isShowingCourseArrangementEditor = true
                    }
                    Button("调这门课") {
                        courseArrangementDrafts = courseArrangementDraftsForCourse(first.id)
                        courseArrangementEditorMode = .course
                        isShowingCourseArrangementEditor = true
                    }
                    Button("删除这节课", role: .destructive) {
                        pendingCourseDeletion = .occurrence(
                            courseID: target.course.id,
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name),
                            week: target.week
                        )
                    }
                    Button("删除这门课", role: .destructive) {
                        pendingCourseDeletion = .wholeCourse(
                            courseID: first.id,
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name)
                        )
                    }
                }

                Section {
                    Button("导入这节课到日历") {
                        onImportCourseOccurrence(target.course.id, target.week)
                    }
                    Button("导入这门课到日历") {
                        onImportCourse(first.id)
                    }
                    Button("移除这节课日历事件", role: .destructive) {
                        onDeleteCalendarMarkers(["\(target.course.id)-w\(target.week)"], currentTerm)
                    }
                    Button("移除这门课日历事件", role: .destructive) {
                        onDeleteCalendarCourse(first.id, currentTerm)
                    }
                }
            }

            if index < academicCourseGroupsByCourse.count - 1 {
                Divider()
                    .listRowInsets(EdgeInsets(
                        top: AppDesignSystem.Spacing.content,
                        leading: AppDesignSystem.Spacing.none,
                        bottom: AppDesignSystem.Spacing.content,
                        trailing: AppDesignSystem.Spacing.none
                    ))
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var academicCourseGroups: [[CourseRecord]] {
        var groups: [[CourseRecord]] = []
        for course in academicCourses {
            if let index = groups.firstIndex(where: {
                scheduleCourseArrangementIdentity($0[0]) == scheduleCourseArrangementIdentity(course)
            }) {
                groups[index].append(course)
            } else {
                groups.append([course])
            }
        }
        return groups
    }

    private var academicCourseGroupsByCourse: [[[CourseRecord]]] {
        var result: [[[CourseRecord]]] = []
        for arrangement in academicCourseGroups {
            let identity = scheduleCourseIdentity(arrangement[0])
            if let index = result.firstIndex(where: {
                scheduleCourseIdentity($0[0][0]) == identity
            }) {
                result[index].append(arrangement)
            } else {
                result.append([arrangement])
            }
        }
        return result
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func mapPlaces(for group: [CourseRecord]) -> [CampusMapPlace] {
        var seen = Set<String>()
        return group.compactMap { course in
            guard let place = CampusMapPlaceCatalog.place(
                campusName: course.campus,
                classroom: course.classroom
            ), seen.insert(place.id).inserted else {
                return nil
            }
            return place
        }
    }

    private func academicCourseRow(for group: [CourseRecord]) -> some View {
        let course = group[0]
        return CourseEvaluationLink(
            request: .lookup(
                courseName: course.name,
                courseNumber: course.number,
                teacher: course.teacher
            )
        ) { request in
            dismiss()
            onOpenAcademicCourse(request)
        }
    }

    private func courseAttributeRows(for group: [CourseRecord]) -> [CourseAttributeRow] {
        guard let first = group.first else { return [] }
        let teachers = unique(group.map(\.teacher).filter { !$0.isEmpty })
        let classrooms = unique(group.map { ScheduleDisplayNormalizer.normalizeClassroom($0.classroom) }.filter { !$0.isEmpty })
        return [
            CourseAttributeRow(label: "名称", value: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name)),
            CourseAttributeRow(label: "地点", value: classrooms.isEmpty ? "暂无" : classrooms.joined(separator: "、")),
            CourseAttributeRow(label: "教师", value: teachers.isEmpty ? "暂无" : teachers.joined(separator: "、")),
            CourseAttributeRow(label: "学分", value: first.creditText),
        ]
    }

    private func arrangementText(for arrangement: [CourseRecord]) -> String {
        guard let first = arrangement.first else { return "时间安排" }
        let weeks = "\(ScheduleCourseEditor.formatWeeks(arrangement.flatMap(\.weeks)))周"
        let weekday = weekdayText(first.weekday).replacingOccurrences(of: "周", with: "")
        let classroom = ScheduleDisplayNormalizer.normalizeClassroom(first.classroom)
        return "\(weeks) 星期\(weekday) \(first.startSection)-\(first.endSection)节 \(classroom)"
    }

    private func weekdayText(_ weekday: Int) -> String {
        let titles = ["", "一", "二", "三", "四", "五", "六", "日"]
        return titles.indices.contains(weekday) ? titles[weekday] : "?"
    }

    private func mutationTarget(for courses: [CourseRecord]) -> (course: CourseRecord, week: Int) {
        guard let first = courses.first else {
            fatalError("课程详情缺少课程记录")
        }
        if let currentCourse = courses.first(where: { $0.weeks.contains(currentWeek) }) {
            return (currentCourse, currentWeek)
        }
        if let firstWeek = courses.flatMap(\.weeks).sorted().first,
           let firstCourse = courses.first(where: { $0.weeks.contains(firstWeek) }) {
            return (firstCourse, firstWeek)
        }
        return (first, currentWeek)
    }
}
