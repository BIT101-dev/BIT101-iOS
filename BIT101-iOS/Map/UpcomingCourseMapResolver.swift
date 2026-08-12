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

/// 从本地课表缓存中解析“下一节课 + 校区 + 建筑”。
enum UpcomingCourseMapResolver {
    static func nextTarget(in cache: ScheduleCache, now: Date = Date()) -> UpcomingCourseMapTarget? {
        guard let firstDay = cache.firstDay else { return nil }
        let slots = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })

        return cache.courses.flatMap { course -> [UpcomingCourseMapTarget] in
            guard let startSlot = slots[course.startSection] else { return [] }
            let campus = CampusMapPlaceCatalog.campus(
                campusName: course.campus,
                classroom: course.classroom
            )
            let place = CampusMapPlaceCatalog.place(
                campusName: course.campus,
                classroom: course.classroom
            )

            return course.weeks.compactMap { week in
                guard let startDate = ScheduleSharedDateCodec.combine(
                    firstDay: firstDay,
                    week: week,
                    weekday: course.weekday,
                    time: startSlot.start
                ), startDate > now else {
                    return nil
                }

                return UpcomingCourseMapTarget(
                    id: "\(course.id)-\(startDate.timeIntervalSinceReferenceDate)",
                    courseName: course.name,
                    classroom: course.classroom,
                    startDate: startDate,
                    campus: campus,
                    place: place
                )
            }
        }
        .min { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.courseName < rhs.courseName
        }
    }
}
