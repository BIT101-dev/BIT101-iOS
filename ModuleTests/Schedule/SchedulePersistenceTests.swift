import BIT101TestSupport
import ClientCore
import Foundation
import ScheduleContracts
import ScheduleDomain
import SchedulePersistence
import SchedulePorts
import Testing

@testable import ScheduleFeature
@testable import StorageCore

@MainActor
struct SchedulePersistenceTests {
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "date", "time", "reverse", "duplicate", "repeat-date", "extra-date", "exam",
            "course-id", "course-duplicate", "rule-id", "shared-id", "ddl-id", "ddl-duplicate",
            "ddl-title", "ddl-text",
        ])
    func damagedPersonalPlacementsPreserveSchedule(kind: String) async throws {
        let files = ModuleScoreFiles()
        let account = AppStorageSession(accountIdentifier: "personal-placement")
        let store = SchedulePersistenceStore(
            files: files, storageRoot: URL(fileURLWithPath: "/personal-placement"),
            userStateMatches: { _, _ in true })
        let valid = ScheduleCache()
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        #expect(
            await store.write(
                valid, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) != nil)
        let original = try files.readData(at: url)
        var record = CustomScheduleRecord(
            id: "event", title: "活动", subtitle: "", description: "",
            dateString: "2026-09-07", beginTime: "12:10", endTime: "12:40")
        var damaged = valid
        switch kind {
        case "date": record.dateString = "2026-02-31"
        case "time": record.beginTime = "25:00"
        case "reverse": record.endTime = "12:00"
        case "repeat-date": record.additionalDateStrings = [record.dateString]
        case "extra-date": record.additionalDateStrings = ["bad-date"]
        case "course-id", "course-duplicate", "rule-id", "shared-id":
            let courses = try ScheduleCourseEditor.adding(
                CourseDraft(title: "课程", weekday: 1, weeksText: "1"),
                to: [], term: "term", id: kind == "course-id" ? "" : "course")
            switch kind {
            case "rule-id":
                let rule = ScheduleCourseRule(
                    id: "rule", sourceIdentity: "local:course", sourceCourses: [],
                    replacementCourses: courses)
                let conflicting = ScheduleCourseRule(
                    id: rule.id, sourceIdentity: "local:other", sourceCourses: [],
                    replacementCourses: courses)
                damaged.manualCourseRulesByTerm = ["term": [rule, conflicting]]
            case "shared-id":
                let shared = SharedScheduleRecord(
                    id: "shared", title: "分享",
                    payload: .init(
                        currentTerm: "term",
                        firstDayString: "2026-09-07", timeTable: damaged.timeTable, courses: courses
                    ))
                var conflicting = shared
                conflicting.title = "另一份分享"
                damaged.sharedSchedules = [shared, conflicting]
            default:
                let conflicting = try ScheduleCourseEditor.adding(
                    CourseDraft(title: "另一门课程", weekday: 2, weeksText: "1"),
                    to: [], term: "term", id: "course")
                damaged.courseData.store(
                    .init(
                        term: "term", firstDayString: "2026-09-07",
                        courses: kind == "course-duplicate" ? courses + conflicting : courses,
                        exams: [], updatedAt: .distantPast))
            }
        case "ddl-id", "ddl-duplicate", "ddl-title", "ddl-text":
            let event = DDLEventRecord(
                id: kind == "ddl-id" ? "" : "ddl", group: "main",
                title: kind == "ddl-title" ? " \n" : "作业",
                text: kind == "ddl-text"
                    ? String(repeating: "x", count: ScheduleCourseConstraints.maximumFieldBytes + 1)
                    : "",
                dueAt: .distantFuture, done: false)
            var conflicting = event
            conflicting.title = "另一份作业"
            damaged.ddlEvents = kind == "ddl-duplicate" ? [event, conflicting] : [event]
        case "exam":
            let exam = ExamRecord(
                id: "exam", term: "term", name: "考试", courseID: "course", teacher: "",
                classroom: "",
                dateString: "2026-09-07", beginTime: "12:00", endTime: "11:00", examMode: "",
                seatID: "")
            damaged.courseData.store(
                .init(
                    term: "term", firstDayString: "", courses: [], exams: [exam],
                    updatedAt: .distantPast))
        default: break
        }
        var conflicting = record
        conflicting.title = "另一项活动"
        damaged.customSchedules = kind == "duplicate" ? [record, conflicting] : [record]
        #expect(!damaged.isValidForPersistence)
        #expect(
            await store.write(
                damaged, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == original)
        let bytes = try JSONEncoder().encode(damaged)
        try files.writeData(bytes, to: url, options: .atomic)
        let reset = try #require(await store.load(for: account).cacheIfReadable)
        #expect(reset.isValidForPersistence)
        var failure: String?
        #expect(
            SchedulePersistenceStore.decodeCache(bytes, onFailure: { failure = $0 }).isUnreadable)
        let field =
            kind.hasPrefix("ddl")
            ? "ddlEvents"
            : kind == "shared-id"
                ? "sharedSchedules"
                : kind.hasPrefix("course") || kind == "rule-id"
                    ? "courses" : kind == "exam" ? "exams" : "customSchedules"
        #expect(failure?.contains(field) == true)
        #expect(await store.readFailure(for: account)?.contains(field) == true)
        #expect(
            await store.readFailure(for: AppStorageSession(accountIdentifier: "other-account"))
                == nil)
        #expect(try files.readData(at: url) == bytes)
        #expect(
            await store.write(
                reset, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == bytes)
        #expect(
            await store.write(
                reset, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .recovery, expectedUpdatedAt: nil) != nil)
        #expect(try files.readData(at: url) != bytes)
    }

    @Test(arguments: ["missing", "type", "date", "path", "size"])
    func cacheReadDiagnosticsIdentifyFields(kind: String) throws {
        let secret = "PRIVATE_USER_CONTENT"
        let course = try #require(
            ScheduleCourseEditor.adding(
                CourseDraft(title: secret, weekday: 1, weeksText: "1"),
                to: [], term: "term", id: "course"
            ).first)
        var cache = ScheduleCache()
        cache.courseData.store(
            .init(
                term: "term", firstDayString: "2026-09-07", courses: [course], exams: [],
                updatedAt: .distantPast))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        let expected: String
        switch kind {
        case "missing":
            object.removeValue(forKey: "courseData")
            expected = "decode.missing:courseData"
        case "type":
            object["ddlData"] = secret
            expected = "decode.type:ddlData"
        case "date":
            object["updatedAt"] = secret
            expected = "decode.invalid:updatedAt"
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
        let bytes =
            kind == "size"
            ? Data(repeating: 0, count: SchedulePersistenceStore.maximumCacheBytes + 1)
            : try JSONSerialization.data(withJSONObject: object)
        var failure: String?
        #expect(
            SchedulePersistenceStore.decodeCache(bytes, onFailure: { failure = $0 }).isUnreadable)
        #expect(failure == expected)
        #expect(failure?.contains(secret) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func inaccessibleExistencePreservesSchedule(protection: Bool) async throws {
        let files = ModuleScoreFiles()
        let account = AppStorageSession(accountIdentifier: "protected-schedule")
        let store = SchedulePersistenceStore(
            files: files, storageRoot: URL(fileURLWithPath: "/protected-schedule"),
            userStateMatches: { $0.primaryScheduleTitle == $1.primaryScheduleTitle })
        let cache = ScheduleCache()
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        #expect(
            await store.write(
                cache, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) != nil)
        let original = try files.readData(at: url)
        files.setFailures(reading: !protection, existence: true, protection: protection)
        #expect(!files.fileExists(at: url))
        #expect(await store.load(for: account).isUnreadable)
        #expect(
            await store.readFailure(for: account)?.hasPrefix(
                protection ? "file.protection:" : "file.read:") == true)
        #expect(files.storedData[url] == original)
        #expect(
            await store.write(
                cache, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) == nil)
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
    @Test func localFilesHonorAtomicIdentity() throws {
        let files = LocalAppFileService()
        let root = files.temporaryDirectoryURL.appendingPathComponent(
            "BIT101-FileServiceContract", isDirectory: true)
        try verifyFileServiceContract(files, root: root)
    }

    @Test(.timeLimit(.minutes(1))) func backupEligibilityRestoresDirectories() async throws {
        let support = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let root = support.appendingPathComponent("BIT101Tests-BackupPolicy", isDirectory: true)
        let directory = root.appendingPathComponent("drafts", isDirectory: true)
        let files = LocalAppFileService()
        func exclusion(_ url: URL) throws -> Bool? {
            var fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
            fresh.removeAllCachedResourceValues()
            return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
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
                Issue.record(
                    "备份排除标记期望 \(expected)，父目录标记 \(inheritedExclusion)，根目录、草稿目录及文件实际标记：\(observed)。")
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

    @Test func fileMetadataFailurePreservesCommittedBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BIT101-StoragePolicy", isDirectory: true)
        let files = LocalAppFileService(configureBackup: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        try files.removeItemIfPresent(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try files.removeItem(at: directory) } catch { Issue.record(error) } }
        let url = directory.appendingPathComponent("snapshot.json")
        let original = Data("retained".utf8)
        try original.write(to: url, options: .atomic)
        #expect(try files.readData(at: url) == original)
        #expect(throws: CocoaError.self) {
            try files.writeData(Data("edited".utf8), to: url, options: .atomic)
        }
        #expect(try files.readData(at: url) == original)
        let fresh = directory.appendingPathComponent("fresh.json")
        #expect(throws: CocoaError.self) {
            try files.writeData(original, to: fresh, options: .atomic)
        }
        #expect(files.fileExists(at: fresh) == false)
    }

    private func store(files: ModuleScoreFiles, root: String = "/schedule")
        -> SchedulePersistenceStore
    {
        SchedulePersistenceStore(
            files: files, storageRoot: URL(fileURLWithPath: root),
            userStateMatches: { $0.primaryScheduleTitle == $1.primaryScheduleTitle })
    }

    @Test(.timeLimit(.minutes(1))) func oversizedScheduleFilesPreserveStoredBytes() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "oversized")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data(repeating: 32, count: SchedulePersistenceStore.maximumCacheBytes + 1)
        try files.writeData(bytes, to: url, options: [])
        #expect(await persistence.load(for: account).isUnreadable)
        #expect(
            await persistence.write(
                ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) == nil)
        #expect(files.storedData[url] == bytes)
        #expect(SchedulePersistenceStore.decodeCache(bytes).isUnreadable)
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: [ScheduleCacheSaveSource.local, .localWithoutCloudPush])
    func earlierUiSnapshotPreservesCloudChanges(source: ScheduleCacheSaveSource) async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "concurrent-cloud-write")
        var initial = ScheduleCache()
        initial.cloudSyncBaselineRecordTag = "original"
        initial.syncData.cloudSyncBaselineUserState = Data("original".utf8)
        _ = await persistence.write(
            initial, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud,
            expectedUpdatedAt: nil)
        let repository = ScheduleRepository(
            session: { account }, load: { await persistence.load(for: $0) },
            save: { cache, source, owner in
                guard
                    await persistence.write(
                        cache, accountIdentifier: owner.accountStorageIdentifier,
                        legacyAccountIdentifier: owner.legacyAccountDirectoryNameForMigration,
                        source: source, expectedUpdatedAt: nil) != nil
                else { throw CocoaError(.fileWriteUnknown) }
            })
        await repository.loadIfNeeded()
        var remote = initial
        remote.primaryScheduleTitle = "云端新增"
        remote.cloudSyncBaselineRecordTag = "remote"
        remote.syncData.cloudSyncBaselineUserState = Data("remote".utf8)
        _ = await persistence.write(
            remote, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud,
            expectedUpdatedAt: nil)
        var local = repository.courseState
        local.primaryScheduleTitle = "本机修改"
        repository.courseState = local
        #expect(await repository.persistAndWait(source: source) == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "本机修改")
        #expect(repository.hasPersistenceConflict)
        let saved = await persistence.load(for: account).cacheIfReadable
        #expect(
            saved?.primaryScheduleTitle == "云端新增" && saved?.cloudSyncBaselineRecordTag == "remote")
    }

    @Test(.timeLimit(.minutes(1))) func independentStoresOwnTheirPathsAndAccounts() async throws {
        let files = ModuleScoreFiles()
        let first = store(files: files, root: "/first")
        let second = store(files: files, root: "/second")
        let account = AppStorageSession(accountIdentifier: "account")
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "first"
        let saved = await first.write(
            cache, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local,
            expectedUpdatedAt: nil)
        #expect(saved?.primaryScheduleTitle == "first")
        #expect(await first.load(for: account).cacheIfReadable?.primaryScheduleTitle == "first")
        #expect(await second.load(for: account).cacheIfReadable?.primaryScheduleTitle == "课表")
        #expect(
            await first.load(for: AppStorageSession(accountIdentifier: "other")).cacheIfReadable?
                .primaryScheduleTitle == "课表")
    }

    @Test(.timeLimit(.minutes(1))) func preciseDiskVersionsRoundTrip() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "precise-versions")
        var initial = ScheduleCache()
        initial.updatedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = try #require(
            await persistence.write(
                initial, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil))
        #expect(await persistence.load(for: account).cacheIfReadable?.updatedAt == first.updatedAt)
        var edit = first
        edit.primaryScheduleTitle = "second"
        let second = try #require(
            await persistence.write(
                edit, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: first.updatedAt))
        #expect(second.updatedAt > first.updatedAt)
        #expect(await persistence.load(for: account).cacheIfReadable?.updatedAt == second.updatedAt)
        #expect(
            await persistence.write(
                initial, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .cloud, expectedUpdatedAt: first.updatedAt) == nil)
        #expect(
            await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle == "second")
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        #expect(
            SchedulePersistenceStore.decodeCache(try legacyEncoder.encode(initial)).cacheIfReadable?
                .updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test(.timeLimit(.minutes(1))) func malformedAggregatePreserveConfirmation() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "malformed-sections")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        for key in [
            "courses", "cachedCoursesByTerm", "ddlEvents", "customSchedules",
            "selectedClassroomSectionIDs", "timeTable",
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: [
                "primaryScheduleTitle": "retained", key: "malformed",
            ])
            try files.writeData(bytes, to: url, options: [])
            let recovered = try #require(await persistence.load(for: account).cacheIfReadable)
            #expect(recovered.isValidForPersistence && recovered.primaryScheduleTitle == "retained")
            #expect(
                await persistence.write(
                    recovered, accountIdentifier: account.accountStorageIdentifier,
                    legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                    source: .local, expectedUpdatedAt: nil) == nil)
            #expect(try files.readData(at: url) == bytes)
            #expect(
                await persistence.write(
                    recovered, accountIdentifier: account.accountStorageIdentifier,
                    legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                    source: .recovery, expectedUpdatedAt: nil) != nil)
            #expect(try files.readData(at: url) != bytes)
        }
    }

    @Test(.timeLimit(.minutes(1))) func repeatedTimeTableIDsResetBothDiskFormats() async throws {
        let files = ModuleScoreFiles()
        let account = AppStorageSession(accountIdentifier: "repeated-sections")
        let repository = store(files: files)
        let url = repository.cacheFileURL(for: account.accountStorageIdentifier)
        var cache = ScheduleCache()
        cache.timeTable = [
            TimeSlot(id: 1, start: "08:00", end: "08:45"),
            TimeSlot(id: 1, start: "09:00", end: "09:45"),
        ]
        let legacy = try JSONSerialization.data(withJSONObject: [
            "timeTable": [
                ["id": 1, "start": "08:00", "end": "08:45"],
                ["id": 1, "start": "09:00", "end": "09:45"],
            ]
        ])
        for bytes in [try JSONEncoder().encode(cache), legacy] {
            #expect(SchedulePersistenceStore.decodeCache(bytes).isUnreadable)
            try files.writeData(bytes, to: url, options: [])
            let recovered = try #require(await repository.load(for: account).cacheIfReadable)
            #expect(recovered.timeTable == TimeSlot.default)
            #expect(
                await repository.write(
                    recovered, accountIdentifier: account.accountStorageIdentifier,
                    legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                    source: .local, expectedUpdatedAt: nil) == nil)
            #expect(try files.readData(at: url) == bytes)
            #expect(
                await repository.write(
                    recovered, accountIdentifier: account.accountStorageIdentifier,
                    legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                    source: .recovery, expectedUpdatedAt: nil) != nil)
            #expect(try files.readData(at: url) != bytes)
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "time-table", "shared-time-table", "term-course", "archived-course", "shared-course",
            "source-rule", "replacement-rule",
        ])
    func invalidNewSnapshotsPreserveCommittedState(boundary: String) async throws {
        let invalidCourse = CourseRecord(
            id: "invalid", term: "term", name: "课程", teacher: "", classroom: "",
            description: "", weeks: [0], weekday: 1, startSection: 1, endSection: 2, campus: "",
            number: "",
            credit: 0, hour: 0, type: "", category: "", department: "")
        let repeatedSlots = [
            TimeSlot(id: 1, start: "08:00", end: "08:45"),
            TimeSlot(id: 1, start: "09:00", end: "09:45"),
        ]
        var invalid = ScheduleCache()
        switch boundary {
        case "time-table": invalid.timeTable = repeatedSlots
        case "shared-time-table", "shared-course":
            invalid.sharedSchedules = [
                SharedScheduleRecord(
                    title: "共享",
                    payload: ScheduleExportPayload(
                        currentTerm: "term", firstDayString: "",
                        timeTable: boundary == "shared-time-table"
                            ? repeatedSlots : TimeSlot.default,
                        courses: boundary == "shared-course" ? [invalidCourse] : []))
            ]
        case "term-course", "archived-course":
            invalid.courseData.schedulesByTerm["term"] = TermScheduleSnapshot(
                term: "term", firstDayString: "",
                courses: [invalidCourse], exams: [], updatedAt: .distantPast)
            if boundary == "archived-course" { invalid.courseData.archivedTerms = ["term"] }
        default:
            invalid.manualCourseRulesByTerm["term"] = [
                ScheduleCourseRule(
                    sourceIdentity: "source",
                    sourceCourses: boundary == "source-rule" ? [invalidCourse] : [],
                    replacementCourses: boundary == "replacement-rule" ? [invalidCourse] : [])
            ]
        }
        #expect(
            SchedulePersistenceStore.decodeCache(try JSONEncoder().encode(invalid)).isUnreadable)
        for hasCommittedFile in [false, true] {
            let files = ModuleScoreFiles()
            let persistence = store(files: files)
            let account = AppStorageSession(accountIdentifier: "invalid-new-snapshot")
            let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
            var valid = ScheduleCache()
            valid.primaryScheduleTitle = "已保存课表"
            if hasCommittedFile {
                #expect(
                    await persistence.write(
                        valid, accountIdentifier: account.accountStorageIdentifier,
                        legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                        source: .local, expectedUpdatedAt: nil) != nil)
            }
            let committedBytes = files.storedData[url]
            #expect(
                await persistence.write(
                    invalid, accountIdentifier: account.accountStorageIdentifier,
                    legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                    source: .local, expectedUpdatedAt: nil) == nil)
            #expect(files.storedData[url] == committedBytes)
            let restored = await persistence.load(for: account)
            if hasCommittedFile {
                #expect(
                    restored.cacheIfReadable?.primaryScheduleTitle == valid.primaryScheduleTitle)
            } else {
                if case .missing = restored {} else { Issue.record("无效初次写入应保留缺失状态") }
            }
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "corrupt-source", "[]", "null", #"{"unrelated":1}"#,
            #"{"courseData":{},"updatedAt":0}"#,
        ])
    func unrecognizedCacheRootsPreserveTheirBytes(source: String) async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "corrupt")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data(source.utf8)
        try files.writeData(bytes, to: url, options: [])
        #expect(await persistence.load(for: account).isUnreadable)
        #expect(
            await persistence.write(
                ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test(.timeLimit(.minutes(1))) func failedWritesReturnFailure() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "write-failure")
        let initial = ScheduleCache()
        #expect(
            await persistence.write(
                initial, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) != nil)
        files.setFailures(writing: true)
        var update = initial
        update.primaryScheduleTitle = "edited"
        #expect(
            await persistence.write(
                update, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
                source: .local, expectedUpdatedAt: nil) == nil)
        #expect(
            await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle
                == initial.primaryScheduleTitle)
    }

    @Test(.timeLimit(.minutes(1))) func repositoryReportsSaveFailure() async {
        let account = AppStorageSession(accountIdentifier: "repository")
        let repository = ScheduleRepository(
            session: { account }, load: { _ in .missing },
            save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "edited"
        #expect(await repository.persistAndWait() == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "edited")
        #expect(repository.notice?.title == "日程保存失败")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func ddlSuccessWaitsForPersistence(deliversSources: Bool) async {
        let account = AppStorageSession(accountIdentifier: "ddl")
        let repository = ScheduleRepository(
            session: { account }, load: { _ in .missing },
            save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        await repository.loadIfNeeded()
        let viewModel = ScheduleDDLViewModel(
            service: DDLService(deliversSources: deliversSources), repository: repository)
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

        func finishFirstWrite() {
            completion?.resume()
            completion = nil
        }
    }

    private func repository(writer: DelayedWriter, session: @escaping () -> AppStorageSession)
        -> ScheduleRepository
    {
        ScheduleRepository(
            session: session,
            load: { _ in writer.stored.map(ScheduleCacheLoadResult.loaded) ?? .missing },
            save: { cache, _, session in try await writer.save(cache, session: session) })
    }

    @Test(.timeLimit(.minutes(1))) func queuedWritesPreserveOrder() async throws {
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
        #expect(writer.writes.map(\.0) == ["first", "second"])
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "second")
        #expect(repository.persistenceSnapshot.updatedAt == Date(timeIntervalSince1970: 2))
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

    @Test(.timeLimit(.minutes(1))) func cancelledWaiterKeepsCommittedData() async throws {
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

    @Test(.timeLimit(.minutes(1))) func oldAccountFailuresWritesStayWithOwner() async throws {
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
        let deliversSources: Bool
        func syncDDLEvents(
            existingEvents: [DDLEventRecord], storedURL: String,
            schoolSMSCodeHandler: SchoolSMSCodeHandler?, onSource: DDLSyncSourceDelivery?
        ) async throws -> DDLSyncPayload {
            let payload = DDLSyncPayload(url: "https://example.invalid/calendar", events: [])
            if deliversSources { try await onSource?(payload) }
            return payload
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws
            -> String
        { "https://example.invalid/calendar" }
    }
}
