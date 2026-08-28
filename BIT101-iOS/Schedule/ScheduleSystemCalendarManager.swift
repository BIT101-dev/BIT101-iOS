import EventKit
import Foundation

/// 写入系统日历前的纯数据模型，便于在不访问 EventKit 的情况下验证日期计算。
nonisolated struct ScheduleSystemCalendarEventDraft: Equatable {
    let markerID: String
    let title: String
    let location: String
    let notes: String
    let startDate: Date
    let endDate: Date
}

/// 将课表里的周次、星期和节次展开成独立日历事件。
nonisolated enum ScheduleSystemCalendarEventBuilder {
    static func makeDrafts(
        courses: [CourseRecord],
        firstDay: Date,
        timeTable: [TimeSlot]
    ) -> [ScheduleSystemCalendarEventDraft] {
        let slots = Dictionary(uniqueKeysWithValues: timeTable.map { ($0.id, $0) })
        let calendar = shanghaiCalendar()

        return courses.flatMap { course in
            guard
                let startSlot = slots[course.startSection],
                let endSlot = slots[course.endSection]
            else { return [ScheduleSystemCalendarEventDraft]() }

            return course.weeks.compactMap { week in
                let weekOffset = week > 0 ? week - 1 : week
                let dayOffset = weekOffset * 7 + (course.weekday - 1)
                guard
                    let day = calendar.date(
                        byAdding: .day,
                        value: dayOffset,
                        to: firstDay
                    ),
                    let startDate = date(on: day, time: startSlot.start, calendar: calendar),
                    let endDate = date(on: day, time: endSlot.end, calendar: calendar),
                    endDate > startDate
                else { return nil }

                let noteLines = [
                    course.teacher.isEmpty ? nil : "教师：\(course.teacher)",
                    course.number.isEmpty ? nil : "课程编号：\(course.number)",
                    course.description.isEmpty ? nil : course.description,
                ].compactMap { $0 }

                return ScheduleSystemCalendarEventDraft(
                    markerID: "\(course.id)-w\(week)",
                    title: course.name,
                    location: course.classroom,
                    notes: noteLines.joined(separator: "\n"),
                    startDate: startDate,
                    endDate: endDate
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.title < rhs.title
        }
    }

    private static func date(on day: Date, time: String, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }

        var components = calendar.dateComponents(
            [.year, .month, .day],
            from: day
        )
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0
        return calendar.date(from: components)
    }

    private static func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
        return calendar
    }
}

enum ScheduleSystemCalendarError: LocalizedError {
    case permissionDenied
    case noWritableCalendarSource
    case missingSchedule
    case noImportedEvents

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "BIT101 没有完整日历访问权限。请在系统设置的“隐私与安全性－日历”中允许后重试。"
        case .noWritableCalendarSource:
            return "未找到可以写入的系统日历账户。请先在“日历”App 中启用 iCloud 或本地日历。"
        case .missingSchedule:
            return "当前学期还没有可导入的课程，或尚未取得学期起始日期。"
        case .noImportedEvents:
            return "没有找到由 BIT101 导入的日历事件。"
        }
    }
}

/// 系统日历导入、更新与删除协调器。
///
/// 每条事件同时保存 EventKit identifier 和 `bit101://calendar-course/...` URL 标记：
/// identifier 用于快速删除；URL 标记用于日历同步导致 identifier 变化后的兜底识别。
@MainActor
final class ScheduleSystemCalendarManager {
    static let shared = ScheduleSystemCalendarManager()

    private struct ImportedBatch: Codable {
        let term: String
        let calendarIdentifier: String
        let eventIdentifiers: [String]
        let startDate: Date
        let endDate: Date
    }

    private static let calendarTitle = "BIT101 课表"
    private static let batchesKey = "schedule.system-calendar.imported-batches"
    private static let calendarIdentifierKey = "schedule.system-calendar.identifier"

