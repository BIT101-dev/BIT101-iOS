import BIT101TestSupport
import Foundation
import SchedulePersistence
import StorageCore
import Testing

@testable import ScheduleDomain
@testable import ScheduleSync

extension ScheduleSyncTests {
    @Test(.timeLimit(.minutes(1))) func remoteApplyUsesInjectedLocalOwner() async throws {
        let local = Local()
        local.cache.currentTerm = "school-term"
        local.cache.courseData.store(
            TermScheduleSnapshot(
                term: "school-term", firstDayString: "", courses: [], exams: [],
                updatedAt: .distantPast))
        let manager = local.manager(Cloud(remote: try record(title: "remote", updatedAt: 40)))
        await manager.refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "remote")
        #expect(local.cache.currentTerm == "school-term")
        #expect(local.cache.cachedCoursesByTerm.keys.contains("school-term"))
        #expect(local.cache.cloudSyncBaselineRecordTag == "remote-tag")
        #expect(local.sources == [.cloud])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["student", "cloud"])
    func delayedReadHonorsSwitches(owner: String) async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40), holdRead: true)
        let manager = local.manager(cloud)
        let task = Task { await manager.refreshFromCloudIfNeeded() }
        try await cloud.waitForEntry()
        local.account = ScheduleCloudAccount(
            studentID: "A", session: local.account.session,
            generation: owner == "student" ? 3 : 1, cloudGeneration: owner == "cloud" ? 1 : 0)
        await cloud.resume()
        await task.value
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
        #expect(await cloud.saved.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["apply", "upload", "conflict", "save"])
    func cancelledSyncDiscardsLateTransportResults(stage: String) async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = stage != "apply"
        local.cache.cloudSyncBaselineRecordTag = stage == "conflict" ? "old-tag" : "remote-tag"
        let cloud = Cloud(
            remote: try record(
                title: "remote", updatedAt: stage == "apply" || stage == "conflict" ? 40 : 20),
            holdRead: stage != "save", holdSave: stage == "save")
        let manager = local.manager(cloud)
        let pending = Task {
            if stage == "upload" || stage == "save" {
                await manager.pushLatestCache()
            } else {
                await manager.refreshFromCloudIfNeeded()
            }
        }
        try await cloud.waitForEntry()
        let statuses = local.statuses
        pending.cancel()
        await cloud.resume()
        await pending.value
        #expect(
            local.cache.primaryScheduleTitle == "local" && local.sources.isEmpty
                && local.resolutions.isEmpty)
        #expect(local.statuses == statuses)
        #expect(await cloud.saved.count == (stage == "save" ? 1 : 0))
        await manager.refreshFromCloudIfNeeded()
        if stage == "conflict" {
            #expect(local.resolutions.count == 1)
        } else {
            #expect(!local.sources.isEmpty && local.cache.hasUnpushedCloudChanges == false)
            #expect(local.cache.primaryScheduleTitle == (stage == "apply" ? "remote" : "local"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func accountSwitchRefreshUsesCurrentOwner() async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "A remote", updatedAt: 40), holdRead: true)
        let manager = local.manager(cloud)
        let first = Task { await manager.refreshFromCloudIfNeeded() }
        try await cloud.waitForEntry()
        local.account = ScheduleCloudAccount(
            studentID: "B", session: AppStorageSession(accountIdentifier: "B"), generation: 2)
        local.cache.primaryScheduleTitle = "B local"
        await cloud.replaceRemote(
            try record(
                title: "B remote", updatedAt: 40, studentID: "B", recordName: "schedule-cache-B"))
        await manager.refreshFromCloudIfNeeded()
        await cloud.resume()
        await first.value
        try await local.waitForSave()
        #expect(local.cache.primaryScheduleTitle == "B remote")
        #expect(local.sources == [.cloud])
    }

    @Test(.timeLimit(.minutes(1))) func editsDuringCloudSaveKeepTheirDirtyState() async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        let cloud = Cloud(holdSave: true)
        let manager = local.manager(cloud)
        let task = Task { await manager.pushLatestCache() }
        try await cloud.waitForEntry()
        local.cache.primaryScheduleTitle = "continued edit"
        local.cache.updatedAt = Date(timeIntervalSince1970: 45)
        await cloud.resume()
        await task.value
        #expect(local.cache.primaryScheduleTitle == "continued edit")
        #expect(local.cache.updatedAt == Date(timeIntervalSince1970: 45))
        #expect(local.cache.hasUnpushedCloudChanges)
        #expect(local.cache.cloudSyncBaselineRecordTag == "saved-tag")
        #expect(local.sources == [.cloudBaseline])
    }

    @Test(.timeLimit(.minutes(1))) func optimisticLockConflictUsesInjectedDecision() async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        local.cache.cloudSyncBaselineRecordTag = "old-tag"
        let cloud = Cloud(
            remote: try record(title: "old", updatedAt: 20, tag: "old-tag"),
            conflict: try record(title: "concurrent remote", updatedAt: 40))
        let manager = local.manager(cloud)
        await manager.pushLatestCache()
        #expect(local.resolutions.count == 1)
        let resolve = try #require(local.resolutions.first)
        await resolve(.useCloud)
        #expect(local.cache.primaryScheduleTitle == "concurrent remote")
        #expect(local.cache.hasUnpushedCloudChanges == false)
        #expect(local.sources == [.cloud])
    }

    @Test(.timeLimit(.minutes(1))) func invalidIdentityAndPreserveStateState() async throws {
        for remote in [
            try record(title: "wrong account", updatedAt: 40, studentID: "B"),
            try record(title: "future", updatedAt: 40, version: 4),
            try record(
                title: "repeated sections", updatedAt: 40,
                timeTable: [
                    TimeSlot(id: 1, start: "08:00", end: "08:45"),
                    TimeSlot(id: 1, start: "09:00", end: "09:45"),
                ]),
        ] {
            let local = Local()
            let cloud = Cloud(remote: remote)
            await local.manager(cloud).refreshFromCloudIfNeeded()
            #expect(local.cache.primaryScheduleTitle == "local")
            #expect(local.sources.isEmpty)
            #expect(await cloud.saved.isEmpty)
        }
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: [false, true],
        [ScheduleCacheConflictResolution.keepLocal, .useCloud])
    func shorterCloudTablePreservesSchoolCourses(
        dirty: Bool, choice: ScheduleCacheConflictResolution
    ) async throws {
        let local = Local()
        local.cache.currentTerm = "term"
        let courses = try ScheduleCourseEditor.adding(
            CourseDraft(title: "晚间课程", weeksText: "1", selectedSections: [12]),
            to: [], term: "term", id: "school")
        local.cache.courseData.store(
            .init(term: "term", firstDayString: "", courses: courses, exams: [], updatedAt: Date()))
        local.cache.hasUnpushedCloudChanges = dirty
        let cloud = Cloud(
            remote: try record(
                title: "remote", updatedAt: 40,
                timeTable: [.init(id: 1, start: "08:00", end: "08:45")]))
        let manager = local.manager(cloud)
        await manager.refreshFromCloudIfNeeded()
        #expect(local.statuses.last == .conflict && local.sources.isEmpty)
        let resolve = try #require(local.resolutions.first)
        await resolve(choice)
        #expect(local.cache.courses == courses)
        #expect(local.cache.timeTable == TimeSlot.default)
        if choice == .useCloud {
            if case .failed(let message)? = local.statuses.last {
                #expect(message.contains("保留本机版本"))
            } else {
                Issue.record("节次差异需要发布调整时间表的失败状态")
            }
            #expect(local.sources.isEmpty)
            #expect(await cloud.saved.isEmpty)
        } else {
            #expect(local.statuses.last == .synchronized)
            #expect(await cloud.saved.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func localCompareAndSaveFailurePreservesCache() async throws {
        let local = Local()
        local.failsSave = true
        await local.manager(Cloud(remote: try record(title: "remote", updatedAt: 40)))
            .refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func uploadingExistingRecordToken() async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        local.cache.cloudSyncBaselineRecordTag = "remote-tag"
        let cloud = Cloud(remote: try record(title: "old", updatedAt: 20))
        await local.manager(cloud).pushLatestCache()
        let saved = try #require(await cloud.saved.first)
        #expect(saved.systemFields == Data("lock-token".utf8))
        #expect(saved.recordName == "schedule-cache-A")
        #expect(local.cache.cloudSyncBaselineRecordTag == "saved-tag")
    }

    @Test(.timeLimit(.minutes(1))) func cloudStatusReportsSuccess() async throws {
        let saved = Local()
        await saved.manager(Cloud(remote: try record(title: "remote", updatedAt: 40)))
            .refreshFromCloudIfNeeded()
        #expect(saved.statuses == [.syncing, .synchronized])
        let deferred = Local()
        deferred.failsSave = true
        await deferred.manager(Cloud(remote: try record(title: "remote", updatedAt: 40)))
            .refreshFromCloudIfNeeded()
        #expect(deferred.statuses.last == .pending)
        #expect(deferred.cache.primaryScheduleTitle == "local")
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["readMatch", "pushMatch", "pushNew", "keepLocal", "useCloud"])
    func baselineSaveFailuresRetry(stage: String) async throws {
        let local = Local()
        local.failsSave = true
        local.cache.hasUnpushedCloudChanges = stage != "readMatch"
        let original = local.cache
        let choice = stage == "keepLocal" || stage == "useCloud"
        let cloud = Cloud(
            remote: stage == "pushNew"
                ? nil
                : try record(
                    title: choice ? "remote" : "local", updatedAt: 40))
        let manager = local.manager(cloud)
        func synchronize() async throws {
            if stage.hasPrefix("push") {
                await manager.pushLatestCache()
            } else {
                await manager.refreshFromCloudIfNeeded()
                if choice {
                    let resolve = try #require(local.resolutions.last)
                    await resolve(stage == "keepLocal" ? .keepLocal : .useCloud)
                }
            }
        }
        try await synchronize()
        if case .failed(let reason)? = local.statuses.last {
            #expect(reason.contains("保存失败"))
        } else {
            Issue.record("基线写入磁盘失败需要呈现失败状态")
        }
        #expect(
            local.sources.isEmpty
                && local.cache.cloudSyncBaselineRecordTag == original.cloudSyncBaselineRecordTag)
        #expect(
            local.cache.primaryScheduleTitle == original.primaryScheduleTitle
                && local.cache.updatedAt == original.updatedAt)
        #expect(local.cache.hasUnpushedCloudChanges == original.hasUnpushedCloudChanges)
        #expect(await cloud.saved.count == (stage == "pushNew" ? 1 : 0))
        local.failsSave = false
        try await synchronize()
        #expect(local.statuses.last == .synchronized && !local.cache.hasUnpushedCloudChanges)
        #expect(
            local.cache.cloudSyncBaselineRecordTag
                == (stage == "pushNew" || stage == "keepLocal" ? "saved-tag" : "remote-tag"))
        #expect(await cloud.saved.count == (stage == "pushNew" || stage == "keepLocal" ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1))) func cloudStatusPreservesFailure() async {
        let local = Local()
        await local.manager(Cloud(failsRead: true)).refreshFromCloudIfNeeded()
        guard case .failed(let reason)? = local.statuses.last else {
            Issue.record("A cloud transport failure must reach the status consumer")
            return
        }
        #expect(!reason.isEmpty)
        let unavailable = Local()
        let cloud = Cloud(available: false)
        await unavailable.manager(cloud).pushLatestCache()
        #expect(unavailable.statuses == [.unavailable])
        #expect(await cloud.saved.isEmpty)
    }
}
