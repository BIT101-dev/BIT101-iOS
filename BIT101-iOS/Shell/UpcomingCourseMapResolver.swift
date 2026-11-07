import Foundation
import MapFeature
import ScheduleContracts
import ScheduleDomain

@MainActor
final class UpcomingCourseMapProjection {
    private var snapshot: ScheduleCourseSnapshot?
    private var resolvedAt: Date?
    private var target: UpcomingCourseMapTarget?

    func resolve(in snapshot: ScheduleCourseSnapshot, now: Date) -> UpcomingCourseMapTarget? {
        let timeMovedBackwards = resolvedAt.map { now < $0 } ?? true
        if self.snapshot != snapshot || timeMovedBackwards
            || target.map({ now >= $0.startDate }) == true
        {
            target = UpcomingCourseMapResolver.nextTarget(in: snapshot, now: now)
            self.snapshot = snapshot
            resolvedAt = now
        }
        return target
    }
}

/// 从本地课表缓存中解析“下一节课 + 校区 + 建筑”。
enum UpcomingCourseMapResolver {
    static func nextTarget(in snapshot: ScheduleCourseSnapshot, now: Date = Date())
        -> UpcomingCourseMapTarget?
    {
        guard let firstDay = snapshot.firstDay else { return nil }
        let slots = Dictionary(uniqueKeysWithValues: snapshot.timeTable.map { ($0.id, $0) })

        var earliest: (course: CourseRecord, date: Date)?
        for course in snapshot.courses {
            guard let startSlot = slots[course.startSection] else { continue }
            for week in course.weeks {
                guard
                    let startDate = ScheduleSharedDateCodec.combine(
                        firstDay: firstDay,
                        week: week,
                        weekday: course.weekday,
                        time: startSlot.start
                    ), startDate > now
                else {
                    continue
                }
                if let current = earliest,
                    startDate > current.date
                        || startDate == current.date && course.name >= current.course.name
                {
                    continue
                }
                earliest = (course, startDate)
            }
        }
        guard let earliest else { return nil }
        let course = earliest.course
        return UpcomingCourseMapTarget(
            id: "\(course.id)-\(earliest.date.timeIntervalSinceReferenceDate)",
            courseName: course.name, classroom: course.classroom, startDate: earliest.date,
            campus: CampusMapPlaceCatalog.campus(
                campusName: course.campus, classroom: course.classroom),
            place: CampusMapPlaceCatalog.place(
                campusName: course.campus, classroom: course.classroom),
            startDateText: ScheduleDateCodec.formatRelativeDateTime(earliest.date)
        )
    }
}
