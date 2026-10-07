import Foundation
import ScheduleDomain
import Testing
@testable import ScheduleSync

struct ScheduleCloudMergeTests {
    private func event(_ id: String, title: String = "DDL") -> DDLEventRecord {
        .init(id: id, group: "main", title: title, text: "", dueAt: Date(timeIntervalSince1970: 100), done: false)
    }

    private func merged(_ base: ScheduleCache, _ local: ScheduleCache, _ remote: ScheduleCache) throws -> ScheduleCache? {
        let baseline = try ScheduleCloudStateMerge.baseline(for: base)
        guard let state = try ScheduleCloudStateMerge.merge(local: .init(cache: local), remote: .init(cache: remote),
            baseline: baseline) else { return nil }
        var cache = local
        state.apply(to: &cache)
        return cache
    }

    @Test func independentAdditionsDeletionsAndCompletionsConvergeInBothOrders() throws {
        var base = ScheduleCache()
        base.ddlEvents = [event("removed"), event("kept")]
        base.lexueDDLCompletionByID = ["eclass:1": false, "eclass:2": false]
        var local = base
        local.ddlEvents = [event("kept"), event("local")]
        local.lexueDDLCompletionByID["eclass:1"] = true
        var remote = base
        remote.ddlEvents.append(event("remote"))
        remote.lexueDDLCompletionByID["eclass:2"] = true
        remote.showSunday = false
        let forward = try #require(try merged(base, local, remote))
        let backward = try #require(try merged(base, remote, local))
        #expect(Set(forward.ddlEvents.map(\.id)) == ["kept", "local", "remote"])
        #expect(forward.lexueDDLCompletionByID == ["eclass:1": true, "eclass:2": true])
        #expect(forward.showSunday == false)
        #expect(try ScheduleCloudSyncState.matches(forward, backward))
    }

    @Test func concurrentEditsAndDeleteVersusEditKeepTheConflictChoice() throws {
        var base = ScheduleCache()
        base.ddlEvents = [event("shared")]
        var local = base
        local.ddlEvents[0].title = "local"
        var remote = base
        remote.ddlEvents[0].title = "remote"
        #expect(try merged(base, local, remote) == nil)
        local.ddlEvents = []
        #expect(try merged(base, local, remote) == nil)
        remote = base
        #expect(try merged(base, local, remote)?.ddlEvents.isEmpty == true)
    }

    @Test func independentlyAddedCourseRulesAndCustomSchedulesSurvive() throws {
        let base = ScheduleCache()
        var local = base
        var remote = base
        local.manualCourseRulesByTerm = ["term": [.init(id: "local", sourceIdentity: "a", sourceCourses: [], replacementCourses: [])]]
        remote.manualCourseRulesByTerm = ["term": [.init(id: "remote", sourceIdentity: "b", sourceCourses: [], replacementCourses: [])]]
        local.customSchedules = [.init(id: "a", title: "a", subtitle: "", description: "", dateString: "", beginTime: "", endTime: "")]
        remote.customSchedules = [.init(id: "b", title: "b", subtitle: "", description: "", dateString: "", beginTime: "", endTime: "")]
        let result = try #require(try merged(base, local, remote))
        #expect(Set(result.manualCourseRulesByTerm["term", default: []].map(\.id)) == ["local", "remote"])
        #expect(Set(result.customSchedules.map(\.id)) == ["a", "b"])
    }

    @Test func campusChangeConflictsWithOldCampusBuildingSelection() throws {
        var base = ScheduleCache()
        base.selectedCampusName = "中关村校区"
        base.selectedCampusCode = "1"
        base.selectedBuildingID = ""
        var local = base
        local.selectedCampusName = "良乡校区"
        local.selectedCampusCode = "2"
        var remote = base
        remote.selectedBuildingID = "zgc-building"
        #expect(try merged(base, local, remote) == nil)
        #expect(try merged(base, remote, local) == nil)
        local = base
        local.ddlBeforeDay = base.ddlBeforeDay + 1
        let result = try #require(try merged(base, local, remote))
        #expect(result.selectedCampusCode == "1")
        #expect(result.selectedBuildingID == "zgc-building")
        #expect(result.ddlBeforeDay == local.ddlBeforeDay)
    }
}
