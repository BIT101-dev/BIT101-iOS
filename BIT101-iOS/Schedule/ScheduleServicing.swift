import Foundation

/// 日程状态机使用的学校系统能力；缓存与 UI 状态仍由 ViewModel 持有。
protocol ScheduleServicing {
    func syncCourses(term: String?) async throws -> CourseSyncPayload
    func fetchAvailableTerms() async throws -> [String]
    func submitSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge,
        term: String?
    ) async throws -> CourseSyncPayload
    func submitSMSCodeForTeachingCenterAuthentication(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws
    func fetchCurrentTermOnly() async throws -> String
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload
    func refreshLexueCalendarURL() async throws -> String
    func fetchCampuses() async throws -> [CampusRecord]
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord]
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord]
}

extension ScheduleService: ScheduleServicing {}
