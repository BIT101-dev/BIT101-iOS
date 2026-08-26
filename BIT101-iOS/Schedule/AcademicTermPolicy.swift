import Foundation

nonisolated enum AcademicActivityPhase: Equatable {
    case teaching
    case vacation
    case unknown
}

/// Calendar fallback used to keep the current and next semester available offline.
/// School-provided first-week dates remain authoritative whenever they exist.
nonisolated enum AcademicTermPolicy {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }

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

    /// School first-week data may begin a semester just before the March or
    /// September fallback boundary (for example, August 31).
    static func preferredCachedTerm(cache: ScheduleCache, on date: Date) -> String {
        let terms = adjacentTerms(on: date)
        guard terms.count == 2 else { return preferredTerm(on: date) }
        // A user may explicitly fetch and select the upcoming semester before
        // its first week begins. Smart switching is only allowed to advance a
        // timetable; it must not undo that explicit selection on every launch.
        if cache.currentTerm == terms[1] {
            return terms[1]
        }
        if let nextStart = cache.termSchedulesByTerm[terms[1]]?.firstDay,
           date >= nextStart
        {
            return terms[1]
        }
        return terms[0]
    }

    /// Distinguishes teaching time from the post-week-16/pre-next-term vacation.
    /// Unknown data intentionally preserves the old behavior instead of silently
    /// disabling useful refreshes for a user whose timetable has never synced.
    static func activityPhase(cache: ScheduleCache, on date: Date) -> AcademicActivityPhase {
        let terms = adjacentTerms(on: date)
        guard let currentTerm = terms.first else { return .unknown }
        let currentStart = cache.termSchedulesByTerm[currentTerm]?.firstDay
            ?? (cache.currentTerm == currentTerm ? cache.firstDay : nil)
        guard let currentStart else { return .unknown }

        if let nextTerm = terms.dropFirst().first,
           let nextStart = cache.termSchedulesByTerm[nextTerm]?.firstDay,
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

nonisolated enum ScoreAutomaticRefreshPolicy {
    /// Automatic score refresh is useful only after week 16 and before the next
    /// semester starts. Missing dates fail closed to avoid unnecessary traffic.
    static func isWithinRefreshWindow(cache: ScheduleCache, now: Date) -> Bool {
        guard AcademicTermPolicy.activityPhase(cache: cache, on: now) == .vacation else {
            return false
        }
        let terms = AcademicTermPolicy.adjacentTerms(on: now)
        guard let currentTerm = terms.first else { return false }

        let currentSnapshot = cache.termSchedulesByTerm[currentTerm]
        let currentFirstDay = currentSnapshot?.firstDay
            ?? (cache.currentTerm == currentTerm ? cache.firstDay : nil)
        guard let currentFirstDay else { return false }

        let calendar = Calendar(identifier: .gregorian)
        guard let refreshStart = calendar.date(byAdding: .day, value: 16 * 7, to: currentFirstDay) else {
            return false
        }

        let nextTerm = terms.dropFirst().first
        let schoolNextStart = nextTerm.flatMap { cache.termSchedulesByTerm[$0]?.firstDay }
        let refreshEnd = schoolNextStart ?? AcademicTermPolicy.nextBoundary(after: now)
        return now >= refreshStart && now < refreshEnd
    }
}