    private let eventStore: EKEventStore
    private let defaults: UserDefaults

    init(eventStore: EKEventStore = EKEventStore(), defaults: UserDefaults = .standard) {
        self.eventStore = eventStore
        self.defaults = defaults
    }

    func importCurrentTerm(from cache: ScheduleCache) async throws -> Int {
        guard let firstDay = cache.firstDay, !cache.courses.isEmpty else {
            throw ScheduleSystemCalendarError.missingSchedule
        }

        let drafts = ScheduleSystemCalendarEventBuilder.makeDrafts(
            courses: cache.courses,
            firstDay: firstDay,
            timeTable: cache.timeTable
        )
        guard let first = drafts.first, let last = drafts.last else {
            throw ScheduleSystemCalendarError.missingSchedule
        }

        try await requireFullAccess()
        let calendar = try writableBIT101Calendar()
        try removeImportedEvents(
            term: cache.currentTerm,
            calendar: calendar,
            startDate: first.startDate.addingTimeInterval(-24 * 60 * 60),
            endDate: last.endDate.addingTimeInterval(24 * 60 * 60)
        )

        var savedEvents: [EKEvent] = []
        for draft in drafts {
            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = draft.title
            event.location = draft.location
            event.notes = draft.notes
            event.startDate = draft.startDate
            event.endDate = draft.endDate
            event.timeZone = ScheduleSharedDateCodec.calendar.timeZone
            event.url = markerURL(id: draft.markerID, term: cache.currentTerm)
            try eventStore.save(event, span: .thisEvent, commit: false)
            savedEvents.append(event)
        }
        try eventStore.commit()
        let eventIdentifiers = savedEvents.compactMap(\.eventIdentifier)

        var batches = loadBatches().filter { $0.term != cache.currentTerm }
        batches.append(ImportedBatch(
            term: cache.currentTerm,
            calendarIdentifier: calendar.calendarIdentifier,
            eventIdentifiers: eventIdentifiers,
            startDate: first.startDate.addingTimeInterval(-24 * 60 * 60),
            endDate: last.endDate.addingTimeInterval(24 * 60 * 60)
        ))
        saveBatches(batches)
        return drafts.count
    }

    func deleteAllImportedEvents() async throws -> Int {
        try await requireFullAccess()

        let batches = loadBatches()
        var eventsByIdentifier: [String: EKEvent] = [:]

        for batch in batches {
            for identifier in batch.eventIdentifiers {
                if let event = eventStore.event(withIdentifier: identifier), isBIT101Event(event) {
                    eventsByIdentifier[identifier] = event
                }
            }
            for event in taggedEvents(
                calendars: calendarForBatch(batch).map { [$0] },
                startDate: batch.startDate,
                endDate: batch.endDate,
                term: nil
            ) {
                eventsByIdentifier[event.eventIdentifier] = event
            }
        }

        // 本地标识被清理后，仍可在专用日历中根据机器 URL 找回 BIT101 事件。
        if let calendar = existingBIT101Calendar() {
            let lowerBound = ScheduleSharedDateCodec.calendar.date(
                byAdding: .year,
                value: -10,
                to: Date()
            ) ?? Date.distantPast
            let upperBound = ScheduleSharedDateCodec.calendar.date(
                byAdding: .year,
                value: 10,
                to: Date()
            ) ?? Date.distantFuture
            for event in taggedEvents(
                calendars: [calendar],
                startDate: lowerBound,
                endDate: upperBound,
                term: nil
            ) {
                eventsByIdentifier[event.eventIdentifier] = event
            }
        }

        guard !eventsByIdentifier.isEmpty else {
            throw ScheduleSystemCalendarError.noImportedEvents
        }

        for event in eventsByIdentifier.values {
            try eventStore.remove(event, span: .thisEvent, commit: false)
        }
        try eventStore.commit()
        saveBatches([])
        return eventsByIdentifier.count
    }

