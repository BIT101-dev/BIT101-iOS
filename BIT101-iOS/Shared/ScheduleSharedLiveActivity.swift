#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)

import ActivityKit
import Foundation

/// 课程提醒 Live Activity 的共享属性定义。
///
/// 主 App 负责计算和驱动状态；widget / 未来 watch 展示层只依赖这里，
/// 避免多 target 各自维护一份同名但未必完全一致的 attributes 契约。
nonisolated struct CourseReminderActivityAttributes: ActivityAttributes {
    /// 锁屏 / 灵动岛展示所需的最小动态状态。
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
