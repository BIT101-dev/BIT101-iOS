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
}

#endif