    private func requireFullAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined, .writeOnly:
            guard try await eventStore.requestFullAccessToEvents() else {
                throw ScheduleSystemCalendarError.permissionDenied
            }
        case .denied, .restricted:
            throw ScheduleSystemCalendarError.permissionDenied
        case .authorized:
            return
        @unknown default:
            throw ScheduleSystemCalendarError.permissionDenied
        }
    }

    private func writableBIT101Calendar() throws -> EKCalendar {
        if let existing = existingBIT101Calendar() {
            return existing
        }

        guard let source = eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
            ?? eventStore.sources.first(where: { $0.sourceType == .local })
        else {
            throw ScheduleSystemCalendarError.noWritableCalendarSource
        }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = Self.calendarTitle
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        defaults.set(calendar.calendarIdentifier, forKey: Self.calendarIdentifierKey)
        return calendar
    }

    private func existingBIT101Calendar() -> EKCalendar? {
        if
            let identifier = defaults.string(forKey: Self.calendarIdentifierKey),
            let calendar = eventStore.calendar(withIdentifier: identifier)
        {
            return calendar
        }
        return eventStore.calendars(for: .event).first(where: { $0.title == Self.calendarTitle })
    }

    private func calendarForBatch(_ batch: ImportedBatch) -> EKCalendar? {
        eventStore.calendar(withIdentifier: batch.calendarIdentifier)
    }

    private func removeImportedEvents(
        term: String,
        calendar: EKCalendar,
        startDate: Date,
        endDate: Date
    ) throws {
        let matchingBatches = loadBatches().filter { $0.term == term }
        var eventsByIdentifier: [String: EKEvent] = [:]

        for batch in matchingBatches {
            for identifier in batch.eventIdentifiers {
                if let event = eventStore.event(withIdentifier: identifier), isBIT101Event(event, term: term) {
                    eventsByIdentifier[identifier] = event
                }
            }
            for event in taggedEvents(
                calendars: calendarForBatch(batch).map { [$0] },
                startDate: batch.startDate,
                endDate: batch.endDate,
                term: term
            ) {
                eventsByIdentifier[event.eventIdentifier] = event
            }
        }

        // 即使本地 batch 元数据丢失，仍可通过事件 URL 中的机器标记识别并替换。
        for event in taggedEvents(
            calendars: [calendar],
            startDate: startDate,
            endDate: endDate,
            term: term
        ) {
            eventsByIdentifier[event.eventIdentifier] = event
        }

        for event in eventsByIdentifier.values {
            try eventStore.remove(event, span: .thisEvent, commit: false)
        }
    }

    private func taggedEvents(
        calendars: [EKCalendar]?,
        startDate: Date,
        endDate: Date,
        term: String?
    ) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )
        return eventStore.events(matching: predicate).filter { isBIT101Event($0, term: term) }
    }

    private func markerURL(id: String, term: String) -> URL? {
        var components = URLComponents()
        components.scheme = "bit101"
        components.host = "calendar-course"
        components.path = "/\(id)"
        components.queryItems = [URLQueryItem(name: "term", value: term)]
        return components.url
    }

    private func isBIT101Event(_ event: EKEvent, term: String? = nil) -> Bool {
        guard
            let url = event.url,
            url.scheme?.lowercased() == "bit101",
            url.host?.lowercased() == "calendar-course"
        else { return false }

        guard let term else { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "term" })?
            .value == term
    }

    private func loadBatches() -> [ImportedBatch] {
        guard let data = defaults.data(forKey: Self.batchesKey) else { return [] }
        return (try? JSONDecoder().decode([ImportedBatch].self, from: data)) ?? []
    }

    private func saveBatches(_ batches: [ImportedBatch]) {
        if batches.isEmpty {
            defaults.removeObject(forKey: Self.batchesKey)
        } else if let data = try? JSONEncoder().encode(batches) {
            defaults.set(data, forKey: Self.batchesKey)
        }
    }
}
