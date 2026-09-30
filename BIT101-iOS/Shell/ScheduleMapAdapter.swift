import MapFeature
import ScheduleDomain
import ScheduleContracts
import Foundation

/// 从本地课表缓存中解析“下一节课 + 校区 + 建筑”。
enum UpcomingCourseMapResolver {
    static func nextTarget(in snapshot: ScheduleCourseSnapshot, now: Date = Date()) -> UpcomingCourseMapTarget? {
        guard let firstDay = snapshot.firstDay else { return nil }
        let slots = Dictionary(uniqueKeysWithValues: snapshot.timeTable.map { ($0.id, $0) })

        return snapshot.courses.flatMap { course -> [UpcomingCourseMapTarget] in
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
                    place: place,
                    startDateText: ScheduleDateCodec.formatRelativeDateTime(startDate)
                )
            }
        }
        .min { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.courseName < rhs.courseName
        }
    }
}
