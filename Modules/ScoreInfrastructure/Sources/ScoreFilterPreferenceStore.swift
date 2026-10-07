import ScoreDomain
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
            keyPrefix: "score.filter.preferences", defaults: defaults, sessionProvider: session
        )
    }

    public func load() -> ScoreFilterPreferenceSnapshot? {
        store.load()
    }

    public func save(
        selectedTerms: Set<String>,
        selectedCourseTypes: Set<String>,
        sortIndex: ScoreSortIndex,
        sortOrder: ScoreSortOrder
    ) {
        let snapshot = ScoreFilterPreferenceSnapshot(
            selectedTerms: selectedTerms.sorted(),
            selectedCourseTypes: selectedCourseTypes.sorted(),
            sortIndex: sortIndex.rawValue,
            sortOrder: sortOrder.rawValue
        )
        store.save(snapshot)
        saveSubject.send(session())
        changeSubject.send(session())
    }

    /// 将 iCloud 筛选偏好写入本地存储，并发布所属账号的变更。
    public func applySynced(_ snapshot: ScoreFilterPreferenceSnapshot) {
        store.save(snapshot)
        changeSubject.send(session())
    }
}
