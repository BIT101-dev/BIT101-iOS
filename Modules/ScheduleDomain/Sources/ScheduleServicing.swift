import ClientCore
/// 日程状态机使用的学校系统能力；账号数据归仓库，UI 状态归各子功能。
public protocol ScheduleCourseServicing {
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
}

public protocol ScheduleDDLServicing {
    func syncDDLEvents(
        existingEvents: [DDLEventRecord],
        storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?
    ) async throws -> DDLSyncPayload
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String
}

public protocol ScheduleClassroomServicing {
    func fetchCurrentTermOnly() async throws -> String
    func prepareTeachingCenterAccess() async throws
    func fetchCampuses() async throws -> [CampusRecord]
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord]
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord]
}

public protocol ScheduleServicing: ScheduleCourseServicing, ScheduleDDLServicing, ScheduleClassroomServicing {}

