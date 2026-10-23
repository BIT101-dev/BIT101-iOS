@testable import ScheduleFeature
import ScheduleDomain
import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Classroom availability calculation")
struct ClassroomAvailabilityCalculatorTests {
    private let timeTable = [
        TimeSlot(id: 1, start: "08:00", end: "08:45"),
        TimeSlot(id: 2, start: "08:50", end: "09:35"),
        TimeSlot(id: 3, start: "09:55", end: "10:40"),
    ]

    @Test("A free room lists its available sections")
    func listsFreeSections() {
        let record = ClassroomRecord(id: "a", name: "101", busyTimeCodes: [2])
        let item = ClassroomAvailabilityCalculator.availability(
            for: record,
            timeTable: timeTable,
            nowMinutes: 8 * 60 + 30
        )

        #expect(item.isFreeNow)
        #expect(item.freeSections == [1, 3])
        #expect(item.prettyFreeTimes == "1, 3")
    }

    @Test("Occupied sections use an exclusive ending boundary")
    func usesExclusiveClassEndBoundary() {
        let record = ClassroomRecord(id: "a", name: "101", busyTimeCodes: [1, 2])
        let item = ClassroomAvailabilityCalculator.availability(
            for: record,
            timeTable: timeTable,
            nowMinutes: 9 * 60
        )

        #expect(!item.isFreeNow)
        #expect(ClassroomAvailabilityCalculator.availability(for: record, timeTable: timeTable,
            nowMinutes: 9 * 60 + 35).isFreeNow)
    }

    @Test("A break between occupied classes is free")
    func reportsBreakBetweenOccupiedClasses() {
        let record = ClassroomRecord(id: "a", name: "101", busyTimeCodes: [1, 2])
        let busy = ClassroomAvailabilityCalculator.availability(for: record, timeTable: timeTable, nowMinutes: 8 * 60 + 30)
        let free = ClassroomAvailabilityCalculator.availability(for: record, timeTable: timeTable, nowMinutes: 8 * 60 + 45)
        #expect(!busy.isFreeNow && free.isFreeNow)
    }

    @Test("Touching and overlapping occupied intervals stay busy until their final endpoint")
    func mergesContinuousOccupancy() {
        let slots = [TimeSlot(id: 3, start: "09:00", end: "09:45"),
                     TimeSlot(id: 1, start: "08:00", end: "08:45"),
                     TimeSlot(id: 2, start: "08:45", end: "09:30")]
        let record = ClassroomRecord(id: "a", name: "101", busyTimeCodes: [1, 2, 3])
        let busy = ClassroomAvailabilityCalculator.availability(for: record, timeTable: slots, nowMinutes: 8 * 60 + 30)
        let free = ClassroomAvailabilityCalculator.availability(for: record, timeTable: slots, nowMinutes: 9 * 60 + 45)
        #expect(!busy.isFreeNow && free.isFreeNow)
    }

    @Test("Filters retain rooms free in any selected section")
    func filtersSelectedSections() {
        let records = [
            ClassroomRecord(id: "a", name: "101", busyTimeCodes: [1]),
            ClassroomRecord(id: "b", name: "102", busyTimeCodes: [2]),
        ]
        let result = ClassroomAvailabilityCalculator.availabilities(
            records: records,
            timeTable: timeTable,
            selectedSections: [2, 2, 99],
            nowMinutes: 7 * 60
        )

        #expect(result.map(\.id) == ["a"])
        #expect(ClassroomAvailabilityCalculator.normalizedSections([99, 2, 2, 1], in: timeTable) == [1, 2])
    }

    @Test("Section and building helpers handle schedule conventions")
    func presentationHelpers() {
        #expect(ClassroomAvailabilityCalculator.sectionsText([5, 3, 4, 8]) == "3~5, 8")
        #expect(ClassroomAvailabilityCalculator.sectionBlock(at: 10 * 60, in: TimeSlot.default) == [3, 4, 5])
        #expect(ClassroomAvailabilityCalculator.normalizedBuildingName(" 理教楼 A-101 ") == "理教A101")
        #expect(ClassroomAvailabilityCalculator.buildingCandidates(from: "综教A101") == ["综教A101", "综教A"])
    }
}
