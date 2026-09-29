//
//  UpcomingCourseMapResolver.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-08-12.
//

import Foundation

/// 地图页从主课表中解析出的下一节课程。
struct UpcomingCourseMapTarget: Equatable {
    let id: String
    let courseName: String
    let classroom: String
    let startDate: Date
    let campus: CampusPreset?
    let place: CampusMapPlace?
}
