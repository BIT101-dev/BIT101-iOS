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
        let dayChanged =
            resolvedAt.map { !ScheduleSharedDateCodec.calendar.isDate($0, inSameDayAs: now) }
            ?? true
        let timeMovedBackwards = resolvedAt.map { now < $0 } ?? true
        if self.snapshot != snapshot || dayChanged || timeMovedBackwards
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
        let calendar = ScheduleSharedDateCodec.calendar
        guard let firstDay = snapshot.firstDay,
            let dayOffset = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: firstDay),
                to: calendar.startOfDay(for: now)).day
        else { return nil }
        let currentWeekOffset = ScheduleWeekCodec.weekOffset(
            forWeekNumber: ScheduleWeekCodec.weekNumber(forDayOffset: dayOffset))
        let slots = Dictionary(
            snapshot.timeTable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var earliest: (course: CourseRecord, date: Date)?
        for course in snapshot.courses {
            guard let startSlot = slots[course.startSection],
                let startDate = nextStartDate(
                    for: course, firstDay: firstDay, now: now,
                    currentWeekOffset: currentWeekOffset, time: startSlot.start)
            else { continue }
            if let current = earliest,
                startDate > current.date
                    || startDate == current.date && course.name >= current.course.name
            {
                continue
            }
            earliest = (course, startDate)
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

    private static func nextStartDate(
        for course: CourseRecord, firstDay: Date, now: Date,
        currentWeekOffset: Int, time: String
    ) -> Date? {
        for week in Set(course.weeks).sorted() {
            guard ScheduleCourseConstraints.isValidWeek(week),
                ScheduleWeekCodec.weekOffset(forWeekNumber: week) >= currentWeekOffset,
                let start = ScheduleSharedDateCodec.combine(
                    firstDay: firstDay, week: week, weekday: course.weekday, time: time),
                start > now
            else { continue }
            return start
        }
        return nil
    }
}
