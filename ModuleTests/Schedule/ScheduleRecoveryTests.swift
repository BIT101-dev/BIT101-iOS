import BIT101TestSupport
import Foundation
import ScheduleDomain
import SchedulePersistence
@testable import ScheduleFeature
import StorageCore
import Testing

@MainActor
struct ScheduleRecoveryTests {
    @Test(.timeLimit(.minutes(1))) func rebuildConfirmationExpiresWhenTheAccountChanges() async {
        var account = AppStorageSession(accountIdentifier: "first")
        var saves = 0
        let repository = ScheduleRepository(session: { account }, load: { _ in .damaged }, save: { _, _, _ in saves += 1 })
        await repository.loadIfNeeded()
        let generation = repository.accountGeneration
        account = AppStorageSession(accountIdentifier: "second")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        await repository.rebuildCache(expectedGeneration: generation)
        #expect(saves == 0 && repository.hasReadFailure && repository.canRebuildCache)
    }

    @Test(.timeLimit(.minutes(1))) func newerScheduleFormatsPreserveTheOriginalDuringRebuildRequests() async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "future-rebuild")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/future-rebuild"),
            userStateMatches: ScheduleCloudSyncState.matches)
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data(#"{"schemaVersion":2,"courseData":{}}"#.utf8)
        try files.writeData(bytes, to: url, options: [])
        let result = await store.load(for: account)
        #expect(result.isUnreadable && !result.isDamaged)
        #expect(await store.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .rebuild, expectedUpdatedAt: nil) == nil)
        #expect(files.storedData[url] == bytes)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func confirmedRootRebuildKeepsCurrentMemoryAndOtherAccounts(legacy: Bool) async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "root-rebuild")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/root-rebuild"),
            userStateMatches: ScheduleCloudSyncState.matches)
        var initial = ScheduleCache()
        initial.primaryScheduleTitle = "保留的日程"
        initial.hasUnpushedCloudChanges = false
        let current = store.cacheFileURL(for: account.accountStorageIdentifier)
        let other = store.cacheFileURL(for: AppStorageSession(accountIdentifier: "other").accountStorageIdentifier)
        let valid = try JSONEncoder().encode(initial)
        try files.writeData(valid, to: current, options: [])
        try files.writeData(valid, to: other, options: [])
        let repository = ScheduleRepository(session: { account }, load: { await store.load(for: $0) }, save: { cache, source, _ in
            guard await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: source,
                expectedUpdatedAt: cache.updatedAt) != nil else { throw CocoaError(.fileWriteUnknown) }
        })
        await repository.loadIfNeeded()
        let damagedURL = legacy ? store.cacheFileURL(for: account.legacyAccountDirectoryNameForMigration) : current
        if legacy { try files.removeItem(at: current) }
        let damaged = Data("{".utf8)
        try files.writeData(damaged, to: damagedURL, options: [])
        await repository.reload()
        #expect(repository.hasReadFailure && repository.canRebuildCache && !repository.isWritable)
        #expect(files.storedData[damagedURL] == damaged)
        await repository.rebuildCache(expectedGeneration: repository.accountGeneration)
        #expect(repository.isWritable && !repository.hasReadFailure && !repository.canRebuildCache)
        let restored = try #require(await store.load(for: account).cacheIfReadable)
        #expect(restored.primaryScheduleTitle == initial.primaryScheduleTitle && !restored.hasUnpushedCloudChanges)
        #expect(files.storedData[other] == valid)
        if legacy { #expect(files.storedData[damagedURL] == nil) }
    }

    @Test(.timeLimit(.minutes(1))) func rebuildPreservesAFileThatBecameReadableBeforeConfirmation() async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "rebuild-version")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/rebuild-version"),
            userStateMatches: ScheduleCloudSyncState.matches)
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(Data("{".utf8), to: url, options: [])
        let repository = ScheduleRepository(session: { account }, load: { await store.load(for: $0) }, save: { cache, source, _ in
            guard await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: source,
                expectedUpdatedAt: cache.updatedAt) != nil else { throw CocoaError(.fileWriteUnknown) }
        })
        await repository.loadIfNeeded()
        var newer = ScheduleCache()
        newer.primaryScheduleTitle = "新版本"
        let bytes = try JSONEncoder().encode(newer)
        try files.writeData(bytes, to: url, options: [])
        await repository.rebuildCache(expectedGeneration: repository.accountGeneration)
        #expect(files.storedData[url] == bytes && repository.hasReadFailure)
        await repository.reload()
        #expect(repository.isWritable && repository.courseState.primaryScheduleTitle == "新版本")
    }

    @Test(.timeLimit(.minutes(1))) func transientReadFailuresKeepTheRetryPath() async {
        var saves = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "file-access") },
            load: { _ in .unreadable }, save: { _, _, _ in saves += 1 })
        await repository.loadIfNeeded()
        await repository.rebuildCache(expectedGeneration: repository.accountGeneration)
        #expect(repository.hasReadFailure && !repository.canRebuildCache && saves == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func damagedNeighborKeepsCustomSectionsThroughRecoveryConfirmation(structured: Bool) async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "custom-section-recovery")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/custom-section-recovery"),
            userStateMatches: ScheduleCloudSyncState.matches)
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.timeTable.append(TimeSlot(id: 14, start: "21:00", end: "21:45"))
        let courses = try ScheduleCourseEditor.adding(.init(title: "课程", weekday: 1,
            startSection: 14, endSection: 14, weeksText: "1"), to: [], term: cache.currentTerm, id: "late-course")
        cache.courseData.store(.init(term: cache.currentTerm, firstDayString: "2026-09-07", courses: courses,
            exams: [], updatedAt: .distantPast))
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        var course = try #require(root["courseData"] as? [String: Any])
        course["primaryScheduleTitle"] = 7
        if structured { root["courseData"] = course }
        else {
            course["termSchedulesByTerm"] = course.removeValue(forKey: "schedulesByTerm")
            course["storedCourseScheduleParserVersion"] = 2
            root = course
        }
        let bytes = try JSONSerialization.data(withJSONObject: root)
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(bytes, to: url, options: [])
        let recovered = try #require(await store.load(for: account).cacheIfReadable)
        #expect(recovered.timeTable == cache.timeTable && recovered.courses == courses)
        #expect(files.storedData[url] == bytes)
        #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .recovery, expectedUpdatedAt: nil) != nil)
        let restored = try #require(await store.load(for: account).cacheIfReadable)
        #expect(restored.timeTable == cache.timeTable && restored.courses == courses)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func damagedFieldsKeepSchoolSchedulesAndCloudConsentUntilRecoveryConfirmation(wholeSyncBlock: Bool) async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "schedule-field-recovery")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/schedule-field-recovery"),
            userStateMatches: ScheduleCloudSyncState.matches)
        var cache = ScheduleCache()
        cache.currentTerm = "2026-2027-1"
        cache.iCloudSyncEnabled = false
        let courses = try ScheduleCourseEditor.adding(.init(title: "课程", weekday: 1, weeksText: "1"),
            to: [], term: cache.currentTerm, id: "school-course")
        cache.courseData.store(.init(term: cache.currentTerm, firstDayString: "2026-09-07", courses: courses,
            exams: [], updatedAt: Date(timeIntervalSince1970: 100)))
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        var course = try #require(root["courseData"] as? [String: Any])
        course["manualFirstDayStringsByTerm"] = 7
        root["courseData"] = course
        var sync = try #require(root["syncData"] as? [String: Any])
        sync["cloudSyncBaselineAt"] = "damaged date"
        root["syncData"] = wholeSyncBlock ? 7 : sync
        let bytes = try JSONSerialization.data(withJSONObject: root)
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(bytes, to: url, options: [])
        let recovered = try #require(await store.load(for: account).cacheIfReadable)
        #expect(recovered.currentTerm == cache.currentTerm && recovered.courses == courses)
        #expect(recovered.iCloudSyncEnabled == false && files.storedData[url] == bytes)
        #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud, expectedUpdatedAt: nil) == nil)
        #expect(files.storedData[url] == bytes)
        for source in [ScheduleCacheSaveSource.local, .localWithoutCloudPush, .cloudBaseline] {
            #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: source, expectedUpdatedAt: nil) == nil)
            #expect(files.storedData[url] == bytes)
        }
        #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .recovery, expectedUpdatedAt: nil) != nil)
    }

    @Test(.timeLimit(.minutes(1))) func recoveryConfirmationKeepsEditsMadeBeforeTheDiskReadFailed() async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "schedule-pending-recovery")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/schedule-pending-recovery"),
            userStateMatches: ScheduleCloudSyncState.matches)
        let initial = ScheduleCache(), url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(JSONEncoder().encode(initial), to: url, options: [])
        let repository = ScheduleRepository(session: { account }, load: { await store.load(for: $0) }, save: { cache, source, _ in
            guard await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: source,
                expectedUpdatedAt: cache.updatedAt) != nil else { throw CocoaError(.fileWriteUnknown) }
        })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "待保存的编辑"
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        var course = try #require(root["courseData"] as? [String: Any])
        course["customSchedules"] = [7]
        root["courseData"] = course
        let bytes = try JSONSerialization.data(withJSONObject: root)
        try files.writeData(bytes, to: url, options: [])
        await repository.reload()
        #expect(repository.requiresRecoveryConfirmation && !repository.isWritable)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "待保存的编辑")
        #expect(files.storedData[url] == bytes)
        await repository.confirmRecovery()
        #expect(repository.isWritable && !repository.requiresRecoveryConfirmation)
        #expect(await store.load(for: account).cacheIfReadable?.primaryScheduleTitle == "待保存的编辑")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["courses", "exams"])
    func damagedSchoolRecordsKeepValidNeighborsWithinTheirSemester(structured: Bool, collection: String) async throws {
        for defect in ["placement", "duplicate", "scalar"] {
            var cache = ScheduleCache()
            cache.currentTerm = "term"
            let courses = try (0..<3).flatMap { index in
                try ScheduleCourseEditor.adding(.init(title: "课程", weekday: 1, weeksText: "1"),
                    to: [], term: "term", id: "course-\(index)")
            }
            let exams = (0..<3).map { index in
                ExamRecord(id: "exam-\(index)", term: "term", name: "考试", courseID: "", teacher: "", classroom: "",
                    dateString: "2026-09-07", beginTime: "12:00", endTime: "13:00", examMode: "", seatID: "")
            }
            cache.courseData.store(.init(term: "term", firstDayString: "2026-09-07", courses: courses, exams: exams, updatedAt: .distantPast))
            var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
            var course = try #require(root["courseData"] as? [String: Any])
            var snapshots = try #require(course["schedulesByTerm"] as? [String: Any])
            var snapshot = try #require(snapshots["term"] as? [String: Any])
            var records = try #require(snapshot[collection] as? [Any])
            if defect == "scalar" { records[1] = 7 }
            else {
                var record = try #require(records[1] as? [String: Any])
                if defect == "duplicate" { record["id"] = (records[0] as? [String: Any])?["id"] }
                else { record[collection == "courses" ? "weekday" : "dateString"] = collection == "courses" ? 9 : "damaged" }
                records[1] = record
            }
            snapshot[collection] = records
            snapshots["term"] = snapshot
            course["schedulesByTerm"] = snapshots
            root["courseData"] = course
            if !structured {
                course["termSchedulesByTerm"] = course.removeValue(forKey: "schedulesByTerm")
                course["storedCourseScheduleParserVersion"] = 2
                root = course
            }
            let bytes = try JSONSerialization.data(withJSONObject: root)
            let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "school-record-recovery")
            let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/school-record-recovery"),
                userStateMatches: ScheduleCloudSyncState.matches)
            let url = store.cacheFileURL(for: account.accountStorageIdentifier)
            try files.writeData(bytes, to: url, options: [])
            let recovered = try #require(await store.load(for: account).cacheIfReadable)
            #expect(recovered.courses.map(\.id) == (collection == "courses" ? [courses[0].id, courses[2].id] : courses.map(\.id)))
            #expect(recovered.exams.map(\.id) == (collection == "exams" ? [exams[0].id, exams[2].id] : exams.map(\.id)))
            #expect(files.storedData[url] == bytes)
            #expect(recovered.isValidForPersistence)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["customSchedules", "sharedSchedules", "manualCourseRulesByTerm", "ddlEvents"])
    func damagedRecordsKeepTheirValidNeighborsAndOriginalBytes(structured: Bool, collection: String) async throws {
        for (defect, legacyFile) in [("invalid", false), ("duplicate", false), ("scalar", true)] {
            let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "schedule-record-recovery")
            let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/schedule-record-recovery"),
                userStateMatches: ScheduleCloudSyncState.matches)
            var cache = ScheduleCache()
            for index in 0..<3 {
                cache.customSchedules.append(.init(id: "custom-\(index)", title: "日程", subtitle: "", description: "",
                    dateString: "2026-09-07", beginTime: "12:00", endTime: "13:00"))
                cache.sharedSchedules.append(.init(id: "shared-\(index)", title: "分享课表", payload: .init(
                    currentTerm: "term", firstDayString: "", timeTable: TimeSlot.default, courses: [])))
                cache.ddlEvents.append(.init(id: "ddl-\(index)", group: "custom", title: "待办", text: "",
                    dueAt: .distantFuture, done: false))
                let courses = try ScheduleCourseEditor.adding(.init(title: "课程", weekday: 1, weeksText: "1"),
                    to: [], term: "term", id: "course-\(index)")
                cache.manualCourseRulesByTerm["term", default: []].append(.init(id: "rule-\(index)",
                    sourceIdentity: "local:\(index)", sourceCourses: [], replacementCourses: courses))
            }
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
            let course = try #require(encoded["courseData"] as? [String: Any])
            let ddl = try #require(encoded["ddlData"] as? [String: Any])
            var root = structured ? encoded : course.merging(ddl) { _, new in new }
            let block = collection == "ddlEvents" ? "ddlData" : "courseData"
            var fields = structured ? try #require(root[block] as? [String: Any]) : root
            let raw = collection == "manualCourseRulesByTerm"
                ? (fields[collection] as? [String: Any])?["term"] : fields[collection]
            var records = try #require(raw as? [Any])
            if defect == "scalar" { records[1] = 7 }
            else {
                var record = try #require(records[1] as? [String: Any])
                record["id"] = defect == "duplicate" ? (records[0] as? [String: Any])?["id"] : NSNull()
                records[1] = record
            }
            if collection == "manualCourseRulesByTerm" { fields[collection] = ["term": records] }
            else { fields[collection] = records }
            if structured { root[block] = fields } else { root = fields }
            let bytes = try JSONSerialization.data(withJSONObject: root)
            let url = store.cacheFileURL(for: legacyFile ? account.legacyAccountDirectoryNameForMigration : account.accountStorageIdentifier)
            try files.writeData(bytes, to: url, options: .atomic)
            let result = await store.load(for: account)
            let recovered = try #require(result.cacheIfReadable)
            #expect(recovered.isValidForPersistence)
            #expect(recovered.customSchedules.count == (collection == "customSchedules" ? 2 : 3))
            #expect(recovered.sharedSchedules.count == (collection == "sharedSchedules" ? 2 : 3))
            #expect(recovered.manualCourseRulesByTerm["term"]?.count == (collection == "manualCourseRulesByTerm" ? 2 : 3))
            #expect(recovered.ddlEvents.count == (collection == "ddlEvents" ? 2 : 3))
            #expect(files.storedData[url] == bytes)
            #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: result.isRecovered ? .recovery : .local, expectedUpdatedAt: nil) != nil)
            let reopened = try #require(await store.load(for: account).cacheIfReadable)
            #expect(reopened.customSchedules == recovered.customSchedules && reopened.sharedSchedules == recovered.sharedSchedules)
            #expect(reopened.manualCourseRulesByTerm == recovered.manualCourseRulesByTerm && reopened.ddlEvents == recovered.ddlEvents)
        }
    }
}
