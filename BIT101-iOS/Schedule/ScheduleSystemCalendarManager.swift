import EventKit
import Foundation

/// 系统日历可识别的校园建筑坐标。
nonisolated struct ScheduleSystemCalendarStructuredLocation: Equatable {
    let title: String
    let latitude: Double
    let longitude: Double
}

/// 保存写入系统日历前的数据，支持独立于 EventKit 的日期计算验证。
nonisolated struct ScheduleSystemCalendarEventDraft: Equatable {
    let markerID: String
    let title: String
    let location: String
    let structuredLocation: ScheduleSystemCalendarStructuredLocation?
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
        let slots = Dictionary(timeTable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let calendar = shanghaiCalendar()

        let drafts: [ScheduleSystemCalendarEventDraft] = courses.flatMap { (course: CourseRecord) -> [ScheduleSystemCalendarEventDraft] in
            guard
                let startSlot = slots[course.startSection],
                let endSlot = slots[course.endSection]
            else { return [] }

            guard (1 ... 7).contains(course.weekday) else { return [] }

            return course.weeks.compactMap { week in
                let weekOffset = ScheduleWeekCodec.weekOffset(forWeekNumber: week)
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
                    course.number.isEmpty ? nil : "课程编号：\(dataDetectorSafeCourseNumber(course.number))",
                    course.description.isEmpty ? nil : course.description,
                ].compactMap { $0 }
                let structuredLocation = CampusMapPlaceCatalog.place(
                    campusName: course.campus,
                    classroom: course.classroom
                ).map {
                    ScheduleSystemCalendarStructuredLocation(
                        title: "北京理工大学 · \($0.campus.displayName) · \($0.name)",
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }

                return ScheduleSystemCalendarEventDraft(
                    markerID: "\(course.id)-w\(week)",
                    title: course.name,
                    location: displayLocation(campus: course.campus, classroom: course.classroom),
                    structuredLocation: structuredLocation,
                    notes: noteLines.joined(separator: "\n"),
                    startDate: startDate,
                    endDate: endDate
                )
            }
        }
        var uniqueDrafts: [String: ScheduleSystemCalendarEventDraft] = [:]
        for draft in drafts {
            uniqueDrafts[draft.markerID] = draft
        }
        return uniqueDrafts.values.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.title < rhs.title
        }
    }

    static func makeDraft(for exam: ExamRecord) -> ScheduleSystemCalendarEventDraft? {
        let calendar = shanghaiCalendar()
        guard
            let day = date(from: exam.dateString, calendar: calendar),
            let startDate = date(on: day, time: exam.beginTime, calendar: calendar),
            let endDate = date(on: day, time: exam.endTime, calendar: calendar),
            endDate > startDate
        else { return nil }

        let noteLines = [
            exam.courseID.isEmpty ? nil : "课程号：\(dataDetectorSafeCourseNumber(exam.courseID))",
            exam.teacher.isEmpty ? nil : "教师：\(exam.teacher)",
            exam.examMode.isEmpty ? nil : "形式：\(exam.examMode)",
            exam.seatID.isEmpty ? nil : "座位号：\(exam.seatID)",
            "考试时间：\(exam.beginTime)-\(exam.endTime)",
        ].compactMap { $0 }

        return ScheduleSystemCalendarEventDraft(
            markerID: "exam-\(exam.id)",
            title: "[考试] \(exam.name)",
            location: exam.classroom,
            structuredLocation: structuredLocation(campus: "", classroom: exam.classroom),
            notes: noteLines.joined(separator: "\n"),
            startDate: startDate,
            endDate: endDate
        )
    }

    static func makeDraft(for schedule: CustomScheduleRecord) -> ScheduleSystemCalendarEventDraft? {
        let calendar = shanghaiCalendar()
        guard
            let day = date(from: schedule.dateString, calendar: calendar),
            let startDate = date(on: day, time: schedule.beginTime, calendar: calendar),
            let endDate = date(on: day, time: schedule.endTime, calendar: calendar),
            endDate > startDate
        else { return nil }

        return ScheduleSystemCalendarEventDraft(
            markerID: "custom-\(schedule.id)",
            title: schedule.title,
            location: schedule.subtitle,
            structuredLocation: structuredLocation(campus: "", classroom: schedule.subtitle),
            notes: schedule.description,
            startDate: startDate,
            endDate: endDate
        )
    }

    /// 组合校区和教室文本；教室字段已包含校区时沿用原始教室文本。
    private static func displayLocation(campus: String, classroom: String) -> String {
        let campusText = campus.trimmingCharacters(in: .whitespacesAndNewlines)
        let classroomText = classroom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !campusText.isEmpty else { return classroomText }
        guard !classroomText.isEmpty else { return campusText }
        guard !classroomText.contains(campusText.replacingOccurrences(of: "校区", with: "")) else {
            return classroomText
        }
        return "\(campusText) · \(classroomText)"
    }

    private static func structuredLocation(
        campus: String,
        classroom: String
    ) -> ScheduleSystemCalendarStructuredLocation? {
        CampusMapPlaceCatalog.place(campusName: campus, classroom: classroom).map {
            ScheduleSystemCalendarStructuredLocation(
                title: "北京理工大学 · \($0.campus.displayName) · \($0.name)",
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }

    /// 在连续数字之间插入不可见的 word joiner，保留视觉内容，同时阻止系统日历
    /// 把纯数字课程号误判成可拨打的电话号码。
    static func dataDetectorSafeCourseNumber(_ value: String) -> String {
        var result = ""
        var previousWasNumber = false
        for character in value {
            if previousWasNumber, character.isNumber {
                result.append("\u{2060}")
            }
            result.append(character)
            previousWasNumber = character.isNumber
        }
        return result
    }

    private static func date(on day: Date, time: String, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0 ... 23).contains(hour) || (hour == 24 && minute == 0),
            (0 ... 59).contains(minute)
        else { return nil }

        var components = calendar.dateComponents(
            [.year, .month, .day],
            from: day
        )
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func date(from value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2]),
            (1 ... 12).contains(month),
            (1 ... 31).contains(day)
        else { return nil }

        let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        ))
        guard let date else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        return date
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

    var shouldOpenSettings: Bool {
        switch self {
        case .permissionDenied, .noWritableCalendarSource:
            return true
        case .missingSchedule, .noImportedEvents:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "当前日历账户的写入权限需要调整。请在系统设置的“隐私与安全性－日历”中开启 BIT101 权限，并确认 iCloud 或本地日历账户处于可写状态。"
        case .noWritableCalendarSource:
            return "未找到可以写入的系统日历账户。请先在“日历”App 中启用 iCloud 或本地日历。"
        case .missingSchedule:
            return "当前学期还没有可导入的课程，或尚未取得学期起始日期。"
        case .noImportedEvents:
            return "没有找到由 BIT101 导入的日历事件。"
        }
    }
}

