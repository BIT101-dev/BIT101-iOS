import Foundation

nonisolated enum AcademicActivityPhase: Equatable {
    case teaching
    case vacation
    case unknown
}

/// Calendar fallback used to keep adjacent term identifiers available offline.
/// Cached school first-week dates refine the selected term whenever they exist.
nonisolated enum AcademicTermPolicy {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    /// Returns the semester containing `date` and the semester following it.
    /// March 1 and September 1 are the local fallback boundaries used by BIT.
    static func adjacentTerms(on date: Date) -> [String] {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1

        if month <= 2 {
            return ["\(year - 1)-\(year)-1", "\(year - 1)-\(year)-2"]
        }
        if month <= 8 {
            return ["\(year - 1)-\(year)-2", "\(year)-\(year + 1)-1"]
        }
        return ["\(year)-\(year + 1)-1", "\(year)-\(year + 1)-2"]
    }

    static func preferredTerm(on date: Date) -> String {
        adjacentTerms(on: date)[0]
    }

    /// Distinguishes teaching time from the post-week-16/pre-next-term vacation.
    /// Data availability determines whether the result is `.unknown`; this keeps
    /// refreshes available before the first timetable sync.
    static func activityPhase(cache: ScheduleCache, on date: Date) -> AcademicActivityPhase {
        let terms = adjacentTerms(on: date)
        let currentTerm = terms[0]
        let currentStart = cache.termSchedulesByTerm[currentTerm]?.firstDay
            ?? (cache.currentTerm == currentTerm ? cache.firstDay : nil)
        guard let currentStart else { return .unknown }

        if let nextStart = cache.termSchedulesByTerm[terms[1]]?.firstDay,
           date >= nextStart
        {
            return .teaching
        }
        if date < currentStart { return .vacation }
        guard let vacationStart = calendar.date(byAdding: .day, value: 16 * 7, to: currentStart) else {
            return .unknown
        }
        return date < vacationStart ? .teaching : .vacation
    }

    /// Calendar boundary at which the next term becomes the fallback current term.
    static func nextBoundary(after date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        var target = DateComponents()
        target.calendar = calendar
        target.timeZone = calendar.timeZone

        if month <= 2 {
            target.year = year
            target.month = 3
        } else if month <= 8 {
            target.year = year
            target.month = 9
        } else {
            target.year = year + 1
            target.month = 3
        }
        target.day = 1
        return calendar.date(from: target) ?? date
    }
}
