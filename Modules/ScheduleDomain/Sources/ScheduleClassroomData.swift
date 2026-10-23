import Foundation

public nonisolated struct ClassroomQueryCache: Codable, Equatable, Sendable {
    public var term: String
    public var queryDate: Date
    public var attemptedAt: Date
    public var updatedAt: Date?
    public var records: [ClassroomRecord]?

    public init(term: String, queryDate: Date, attemptedAt: Date, updatedAt: Date? = nil, records: [ClassroomRecord]? = nil) {
        self.term = term; self.queryDate = queryDate; self.attemptedAt = attemptedAt
        self.updatedAt = updatedAt; self.records = records
    }

    public var isValid: Bool {
        guard queryDate.timeIntervalSince1970.isFinite, attemptedAt.timeIntervalSince1970.isFinite,
              updatedAt?.timeIntervalSince1970.isFinite ?? true else { return false }
        if let records {
            return updatedAt != nil && !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && records.allSatisfy(\.hasValidOccupancy)
        }
        return updatedAt == nil
    }
}

public nonisolated struct ScheduleClassroomData: Codable, Equatable, Sendable {
    public var selectedCampusName: String = ""
    public var selectedCampusCode: String = ""
    public var selectedBuildingID: String = ""
    public var cachedClassroomCampuses: [CampusRecord] = []
    public var cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]] = [:]
    public var selectedClassroomSectionIDs: [Int] = []
    public var isClassroomSectionFilterCustomized: Bool = false
    public var classroomRefreshDay: Date?
    public var classroomBuildingRefreshDaysByCampusCode: [String: Date]?
    public var cachedClassroomQueriesByBuildingID: [String: ClassroomQueryCache]?
    public init() {}
}
