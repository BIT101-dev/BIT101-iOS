//
//  BIT101ScheduleWidgetsBundle.swift
//  BIT101ScheduleWidgets
//
//  Created by Codex on 2026-03-28.
//

import SwiftUI
import WidgetKit

/// 课程表小组件入口。
///
/// 当前扩展同时承载桌面 widget 和课程提醒 Live Activity，
/// 因此 bundle 里会按系统版本条件挂出两个入口。
///
/// 这里本身不做任何业务判断，只负责把“这个扩展里有哪些系统可见能力”
/// 暴露给 WidgetKit：
/// - `BIT101ScheduleWidgets`：桌面与锁屏组件
/// - `CourseReminderLiveActivityWidget`：锁屏提醒与灵动岛
@main
struct BIT101ScheduleWidgetsBundle: WidgetBundle {
    /// 扩展内实际暴露给系统的全部 widget。
    var body: some Widget {
        BIT101ScheduleWidgets()
        // Live Activity 至少要求 iOS 16.2，这里保留版本门槛，避免老系统加载失败。
        if #available(iOSApplicationExtension 16.2, *) {
            CourseReminderLiveActivityWidget()
        }
    }
}
