import Foundation
import ScheduleContracts
import ScheduleDomain
import SchedulePorts

nonisolated struct ScheduleSystemCalendarNavigationRequest: Equatable {
    let markerID: String
    let term: String
}

nonisolated enum ScheduleSystemCalendarTarget {
    case course(CourseRecord, week: Int)
    case exam(ExamRecord)
    case custom(CustomScheduleRecord, dateString: String)

    static func resolve(markerID: String, courses: [CourseRecord], exams: [ExamRecord],
        customSchedules: [CustomScheduleRecord]) -> Self? {
        for course in courses {
            if let week = course.weeks.first(where: { ScheduleSystemCalendarMarkerID.course(course.id, week: $0) == markerID }) {
                return .course(course, week: week)
            }
        }
        if let exam = exams.first(where: { ScheduleSystemCalendarMarkerID.exam($0.id) == markerID }) { return .exam(exam) }
        for schedule in customSchedules {
            if let date = schedule.occurrenceDateStrings.first(where: { schedule.occurrenceID(for: $0) == markerID }) {
                return .custom(schedule, dateString: date)
            }
        }
        return nil
    }
}

extension ScheduleViewModel {
    func selectSystemCalendarTarget(_ request: ScheduleSystemCalendarNavigationRequest) -> ScheduleSystemCalendarTarget? {
        repository.selectCachedCourseTerm(request.term)
        for (index, variant) in courseSchedules.enumerated() where variant.currentTerm == request.term {
            guard let target = ScheduleSystemCalendarTarget.resolve(markerID: request.markerID, courses: variant.courses,
                exams: variant.exams, customSchedules: variant.customSchedules) else { continue }
            selectedCourseScheduleIndex = index
            return target
        }
        return nil
    }
}

#if os(iOS)
extension CourseScheduleTabView {
    func consumeSystemCalendarRequest() {
        guard let request = viewModel.requestedSystemCalendarEvent else { return }
        defer { viewModel.requestedSystemCalendarEvent = nil }
        if let target = viewModel.selectSystemCalendarTarget(request) {
            switch target {
            case let .course(course, week):
                viewModel.selectedWeek = week
                selectedEntry = courseEntry(for: course)
            case let .exam(exam):
                focusCalendarDate(exam.dateString)
                selectedEntry = examEntry(for: exam)
            case let .custom(schedule, dateString):
                focusCalendarDate(dateString)
                selectedEntry = customEntry(for: schedule, dateString: dateString)
            }
            return
        }
        viewModel.notice = .userInput(title: "查看日历日程",
            message: "请在课表设置中选择 \(request.term) 学期并同步，随后重新打开日历事件。")
    }

    private func focusCalendarDate(_ value: String) {
        guard let firstDay = activeSchedule.firstDay, let date = ScheduleSharedDateCodec.parseDate(value) else { return }
        let days = ScheduleSharedDateCodec.calendar.dateComponents([.day], from: firstDay, to: date).day ?? 0
        let week = ScheduleWeekCodec.weekNumber(forDayOffset: days)
        if ScheduleCourseConstraints.isValidWeek(week) { viewModel.selectedWeek = week }
    }
}
#endif
