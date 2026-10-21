import BIT101TestSupport
import SchedulePorts
import ClientCore
import Foundation
import ScheduleDomain
import ScheduleContracts
@testable import ScheduleFeature
import SchedulePersistence
@testable import StorageCore
import Testing

@MainActor
struct SchedulePersistenceTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["date", "time", "reverse", "duplicate", "repeat-date", "extra-date", "exam",
        "course-id", "course-duplicate", "rule-id", "shared-id", "ddl-id", "ddl-duplicate", "ddl-title", "ddl-text"])
    func damagedPersonalPlacementsPreserveTheStoredSchedule(kind: String) async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "personal-placement")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/personal-placement"), userStateMatches: { _, _ in true })
        let valid = ScheduleCache(), url = store.cacheFileURL(for: account.accountStorageIdentifier)
        #expect(await store.write(valid, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        let original = try files.readData(at: url)
        var record = CustomScheduleRecord(id: "event", title: "活动", subtitle: "", description: "",
            dateString: "2026-09-07", beginTime: "12:10", endTime: "12:40")
        var damaged = valid
        switch kind {
        case "date": record.dateString = "2026-02-31"
        case "time": record.beginTime = "25:00"
        case "reverse": record.endTime = "12:00"
        case "repeat-date": record.additionalDateStrings = [record.dateString]
        case "extra-date": record.additionalDateStrings = ["bad-date"]
        case "course-id", "course-duplicate", "rule-id", "shared-id":
            let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "课程", weekday: 1, weeksText: "1"),
                to: [], term: "term", id: kind == "course-id" ? "" : "course")
            switch kind {
            case "rule-id":
                let rule = ScheduleCourseRule(id: "rule", sourceIdentity: "local:course", sourceCourses: [], replacementCourses: courses)
                let conflicting = ScheduleCourseRule(id: rule.id, sourceIdentity: "local:other", sourceCourses: [], replacementCourses: courses)
                damaged.manualCourseRulesByTerm = ["term": [rule, conflicting]]
            case "shared-id":
                let shared = SharedScheduleRecord(id: "shared", title: "分享", payload: .init(currentTerm: "term",
                    firstDayString: "2026-09-07", timeTable: damaged.timeTable, courses: courses))
                var conflicting = shared
                conflicting.title = "另一份分享"
                damaged.sharedSchedules = [shared, conflicting]
            default:
                let conflicting = try ScheduleCourseEditor.adding(CourseDraft(title: "另一门课程", weekday: 2, weeksText: "1"),
                    to: [], term: "term", id: "course")
                damaged.courseData.store(.init(term: "term", firstDayString: "2026-09-07",
                    courses: kind == "course-duplicate" ? courses + conflicting : courses, exams: [], updatedAt: .distantPast))
            }
        case "ddl-id", "ddl-duplicate", "ddl-title", "ddl-text":
            let event = DDLEventRecord(id: kind == "ddl-id" ? "" : "ddl", group: "main",
                title: kind == "ddl-title" ? " \n" : "作业",
                text: kind == "ddl-text" ? String(repeating: "x", count: ScheduleCourseConstraints.maximumFieldBytes + 1) : "",
                dueAt: .distantFuture, done: false)
            var conflicting = event
            conflicting.title = "另一份作业"
            damaged.ddlEvents = kind == "ddl-duplicate" ? [event, conflicting] : [event]
        case "exam":
            let exam = ExamRecord(id: "exam", term: "term", name: "考试", courseID: "course", teacher: "", classroom: "",
                dateString: "2026-09-07", beginTime: "12:00", endTime: "11:00", examMode: "", seatID: "")
            damaged.courseData.store(.init(term: "term", firstDayString: "", courses: [], exams: [exam], updatedAt: .distantPast))
        default: break
        }
        var conflicting = record
        conflicting.title = "另一项活动"
        damaged.customSchedules = kind == "duplicate" ? [record, conflicting] : [record]
        #expect(!damaged.isValidForPersistence)
        #expect(await store.write(damaged, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == original)
        let bytes = try JSONEncoder().encode(damaged)
        try files.writeData(bytes, to: url, options: .atomic)
        let reset = try #require(await store.load(for: account).cacheIfReadable)
        #expect(reset.isValidForPersistence)
        var failure: String?
        #expect(SchedulePersistenceStore.decodeCache(bytes, onFailure: { failure = $0 }).isUnreadable)
        let field = kind.hasPrefix("ddl") ? "ddlEvents" : kind == "shared-id" ? "sharedSchedules"
            : kind.hasPrefix("course") || kind == "rule-id" ? "courses" : kind == "exam" ? "exams" : "customSchedules"
        #expect(failure?.contains(field) == true)
        #expect(await store.readFailure(for: account)?.contains(field) == true)
        #expect(await store.readFailure(for: AppStorageSession(accountIdentifier: "other-account")) == nil)
        #expect(try files.readData(at: url) == bytes)
        #expect(await store.write(reset, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        #expect(try files.readData(at: url) != bytes)
    }

    @Test(arguments: ["missing", "type", "date", "path", "size"])
    func cacheReadDiagnosticsIdentifyFieldsAndMaskPersonalKeys(kind: String) throws {
        let secret = "PRIVATE_USER_CONTENT"
        let course = try #require(ScheduleCourseEditor.adding(CourseDraft(title: secret, weekday: 1, weeksText: "1"),
            to: [], term: "term", id: "course").first)
        var cache = ScheduleCache()
        cache.courseData.store(.init(term: "term", firstDayString: "2026-09-07", courses: [course], exams: [], updatedAt: .distantPast))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        let expected: String
        switch kind {
        case "missing": object.removeValue(forKey: "courseData"); expected = "decode.missing:courseData"
        case "type": object["ddlData"] = secret; expected = "decode.type:ddlData"
        case "date": object["updatedAt"] = secret; expected = "decode.invalid:updatedAt"
        case "path":
            var data = try #require(object["courseData"] as? [String: Any])
            let snapshots = try #require(data["schedulesByTerm"] as? [String: Any])
            var snapshot = try #require(snapshots["term"] as? [String: Any])
            var course = try #require((snapshot["courses"] as? [[String: Any]])?.first)
            course["weekday"] = secret
            snapshot["courses"] = [course]
            data["schedulesByTerm"] = [secret: snapshot]
            object["courseData"] = data
            expected = "decode.type:courseData.schedulesByTerm.*.courses.[].weekday"
        default: expected = "decode.sizeLimit"
        }
        let bytes = kind == "size" ? Data(repeating: 0, count: SchedulePersistenceStore.maximumCacheBytes + 1)
            : try JSONSerialization.data(withJSONObject: object)
        var failure: String?
        #expect(SchedulePersistenceStore.decodeCache(bytes, onFailure: { failure = $0 }).isUnreadable)
        #expect(failure == expected)
        #expect(failure?.contains(secret) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func inaccessibleExistencePreservesTheScheduleAndReportsFailedCleanup(protection: Bool) async throws {
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "protected-schedule")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/protected-schedule"),
            userStateMatches: { $0.primaryScheduleTitle == $1.primaryScheduleTitle })
        let cache = ScheduleCache(), url = store.cacheFileURL(for: account.accountStorageIdentifier)
        #expect(await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        let original = try files.readData(at: url)
        files.setFailures(reading: !protection, existence: true, protection: protection)
        #expect(!files.fileExists(at: url))
        #expect(await store.load(for: account).isUnreadable)
        #expect(await store.readFailure(for: account)?.hasPrefix(protection ? "file.protection:" : "file.read:") == true)
        #expect(files.storedData[url] == original)
        #expect(await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        files.setFailures(removal: true, existence: true)
        #expect(await store.clear(urls: [url]) == false)
        #expect(files.storedData[url] == original)
        files.setFailures()
        #expect(await store.load(for: account).cacheIfReadable != nil)
        #expect(await store.readFailure(for: account) == nil)
        #expect(await store.clear(urls: [url]))
        #expect(await store.load(for: account).isUnreadable == false)
    }
    @Test func localFilesRejectNetworkReadAddresses() throws {
        let files = LocalAppFileService()
        let url = try #require(URL(string: "https://example.invalid/probe"))
        #expect(throws: CocoaError.self) { try files.readData(at: url) }
    }
    @Test func localFilesHonorTheSharedAtomicIdentityAndDirectoryContract() throws {
        let files = LocalAppFileService()
        let root = files.temporaryDirectoryURL.appendingPathComponent("BIT101-FileServiceContract", isDirectory: true)
        try verifyFileServiceContract(files, root: root)
    }

    @Test(.timeLimit(.minutes(1))) func backupEligibilityRestoresExistingUserDirectoriesAndPreservesBytes() async throws {
        let support = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let root = support.appendingPathComponent("BIT101Tests-BackupPolicy", isDirectory: true)
        let directory = root.appendingPathComponent("drafts", isDirectory: true)
        let files = LocalAppFileService()
        func exclusion(_ url: URL) throws -> Bool? {
            var fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
            fresh.removeAllCachedResourceValues()
            return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        let inheritedExclusion = try exclusion(support) == true
        try files.removeItemIfPresent(at: root)
        try files.createDirectory(at: directory)
        defer { do { try files.removeItem(at: root) } catch { Issue.record(error) } }
        let file = directory.appendingPathComponent("draft.json")
        let original = Data("user-created-draft".utf8)
        try files.writeData(original, to: file, options: .atomic)
        for excluded in [true, false, true, false] {
            try files.setBackupExcluded(excluded, at: root, recursively: true)
            let expected = excluded || inheritedExclusion
            var observed: [Bool] = []
            do {
                try await waitForTestEvent {
                    observed = try [root, directory, file].map { try exclusion($0) == true }
                    return observed.allSatisfy { $0 == expected }
                }
            } catch {
                Issue.record("备份排除标记期望 \(expected)，父目录标记 \(inheritedExclusion)，根目录、草稿目录及文件实际标记：\(observed)。")
                throw error
            }
            for (target, actual) in zip([root, directory, file], observed) {
                #expect(actual == expected, "备份排除标记 \(expected)，目标 \(target.lastPathComponent)。")
            }
            #expect(try files.readData(at: file) == original)
        }
        try files.writeData(Data("edited".utf8), to: file, options: .atomic)
        var directoryExcluded: Bool? = nil
        try await waitForTestEvent {
            directoryExcluded = try exclusion(directory)
            return (directoryExcluded == true) == inheritedExclusion
        }
        #expect((directoryExcluded == true) == inheritedExclusion)
        #expect(try files.readData(at: file) == Data("edited".utf8))
    }

    @Test func localFileMetadataFailurePreservesCommittedBytesAndReadableFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BIT101-StoragePolicy", isDirectory: true)
        let files = LocalAppFileService(configureBackup: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        try files.removeItemIfPresent(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try files.removeItem(at: directory) } catch { Issue.record(error) } }
        let url = directory.appendingPathComponent("snapshot.json")
        let original = Data("retained".utf8)
        try original.write(to: url, options: .atomic)
        #expect(try files.readData(at: url) == original)
        #expect(throws: CocoaError.self) { try files.writeData(Data("edited".utf8), to: url, options: .atomic) }
        #expect(try files.readData(at: url) == original)
        let fresh = directory.appendingPathComponent("fresh.json")
        #expect(throws: CocoaError.self) { try files.writeData(original, to: fresh, options: .atomic) }
        #expect(files.fileExists(at: fresh) == false)
    }

    private func store(files: ModuleScoreFiles, root: String = "/schedule") -> SchedulePersistenceStore {
        SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: root), userStateMatches: { $0.primaryScheduleTitle == $1.primaryScheduleTitle })
    }

    @Test(.timeLimit(.minutes(1))) func oversizedScheduleFilesPreserveTheStoredBytes() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "oversized")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data(repeating: 32, count: SchedulePersistenceStore.maximumCacheBytes + 1)
        try files.writeData(bytes, to: url, options: [])
        #expect(await persistence.load(for: account).isUnreadable)
        #expect(await persistence.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(files.storedData[url] == bytes)
        #expect(SchedulePersistenceStore.decodeCache(bytes).isUnreadable)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ScheduleCacheSaveSource.local, .localWithoutCloudPush])
    func anEarlierUISnapshotPreservesCloudChangesAndItsUncommittedEdits(source: ScheduleCacheSaveSource) async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "concurrent-cloud-write")
        var initial = ScheduleCache()
        initial.cloudSyncBaselineRecordTag = "original"
        initial.syncData.cloudSyncBaselineUserState = Data("original".utf8)
        _ = await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud, expectedUpdatedAt: nil)
        let repository = ScheduleRepository(session: { account }, load: { await persistence.load(for: $0) },
            save: { cache, source, owner in
                guard await persistence.write(cache, accountIdentifier: owner.accountStorageIdentifier,
                    legacyAccountIdentifier: owner.legacyAccountDirectoryNameForMigration, source: source, expectedUpdatedAt: nil) != nil
                else { throw CocoaError(.fileWriteUnknown) }
            })
        await repository.loadIfNeeded()
        var remote = initial
        remote.primaryScheduleTitle = "云端新增"
        remote.cloudSyncBaselineRecordTag = "remote"
        remote.syncData.cloudSyncBaselineUserState = Data("remote".utf8)
        _ = await persistence.write(remote, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud, expectedUpdatedAt: nil)
        var local = repository.courseState
        local.primaryScheduleTitle = "本机修改"
        repository.courseState = local
        #expect(await repository.persistAndWait(source: source) == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "本机修改")
        #expect(repository.hasPersistenceConflict)
        let saved = await persistence.load(for: account).cacheIfReadable
        #expect(saved?.primaryScheduleTitle == "云端新增" && saved?.cloudSyncBaselineRecordTag == "remote")
    }

    @Test(.timeLimit(.minutes(1))) func independentStoresOwnTheirPathsAndAccounts() async throws {
        let files = ModuleScoreFiles()
        let first = store(files: files, root: "/first")
        let second = store(files: files, root: "/second")
        let account = AppStorageSession(accountIdentifier: "account")
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "first"
        let saved = await first.write(cache, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil)
        #expect(saved?.primaryScheduleTitle == "first")
        #expect(await first.load(for: account).cacheIfReadable?.primaryScheduleTitle == "first")
        #expect(await second.load(for: account).cacheIfReadable?.primaryScheduleTitle == "课表")
        #expect(await first.load(for: AppStorageSession(accountIdentifier: "other")).cacheIfReadable?.primaryScheduleTitle == "课表")
    }

    @Test(.timeLimit(.minutes(1))) func preciseDiskVersionsRoundTripAndRejectAnEarlierCompareToken() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "precise-versions")
        var initial = ScheduleCache()
        initial.updatedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = try #require(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil))
        #expect(await persistence.load(for: account).cacheIfReadable?.updatedAt == first.updatedAt)
        var edit = first
        edit.primaryScheduleTitle = "second"
        let second = try #require(await persistence.write(edit, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: first.updatedAt))
        #expect(second.updatedAt > first.updatedAt)
        #expect(await persistence.load(for: account).cacheIfReadable?.updatedAt == second.updatedAt)
        #expect(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud, expectedUpdatedAt: first.updatedAt) == nil)
        #expect(await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle == "second")
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        #expect(SchedulePersistenceStore.decodeCache(try legacyEncoder.encode(initial)).cacheIfReadable?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test(.timeLimit(.minutes(1))) func malformedAggregateSectionsResetAndKeepStorageAvailable() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "malformed-sections")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        for key in ["courses", "cachedCoursesByTerm", "ddlEvents", "customSchedules", "selectedClassroomSectionIDs", "timeTable"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["primaryScheduleTitle": "retained", key: "malformed"])
            try files.writeData(bytes, to: url, options: [])
            #expect(await persistence.load(for: account).cacheIfReadable?.isValidForPersistence == true)
            #expect(await persistence.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
            #expect(try files.readData(at: url) != bytes)
        }
    }

    @Test(.timeLimit(.minutes(1))) func repeatedTimeTableIDsResetBothDiskFormats() async throws {
        let files = ModuleScoreFiles()
        let account = AppStorageSession(accountIdentifier: "repeated-sections")
        let repository = store(files: files)
        let url = repository.cacheFileURL(for: account.accountStorageIdentifier)
        var cache = ScheduleCache()
        cache.timeTable = [TimeSlot(id: 1, start: "08:00", end: "08:45"), TimeSlot(id: 1, start: "09:00", end: "09:45")]
        let legacy = try JSONSerialization.data(withJSONObject: ["timeTable": [
            ["id": 1, "start": "08:00", "end": "08:45"], ["id": 1, "start": "09:00", "end": "09:45"]]])
        for bytes in [try JSONEncoder().encode(cache), legacy] {
            #expect(SchedulePersistenceStore.decodeCache(bytes).isUnreadable)
            try files.writeData(bytes, to: url, options: [])
            #expect(await repository.load(for: account).cacheIfReadable?.timeTable == TimeSlot.default)
            #expect(await repository.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
            #expect(try files.readData(at: url) != bytes)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["time-table", "shared-time-table", "term-course", "archived-course", "shared-course", "source-rule", "replacement-rule"])
    func invalidNewSnapshotsPreserveTheCommittedFileOrMissingState(boundary: String) async throws {
        let invalidCourse = CourseRecord(id: "invalid", term: "term", name: "课程", teacher: "", classroom: "",
            description: "", weeks: [0], weekday: 1, startSection: 1, endSection: 2, campus: "", number: "",
            credit: 0, hour: 0, type: "", category: "", department: "")
        let repeatedSlots = [TimeSlot(id: 1, start: "08:00", end: "08:45"), TimeSlot(id: 1, start: "09:00", end: "09:45")]
        var invalid = ScheduleCache()
        switch boundary {
        case "time-table": invalid.timeTable = repeatedSlots
        case "shared-time-table", "shared-course":
            invalid.sharedSchedules = [SharedScheduleRecord(title: "共享", payload: ScheduleExportPayload(
                currentTerm: "term", firstDayString: "", timeTable: boundary == "shared-time-table" ? repeatedSlots : TimeSlot.default,
                courses: boundary == "shared-course" ? [invalidCourse] : []))]
        case "term-course", "archived-course":
            invalid.courseData.schedulesByTerm["term"] = TermScheduleSnapshot(term: "term", firstDayString: "",
                courses: [invalidCourse], exams: [], updatedAt: .distantPast)
            if boundary == "archived-course" { invalid.courseData.archivedTerms = ["term"] }
        default:
            invalid.manualCourseRulesByTerm["term"] = [ScheduleCourseRule(sourceIdentity: "source",
                sourceCourses: boundary == "source-rule" ? [invalidCourse] : [],
                replacementCourses: boundary == "replacement-rule" ? [invalidCourse] : [])]
        }
        #expect(SchedulePersistenceStore.decodeCache(try JSONEncoder().encode(invalid)).isUnreadable)
        for hasCommittedFile in [false, true] {
            let files = ModuleScoreFiles()
            let persistence = store(files: files)
            let account = AppStorageSession(accountIdentifier: "invalid-new-snapshot")
            let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
            var valid = ScheduleCache()
            valid.primaryScheduleTitle = "已保存课表"
            if hasCommittedFile {
                #expect(await persistence.write(valid, accountIdentifier: account.accountStorageIdentifier,
                    legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
            }
            let committedBytes = files.storedData[url]
            #expect(await persistence.write(invalid, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
            #expect(files.storedData[url] == committedBytes)
            let restored = await persistence.load(for: account)
            if hasCommittedFile { #expect(restored.cacheIfReadable?.primaryScheduleTitle == valid.primaryScheduleTitle) }
            else {
                if case .missing = restored {} else { Issue.record("无效初次写入应保留缺失状态") }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["corrupt-source", "{}", #"{"unrelated":1}"#, #"{"courseData":{},"updatedAt":0}"#])
    func corruptedSourceResetsAndKeepsStorageAvailable(source: String) async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "corrupt")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data(source.utf8)
        try files.writeData(bytes, to: url, options: [])
        #expect(await persistence.load(for: account).cacheIfReadable?.isValidForPersistence == true)
        #expect(await persistence.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        #expect(try files.readData(at: url) != bytes)
    }

    @Test(.timeLimit(.minutes(1))) func failedWritesReturnFailureAndPreserveTheStoredVersion() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "write-failure")
        let initial = ScheduleCache()
        #expect(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        files.setFailures(writing: true)
        var update = initial
        update.primaryScheduleTitle = "edited"
        #expect(await persistence.write(update, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle == initial.primaryScheduleTitle)
    }

    @Test(.timeLimit(.minutes(1))) func repositoryReportsSaveFailureAndPreservesEdits() async {
        let account = AppStorageSession(accountIdentifier: "repository")
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "edited"
        #expect(await repository.persistAndWait() == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "edited")
        #expect(repository.notice?.title == "日程保存失败")
    }

    @Test(.timeLimit(.minutes(1))) func ddlSuccessWaitsForPersistence() async {
        let account = AppStorageSession(accountIdentifier: "ddl")
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        await repository.loadIfNeeded()
        let viewModel = ScheduleDDLViewModel(service: DDLService(), repository: repository)
        #expect(await viewModel.syncDDL() == false)
        #expect(viewModel.notice == nil)
        #expect(repository.notice?.title == "日程保存失败")
    }

    private final class DelayedWriter {
        var stored: ScheduleCache?
        var writes: [(String, AppStorageSession)] = []
        var failsFirstWrite = false
        private var completion: CheckedContinuation<Void, Never>?

        func save(_ cache: ScheduleCache, session: AppStorageSession) async throws {
            writes.append((cache.primaryScheduleTitle, session))
            if writes.count == 1 {
                await withCheckedContinuation { completion = $0 }
                if failsFirstWrite { throw CocoaError(.fileWriteNoPermission) }
            }
            stored = cache
            stored?.updatedAt = Date(timeIntervalSince1970: Double(writes.count))
        }

        func waitUntilStarted() async throws {
            try await waitForTestEvent { completion != nil }
        }

        func finishFirstWrite() { completion?.resume(); completion = nil }
    }

    private func repository(writer: DelayedWriter, session: @escaping () -> AppStorageSession) -> ScheduleRepository {
        ScheduleRepository(session: session, load: { _ in writer.stored.map(ScheduleCacheLoadResult.loaded) ?? .missing }, save: { cache, _, session in try await writer.save(cache, session: session) })
    }

    @Test(.timeLimit(.minutes(1))) func queuedWritesPreserveOrderAndReloadTheCommittedVersion() async throws {
        let account = AppStorageSession(accountIdentifier: "queued")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "first"
        repository.persist()
        try await writer.waitUntilStarted()
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "second"
        repository.persist()
        writer.finishFirstWrite()
        #expect(await repository.persistAndWait())
        #expect(writer.writes.map(\.0) == ["first", "second", "second"])
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "second")
        #expect(repository.persistenceSnapshot.updatedAt == Date(timeIntervalSince1970: 3))
    }

    @Test(.timeLimit(.minutes(1))) func editsMadeDuringSavingRemainInMemory() async throws {
        let account = AppStorageSession(accountIdentifier: "editing")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "saved"
        let saving = Task { await repository.persistAndWait() }
        try await writer.waitUntilStarted()
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "editing"
        writer.finishFirstWrite()
        #expect(await saving.value)
        #expect(writer.stored?.primaryScheduleTitle == "saved")
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "editing")
    }

    @Test(.timeLimit(.minutes(1))) func cancelledWaiterKeepsCommittedDataAndReturnsCancellationOutcome() async throws {
        let account = AppStorageSession(accountIdentifier: "cancelled-waiter")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "committed-edit"
        let saving = Task { await repository.persistAndWait() }
        try await writer.waitUntilStarted()
        saving.cancel()
        writer.finishFirstWrite()
        #expect(await saving.value == false)
        #expect(writer.stored?.primaryScheduleTitle == "committed-edit")
        #expect(repository.notice == nil)
    }

    @Test(.timeLimit(.minutes(1))) func oldAccountFailuresAndQueuedWritesStayWithTheirOwner() async throws {
        var account = AppStorageSession(accountIdentifier: "old")
        let writer = DelayedWriter()
        writer.failsFirstWrite = true
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "old-edit"
        let saving = Task { await repository.persistAndWait() }
        try await writer.waitUntilStarted()
        repository.persist()
        account = AppStorageSession(accountIdentifier: "current")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "current-edit"
        writer.finishFirstWrite()
        #expect(await saving.value == false)
        #expect(await repository.persistAndWait())
        #expect(writer.writes.map(\.0) == ["old-edit", "current-edit"])
        #expect(writer.writes.last?.1 == account)
        #expect(repository.notice == nil)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "current-edit")
    }

    private struct DDLService: ScheduleDDLServicing {
        func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload {
            DDLSyncPayload(url: "https://example.invalid/calendar", events: [])
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "https://example.invalid/calendar" }
    }
}

