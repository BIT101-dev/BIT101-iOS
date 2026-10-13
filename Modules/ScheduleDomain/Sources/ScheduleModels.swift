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
/// - 缓存课表标题展示
public nonisolated let scheduleNameCharacterLimit = 8
