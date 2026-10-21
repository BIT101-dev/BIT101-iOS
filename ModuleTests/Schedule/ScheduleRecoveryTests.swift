import BIT101TestSupport
import Foundation
import ScheduleDomain
import SchedulePersistence
import StorageCore
import Testing

@MainActor
struct ScheduleRecoveryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func damagedFieldsKeepSchoolSchedulesAndCloudConsentUntilLocalSave(wholeSyncBlock: Bool) async throws {
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
        #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
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
            let recovered = try #require(await store.load(for: account).cacheIfReadable)
            #expect(recovered.isValidForPersistence)
            #expect(recovered.customSchedules.count == (collection == "customSchedules" ? 2 : 3))
            #expect(recovered.sharedSchedules.count == (collection == "sharedSchedules" ? 2 : 3))
            #expect(recovered.manualCourseRulesByTerm["term"]?.count == (collection == "manualCourseRulesByTerm" ? 2 : 3))
            #expect(recovered.ddlEvents.count == (collection == "ddlEvents" ? 2 : 3))
            #expect(files.storedData[url] == bytes)
            #expect(await store.write(recovered, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
            let reopened = try #require(await store.load(for: account).cacheIfReadable)
            #expect(reopened.customSchedules == recovered.customSchedules && reopened.sharedSchedules == recovered.sharedSchedules)
            #expect(reopened.manualCourseRulesByTerm == recovered.manualCourseRulesByTerm && reopened.ddlEvents == recovered.ddlEvents)
        }
    }
}
