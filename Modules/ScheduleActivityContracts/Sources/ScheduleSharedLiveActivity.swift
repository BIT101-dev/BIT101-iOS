#if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)

import ActivityKit
import Foundation

/// `CourseReminderActivityAttributes` 定义课程提醒 Live Activity 的共享属性。
///
/// 主 App 计算并驱动状态，Widget 与 Live Activity 展示层读取这份契约；
/// 多个 target 通过此处的共享定义保持 attributes 契约一致。
public nonisolated struct CourseReminderActivityAttributes: ActivityAttributes {
    /// `ContentState` 为锁屏与灵动岛提供课程提醒的最小动态状态。
    public struct ContentState: Codable, Hashable, Sendable {
        public init(kindText: String, title: String, classroom: String, teacher: String, timeRangeText: String, countdownTargetDate: Date) {
            self.kindText = kindText
            self.title = title
            self.classroom = classroom
            self.teacher = teacher
            self.timeRangeText = timeRangeText
            self.countdownTargetDate = countdownTargetDate
        }

        public let kindText: String
        public let title: String
        public let classroom: String
        public let teacher: String
        public let timeRangeText: String
        public let countdownTargetDate: Date
    }

    public init(studentID: String) {
        self.studentID = studentID
    }

    public let studentID: String
    public static let maximumPayloadBytes = 4_096

    /// ActivityKit 静态属性与动态状态共同使用编码容量。
    public func boundedContentState(_ state: ContentState) throws -> ContentState {
        let encoder = JSONEncoder(), attributesBytes = try encoder.encode(self).count
        if try attributesBytes + encoder.encode(state).count <= Self.maximumPayloadBytes { return state }
        let empty = ContentState(kindText: "", title: "", classroom: "", teacher: "", timeRangeText: "",
            countdownTargetDate: state.countdownTargetDate)
        let remaining = Self.maximumPayloadBytes - attributesBytes - (try encoder.encode(empty).count)
        guard remaining >= 0 else { throw CocoaError(.fileReadTooLarge) }
        let budget = remaining / 5
        func fitting(_ text: String) throws -> String {
            if try encoder.encode(text).count - 2 <= budget { return text }
            var prefix = "", used = "…".utf8.count
            guard used <= budget else { return "" }
            for character in text {
                let bytes = try encoder.encode(String(character)).count - 2
                guard used + bytes <= budget else { break }
                prefix.append(character)
                used += bytes
            }
            return prefix + "…"
        }
        return try ContentState(kindText: fitting(state.kindText), title: fitting(state.title),
            classroom: fitting(state.classroom), teacher: fitting(state.teacher),
            timeRangeText: fitting(state.timeRangeText), countdownTargetDate: state.countdownTargetDate)
    }
}

#endif
