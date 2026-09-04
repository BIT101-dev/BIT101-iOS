//
//  ScheduleCourseEntries.swift
//  BIT101-iOS
//

import SwiftUI

/// 统一压缩教室名称里的冗长楼名，提升课表卡片可读性。
private func normalizeDisplayedClassroom(_ value: String) -> String {
    ScheduleDisplayNormalizer.courseCardClassroomText(value)
}

/// 对课程标题做本地展示优化。
private func normalizeDisplayedCourseTitle(_ value: String) -> String {
    ScheduleDisplayNormalizer.normalizeCourseTitle(value)
}

extension CourseScheduleTabView {
    var scheduleEntries: [ScheduleCalendarEntry] {
        guard let firstDay = activeSchedule.firstDay else {
            return []
        }

        // 课表网格只关心当前周，所以先把课程、考试和自定义日程全部压平成同一套日历块模型。
        let weekStart = Calendar.current.date(
            byAdding: .day,
            value: ScheduleWeekCodec.weekOffset(forWeekNumber: viewModel.selectedWeek) * 7,
            to: firstDay
        ) ?? firstDay
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart

        let courseEntries: [ScheduleCalendarEntry]
        switch viewModel.cache.scheduleDisplayMode {
        case .weekly:
            courseEntries = activeSchedule.courses
                .filter { $0.weeks.contains(viewModel.selectedWeek) }
                .map { courseEntry(for: $0) }
        case .allWeeks:
            courseEntries = makeAllWeeksCourseEntries(from: activeSchedule.courses)
        }

        let examEntries = viewModel.cache.showExamInfo ? activeSchedule.exams.compactMap { exam -> ScheduleCalendarEntry? in
            guard
                let examDate = ScheduleDateCodec.parseDate(exam.dateString),
                examDate >= weekStart,
                examDate < weekEnd
            else {
                return nil
            }

            let weekday = ScheduleDateCodec.weekdayIndex(from: examDate)
            let startSection = convertTimeToSection(timeText: exam.beginTime, timeTable: activeSchedule.timeTable)
            let endSection = convertTimeToSection(timeText: exam.endTime, timeTable: activeSchedule.timeTable)

            guard endSection > startSection + 0.05 else {
                return nil
            }

            return ScheduleCalendarEntry(
                id: "exam-\(exam.id)",
                sourceID: exam.id,
                sourceIDs: [exam.id],
                dayOfWeek: weekday,
                startSection: startSection,
                endSection: endSection,
                title: "(考试)\n\(exam.name)",
                subtitle: normalizeDisplayedClassroom(exam.classroom),
                detailLines: [
                    exam.teacher.isEmpty ? nil : "教师：\(exam.teacher)",
                    exam.classroom.isEmpty ? nil : "教室：\(normalizeDisplayedClassroom(exam.classroom))",
                    exam.examMode.isEmpty ? nil : "形式：\(exam.examMode)",
                    (exam.beginTime.isEmpty || exam.endTime.isEmpty) ? nil : "时间：\(exam.beginTime)-\(exam.endTime)",
                    exam.seatID.isEmpty ? nil : "座位号：\(exam.seatID)",
                ].compactMap { $0 },
                kind: .exam
            )
        } : []

        let customEntries = activeSchedule.customSchedules.compactMap { schedule -> ScheduleCalendarEntry? in
            guard
                let date = ScheduleDateCodec.parseDate(schedule.dateString),
                date >= weekStart,
                date < weekEnd
            else {
                return nil
            }

            let weekday = ScheduleDateCodec.weekdayIndex(from: date)
            let startSection = convertTimeToSection(timeText: schedule.beginTime, timeTable: activeSchedule.timeTable)
            let endSection = convertTimeToSection(timeText: schedule.endTime, timeTable: activeSchedule.timeTable)
            guard endSection > startSection + 0.05 else {
                return nil
            }

            return ScheduleCalendarEntry(
                id: "custom-\(schedule.id)",
                sourceID: schedule.id,
                sourceIDs: [schedule.id],
                dayOfWeek: weekday,
                startSection: startSection,
                endSection: endSection,
                title: schedule.title,
                subtitle: schedule.subtitle,
                detailLines: [
                    schedule.subtitle.isEmpty ? nil : "副标题：\(schedule.subtitle)",
                    schedule.description.isEmpty ? nil : "描述：\(schedule.description)",
                    "日期：\(schedule.dateString)",
                    "时间：\(schedule.beginTime)-\(schedule.endTime)",
                ].compactMap { $0 },
                kind: .custom
            )
        }

        let entries = courseEntries + examEntries + customEntries
        return viewModel.cache.scheduleDisplayMode == .allWeeks
            ? entries
            : normalize(entries: entries)
    }

    func courseEntry(
        for course: CourseRecord,
        sourceIDs: [String] = [],
        includeWeekInfo: Bool = false
    ) -> ScheduleCalendarEntry {
        let subtitleParts = includeWeekInfo
            ? [compactWeekText(course.weeks)].compactMap { $0 }
            : [course.classroom.isEmpty ? nil : normalizeDisplayedClassroom(course.classroom)].compactMap { $0 }

        return ScheduleCalendarEntry(
            id: "course-\(course.id)",
            sourceID: course.id,
            sourceIDs: sourceIDs.isEmpty ? [course.id] : sourceIDs,
            dayOfWeek: course.weekday,
            startSection: CGFloat(course.startSection - 1),
            endSection: CGFloat(course.endSection),
            title: normalizeDisplayedCourseTitle(course.name),
            subtitle: subtitleParts.joined(separator: "\n"),
            detailLines: [
                course.teacher.isEmpty ? nil : "教师：\(course.teacher)",
                course.classroom.isEmpty ? nil : "教室：\(normalizeDisplayedClassroom(course.classroom))",
                "学分：\(course.credit > 0 ? String(course.credit) : "-")",
                "节次：\(course.sectionText)",
                course.description.isEmpty ? nil : course.description,
            ].compactMap { $0 },
            kind: .course
        )
    }

