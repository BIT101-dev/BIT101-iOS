import ScoreDomain
import ScorePorts
import StorageCore
import Combine
import Foundation

public final class ScoreFilterPreferenceStore: ScoreFilterPreferencesStoring {
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private let session: () -> AppStorageSession
    private let store: AccountScopedCodableStore<ScoreFilterPreferenceSnapshot>

    public init(defaults: UserDefaults, session: @escaping () -> AppStorageSession) {
        self.session = session
        store = AccountScopedCodableStore(
            keyPrefix: "score.filter.preferences", defaults: defaults, sessionProvider: session,
            snapshotKeys: ScoreFilterPreferenceSnapshot.storageKeys
        )
    }

    public func load() -> ScoreFilterPreferenceSnapshot? {
        store.load()
    }

    public func reset() {
        store.remove()
        changeSubject.send(session())
    }

    public var hasUnreadableSnapshot: Bool {
        if case .unreadable = store.read() { return true }
        return false
    }

    @discardableResult
    public func save(
        selectedTerms: Set<String>,
        selectedCourseTypes: Set<String>,
        sortIndex: ScoreSortIndex,
        sortOrder: ScoreSortOrder
    ) -> Bool {
        let snapshot = ScoreFilterPreferenceSnapshot(
            selectedTerms: selectedTerms.sorted(),
            selectedCourseTypes: selectedCourseTypes.sorted(),
            sortIndex: sortIndex.rawValue,
            sortOrder: sortOrder.rawValue
        )
        guard store.save(snapshot) else { return false }
        saveSubject.send(session())
        changeSubject.send(session())
        return true
    }

    /// 将 iCloud 筛选偏好写入本地存储，并发布所属账号的变更。
    @discardableResult public func applySynced(_ snapshot: ScoreFilterPreferenceSnapshot) -> Bool {
        guard store.save(snapshot) else { return false }
        changeSubject.send(session())
        return true
    }
}
