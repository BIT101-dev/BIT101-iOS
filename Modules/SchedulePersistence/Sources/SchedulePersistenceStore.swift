import Foundation
import OSLog
import ScheduleDomain
import StorageCore

/// 注入式日程磁盘仓库，账号路径与串行写入归单个实例维护。
public actor SchedulePersistenceStore {
    public nonisolated static let maximumCacheBytes = ScheduleCache.maximumEncodedBytes
    private nonisolated let executor = StorageFileExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private nonisolated let files: any AppFileService
    private nonisolated let storageRoot: URL
    private let userStateMatches: @Sendable (ScheduleCache, ScheduleCache) throws -> Bool
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScheduleCache")
    private var lastReadFailure: (url: URL, summary: String)?
    private nonisolated struct CacheVersion: Decodable { let schemaVersion: Int }
    private static let legacyBlockKeys: [String: Set<String>] = [
        "courseData": ["storedCourseScheduleParserVersion", "primaryScheduleTitle", "currentTerm", "firstDayString",
            "coursesUpdatedAt", "courses", "exams", "cachedCoursesByTerm", "schoolCoursesByTerm", "termSchedulesByTerm",
            "manualFirstDayStringsByTerm", "timeTable"],
        "ddlData": ["lexueCalendarURL", "ddlEvents", "lexueDDLCompletionByID", "ddlUpdatedAt", "ddlBeforeDay", "ddlAfterDay"],
        "classroomData": ["selectedCampusName", "selectedCampusCode", "selectedBuildingID", "cachedClassroomCampuses",
            "cachedClassroomBuildingsByCampusCode", "selectedClassroomSectionIDs", "isClassroomSectionFilterCustomized"],
        "presentation": ["showSaturday", "showSunday", "showExamInfo", "scheduleDisplayMode", "scheduleCardContentModeV2",
            "showCourseLiveActivityReminder", "courseLiveActivityLeadMinutes"],
        "syncData": ["iCloudSyncEnabled", "cloudSyncBaselineAt", "cloudSyncBaselineRecordTag", "hasUnpushedCloudChanges"],
    ]

    public init(files: any AppFileService, storageRoot: URL, userStateMatches: @escaping @Sendable (ScheduleCache, ScheduleCache) throws -> Bool) {
        self.files = files
        self.storageRoot = storageRoot
        self.userStateMatches = userStateMatches
    }

    public func load(for session: AppStorageSession) -> ScheduleCacheLoadResult {
        let result = read(accountIdentifier: session.accountStorageIdentifier, legacyAccountIdentifier: session.legacyAccountDirectoryNameForMigration)
        if case .loaded(let cache) = result {
            migrateLegacyIfNeeded(cache, accountIdentifier: session.accountStorageIdentifier, legacyAccountIdentifier: session.legacyAccountDirectoryNameForMigration)
        }
        return result
    }

    public nonisolated func cacheFileURL(for accountIdentifier: String) -> URL {
        storageRoot.appending(path: accountIdentifier, directoryHint: .isDirectory).appending(path: "schedule-cache.json")
    }

    public func readFailure(for session: AppStorageSession) -> String? {
        guard let failure = lastReadFailure,
              [session.accountStorageIdentifier, session.legacyAccountDirectoryNameForMigration]
                .contains(where: { cacheFileURL(for: $0) == failure.url }) else { return nil }
        return failure.summary
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let legacy = try? value.decode(String.self) {
                do { return try Date(legacy, strategy: .iso8601) }
                catch { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Schedule cache date requires ISO 8601.") }
            }
            return Date(timeIntervalSinceReferenceDate: try value.decode(Double.self))
        }
        return decoder
    }

    private func read(
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) -> ScheduleCacheLoadResult {
        let currentURL = cacheFileURL(for: accountIdentifier)
        let currentResult = readCacheFile(at: currentURL)
        switch currentResult {
        case .loaded, .recovered, .damaged, .unreadable:
            return currentResult
        case .missing:
            break
        }

        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard legacyURL != currentURL else { return .missing }
        return readCacheFile(at: legacyURL)
    }

    private func readCacheFile(at url: URL) -> ScheduleCacheLoadResult {
        if lastReadFailure?.url == url { lastReadFailure = nil }
        var operation = "protection"
        do {
            try files.setPrivateFileProtection(at: url)
            operation = "read"
            let data = try files.readData(at: url, maximumBytes: Self.maximumCacheBytes)
            let result = Self.decodeCache(data) { summary in
                lastReadFailure = (url, summary)
            }
            if let failure = lastReadFailure, failure.url == url {
                Self.logger.error("课表缓存重建：\(failure.summary, privacy: .public)")
            }
            let recovered = result.isUnreadable
            guard var cache = result.cacheIfReadable ?? Self.resetDamagedBlocks(data) else {
                if let version = try? Self.makeDecoder().decode(CacheVersion.self, from: data),
                   version.schemaVersion > ScheduleCache.schemaVersion { return .unreadable }
                return .damaged
            }
            if cache.currentTerm.isEmpty, let snapshot = cache.termSchedulesByTerm.values
                .filter({ $0.hasDisplayableData && $0.firstDay != nil })
                .sorted(by: { $0.updatedAt == $1.updatedAt ? $0.term > $1.term : $0.updatedAt > $1.updatedAt }).first {
                cache.currentTerm = snapshot.term
            }
            return recovered ? .recovered(cache) : .loaded(cache)
        } catch {
            if AppFileSystem.isMissingFile(error) { return .missing }
            let failure = error as NSError
            let summary = "file.\(operation):\(failure.domain).\(failure.code)"
            lastReadFailure = (url, summary)
            Self.logger.error("课表缓存读取失败，保留现有内容：\(summary, privacy: .public)")
            return .unreadable
        }
    }

    private nonisolated static func admittedRoot(_ data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if root["schemaVersion"] == nil {
            guard Set(root.keys).isDisjoint(with: legacyBlockKeys.keys) else { return nil }
            let known = legacyBlockKeys.values.reduce(into: Set(["updatedAt"])) { $0.formUnion($1) }
                .union(["customSchedules", "sharedSchedules", "manualCourseRulesByTerm"])
            guard root.isEmpty || !Set(root.keys).isDisjoint(with: known) else { return nil }
        }
        return root
    }

    /// 数据块按字段和记录恢复，原始字节由用户的恢复确认承接。
    private nonisolated static func resetDamagedBlocks(_ data: Data) -> ScheduleCache? {
        guard let root = admittedRoot(data),
              let defaults = try? JSONSerialization.jsonObject(with: makeEncoder().encode(ScheduleCache())) as? [String: Any]
        else { return nil }
        let structured = root["schemaVersion"] != nil
        if structured {
            guard let version = try? makeDecoder().decode(CacheVersion.self, from: data),
                  version.schemaVersion == ScheduleCache.schemaVersion else { return nil }
        }
        let decoder = makeDecoder()
        func value<Value: Decodable>(_ raw: Any?, as type: Value.Type) -> Value? {
            guard let raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else { return nil }
            return try? decoder.decode(type, from: data)
        }
        func object<Value: Encodable>(_ value: Value) -> Any? {
            guard let bytes = try? makeEncoder().encode(value) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
        }
        func records<Record: Decodable & Identifiable>(_ raw: Any?, as type: Record.Type,
            valid: (Record) -> Bool) -> [Record] {
            var ids: Set<Record.ID> = []
            return (raw as? [Any] ?? []).compactMap { raw in
                guard let record = value(raw, as: type), valid(record), ids.insert(record.id).inserted else { return nil }
                return record
            }
        }
        var course = structured ? root["courseData"] as? [String: Any] ?? [:] : root
        let rawTable = value(course["timeTable"], as: [TimeSlot].self)
        let table = rawTable.flatMap { TimeSlot.isValidTable($0) ? $0 : nil } ?? TimeSlot.default
        func courses(_ raw: Any?) -> [CourseRecord] {
            records(raw, as: CourseRecord.self, valid: { TimeSlot.supports([$0], in: table) })
        }
        for key in ["schedulesByTerm", "termSchedulesByTerm"] {
            guard let entries = course[key] as? [String: Any] else { continue }
            var snapshots: [String: TermScheduleSnapshot] = [:]
            for (term, raw) in entries {
                guard let fields = raw as? [String: Any] else { continue }
                snapshots[term] = .init(term: term,
                    firstDayString: value(fields["firstDayString"], as: String.self) ?? "",
                    courses: courses(fields["courses"]),
                    exams: records(fields["exams"], as: ExamRecord.self, valid: { $0.hasValidPlacement }),
                    updatedAt: value(fields["updatedAt"], as: Date.self) ?? .distantPast)
            }
            course[key] = object(snapshots)
        }
        for key in ["cachedCoursesByTerm", "schoolCoursesByTerm"] {
            if let entries = course[key] as? [String: Any] { course[key] = object(entries.mapValues(courses)) }
        }
        if course["courses"] != nil { course["courses"] = object(courses(course["courses"])) }
        if course["exams"] != nil {
            course["exams"] = object(records(course["exams"], as: ExamRecord.self, valid: { $0.hasValidPlacement }))
        }
        func block(_ name: String) -> ScheduleCache? {
            var object: [String: Any]
            if structured {
                object = defaults
                object[name] = name == "courseData" ? course : root[name]
                if name == "courseData", var course = object[name] as? [String: Any] {
                    for key in ["customSchedules", "sharedSchedules", "manualCourseRulesByTerm"] {
                        course[key] = (defaults[name] as? [String: Any])?[key]
                    }
                    object[name] = course
                }
                if name == "ddlData", var ddl = object[name] as? [String: Any] {
                    ddl["ddlEvents"] = []
                    object[name] = ddl
                }
            } else {
                object = (name == "courseData" ? course : root).filter { legacyBlockKeys[name, default: []].contains($0.key) }
                if name == "ddlData" { object.removeValue(forKey: "ddlEvents") }
            }
            func decoded(_ fields: [String: Any]) -> ScheduleCache? {
                var candidate = object
                if structured { candidate[name] = fields } else { candidate = fields }
                guard let bytes = try? JSONSerialization.data(withJSONObject: candidate) else { return nil }
                return decodeCache(bytes).cacheIfReadable
            }
            guard let fields = structured ? object[name] as? [String: Any] : object else { return nil }
            if let result = decoded(fields) { return result }
            let base = structured ? defaults[name] as? [String: Any] ?? [:] : [:]
            var accepted = base
            let first = ["timeTable", "storedCourseScheduleParserVersion", "currentTerm", "firstDayString", "coursesUpdatedAt", "archivedTerms"]
            for key in first + fields.keys.sorted().filter({ !first.contains($0) }) {
                guard let value = fields[key] else { continue }
                func accepts(_ value: Any) -> Bool {
                    var candidate = accepted
                    candidate[key] = value
                    return decoded(candidate) != nil
                }
                if accepts(value) { accepted[key] = value }
                else if let entries = value as? [String: Any] {
                    var kept: [String: Any] = [:]
                    for (entry, value) in entries where accepts([entry: value]) { kept[entry] = value }
                    accepted[key] = kept
                } else if key != "timeTable", let values = value as? [Any] {
                    var kept: [Any] = []
                    for entry in values where accepts([entry]) { kept.append(entry) }
                    accepted[key] = kept
                }
            }
            return decoded(accepted)
        }
        var cache = ScheduleCache()
        cache.courseData = block("courseData")?.courseData ?? cache.courseData
        cache.customSchedules = records(course["customSchedules"], as: CustomScheduleRecord.self, valid: { $0.hasValidPlacement })
        cache.sharedSchedules = records(course["sharedSchedules"], as: SharedScheduleRecord.self, valid: { record in
            var probe = ScheduleCache()
            probe.sharedSchedules = [record]
            return probe.isValidForPersistence
        })
        cache.ddlData = block("ddlData")?.ddlData ?? cache.ddlData
        cache.classroomData = block("classroomData")?.classroomData ?? cache.classroomData
        cache.presentation = block("presentation")?.presentation ?? cache.presentation
        cache.syncData = block("syncData")?.syncData ?? cache.syncData
        let rawSync = structured ? root["syncData"] as? [String: Any] ?? [:] : root
        let consent = rawSync["iCloudSyncEnabled"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
        cache.iCloudSyncEnabled = consent.flatMap { try? makeDecoder().decode(Bool.self, from: $0) } ?? false
        let ddl = structured ? root["ddlData"] as? [String: Any] ?? [:] : root
        cache.ddlEvents = records(ddl["ddlEvents"], as: DDLEventRecord.self, valid: { $0.hasValidRecord })
        for (term, values) in (course["manualCourseRulesByTerm"] as? [String: Any] ?? [:]) {
            let candidates = records(values, as: ScheduleCourseRule.self, valid: { record in
                var probe = ScheduleCache()
                probe.timeTable = cache.timeTable
                probe.manualCourseRulesByTerm[term] = [record]
                return probe.isValidForPersistence
            })
            cache.manualCourseRulesByTerm[term] = recoveredRules(candidates,
                schoolCourses: cache.courseData.archivedTerms.contains(term) ? [] : cache.courseData.schoolCourses(for: term),
                timeTable: cache.timeTable)
        }
        if let rawDate = root["updatedAt"], let bytes = try? JSONSerialization.data(withJSONObject: rawDate, options: .fragmentsAllowed),
           let date = try? makeDecoder().decode(Date.self, from: bytes) { cache.updatedAt = date }
        return cache.isValidForPersistence ? cache : nil
    }

    /// 逐条维护课程身份，隔离互相冲突的规则并保留其余记录。
    private nonisolated static func recoveredRules(_ rules: [ScheduleCourseRule], schoolCourses: [CourseRecord],
        timeTable: [TimeSlot]) -> [ScheduleCourseRule] {
        let schoolBySource = Dictionary(grouping: schoolCourses, by: scheduleCourseSourceIdentity)
        var projectedBySource = schoolBySource.mapValues { $0.map(\.id) }
        var ids = Set(schoolCourses.map(\.id))
        return rules.filter { rule in
            let active = rule.isLocalAddition
                || scheduleCourseSourceRecordsEqual(schoolBySource[rule.sourceIdentity] ?? [], rule.sourceCourses)
            guard active else { return true }
            guard TimeSlot.supports(rule.replacementCourses, in: timeTable) else { return false }
            let removed = rule.isLocalAddition ? [] : projectedBySource[rule.sourceIdentity] ?? []
            let replacementIDs = Set(rule.replacementCourses.map(\.id))
            let removedIDs = Set(removed)
            guard replacementIDs.allSatisfy({ !ids.contains($0) || removedIDs.contains($0) }) else { return false }
            ids.subtract(removedIDs)
            if !rule.isLocalAddition { projectedBySource[rule.sourceIdentity] = [] }
            ids.formUnion(replacementIDs)
            for course in rule.replacementCourses { projectedBySource[scheduleCourseSourceIdentity(course), default: []].append(course.id) }
            return true
        }
    }

    public nonisolated static func decodeCache(_ data: Data, onFailure: (String) -> Void = { _ in }) -> ScheduleCacheLoadResult {
        guard data.count <= maximumCacheBytes else {
            onFailure("decode.sizeLimit")
            return .unreadable
        }
        guard admittedRoot(data) != nil else { onFailure("decode.root"); return .unreadable }
        do {
            return .loaded(try Self.makeDecoder().decode(ScheduleCache.self, from: data))
        } catch {
            onFailure(decodingFailureSummary(error))
            return .unreadable
        }
    }

    private nonisolated static func decodingFailureSummary(_ error: Error) -> String {
        let kind: String, path: [any CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context): kind = "missing"; path = context.codingPath + [key]
        case DecodingError.typeMismatch(_, let context): kind = "type"; path = context.codingPath
        case DecodingError.valueNotFound(_, let context): kind = "null"; path = context.codingPath
        case DecodingError.dataCorrupted(let context): kind = "invalid"; path = context.codingPath
        default: return "decode.error"
        }
        let fields: Set<String> = ["schemaVersion", "courseData", "ddlData", "classroomData", "presentation", "syncData", "updatedAt",
            "primaryScheduleTitle", "currentTerm", "manualFirstDayStringsByTerm", "manualCourseRulesByTerm", "customSchedules",
            "timeTable", "sharedSchedules", "schedulesByTerm", "archivedTerms", "firstDayString", "courses", "exams", "term",
            "id", "name", "teacher", "classroom", "description", "weeks", "weekday", "startSection", "endSection", "campus",
            "number", "credit", "hour", "type", "category", "department", "sourceIdentity", "sourceCourses", "replacementCourses",
            "title", "subtitle", "dateString", "additionalDateStrings", "beginTime", "endTime", "importedAt", "sharedAt",
            "lexueCalendarURL", "ddlEvents", "lexueDDLCompletionByID", "lexueDDLRetiredAtByID", "ddlUpdatedAt", "ddlBeforeDay",
            "ddlAfterDay", "group", "text", "dueAt", "done", "start", "end", "iCloudSyncEnabled", "cloudSyncBaselineAt",
            "cloudSyncBaselineRecordTag", "cloudSyncBaselineUserState", "hasUnpushedCloudChanges"]
        let location = path.map { key in key.intValue != nil ? "[]" : fields.contains(key.stringValue) ? key.stringValue : "*" }
        return "decode.\(kind):\(location.isEmpty ? "$" : location.joined(separator: "."))"
    }

    private func migrateLegacyIfNeeded(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) {
        guard accountIdentifier != legacyAccountIdentifier else { return }
        let currentURL = cacheFileURL(for: accountIdentifier)
        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard case .missing = readCacheFile(at: currentURL),
              case .loaded = readCacheFile(at: legacyURL), lastReadFailure?.url != legacyURL
        else { return }

        do {
            try files.createDirectory(at: currentURL.deletingLastPathComponent())
            let data = try Self.makeEncoder().encode(cache)
            guard data.count <= Self.maximumCacheBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try files.writeData(
                data,
                to: currentURL,
                options: AppFileSystem.protectedDataWritingOptions
            )
            try files.removeItem(at: legacyURL)
            let directory = legacyURL.deletingLastPathComponent()
            if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
                try files.removeItem(at: directory)
            }
        } catch {
            Self.logger.error("旧课表缓存迁移失败：\(String(describing: error), privacy: .public)")
        }
    }

    public func write(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        legacyAccountIdentifier: String,
        source: ScheduleCacheSaveSource,
        expectedUpdatedAt: Date?
    ) -> ScheduleCache? {
        guard cache.isValidForPersistence else {
            Self.logger.error("日程记录结构无效，保留已有课表缓存")
            return nil
        }
        let url = cacheFileURL(for: accountIdentifier)
        let directory = url.deletingLastPathComponent()
        let currentResult = readCacheFile(at: url)
        let confirmsRecovery = source == .recovery
        let confirmsRebuild = source == .rebuild
        var isRecovering = currentResult.isRecovered
        var isRebuilding = currentResult.isDamaged
        guard currentResult.allowsWrite || (confirmsRecovery && currentResult.isRecovered)
                || (confirmsRebuild && currentResult.isDamaged) else {
            Self.logger.error("保留无法读取的课表缓存，跳过保存")
            return nil
        }
        var storedUpdatedAt = Date.distantPast
        var storedCache: ScheduleCache?
        switch currentResult {
        case .loaded(let currentCache), .recovered(let currentCache):
            storedUpdatedAt = currentCache.updatedAt
            storedCache = currentCache
        case .missing, .damaged, .unreadable: break
        }
        if case .missing = currentResult,
           legacyAccountIdentifier != accountIdentifier
        {
            let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
            let legacyResult = readCacheFile(at: legacyURL)
            isRecovering = legacyResult.isRecovered
            isRebuilding = legacyResult.isDamaged
            guard legacyResult.allowsWrite || (confirmsRecovery && legacyResult.isRecovered)
                    || (confirmsRebuild && legacyResult.isDamaged) else {
                Self.logger.error("保留无法读取的旧版课表缓存，跳过保存")
                return nil
            }
            switch legacyResult {
            case .loaded(let legacyCache), .recovered(let legacyCache):
                storedUpdatedAt = legacyCache.updatedAt
                storedCache = legacyCache
            case .missing, .damaged, .unreadable: break
            }
        }
        if let expectedUpdatedAt, !confirmsRebuild, expectedUpdatedAt != storedUpdatedAt {
            Self.logger.debug("缓存写入跳过，磁盘版本已变化")
            return nil
        }

        do {
            var cache = cache
            if confirmsRecovery, !isRecovering { return nil }
            if confirmsRebuild, !isRebuilding { return nil }
            if source == .cloud { cache.hasUnpushedCloudChanges = false }
            if source == .local || source == .localWithoutCloudPush || source == .recovery,
               let storedCache {
                guard cache.cloudSyncBaselineAt == storedCache.cloudSyncBaselineAt,
                      cache.cloudSyncBaselineRecordTag == storedCache.cloudSyncBaselineRecordTag,
                      cache.syncData.cloudSyncBaselineUserState == storedCache.syncData.cloudSyncBaselineUserState else {
                    Self.logger.error("云端基线已更新，保留磁盘数据和本机修改")
                    return nil
                }
                cache.cloudSyncBaselineAt = storedCache.cloudSyncBaselineAt
                cache.cloudSyncBaselineRecordTag = storedCache.cloudSyncBaselineRecordTag
                cache.syncData.cloudSyncBaselineUserState = storedCache.syncData.cloudSyncBaselineUserState
                let userStateChanged = try !userStateMatches(cache, storedCache)
                cache.hasUnpushedCloudChanges = storedCache.hasUnpushedCloudChanges
                    || (cache.iCloudSyncEnabled && (confirmsRecovery || userStateChanged))
                cache.updatedAt = ScheduleCacheTimestamp.next(
                    after: max(storedCache.updatedAt, storedCache.cloudSyncBaselineAt),
                    now: cache.updatedAt
                )
            }
            try files.createDirectory(at: directory)
            let data = try Self.makeEncoder().encode(cache)
            guard data.count <= Self.maximumCacheBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try files.writeData(
                data,
                to: url,
                options: AppFileSystem.protectedDataWritingOptions
            )
            removeMigratedCacheIfPossible(
                accountIdentifier: accountIdentifier,
                legacyAccountIdentifier: legacyAccountIdentifier,
                includingDamaged: confirmsRebuild
            )
            return cache
        } catch {
            Self.logger.error("保存课表缓存失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func clear(urls: [URL]) -> Bool {
        do {
            for url in urls {
                try files.removeItemIfPresent(at: url)
                if lastReadFailure?.url == url { lastReadFailure = nil }
            }

            for directory in Set(urls.map({ $0.deletingLastPathComponent() })) {
                do {
                    if try files.contentsOfDirectory(at: directory, options: []).isEmpty {
                        try files.removeItemIfPresent(at: directory)
                    }
                } catch {
                    if !AppFileSystem.isMissingFile(error) { throw error }
                }
            }
        } catch {
            Self.logger.error("清理课表缓存失败：\(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private func removeMigratedCacheIfPossible(
        accountIdentifier: String,
        legacyAccountIdentifier: String,
        includingDamaged: Bool = false
    ) {
        guard accountIdentifier != legacyAccountIdentifier else { return }
        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        let result = readCacheFile(at: legacyURL)
        switch result {
        case .loaded: break
        case .damaged where includingDamaged: break
        default: return
        }
        do {
            try files.removeItem(at: legacyURL)
            if lastReadFailure?.url == legacyURL { lastReadFailure = nil }
            let directory = legacyURL.deletingLastPathComponent()
            if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
                try files.removeItem(at: directory)
            }
        } catch {
            Self.logger.error("迁移旧课表缓存清理失败：\(String(describing: error), privacy: .public)")
        }
    }
}

/// 保存与清理共享实例队列，在操作开始和返回时核对所属会话。
@MainActor
public final class SchedulePersistenceCoordinator {
    private var pending: Task<Bool, Never>?
    private var revision = 0

    public init() {}

    @discardableResult
    public func perform(
        isCurrent: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        let previous = pending
        revision &+= 1
        let request = revision
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled, isCurrent() else { return false }
            return await operation()
        }
        pending = task
        let saved = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if revision == request { pending = nil }
        return saved && !Task.isCancelled && isCurrent()
    }
}
