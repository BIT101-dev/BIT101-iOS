//
//  ScheduleCourseEditor.swift
//  BIT101-iOS
//

import Foundation

/// 课程编辑表单的纯校验与周次编解码。
///
/// 与持久化和 UI 状态解耦后，新增、整课编辑和单次调课共享同一套规则，
/// 也可以在不创建 `ScheduleViewModel` 的情况下直接测试边界输入。
enum ScheduleCourseEditor {
    struct ResolvedDraft: Equatable {
        let title: String
        let teacher: String
        let classroom: String
        let weeks: [Int]
        let weekday: Int
        let startSection: Int
        let endSection: Int
    }

    static func parseWeeks(_ text: String) throws -> [Int] {
        let segments = text
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else {
            throw validationError("周次不能为空。")
        }

        var weeks = Set<Int>()
        for segment in segments {
            if segment.contains("-") {
                let bounds = segment
                    .split(separator: "-")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard
                    bounds.count == 2,
                    let lower = Int(bounds[0]),
                    let upper = Int(bounds[1]),
                    lower > 0,
                    upper >= lower
                else {
                    throw invalidWeeksError
                }
                weeks.formUnion(lower ... upper)
            } else {
                guard let week = Int(segment), week > 0 else {
                    throw invalidWeeksError
                }
                weeks.insert(week)
            }
        }
        return weeks.sorted()
    }

    static func formatWeeks(_ weeks: [Int]) -> String {
        let weeks = Array(Set(weeks.filter { $0 > 0 })).sorted()
        guard !weeks.isEmpty else { return "" }

        var ranges: [String] = []
        var lower = weeks[0]
        var upper = weeks[0]
        for week in weeks.dropFirst() {
            if week == upper + 1 {
                upper = week
            } else {
                ranges.append(lower == upper ? "\(lower)" : "\(lower)-\(upper)")
                lower = week
                upper = week
            }
        }
        ranges.append(lower == upper ? "\(lower)" : "\(lower)-\(upper)")
        return ranges.joined(separator: ",")
    }

    static func resolve(_ draft: CourseDraft, fixedWeeks: [Int]? = nil) throws -> ResolvedDraft {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw validationError("课程名称不能为空。") }
        guard (1 ... 7).contains(draft.weekday) else { throw validationError("星期设置不合法。") }
        guard draft.startSection > 0, draft.endSection >= draft.startSection else {
            throw validationError("节次范围不合法。")
        }

        return ResolvedDraft(
            title: title,
            teacher: draft.teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            classroom: draft.classroom.trimmingCharacters(in: .whitespacesAndNewlines),
            weeks: try fixedWeeks ?? parseWeeks(draft.weeksText),
            weekday: draft.weekday,
            startSection: draft.startSection,
            endSection: draft.endSection
        )
    }

    private static var invalidWeeksError: NSError {
        validationError("周次格式不正确，请使用如 1-16,18 的写法。")
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
