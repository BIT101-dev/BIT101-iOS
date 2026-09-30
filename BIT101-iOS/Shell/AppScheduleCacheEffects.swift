import ClientCore
import ScheduleFeature
import TransportCore
import ScheduleInfrastructure
import StorageCore
import ScheduleDomain
import Foundation

/// 应用层连接持久化、组件导出与云同步。
struct AppScheduleCacheEffects: ScheduleCacheEffects, SchedulePlatformActions {
    func didSave(_ courses: ScheduleCourseSnapshot, session: AppStorageSession, source: ScheduleCacheSaveSource, cloudSyncEnabled: Bool) async {
        await ScheduleWidgetExporter.syncAsync(courses: courses, session: session)
#if canImport(CloudKit)
        if source == .local, cloudSyncEnabled {
            Task {
                guard AppFileDirectories.currentSession == session else { return }
                await ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()
            }
        }
#endif
    }

    func didClear() async {
        await ScheduleWidgetExporter.syncFromCurrentCache()
    }

    func enableCloudSync(cache: ScheduleCache, session: AppStorageSession) async {
#if canImport(CloudKit)
        guard AppFileDirectories.currentSession == session else { return }
        await ScheduleCloudSyncManager.shared.reconcileAfterEnabling(localCache: cache)
#endif
    }

    func enableCourseReminder(session: AppStorageSession) async {
        guard AppFileDirectories.currentSession == session else { return }
        _ = await ScheduleLiveActivityManager.shared.requestNotificationAuthorizationIfNeeded()
        guard AppFileDirectories.currentSession == session else { return }
        await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "reminder_toggle_enabled")
    }

    func importSystemCalendar(cache: ScheduleCache) async throws -> Int {
        try await ScheduleSystemCalendarManager.shared.importCurrentTerm(from: cache)
    }

    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int {
        try await ScheduleSystemCalendarManager.shared.importDrafts(ScheduleSystemCalendarEventBuilder.makeDrafts(for: content), term: term)
    }

    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        try await ScheduleSystemCalendarManager.shared.deleteImportedEvents(drafts: ScheduleSystemCalendarEventBuilder.makeDrafts(for: content), term: term)
    }

    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        try await ScheduleSystemCalendarManager.shared.deleteImportedEvents(markerIDs: markerIDs, term: term)
    }

    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult {
        try await ScheduleSystemCalendarManager.shared.deleteAllImportedEvents()
    }
}

struct AppScheduleSchoolSessionRestorer: SchoolSessionRestoring, Sendable {
    let restore: @MainActor @Sendable () async throws -> String?

    init(restore: @escaping @MainActor @Sendable () async throws -> String? = {
        try await LoginService().restoreSchoolSessionIfNeeded()
    }) {
        self.restore = restore
    }

    func restoreSchoolSessionIfNeeded() async throws -> String? {
        do {
            return try await restore()
        } catch let error as LoginServiceError {
            switch error {
            case let .schoolSMSRequired(context):
                throw SchoolSessionRestorationError.secondFactorRequired(context)
            case let .schoolSMSCodeInvalid(message):
                throw ScheduleServiceError.schoolSMSCodeInvalid(message)
            case let .schoolSMSUnavailable(message):
                throw ScheduleServiceError.schoolSMSUnavailable(message)
            default:
                throw ScheduleServiceError.authenticationFailed(error.localizedDescription)
            }
        }
    }
}

enum ScheduleServiceFactory {
    static func makeViewModel() -> ScheduleViewModel {
        let service = make()
        let virtualNetworkLikely: @MainActor @Sendable () -> Bool = { NetworkConnectionDescription.shared.snapshot.virtualNetworkLikely }
        let repository = ScheduleRepository(
            session: { AppFileDirectories.currentSession },
            load: { await ScheduleCacheStore.loadResultAsync(for: $0) },
            save: { ScheduleCacheStore.save($0, source: $1, session: $2) },
            cacheDidChange: .scheduleCacheDidChange
        )
        return ScheduleViewModel(
            service: service,
            repository: repository,
            ddl: ScheduleDDLViewModel(service: service, repository: repository, virtualNetworkLikely: virtualNetworkLikely, beforeSchoolRequest: {
                _ = await NetworkMagicWarningCenter.shared.consider(url: URL(string: "https://sso.bit.edu.cn"))
            }),
            classroom: ScheduleClassroomViewModel(service: service, repository: repository, virtualNetworkLikely: virtualNetworkLikely),
            platformActions: AppScheduleCacheEffects(),
            virtualNetworkLikely: virtualNetworkLikely,
            newCustomScheduleDraft: makeCustomScheduleDraft
        )
    }

    private static func makeCustomScheduleDraft() -> CustomScheduleDraft {
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            let calendar = ScheduleDateCodec.calendar
            let today = calendar.startOfDay(for: Date())
            let begin = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today) ?? today
            let end = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today) ?? begin
            return CustomScheduleDraft(date: today, beginTime: begin, endTime: end)
        }
#endif
        let now = Date()
        let end = Calendar.current.date(byAdding: .minute, value: 60, to: now) ?? now
        return CustomScheduleDraft(date: now, beginTime: now, endTime: end)
    }

    static func make(transport: (any HTTPTransport)? = nil) -> ScheduleService {
        ScheduleService(
            credentials: LoginStorage.shared,
            crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer(),
            rawCourseResponseHandler: ReleaseNetworkSmokeReportStore.writeRawCourseResponse,
            transport: transport
        )
    }
}