enum ScheduleSystemCalendarMutationResult: Equatable {
    case changed(Int)
    case noOp

    var count: Int {
        switch self {
        case let .changed(count): return count
        case .noOp: return 0
        }
    }
}

/// 系统日历导入、更新与删除协调器。
///
/// 每条事件保存 EventKit identifier 和 `bit101://calendar-course/...` URL 标记。
/// identifier 用于快速删除；URL 标记用于日历同步改变 identifier 后识别事件。
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

    func importDrafts(
        _ drafts: [ScheduleSystemCalendarEventDraft],
        term: String,
        replacingTerm: Bool = false
    ) async throws -> Int {
        let orderedDrafts = drafts.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.markerID < rhs.markerID
        }
        guard let first = orderedDrafts.first, let last = orderedDrafts.last else {
            throw ScheduleSystemCalendarError.missingSchedule
        }

        try await requireFullAccess()
        do {
            let calendar = try writableBIT101Calendar()
            let markerIDs = Set(orderedDrafts.map(\.markerID))
            let existingEvents = replacingTerm
                ? events(forTerm: term)
                : events(matchingMarkerIDs: markerIDs, term: term)
            let removedIdentifiers = Set(existingEvents.map(\.eventIdentifier))
            for event in existingEvents {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
            var savedEvents: [EKEvent] = []
            for draft in orderedDrafts {
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = draft.title
                event.location = draft.location
                if let draftLocation = draft.structuredLocation {
                    let structuredLocation = EKStructuredLocation(title: draftLocation.title)
                    structuredLocation.geoLocation = CLLocation(
                        latitude: draftLocation.latitude,
                        longitude: draftLocation.longitude
                    )
                    event.structuredLocation = structuredLocation
                }
                event.notes = draft.notes
                event.startDate = draft.startDate
                event.endDate = draft.endDate
                event.timeZone = ScheduleSharedDateCodec.calendar.timeZone
                event.url = markerURL(id: draft.markerID, term: term)
                try eventStore.save(event, span: .thisEvent, commit: false)
                savedEvents.append(event)
            }
            try eventStore.commit()

            var batches = loadBatches().filter { $0.term != term }
            let oldBatch = loadBatches().first(where: { $0.term == term })
            batches.append(ImportedBatch(
                term: term,
                calendarIdentifier: calendar.calendarIdentifier,
                eventIdentifiers: (oldBatch?.eventIdentifiers ?? []).filter { !removedIdentifiers.contains($0) }
                    + savedEvents.compactMap(\.eventIdentifier),
                startDate: min(oldBatch?.startDate ?? first.startDate, first.startDate.addingTimeInterval(-24 * 60 * 60)),
                endDate: max(oldBatch?.endDate ?? last.endDate, last.endDate.addingTimeInterval(24 * 60 * 60))
            ))
            saveBatches(batches)
            return savedEvents.count
        } catch let error as EKError where Self.isCalendarWritePermissionError(error) {
            throw ScheduleSystemCalendarError.permissionDenied
        }
    }

    func deleteImportedEvents(
        markerIDs: Set<String>,
        term: String? = nil
    ) async throws -> ScheduleSystemCalendarMutationResult {
        try await requireFullAccess()
        let eventsByIdentifier = Dictionary(
            uniqueKeysWithValues: events(matchingMarkerIDs: markerIDs, term: term).map { ($0.eventIdentifier, $0) }
        )
        guard !eventsByIdentifier.isEmpty else { return .noOp }

        do {
            for event in eventsByIdentifier.values {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
            try eventStore.commit()

            let removedIdentifiers = Set(eventsByIdentifier.keys)
            let batches = loadBatches().compactMap { batch -> ImportedBatch? in
                let remaining = batch.eventIdentifiers.filter { !removedIdentifiers.contains($0) }
                guard !remaining.isEmpty else { return nil }
                return ImportedBatch(
                    term: batch.term,
                    calendarIdentifier: batch.calendarIdentifier,
                    eventIdentifiers: remaining,
                    startDate: batch.startDate,
                    endDate: batch.endDate
                )
            }
            saveBatches(batches)
            return .changed(eventsByIdentifier.count)
        } catch let error as EKError where Self.isCalendarWritePermissionError(error) {
            throw ScheduleSystemCalendarError.permissionDenied
        }
    }

    func deleteImportedEvents(
        drafts: [ScheduleSystemCalendarEventDraft],
        term: String? = nil
    ) async throws -> ScheduleSystemCalendarMutationResult {
        try await deleteImportedEvents(markerIDs: Set(drafts.map(\.markerID)), term: term)
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
        return try await importDrafts(
            drafts,
            term: cache.currentTerm,
            replacingTerm: true
        )
    }

    func deleteAllImportedEvents() async throws -> ScheduleSystemCalendarMutationResult {
        try await requireFullAccess()

        do {
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

            // 本地批次记录缺失时，专用日历中的事件 URL 仍可用于识别 BIT101 事件。
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

            guard !eventsByIdentifier.isEmpty else { return .noOp }

            for event in eventsByIdentifier.values {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
            try eventStore.commit()
            saveBatches([])
            return .changed(eventsByIdentifier.count)
        } catch let error as EKError where Self.isCalendarWritePermissionError(error) {
            throw ScheduleSystemCalendarError.permissionDenied
        }
    }

    private func requireFullAccess() async throws {
        do {
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
        } catch let error as ScheduleSystemCalendarError {
            throw error
        } catch {
            if TaskCancellation.matches(error) {
                throw error
            }
            throw ScheduleSystemCalendarError.permissionDenied
        }
    }

    private static func isCalendarWritePermissionError(_ error: EKError) -> Bool {
        switch error.code {
        case .calendarReadOnly,
             .sourceDoesNotAllowCalendarAddDelete,
             .sourceDoesNotAllowEvents,
             .calendarDoesNotAllowEvents,
             .eventStoreNotAuthorized:
            return true
        default:
            return false
        }
    }

    private func writableBIT101Calendar() throws -> EKCalendar {
        if let existing = existingBIT101Calendar() {
            guard existing.allowsContentModifications else {
                throw ScheduleSystemCalendarError.noWritableCalendarSource
            }
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

    private func markerID(from event: EKEvent) -> String {
        event.url?.path
            .removingPercentEncoding?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    }

    private func events(matchingMarkerIDs markerIDs: Set<String>, term: String? = nil) -> [EKEvent] {
        guard !markerIDs.isEmpty else { return [] }
        var eventsByIdentifier: [String: EKEvent] = [:]
        for batch in loadBatches() {
            if let term, batch.term != term { continue }
            for identifier in batch.eventIdentifiers {
                guard let event = eventStore.event(withIdentifier: identifier),
                      isBIT101Event(event, term: term),
                      markerIDs.contains(markerID(from: event))
                else { continue }
                eventsByIdentifier[identifier] = event
            }
        }

        let lowerBound = ScheduleSharedDateCodec.calendar.date(byAdding: .year, value: -10, to: Date()) ?? .distantPast
        let upperBound = ScheduleSharedDateCodec.calendar.date(byAdding: .year, value: 10, to: Date()) ?? .distantFuture
        if let calendar = existingBIT101Calendar() {
            for event in taggedEvents(calendars: [calendar], startDate: lowerBound, endDate: upperBound, term: term)
                where markerIDs.contains(markerID(from: event)) {
                eventsByIdentifier[event.eventIdentifier] = event
            }
        }
        return Array(eventsByIdentifier.values)
    }

    private func events(forTerm term: String) -> [EKEvent] {
        var eventsByIdentifier: [String: EKEvent] = [:]
        let batches = loadBatches().filter { $0.term == term }
        for batch in batches {
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
        if let calendar = existingBIT101Calendar() {
            let lowerBound = ScheduleSharedDateCodec.calendar.date(byAdding: .year, value: -10, to: Date()) ?? .distantPast
            let upperBound = ScheduleSharedDateCodec.calendar.date(byAdding: .year, value: 10, to: Date()) ?? .distantFuture
            for event in taggedEvents(calendars: [calendar], startDate: lowerBound, endDate: upperBound, term: term) {
                eventsByIdentifier[event.eventIdentifier] = event
            }
        }
        return Array(eventsByIdentifier.values)
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
