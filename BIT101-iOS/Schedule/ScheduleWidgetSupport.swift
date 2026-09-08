//
//  ScheduleWidgetSupport.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

import Foundation
import WidgetKit

/// 把当前账号课表缓存导出为 `ScheduleExternalSnapshot`，供外部展示层读取。
///
/// 桌面 widget、锁屏组件、Live Activity 和 Apple Watch 共享这份快照，
/// 外部 target 从快照读取课表所需的最小字段。
enum ScheduleWidgetExporter {
    /// 重新读取当前账号缓存，并同步到共享容器。
    ///
    /// 应用生命周期、登录切换等未持有最新缓存对象的场景使用此入口。
    static func syncFromCurrentCache() {
        sync(cache: ScheduleCacheStore.load())
    }

    /// 把指定缓存同步给外部展示层，并主动刷新 widget 时间线。
    ///
    /// 这里仅导出课表、小节次和首周信息，保持共享层边界最小化。
    static func sync(cache: ScheduleCache) {
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoggedIn = !LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: isLoggedIn,
            studentID: studentID,
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable.map {
                ScheduleExternalTimeSlotSnapshot(id: $0.id, start: $0.start, end: $0.end)
            },
            courses: cache.courses.map {
                ScheduleExternalCourseSnapshot(
                    id: $0.id,
                    name: $0.name,
                    classroom: $0.classroom,
                    teacher: $0.teacher,
                    weeks: $0.weeks,
                    weekday: $0.weekday,
                    startSection: $0.startSection,
                    endSection: $0.endSection
                )
            }
        )
        ScheduleExternalSnapshotStore.save(snapshot)
        WatchScheduleSyncManager.shared.push(snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
