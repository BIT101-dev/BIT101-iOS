#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)

import ActivityKit
import Foundation

/// `CourseReminderActivityAttributes` 定义课程提醒 Live Activity 的共享属性。
///
/// 主 App 计算并驱动状态，Widget 与 Live Activity 展示层读取这份契约；
/// 多个 target 通过此处的共享定义保持 attributes 契约一致。
nonisolated struct CourseReminderActivityAttributes: ActivityAttributes {
    /// `ContentState` 为锁屏与灵动岛提供课程提醒的最小动态状态。
    public struct ContentState: Codable, Hashable {
        let kindText: String
        let title: String
        let classroom: String
        let teacher: String
        let timeRangeText: String
        let countdownTargetDate: Date
    }

    let studentID: String
}

#endif
