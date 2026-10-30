import Foundation
import ScheduleDomain
import ClientCore
/// 日程状态机使用的学校系统能力；账号数据归仓库，UI 状态归各子功能。
public protocol ScheduleCourseServicing {
    func syncCourses(term: String?) async throws -> CourseSyncPayload
    func fetchAvailableTerms() async throws -> [String]
    func submitVerificationCodeForTeachingCenterAuthentication(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws
    func fetchCurrentTermOnly() async throws -> String
}

public typealias DDLSyncSourceDelivery = @MainActor @Sendable (DDLSyncPayload) async throws -> Void

public protocol ScheduleDDLServicing {
    func syncDDLEvents(
        existingEvents: [DDLEventRecord],
        storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?, onSource: DDLSyncSourceDelivery?
    ) async throws -> DDLSyncPayload
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String
}

public extension ScheduleDDLServicing {
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil) async throws -> DDLSyncPayload {
        try await syncDDLEvents(existingEvents: existingEvents, storedURL: storedURL,
            schoolSMSCodeHandler: schoolSMSCodeHandler, onSource: nil)
    }
}

public protocol ScheduleClassroomServicing {
    func fetchCurrentTermOnly() async throws -> String
    func prepareTeachingCenterAccess() async throws
    func fetchCampuses() async throws -> [CampusRecord]
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord]
    func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord]
    /// 使用已准备好的会话预取；会话尚待认证时返回 nil。
    func prefetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord]?
}

public extension ScheduleClassroomServicing {
    func prefetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord]? { nil }
}

public protocol ScheduleServicing: ScheduleCourseServicing, ScheduleDDLServicing, ScheduleClassroomServicing {}