    /// 全学期模式合并重叠课程，文字使用并集范围，背景保留每条记录的原始范围。
    func makeAllWeeksCourseEntries(from courses: [CourseRecord]) -> [ScheduleCalendarEntry] {
        let grouped = Dictionary(grouping: courses, by: scheduleCourseIdentity)
        let entries = courses.map { course in
            let sourceIDs = grouped[scheduleCourseIdentity(course)]?.map(\.id) ?? [course.id]
            return courseEntry(for: course, sourceIDs: sourceIDs, includeWeekInfo: true)
        }

        var result: [ScheduleCalendarEntry] = []
        for day in 1 ... 7 {
            let dayEntries = entries
                .filter { $0.dayOfWeek == day }
                .sorted {
                    if $0.startSection == $1.startSection { return $0.endSection < $1.endSection }
                    return $0.startSection < $1.startSection
                }

            var cluster: [ScheduleCalendarEntry] = []
            var clusterEnd: CGFloat = -.greatestFiniteMagnitude
            for entry in dayEntries {
                if !cluster.isEmpty, entry.startSection >= clusterEnd {
                    result.append(mergedCourseEntry(from: cluster))
                    cluster.removeAll(keepingCapacity: true)
                    clusterEnd = -.greatestFiniteMagnitude
                }
                cluster.append(entry)
                clusterEnd = max(clusterEnd, entry.endSection)
            }
            if !cluster.isEmpty {
                result.append(mergedCourseEntry(from: cluster))
            }
        }
        return result
    }

    func mergedCourseEntry(from entries: [ScheduleCalendarEntry]) -> ScheduleCalendarEntry {
        var courses: [CourseRecord] = []
        var seenIDs = Set<String>()
        for entry in entries {
            for sourceID in entry.resolvedSourceIDs {
                guard seenIDs.insert(sourceID).inserted,
                      let course = activeSchedule.courses.first(where: { $0.id == sourceID })
                else { continue }
                courses.append(course)
            }
        }

        var courseGroups: [[CourseRecord]] = []
        for course in courses {
            if let index = courseGroups.firstIndex(where: {
                scheduleCourseIdentity($0[0]) == scheduleCourseIdentity(course)
            }) {
                courseGroups[index].append(course)
            } else {
                courseGroups.append([course])
            }
        }

        let orderedCourseGroups = courseGroups.sorted { lhs, rhs in
            let lhsCenter = courseGroupCenter(lhs)
            let rhsCenter = courseGroupCenter(rhs)
            if lhsCenter == rhsCenter {
                return lhs[0].name.localizedStandardCompare(rhs[0].name) == .orderedAscending
            }
            return lhsCenter < rhsCenter
        }
        let orderedCourses = orderedCourseGroups.flatMap { $0 }

        let title = orderedCourseGroups
            .map { normalizeDisplayedCourseTitle($0[0].name) }
            .joined(separator: "\n")
        let subtitle = orderedCourseGroups
            .compactMap { compactWeekText($0.flatMap(\.weeks)) }
            .joined(separator: "\n")
        let detailLines = orderedCourses.flatMap { course -> [String] in
            let weekText = compactWeekText(course.weeks) ?? "未知周次"
            return [
                "课程：\(normalizeDisplayedCourseTitle(course.name))（\(weekText)）",
                course.teacher.isEmpty ? nil : "教师：\(course.teacher)",
                course.classroom.isEmpty ? nil : "教室：\(normalizeDisplayedClassroom(course.classroom))",
                "学分：\(course.credit > 0 ? String(course.credit) : "-")",
                "节次：\(course.sectionText)",
            ].compactMap { $0 }
        }

        return ScheduleCalendarEntry(
            id: "course-overview-\(entries[0].dayOfWeek)-\(entries[0].startSection)-\(entries.map(\.id).joined(separator: ","))",
            sourceID: courses.first?.id ?? entries[0].sourceID,
            sourceIDs: orderedCourses.map(\.id),
            dayOfWeek: entries[0].dayOfWeek,
            startSection: entries.map(\.startSection).min() ?? entries[0].startSection,
            endSection: entries.map(\.endSection).max() ?? entries[0].endSection,
            title: title,
            subtitle: subtitle,
            detailLines: detailLines,
            kind: .course,
            backgroundLayers: entries.flatMap(\.backgroundLayers)
        )
    }

    func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    func courseGroupCenter(_ group: [CourseRecord]) -> CGFloat {
        guard !group.isEmpty else { return 0 }
        let centers = group.map { CGFloat($0.startSection - 1 + $0.endSection) / 2 }
        return centers.reduce(0, +) / CGFloat(centers.count)
    }

    func compactWeekText(_ weeks: [Int]) -> String? {
        let sorted = Array(Set(weeks)).sorted()
        guard !sorted.isEmpty else { return nil }

        var ranges: [String] = []
        var start = sorted[0]
        var end = start
        for week in sorted.dropFirst() {
            if week == end + 1 {
                end = week
            } else {
                ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
                start = week
                end = week
            }
        }
        ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
        return ranges.joined(separator: "\n")
    }


}
