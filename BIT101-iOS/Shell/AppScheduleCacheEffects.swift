import UserNotifications
import CommunityTransport
import ScheduleSync
import SchedulePorts
import ClientCore
import ScheduleFeature
import TransportCore
import ScheduleInfrastructure
import StorageCore
import ScheduleDomain
import Foundation

/// 应用层连接持久化、组件导出与云同步。
struct AppScheduleCacheEffects: SchedulePlatformActions {
    let currentSession: () -> AppStorageSession
    let currentIdentity: () -> CommunitySessionIdentity
    let pushCloud: () async -> Void
    let reconcileCloud: () async -> Void
    let requestReminderAuthorization: () async -> Void
    let refreshReminder: (String) async -> Void
    let importCourses: (ScheduleCourseSnapshot, String) async throws -> Int
    let importDrafts: ([ScheduleSystemCalendarEventDraft], String) async throws -> Int
    let deleteEntries: (Set<String>, String?) async throws -> ScheduleSystemCalendarMutationResult
    let deleteAllEntries: () async throws -> ScheduleSystemCalendarMutationResult

    func didSave(session: AppStorageSession, source: ScheduleCacheSaveSource, cloudSyncEnabled: Bool) async {
        guard source == .local, cloudSyncEnabled, session == currentSession() else { return }
        let identity = currentIdentity()
        Task {
            guard session == currentSession(), identity == currentIdentity() else { return }
            await pushCloud()
        }
    }

    func enableCloudSync(session: AppStorageSession) async {
        guard session == currentSession(), !Task.isCancelled else { return }
        await reconcileCloud()
    }

    func enableCourseReminder(session: AppStorageSession) async {
        guard session == currentSession(), !Task.isCancelled else { return }
        let identity = currentIdentity()
        await requestReminderAuthorization()
        guard session == currentSession(), identity == currentIdentity(), !Task.isCancelled else { return }
        await refreshReminder("reminder_toggle_enabled")
    }

    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int {
        try await importCourses(courses, term)
    }

    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int {
        try await importDrafts(ScheduleSystemCalendarEventBuilder.makeDrafts(for: content), term)
    }

    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        try await deleteEntries(Set(ScheduleSystemCalendarEventBuilder.makeDrafts(for: content).map(\.markerID)), term)
    }

    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        try await deleteEntries(markerIDs, term)
    }

    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult {
        try await deleteAllEntries()
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
    static func makeViewModel(
        platformActions: any SchedulePlatformActions,
        didSave: @escaping @MainActor (AppStorageSession, ScheduleCacheSaveSource, Bool) async -> Void
    ) -> ScheduleViewModel {
        let service: any ScheduleServicing
#if BIT101_UI_TESTING
        service = AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" ? UITestSchoolService() : make()
#else
        service = make()
#endif
        let virtualNetworkLikely: @MainActor @Sendable () -> Bool = { NetworkConnectionDescription.shared.snapshot.virtualNetworkLikely }
        let repository = ScheduleRepository(
            session: { AppFileDirectories.currentSession },
            load: { await ScheduleCacheStore.loadResultAsync(for: $0) },
            save: { cache, source, session in
                guard await ScheduleCacheStore.saveAndWait(cache, source: source, expectedAccountIdentifier: session.accountDirectoryName) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                await didSave(session, source, cache.iCloudSyncEnabled)
            },
            changes: ScheduleCacheStore.changes
        )
        return ScheduleViewModel(
            service: service,
            repository: repository,
            ddlService: service,
            classroomService: service,
            platformActions: platformActions,
            virtualNetworkLikely: virtualNetworkLikely,
            beforeSchoolRequest: {
                _ = await NetworkMagicWarningCenter.shared.consider(url: URL(string: "https://sso.bit.edu.cn"))
            },
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

    static func make(
        transport: (any HTTPTransport)? = nil,
        rawCourseResponseHandler: ((Data) -> Void)? = nil
    ) -> ScheduleService {
        ScheduleService(
            credentials: AppAccountSession.storage,
            crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer(),
            teachingCenterState: AppSchoolSession.teachingCenter,
            rawCourseResponseHandler: rawCourseResponseHandler,
            transport: transport ?? NetworkSessionPool.teachingCenter(state: AppSchoolSession.teachingCenter),
            observer: HTTPClient.appObserver
        )
    }
}

/// Production reminder context is selected alongside the platform actions.
extension ScheduleLiveActivityManager {
    static let shared: ScheduleLiveActivityManager = {
        let context = ScheduleReminderContext(
            currentSession: {
                let storage = AppAccountSession.storage
                return ScheduleReminderSession(studentID: storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines),
                    storage: AppFileDirectories.currentSession, generation: storage.communityCredentials.identity.generation,
                    signedIn: !storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            },
            loadCache: { await ScheduleCacheStore.loadResultAsync(for: $0).cacheIfReadable ?? ScheduleCache() }
        )
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return ScheduleLiveActivityManager(context: context, notificationCenter: .current())
        #else
        return ScheduleLiveActivityManager(context: context)
        #endif
    }()
}
