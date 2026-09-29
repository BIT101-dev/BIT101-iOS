import ClientCore
import Combine
import Foundation

/// 日程子功能共享的账号数据源。页面状态由各子功能拥有。
@MainActor
final class ScheduleRepository: ObservableObject {
    @Published var cache = ScheduleCache() {
        didSet { revision &+= 1 }
    }
    @Published private(set) var isWritable = false
    @Published private(set) var isLoading = true
    @Published var notice: ScheduleNotice?
    private(set) var accountGeneration = 0
    private var revision = 0
    private var loadGeneration = 0
    private var hasLoaded = false
    private var ownerSession: AppStorageSession
    private var observer: Task<Void, Never>?
    private let session: () -> AppStorageSession
    private let load: (AppStorageSession) async -> ScheduleCacheStore.LoadResult
    private let save: (ScheduleCache, ScheduleCacheStore.SaveSource, AppStorageSession) -> Void

    init(
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession },
        load: @escaping (AppStorageSession) async -> ScheduleCacheStore.LoadResult = {
            await ScheduleCacheStore.loadResultAsync(for: $0)
        },
        save: @escaping (ScheduleCache, ScheduleCacheStore.SaveSource, AppStorageSession) -> Void = {
            ScheduleCacheStore.save($0, source: $1, session: $2)
        }
    ) {
        self.session = session
        self.ownerSession = session()
        self.load = load
        self.save = save
        observer = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .scheduleCacheDidChange) {
                await self?.reload()
            }
        }
    }

    deinit { observer?.cancel() }

    func resetForCurrentAccount() {
        ownerSession = session()
        accountGeneration &+= 1
        loadGeneration &+= 1
        hasLoaded = false
        isWritable = false
        isLoading = true
        cache = ScheduleCache()
        notice = nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        let account = session()
        guard account == ownerSession else { return }
        let generation = accountGeneration
        let localRevision = revision
        loadGeneration &+= 1
        let request = loadGeneration
        let result = await load(account)
        guard generation == accountGeneration, account == session(),
              request == loadGeneration, localRevision == revision else { return }
        switch result {
        case .loaded(let value):
            cache = value
            isWritable = true
            notice = nil
        case .missing:
            cache = ScheduleCache()
            isWritable = true
            notice = nil
        case .unreadable:
            isWritable = false
            notice = .informational(
                title: "本地课表缓存读取失败",
                message: "原文件已保留，当前课表只读并暂停保存。请联系维护者恢复缓存后重试。"
            )
        }
        isLoading = false
    }

    func persist(source: ScheduleCacheStore.SaveSource = .local) {
        guard isWritable, ownerSession == session() else { return }
        save(cache, source, ownerSession)
    }
}

/// 子功能使用统一账号数据源，分别管理请求、选择与提示状态。
@MainActor
protocol ScheduleStateConsumer: AnyObject {
    var repository: ScheduleRepository { get }
}

extension ScheduleStateConsumer {
    var cache: ScheduleCache {
        get { repository.cache }
        set { repository.cache = newValue }
    }

    var accountGeneration: Int { repository.accountGeneration }
    var isLoadingCache: Bool { repository.isLoading }
    var isCacheWritable: Bool { repository.isWritable }

    func persist(source: ScheduleCacheStore.SaveSource = .local) {
        repository.persist(source: source)
    }
}
