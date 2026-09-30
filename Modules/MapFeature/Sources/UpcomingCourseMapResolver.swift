#if os(iOS)
//
//  UpcomingCourseMapResolver.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-08-12.
//

import Foundation

/// 地图页从主课表中解析出的下一节课程。
public nonisolated struct UpcomingCourseMapTarget: Equatable, Sendable {
    public let id: String
    public let courseName: String
    public let classroom: String
    public let startDate: Date
    public let campus: CampusPreset?
    public let place: CampusMapPlace?
    public let startDateText: String

    public init(id: String, courseName: String, classroom: String, startDate: Date, campus: CampusPreset?, place: CampusMapPlace?, startDateText: String) {
        self.id = id
        self.courseName = courseName
        self.classroom = classroom
        self.startDate = startDate
        self.campus = campus
        self.place = place
        self.startDateText = startDateText
    }
}

#endif
