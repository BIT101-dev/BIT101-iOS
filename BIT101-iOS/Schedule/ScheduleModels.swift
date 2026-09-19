//
//  ScheduleModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 课表名称的统一长度上限。
///
/// 这一上限同时约束：
/// - 设置页里的重命名输入
/// - 导入分享课表后的默认命名
/// - 旧缓存恢复后的标题展示
nonisolated let scheduleNameCharacterLimit = 8

/// 本地缓存发生变化时发出的通知。
///
/// 课表页、小组件导出和灵动岛刷新都会监听这条通知，用来做跨模块同步。
extension Notification.Name {
    static let scheduleCacheDidChange = Notification.Name("BIT101.ScheduleCacheDidChange")
}

/// 日程页的一级分栏。
///
/// 课表、DDL、空教室都挂在“日程”一级页签下，统一使用这个枚举表示分栏切换。