@MainActor
struct SchedulePersistenceCoordinatorTests {
    @Test(.timeLimit(.minutes(1))) func queuedSavesValidateTheGenerationAcrossAccountRoundTrips() async throws {
        let coordinator = SchedulePersistenceCoordinator()
        var generation = 1
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let first = Task { await coordinator.perform(isCurrent: { true }) {
            started = true
            await withCheckedContinuation { release = $0 }
            writes.append(1)
            return true
        } }
        try await waitForTestEvent { !(!started) }
        let oldGeneration = generation
        let queued = Task { await coordinator.perform(isCurrent: { generation == oldGeneration }) {
            writes.append(2)
            return true
        } }
        await Task.yield()
        generation = 3
        release?.resume()
        #expect(await first.value)
        #expect(await queued.value == false)
        #expect(writes == [1])
        #expect(await coordinator.perform(isCurrent: { generation == 3 }) {
            writes.append(3)
            return true
        })
        #expect(writes == [1, 3])
    }

    @Test(.timeLimit(.minutes(1))) func cancellationRetainsTheCommittedWriteAndSkipsQueuedWork() async throws {
        let coordinator = SchedulePersistenceCoordinator()
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let saving = Task { await coordinator.perform(isCurrent: { true }) {
            started = true
            await withCheckedContinuation { release = $0 }
            writes.append(1)
            return true
        } }
        try await waitForTestEvent { !(!started) }
        let queued = Task { await coordinator.perform(isCurrent: { true }) {
            writes.append(2)
            return true
        } }
        await Task.yield()
        queued.cancel()
        saving.cancel()
        release?.resume()
        #expect(await saving.value == false)
        #expect(await queued.value == false)
        #expect(writes == [1])
        #expect(await coordinator.perform(isCurrent: { true }) { writes.append(3); return true })
        #expect(writes == [1, 3])
    }
}

