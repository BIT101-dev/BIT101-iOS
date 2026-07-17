import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Shared infrastructure")
struct InfrastructureTests {
    private struct TestItem: Identifiable, Equatable {
        let id: Int
    }

    private struct TestPagedState: PagedItemsState {
        var items: [TestItem] = []
        var nextPage = 0
        var isLoadingMore = false
        var canLoadMore = true
    }

    @Test("Cancellation signals are normalized")
    func cancellationSignalsAreNormalized() {
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(!TaskCancellation.matches(URLError(.timedOut)))
    }

    @Test("Codable snapshots are isolated by account")
    func codableSnapshotsAreIsolatedByAccount() throws {
        let suiteName = "AccountScopedCodableStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var account = "student-a"
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            defaults: defaults,
            accountIdentifier: { account }
        )

        store.save(["A"])
        #expect(store.load() == ["A"])

        account = "student-b"
        #expect(store.load() == nil)
        store.save(["B"])
        #expect(store.load() == ["B"])

        account = "student-a"
        #expect(store.load() == ["A"])
    }

    @Test("Blank accounts use the guest namespace")
    func blankAccountsUseGuestNamespace() {
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            accountIdentifier: { "  " }
        )

        #expect(store.storageKey == "test.snapshot.guest")
    }

    @Test("Paged state advances and stops on an empty page")
    func pagedStateAdvancesAndStops() {
        var state = TestPagedState()

        state.applyFirstPage([TestItem(id: 1), TestItem(id: 2)])
        #expect(state.nextPage == 1)
        #expect(state.shouldLoadMore(currentID: 2))

        state.isLoadingMore = true
        #expect(!state.shouldLoadMore(currentID: 2))

        state.appendPage([])
        #expect(state.nextPage == 2)
        #expect(!state.canLoadMore)

        state.resetPagination()
        #expect(state.items.isEmpty)
        #expect(state.nextPage == 0)
        #expect(state.canLoadMore)
    }
}

@Suite("Score presentation logic")
struct ScorePresentationTests {
    @Test("Qualitative scores use their numeric ordering")
    func qualitativeScoresUseNumericOrdering() {
        let excellent = makeRow(index: 0, score: "优秀")
        let pass = makeRow(index: 1, score: "及格")

        #expect(ScoreSortIndex.score.compare(excellent, pass) == .orderedDescending)
        #expect(!ScoreSortIndex.score.isMissingValue(in: excellent))
    }

    @Test("Missing values are identified independently from sort direction")
    func missingValuesAreIdentified() {
        let missing = makeRow(index: 0, score: "")
        #expect(ScoreSortIndex.score.isMissingValue(in: missing))
        #expect(ScoreSortOrder.ascending.toggled == .descending)
    }

    private func makeRow(index: Int, score: String) -> ScoreRow {
        ScoreRow(
            index: index,
            headers: ["课程编号", "课程名称", "成绩", "学分"],
            values: ["MATH-\(index)", "高等数学", score, "4"]
        )
    }
}
