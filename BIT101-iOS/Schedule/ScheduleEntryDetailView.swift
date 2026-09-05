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
    let allowsCourseMutation: Bool
    let isOverviewMode: Bool
    let allowsCustomScheduleMutation: Bool
    let onOpenAcademicCourse: (CourseNavigationRequest) -> Void
    let onOpenCourseLocation: (CampusMapLocationRequest) -> Void
    let onEditCourseOccurrence: (String) -> Void
    let onEditCourse: (String) -> Void
    let onDeleteCourseOccurrence: (String) -> Void
    let onDeleteCourse: (String) -> Void
    let onEditCustomSchedule: () -> Void
    let onDeleteCustomSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCourseDeletion: PendingCourseDeletion?
    @State private var academicCourseAlert: AppAlert?

    var body: some View {
        NavigationStack {
            List {
                if entry.kind == .course, !academicCourseGroups.isEmpty {
                    courseDetailSections
                } else {
                    Section {
                        Text(entry.title)
                            .font(.headline)
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
                }

                if entry.kind == .course, !allowsCourseMutation {
                    Section("编辑") {
                        Text(isOverviewMode
                            ? "全学期叠加仅用于查看；请切换为按周显示后再编辑课程。"
                            : "分享课表是只读副本，不能调课、删除课程或做调休 / 放假。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if entry.kind == .custom, allowsCustomScheduleMutation {
                    Section {
                        Button("编辑") {
                            dismiss()
                            onEditCustomSchedule()
                        }
                        Button("删除", role: .destructive) {
                            onDeleteCustomSchedule()
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
            .alert(item: $pendingCourseDeletion) { target in
                Alert(
                    title: Text("确认删除"),
                    message: Text(target.message(entry: entry, currentWeek: currentWeek)),
                    primaryButton: .destructive(Text("删除")) {
                        switch target {
                        case .occurrence:
                            onDeleteCourseOccurrence(target.courseID)
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

        func message(entry: ScheduleCalendarEntry, currentWeek: Int) -> String {
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
        ForEach(academicCourseGroups.indices, id: \.self) { index in
            let group = academicCourseGroups[index]
            let first = group[0]
            Section {
                Text(ScheduleDisplayNormalizer.normalizeCourseTitle(first.name))
                    .font(.headline)
                let classrooms = unique(group.map { ScheduleDisplayNormalizer.normalizeClassroom($0.classroom) }.filter { !$0.isEmpty })
                if !classrooms.isEmpty {
                    Text(classrooms.joined(separator: "\n"))
                        .foregroundStyle(.secondary)
                }
            }

            Section("详情") {
                ForEach(detailLines(for: group), id: \.self) { line in
                    Text(line)
                }
            }

            Section {
                academicCourseRow(for: group)

                Button {
                    let places = mapPlaces(for: group)
                    guard !places.isEmpty else {
                        academicCourseAlert = AppAlert(
                            title: "没有找到上课地点",
                            message: "这门课的教室暂时无法匹配到校园地图。"
                        )
                        return
                    }
                    dismiss()
                    onOpenCourseLocation(
                        CampusMapLocationRequest(
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(group[0].name),
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
                        dismiss()
                        onEditCourseOccurrence(first.id)
                    }
                    Button("调这门课") {
                        dismiss()
                        onEditCourse(first.id)
                    }
                }

                Section {
                    Button("删除这节课", role: .destructive) {
                        pendingCourseDeletion = .occurrence(
                            courseID: first.id,
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name),
                            week: mutationWeek(for: group)
                        )
                    }
                    Button("删除这门课", role: .destructive) {
                        pendingCourseDeletion = .wholeCourse(
                            courseID: first.id,
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name)
                        )
                    }
                }
            }

            if index < academicCourseGroups.count - 1 {
                Divider()
                    .listRowInsets(EdgeInsets(
                        top: AppDesignSystem.Spacing.content,
                        leading: 0,
                        bottom: AppDesignSystem.Spacing.content,
                        trailing: 0
                    ))
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var academicCourseGroups: [[CourseRecord]] {
        var groups: [[CourseRecord]] = []
        for course in academicCourses {
            if let index = groups.firstIndex(where: { scheduleCourseIdentity($0[0]) == scheduleCourseIdentity(course) }) {
                groups[index].append(course)
            } else {
                groups.append([course])
            }
        }
        return groups
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

    private func detailLines(for group: [CourseRecord]) -> [String] {
        guard let first = group.first else { return [] }
        let teachers = unique(group.map(\.teacher).filter { !$0.isEmpty })
        let classrooms = unique(group.map { ScheduleDisplayNormalizer.normalizeClassroom($0.classroom) }.filter { !$0.isEmpty })
        let sections = unique(group.map(\.sectionText))
        let descriptions = unique(group.map(\.description).filter { !$0.isEmpty })
        return [
            teachers.isEmpty ? nil : "教师：\(teachers.joined(separator: "、"))",
            classrooms.isEmpty ? nil : "教室：\(classrooms.joined(separator: "\n"))",
            "学分：\(first.credit > 0 ? String(first.credit) : "-")",
            "节次：\(sections.joined(separator: "\n"))",
            descriptions.isEmpty ? nil : descriptions.joined(separator: "\n"),
        ].compactMap { $0 }
    }

    private func mutationWeek(for group: [CourseRecord]) -> Int {
        guard let course = group.first else { return currentWeek }
        return course.weeks.contains(currentWeek) ? currentWeek : (course.weeks.first ?? currentWeek)
    }
}

func scheduleCourseIdentity(_ course: CourseRecord) -> String {
    let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !number.isEmpty {
        return "number:\(number)|name:\(name)"
    }
    return "name:\(name)|teacher:\(course.teacher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}