@MainActor
struct ScheduleSchemaAndEditingTests {
    @Test(arguments: ["startSection", "endSection", "weekday", "weeks"])
    func invalidPlacementKeepsEveryPersistentCourseSourceUnreadable(field: String) throws {
        let valid = try course()
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        switch field {
        case "startSection": record[field] = Int.min
        case "endSection": record[field] = Int.max
        case "weekday": record[field] = 8
        default: record[field] = [0]
        }
        let bytes = try JSONSerialization.data(withJSONObject: record)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CourseRecord.self, from: bytes) }
        var cache = ScheduleCache()
        cache.courseData.schedulesByTerm[valid.term] = snapshot([valid])
        cache.courseData.manualCourseRulesByTerm[valid.term] = [.init(sourceIdentity: "", sourceCourses: [], replacementCourses: [valid])]
        cache.sharedSchedules = [.init(title: "分享", payload: .init(currentTerm: valid.term, firstDayString: "", timeTable: TimeSlot.default, courses: [valid]))]
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        func corruptCourses(_ value: Any) -> Any {
            if let values = value as? [String: Any] {
                if values["startSection"] != nil { return record }
                return values.mapValues(corruptCourses)
            }
            if let values = value as? [Any] { return values.map(corruptCourses) }
            return value
        }
        #expect(SchedulePersistenceStore.decodeCache(try JSONSerialization.data(withJSONObject: corruptCourses(object))).isUnreadable)
    }
    @Test(arguments: [Int.min, -1, 0, 1, 20, 60, 61, Int.max])
    func presentationLeadMinutesStayBoundedThroughMutationAndDiskDecode(value: Int) throws {
        let expected = value < 1 ? 1 : value > 60 ? 60 : value
        var cache = ScheduleCache()
        cache.presentation.courseLiveActivityLeadMinutes = value
        #expect(cache.presentation.courseLiveActivityLeadMinutes == expected)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        var presentation = try #require(object["presentation"] as? [String: Any])
        presentation["courseLiveActivityLeadMinutes"] = value
        object["presentation"] = presentation
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.presentation.courseLiveActivityLeadMinutes == expected)
        #expect(try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(restored)).courseLiveActivityLeadMinutes == expected)
    }

    private func course(id: String = "school", weekday: Int = 1, weeks: String = "1-4") throws -> CourseRecord {
        try #require(ScheduleCourseEditor.adding(
            CourseDraft(title: "课程", classroom: "文萃楼I203", weekday: weekday,
                startSection: 1, endSection: 2, weeksText: weeks),
            to: [], term: "2026-2027-1", id: id
        ).first)
    }

    private func snapshot(_ courses: [CourseRecord], term: String = "2026-2027-1") -> TermScheduleSnapshot {
        TermScheduleSnapshot(term: term, firstDayString: "2026-09-07", courses: courses,
            exams: [], updatedAt: Date(timeIntervalSince1970: 100))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func repeatedLegacyRecordsRecoverWithoutLosingUserData(legacy: Bool) async throws {
        let original = try course()
        let other = try #require(ScheduleCourseEditor.adding(CourseDraft(title: "其他课程", weekday: 2, weeksText: "1-4"),
            to: [], term: original.term, id: "other").first)
        let replacement = try course(id: "adjusted", weekday: 3)
        let rule = ScheduleCourseRule(id: "rule", sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original], replacementCourses: [replacement])
        let custom = CustomScheduleRecord(id: "custom", title: "个人安排", subtitle: "地点", description: "备注",
            dateString: "2026-09-08", beginTime: "12:10", endTime: "12:40")
        let ddl = DDLEventRecord(id: "ddl", group: "main", title: "作业", text: "个人备注", dueAt: .distantFuture, done: true)
        let shared = SharedScheduleRecord(id: "shared", title: "分享课表", importedAt: Date(timeIntervalSince1970: 200),
            payload: .init(exportedAt: Date(timeIntervalSince1970: 150), currentTerm: original.term,
                firstDayString: "2026-09-07", timeTable: TimeSlot.default, courses: [original, other]))
        var expected = ScheduleCache()
        expected.currentTerm = original.term
        expected.courseData.schedulesByTerm[original.term] = snapshot([original, other])
        expected.manualCourseRulesByTerm = [original.term: [rule]]
        expected.customSchedules = [custom]
        expected.ddlEvents = [ddl]
        expected.lexueDDLCompletionByID = ["lexue": true]
        expected.sharedSchedules = [shared]
        expected.cloudSyncBaselineAt = Date(timeIntervalSince1970: 80)
        expected.cloudSyncBaselineRecordTag = "baseline"
        if !legacy { expected.syncData.cloudSyncBaselineUserState = Data("baseline state".utf8) }
        expected.updatedAt = Date(timeIntervalSince1970: 300)
        var old = expected
        old.courseData.schedulesByTerm[original.term] = snapshot([original, other, original])
        let repeatedRule = ScheduleCourseRule(id: rule.id, sourceIdentity: rule.sourceIdentity,
            sourceCourses: [original, original], replacementCourses: [replacement, replacement])
        old.manualCourseRulesByTerm = [original.term: [repeatedRule, repeatedRule]]
        old.customSchedules = [custom, custom]
        old.ddlEvents = [ddl, ddl]
        let repeatedShared = SharedScheduleRecord(id: shared.id, title: shared.title, importedAt: shared.importedAt,
            payload: .init(exportedAt: shared.sharedAt, currentTerm: shared.currentTerm,
                firstDayString: shared.firstDayString, timeTable: shared.timeTable, courses: [original, other, original]))
        old.sharedSchedules = [repeatedShared, repeatedShared]
        let encoder = JSONEncoder()
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        if legacy {
            var flat: [String: Any] = ["storedCourseScheduleParserVersion": 2, "updatedAt": try #require(object["updatedAt"])]
            for key in ["courseData", "ddlData", "classroomData", "presentation", "syncData"] {
                flat.merge(try #require(object[key] as? [String: Any])) { _, value in value }
            }
            flat["termSchedulesByTerm"] = flat.removeValue(forKey: "schedulesByTerm")
            object = flat
        }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "duplicate-migration")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/duplicate-migration"),
            userStateMatches: { _, _ in true })
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        #expect(await store.write(old, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        try files.writeData(bytes, to: url, options: .atomic)
        let restored = try #require(await store.load(for: account).cacheIfReadable)
        #expect(restored.courseData == expected.courseData)
        #expect(restored.ddlData == expected.ddlData)
        #expect(restored.syncData == expected.syncData)
        #expect(restored.updatedAt == expected.updatedAt)
        #expect(restored.courses == [other, replacement])
        #expect(try files.readData(at: url) == bytes)
        var edited = restored
        edited.primaryScheduleTitle = "恢复后编辑"
        let saved = try #require(await store.write(edited, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
            source: .local, expectedUpdatedAt: restored.updatedAt))
        let reopened = try #require(await store.load(for: account).cacheIfReadable)
        #expect(reopened.courseData == saved.courseData)
        #expect(reopened.ddlData == expected.ddlData)
        #expect(reopened.syncData == expected.syncData)
    }

    @Test func versionedDiskUsesOneSchoolAuthorityAndDerivedPresentation() throws {
        let original = try course()
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(snapshot([original]))
        let edited = try ScheduleCourseEditor.updatingOccurrence(id: original.id, week: 2,
            with: CourseDraft(title: "调课", weekday: 3, startSection: 3, endSection: 4), in: cache.courses,
            adjustedID: "adjusted")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: edited)
        let bytes = try JSONEncoder().encode(cache)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ScheduleCache.schemaVersion)
        for key in ["courses", "cachedCoursesByTerm", "schoolCoursesByTerm", "termSchedulesByTerm", "firstDayString", "exams"] {
            #expect(object[key] == nil)
        }
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(restored.courses == edited)
        #expect(restored.courseData.schoolCourses(for: original.term) == [original])
        #expect(restored.coursesUpdatedAt == Date(timeIntervalSince1970: 100))
        #expect(restored.termSchedulesByTerm[original.term]?.courses == [original])
    }

    @Test func flatMigrationChoosesSchoolBaselineAndPreservesOtherSections() throws {
        let original = try course()
        let obsolete = try course(id: "obsolete", weekday: 4)
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        let object: [String: Any] = [
            "storedCourseScheduleParserVersion": 2, "currentTerm": original.term,
            "firstDayString": "2026-09-07", "courses": try json([obsolete]),
            "cachedCoursesByTerm": try json([original.term: [obsolete]]),
            "schoolCoursesByTerm": try json([original.term: [original]]),
            "termSchedulesByTerm": try json([original.term: snapshot([obsolete])]),
            "primaryScheduleTitle": "  标题  ", "ddlBeforeDay": 12, "selectedBuildingID": "building",
            "courseLiveActivityLeadMinutes": 100, "cloudSyncBaselineRecordTag": "tag"
        ]
        let cache = try JSONDecoder().decode(ScheduleCache.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(cache.courses == [original])
        #expect(cache.cachedCoursesByTerm[original.term] == [original])
        #expect(cache.termSchedulesByTerm[original.term]?.courses == [original])
        #expect(cache.primaryScheduleTitle == "标题")
        #expect(cache.ddlData.ddlBeforeDay == 12)
        #expect(cache.classroomData.selectedBuildingID == "building")
        #expect(cache.presentation.courseLiveActivityLeadMinutes == 60)
        #expect(cache.syncData.cloudSyncBaselineRecordTag == "tag")
        let roundTrip = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(roundTrip.courseData == cache.courseData)
    }

    @Test func historicalCourseSummariesMigrateAndArchiveWithoutLosingGradeMatching() throws {
        let original = try course()
        let encoder = JSONEncoder()
        let map = try JSONSerialization.jsonObject(with: encoder.encode(["past": [original]]))
        let bytes = try JSONSerialization.data(withJSONObject: ["cachedCoursesByTerm": map])
        var cache = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(cache.courseData.archivedTerms == ["past"])
        #expect(cache.cachedCoursesByTerm["past"] == [original])
        #expect(cache.termSchedulesByTerm.isEmpty)
        cache.courseData.store(snapshot([original]))
        cache.currentTerm = original.term
        cache.courseData.archive(term: original.term)
        #expect(cache.courses.isEmpty)
        #expect(cache.firstDayString.isEmpty)
        #expect(cache.coursesUpdatedAt == .distantPast)
        #expect(cache.cachedCoursesByTerm[original.term] == [original])
        cache.courseData.store(snapshot([original]))
        #expect(cache.courses == [original])
        #expect(cache.firstDayString == "2026-09-07")
    }

    @Test func datesMigrateForEmptySchedulesAndOverridesStayTermScoped() throws {
        let bytes = Data(#"{"currentTerm":"2026-2027-1","firstDayString":"2026-09-07"}"#.utf8)
        var cache = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(cache.firstDayString == "2026-09-07")
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2026-09-28"
        cache.currentTerm = "second"
        #expect(cache.firstDayString.isEmpty)
        cache.currentTerm = "2026-2027-1"
        #expect(cache.firstDayString == "2026-09-28")
        cache.manualFirstDayStringsByTerm.removeValue(forKey: cache.currentTerm)
        #expect(cache.firstDayString == "2026-09-07")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["99", "null", #""future""#, "true", "1.5"])
    func unsupportedSchemasPreserveTheStoredFile(header: String) async throws {
        let files = ModuleScoreFiles()
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/schedule"), userStateMatches: { _, _ in true })
        let account = AppStorageSession(accountIdentifier: "schema-owner")
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data("{\"schemaVersion\":\(header),\"currentTerm\":\"retained\"}".utf8)
        try files.writeData(bytes, to: url, options: [])
        #expect(await store.load(for: account).isUnreadable)
        #expect(await store.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test func pendingCloudCourseRulesSurviveUntilTheSchoolSnapshotArrives() throws {
        let original = try course()
        let replacement = try ScheduleCourseEditor.updatingArrangement(id: original.id,
            with: CourseDraft(title: "云端调课", weekday: 3, weeksText: "1-4"), in: [original])
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.setRules([ScheduleCourseRule(sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original], replacementCourses: replacement)], for: original.term)
        var restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.manualCourseRulesByTerm[original.term]?.count == 1)
        #expect(restored.courses.isEmpty)
        restored.courseData.store(snapshot([original]))
        #expect(restored.courses == replacement)
        #expect(restored.manualCourseRulesByTerm[original.term]?.count == 1)
        restored.courseData.store(snapshot([]))
        #expect(restored.manualCourseRulesByTerm[original.term] == nil)
        #expect(restored.courses.isEmpty)
    }

    @Test(arguments: ["structured", "legacy"])
    func cloudAdjustmentSurvivesAnOlderSchoolSnapshotAndDiskRecovery(format: String) throws {
        let old = try course(weekday: 1)
        let incoming = try course(weekday: 2)
        let replacement = try ScheduleCourseEditor.updatingArrangement(id: incoming.id,
            with: CourseDraft(title: "云端调课", weekday: 3, weeksText: "1-4"), in: [incoming])
        let rule = ScheduleCourseRule(sourceIdentity: scheduleCourseSourceIdentity(incoming),
            sourceCourses: [incoming], replacementCourses: replacement)
        var cache = ScheduleCache()
        cache.currentTerm = old.term
        cache.courseData.store(snapshot([old]))
        cache.courseData.setRules([rule], for: old.term)
        let bytes: Data
        if format == "legacy" {
            let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot([old])))
            let ruleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([rule]))
            bytes = try JSONSerialization.data(withJSONObject: ["currentTerm": old.term,
                "termSchedulesByTerm": [old.term: snapshotJSON], "manualCourseRulesByTerm": [old.term: ruleJSON]])
        } else {
            bytes = try JSONEncoder().encode(cache)
        }
        var restored = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(restored.manualCourseRulesByTerm[old.term] == [rule])
        #expect(restored.courses == [old])
        restored.ddlBeforeDay += 1
        restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(restored))
        #expect(restored.manualCourseRulesByTerm[old.term] == [rule])
        restored.courseData.store(snapshot([incoming]))
        #expect(restored.manualCourseRulesByTerm[old.term] == [rule] && restored.courses == replacement)
    }

    @Test func changedSchoolSourceRetiresAdjustmentAndKeepsLocalAddition() throws {
        let original = try course()
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(snapshot([original]))
        let moved = try ScheduleCourseEditor.updatingArrangement(id: original.id,
            with: CourseDraft(title: "修改课程", weekday: 2, weeksText: "1-4"), in: cache.courses)
        let withAddition = try ScheduleCourseEditor.adding(CourseDraft(title: "个人课程", weekday: 4, weeksText: "1"),
            to: moved, term: original.term, id: "local")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: withAddition)
        #expect(cache.manualCourseRulesByTerm[original.term]?.count == 2)
        let refreshed = try course(weekday: 5)
        cache.courseData.store(snapshot([refreshed]))
        #expect(cache.courses.map(\.id) == ["school", "local"])
        #expect(cache.courses.first?.weekday == 5)
        #expect(cache.manualCourseRulesByTerm[original.term]?.count == 1)
    }

    @Test func transferringAndDeletingOccurrencesPreserveTheOriginalSchoolSnapshot() throws {
        let original = try course()
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(snapshot([original]))
        let transferred = try ScheduleCourseEditor.transferring(courses: cache.courses,
            fromWeek: 2, fromWeekday: 1, toWeek: 3, toWeekday: 4, makeID: { "moved" })
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: transferred)
        #expect(cache.courses.first?.weeks == [1, 3, 4])
        #expect(cache.courses.last?.weeks == [3])
        #expect(cache.courses.last?.weekday == 4)
        let deleted = ScheduleCourseEditor.deletingOccurrence(id: "moved", week: 3, from: cache.courses)
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: deleted)
        #expect(cache.courses.count == 1)
        #expect(cache.courseData.schoolCourses(for: original.term) == [original])
        #expect(try ScheduleCourseEditor.transferring(courses: deleted, fromWeek: 1, fromWeekday: 1, toWeek: 1, toWeekday: 1) == deleted)
        #expect(ScheduleCourseEditor.deletingOccurrence(id: "missing", week: 1, from: deleted) == deleted)
    }

    @Test func editingValidationAndConflictBoundaries() throws {
        let resolved = try ScheduleCourseEditor.resolve(CourseDraft(title: "  标题  ", buildingName: "文萃楼", roomNumber: "I203",
            weeksText: "-2--1,1-3,3", selectedSections: [3, 2, 2, 1]))
        #expect(resolved.title == "标题")
        #expect(resolved.classroom == "文萃楼 I203")
        #expect(resolved.weeks == [-2, -1, 1, 2, 3])
        #expect(resolved.startSection == 1)
        #expect(resolved.endSection == 3)
        for draft in [CourseDraft(title: " ", weeksText: "1"), CourseDraft(title: "课程", weekday: 8, weeksText: "1"),
            CourseDraft(title: "课程", weeksText: "1", selectedSections: [1, 3])] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.resolve(draft) }
        }
        for weeks in ["", "0", "3-1", "a", "1-0"] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks(weeks) }
        }
        #expect(ScheduleCourseConstraints.validWeeks == Array(-53 ... -1) + Array(1 ... 53))
        let original = try course()
        let overlap = try course(id: "overlap")
        #expect(ScheduleCourseEditor.conflictDescription(candidates: [original], against: [overlap])?.contains("发生冲突") == true)
        #expect(ScheduleCourseEditor.conflictDescription(candidates: [original], against: [try course(id: "other", weekday: 2)]) == nil)
        #expect(ScheduleCourseEditor.deleting(id: original.id, from: [original]).isEmpty)
    }

    @Test(arguments: [0, 54, 105, -54])
    func outOfRangeTransfersPreserveSourceCourses(week: Int) throws {
        let original = try course()
        var generatedIDs = 0
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.transferring(courses: [original], fromWeek: 1, fromWeekday: 1,
                toWeek: week, toWeekday: 4, makeID: { generatedIDs += 1; return "moved" })
        }
        #expect(generatedIDs == 0)
        for boundary in [-53, 53] {
            let moved = try ScheduleCourseEditor.transferring(courses: [original], fromWeek: 1, fromWeekday: 1,
                toWeek: boundary, toWeekday: 4, makeID: { "moved" })
            #expect(moved.last?.weeks == [boundary])
        }
    }
}
