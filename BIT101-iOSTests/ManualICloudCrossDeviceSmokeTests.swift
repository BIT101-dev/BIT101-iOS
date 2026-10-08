import ScoreDomain
#if DEBUG || ICLOUD_CROSS_DEVICE_SMOKE
import CryptoKit
import Foundation
import Testing
@testable import BIT101_iOS

/// 同步证据同时核对完整载荷和本次业务域版本。
nonisolated enum ICloudSmokeEvidence {
    static func returningPayload(_ payload: ScoreCacheSyncPayload, token: String) throws -> ScoreCacheSyncPayload {
        guard let row = payload.rows.first, !row.values.isEmpty else { throw URLError(.cannotParseResponse) }
        var result = payload
        var values = row.values.map(\.value)
        let field = row.values.firstIndex(where: { $0.key == "课程名称" }) ?? 0
        values[field] += "-" + token
        result.rows[0] = ScoreRow(index: 0, headers: row.values.map(\.key), values: values)
        return result
    }

    static func fingerprint(_ payload: ScoreCacheSyncPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(
        _ payload: ScoreCacheSyncPayload?, fingerprint expected: String,
        localVersion: Date?, expectedVersion: Date
    ) -> Bool {
        guard let payload, !payload.rows.isEmpty, localVersion == expectedVersion else { return false }
        return (try? fingerprint(payload)) == expected
    }
}

@Suite("iCloud smoke evidence")
struct ICloudSmokeEvidenceTests {
    @Test("A prior cache requires the newly received business version")
    func priorCacheRequiresCurrentVersion() throws {
        let version = Date(timeIntervalSince1970: 100)
        let row = ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["课程", "90"])
        let payload = ScoreCacheSyncPayload(rows: [row], updatedAt: version, detailedUpdatedAt: nil)
        let digest = try ICloudSmokeEvidence.fingerprint(payload)
        let returned = try ICloudSmokeEvidence.returningPayload(payload, token: "mac")
        #expect(returned.rows.count == payload.rows.count)
        #expect(returned.updatedAt == payload.updatedAt)
        #expect(try ICloudSmokeEvidence.fingerprint(returned) != digest)
        #expect(!ICloudSmokeEvidence.matches(payload, fingerprint: try ICloudSmokeEvidence.fingerprint(returned),
                                            localVersion: version, expectedVersion: version))
        #expect(ICloudSmokeEvidence.matches(payload, fingerprint: digest, localVersion: version, expectedVersion: version))
        #expect(!ICloudSmokeEvidence.matches(payload, fingerprint: digest, localVersion: nil, expectedVersion: version))
        #expect(!ICloudSmokeEvidence.matches(payload, fingerprint: digest, localVersion: version, expectedVersion: version.addingTimeInterval(1)))
        #expect(!ICloudSmokeEvidence.matches(nil, fingerprint: digest, localVersion: version, expectedVersion: version))
        let changed = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["课程", "80"])],
            updatedAt: version, detailedUpdatedAt: nil
        )
        #expect(!ICloudSmokeEvidence.matches(changed, fingerprint: digest, localVersion: version, expectedVersion: version))
        let empty = ScoreCacheSyncPayload(rows: [], updatedAt: version, detailedUpdatedAt: nil)
        #expect(!ICloudSmokeEvidence.matches(empty, fingerprint: try ICloudSmokeEvidence.fingerprint(empty), localVersion: version, expectedVersion: version))
    }
}
#endif

#if ICLOUD_CROSS_DEVICE_SMOKE
import CloudKit
import CommunityPersistence
import CommunityCore
import ScheduleDomain
import ScheduleSync
import SchedulePersistence
import ScoreInfrastructure
import StorageCore
import XCTest

/// 真机与 Catalyst 使用独立验收账号和内存仓库，验证生产协调器接收完整成绩载荷和业务版本。
nonisolated final class ICloudCrossDeviceSmokeTests: XCTestCase {
    private enum Stage: String, Codable {
        case preparing
        case phoneUploaded
        case macRestored
    }

    private struct Coordination: Codable {
        var token: String
        var account: String
        var accountIdentifier: String
        var stage: Stage
        var scoreFingerprint: String
        var phoneVersion: Date?
        var macVersion: Date?
        var preferenceVersions: [String: Date] = [:]
    }

    @MainActor private var cloud: NSUbiquitousKeyValueStore { .default }
    @MainActor private var smokeSession: AppStorageSession { AppStorageSession(accountIdentifier: "__bit101_icloud_smoke__") }
    private let preferenceDomain = "BIT101Tests.icloud-cross-device-smoke"
    @MainActor private var phoneSchedule: ScheduleSmokeStore?
    @MainActor private var propagationDeadline: Date?

    @MainActor
    private final class ScheduleSmokeStore {
        let account = ScheduleCloudAccount(studentID: "__bit101_icloud_smoke__",
            session: AppStorageSession(accountIdentifier: "__bit101_icloud_smoke__"), generation: 1)
        private(set) var cache = ScheduleCache()
        var status = ScheduleCloudSyncStatus.idle
        let transport = AppScheduleCloudTransport()
        private let repository = SchedulePersistenceStore(files: PreferenceMemoryFiles(),
            storageRoot: URL(fileURLWithPath: "/icloud-smoke"), userStateMatches: ScheduleCloudSyncState.matches)
        lazy var manager = ScheduleCloudSyncManager(local: ScheduleCloudLocalStore(
            currentAccount: { self.account },
            load: { session in
                guard session == self.account.session else { return .missing }
                return await self.repository.load(for: session)
            },
            save: { value, source, account, expected in
                guard account == self.account,
                      let saved = await self.repository.write(value,
                        accountIdentifier: account.session.accountStorageIdentifier,
                        legacyAccountIdentifier: account.session.legacyAccountDirectoryNameForMigration,
                        source: source, expectedUpdatedAt: expected) else { return false }
                self.cache = saved
                return true
            }
        ), transport: transport, presentConflict: { _, _ in XCTFail("验收数据应按版本往返并保留真实记录锁") },
            reportStatus: { _, status in self.status = status })

        init() async throws {
            cache.iCloudSyncEnabled = true
            try await replaceCache(cache, source: .cloudBaseline, expected: nil)
        }

        func replaceCache(_ value: ScheduleCache, source: ScheduleCacheSaveSource, expected: Date? = nil) async throws {
            guard let saved = await repository.write(value, accountIdentifier: account.session.accountStorageIdentifier,
                legacyAccountIdentifier: account.session.legacyAccountDirectoryNameForMigration,
                source: source, expectedUpdatedAt: expected) else { throw CocoaError(.fileWriteUnknown) }
            cache = saved
        }
    }

    @MainActor
    func testPhoneRoundTrip() async throws {
        let coordinator = try await uploadPhoneScores()
        defer { coordinator.setEnabled(false); clearLocalSmokePreferences() }
        try await verifyPhoneScoresAndCleanup(coordinator: coordinator)
    }

    @MainActor
    private func uploadPhoneScores() async throws -> ExperimentalPreferenceCloudSync {
        let timestamp = Date()
        let payload = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0,
            headers: ["课程名称", "成绩", "课程性质", "学分", "学期"],
            values: ["功能验收", "95", "选修", "1", "验收学期"])],
            updatedAt: timestamp, detailedUpdatedAt: timestamp)
        try await restorePhoneState()
        let schedule = try await ScheduleSmokeStore()
        try await schedule.replaceCache(scheduleFixture(stage: "phone"), source: .cloudBaseline)
        await schedule.manager.pushLatestLocalCacheIfNeeded()
        XCTAssertEqual(schedule.status, .synchronized, "CloudKit Production 应保存生产日程载荷")
        _ = try await schedule.transport.record(named: schedule.account.recordName)
        phoneSchedule = schedule
        let manager = try smokeCoordinator()
        let prepared = await manager.stores.scoreCache.applySynced(payload, for: nil, replacing: nil)
        XCTAssertTrue(prepared)
        configurePreferences(stage: "phone", coordinator: manager)
        var coordination = Coordination(
            token: try runID(), account: smokeSession.accountDirectoryName,
            accountIdentifier: smokeSession.accountIdentifier, stage: .preparing,
            scoreFingerprint: try ICloudSmokeEvidence.fingerprint(payload)
        )
        try save(coordination)
        manager.setEnabled(true)
        coordination.phoneVersion = try await publishScores(
            fingerprint: coordination.scoreFingerprint, after: Date(), coordinator: manager
        )
        coordination.preferenceVersions = try await publishPreferences(coordinator: manager)
        coordination.stage = .phoneUploaded
        try save(coordination)
        print("ICLOUD_SMOKE_PHONE_UPLOADED token=\(coordination.token) scores=\(payload.rows.count)")
        return manager
    }

    @MainActor
    func testMacReceiveAndRestore() async throws {
        let coordination = try await requireCoordination(stage: .phoneUploaded, selectPhoneAccount: true)
        let phoneVersion = try XCTUnwrap(coordination.phoneVersion)
        let coordinator = try smokeCoordinator()
        defer { coordinator.setEnabled(false); clearLocalSmokePreferences() }
        coordinator.setEnabled(true)
        let received = await waitUntil {
            coordinator.reconcileCloudSnapshot()
            return await self.localScoresMatch(coordination, version: phoneVersion, coordinator: coordinator)
                && self.preferencesMatch(stage: "phone", versions: coordination.preferenceVersions, coordinator: coordinator)
        }
        guard received else {
            XCTFail("Mac 接收本次成绩载荷和业务版本超时")
            return
        }
        let schedule = try await ScheduleSmokeStore()
        await schedule.manager.refreshFromCloudIfNeeded()
        XCTAssertEqual(schedule.status, .synchronized)
        XCTAssertEqual(schedule.cache.primaryScheduleTitle, try runID() + "-phone")
        XCTAssertTrue(try ScheduleCloudSyncState.matches(schedule.cache, scheduleFixture(stage: "phone")))
        let priorRecord = try await schedule.transport.record(named: schedule.account.recordName)
        var returningSchedule = try scheduleFixture(stage: "mac")
        returningSchedule.updatedAt = Date().addingTimeInterval(1)
        returningSchedule.hasUnpushedCloudChanges = true
        try await schedule.replaceCache(returningSchedule, source: .localWithoutCloudPush, expected: schedule.cache.updatedAt)
        await schedule.manager.pushLatestLocalCacheIfNeeded()
        XCTAssertEqual(schedule.status, .synchronized)
        do {
            _ = try await schedule.transport.save(priorRecord)
            XCTFail("旧 CloudKit 记录锁应产生服务端版本冲突")
        } catch {
            XCTAssertEqual(error as? ScheduleCloudTransportError, .serverRecordChanged)
        }
        var completed = coordination
        let receivedCache = await coordinator.stores.scoreCache.syncPayload(for: nil)
        let receivedPayload = try XCTUnwrap(receivedCache)
        let returningPayload = try ICloudSmokeEvidence.returningPayload(receivedPayload, token: try runID() + "-mac")
        let applied = await coordinator.stores.scoreCache.applySynced(returningPayload, for: nil, replacing: nil)
        XCTAssertTrue(applied)
        completed.scoreFingerprint = try ICloudSmokeEvidence.fingerprint(returningPayload)
        XCTAssertNotEqual(completed.scoreFingerprint, coordination.scoreFingerprint)
        completed.macVersion = try await publishScores(
            fingerprint: completed.scoreFingerprint, after: phoneVersion, coordinator: coordinator
        )
        configurePreferences(stage: "mac", coordinator: coordinator)
        completed.preferenceVersions = try await publishPreferences(coordinator: coordinator)
        completed.stage = .macRestored
        try save(completed)
        coordinator.setEnabled(false)
        print("ICLOUD_SMOKE_MAC_RECEIVED_AND_PUBLISHED token=\(coordination.token)")
        let cleaned = await waitUntil {
            guard ExperimentalPreferenceSyncDomain.allCases.allSatisfy({
                self.cloud.object(forKey: "preference-sync.v2.\(coordination.account).\($0.rawValue)") == nil
            }), self.cloud.object(forKey: self.coordinationKey(account: coordination.account)) == nil else { return false }
            return (try? await self.cloudRecordWasDeleted()) == true
        }
        XCTAssertTrue(cleaned, "Mac 应接收验收 KVS 删除，并确认 CloudKit 记录已删除")
    }

    @MainActor
    private func verifyPhoneScoresAndCleanup(coordinator manager: ExperimentalPreferenceCloudSync) async throws {
        let coordination = try await requireCoordination(stage: .macRestored)
        let macVersion = try XCTUnwrap(coordination.macVersion)
        let phoneVersion = try XCTUnwrap(coordination.phoneVersion)
        XCTAssertGreaterThan(macVersion, phoneVersion)
        manager.setEnabled(true)
        let received = await waitUntil {
            manager.reconcileCloudSnapshot()
            return await self.localScoresMatch(coordination, version: macVersion, coordinator: manager)
                && self.preferencesMatch(stage: "mac", versions: coordination.preferenceVersions, coordinator: manager)
        }
        guard received else {
            XCTFail("手机接收 Mac 发布的成绩载荷和业务版本超时")
            return
        }
        manager.setEnabled(false)
        let schedule = try XCTUnwrap(phoneSchedule)
        await schedule.manager.refreshFromCloudIfNeeded()
        XCTAssertEqual(schedule.status, .synchronized)
        XCTAssertEqual(schedule.cache.primaryScheduleTitle, try runID() + "-mac")
        XCTAssertTrue(try ScheduleCloudSyncState.matches(schedule.cache, scheduleFixture(stage: "mac")))
        try await restorePhoneState()
        print("ICLOUD_SMOKE_PHONE_VERIFIED token=\(coordination.token)")
    }

    @MainActor
    private func smokeCoordinator() throws -> ExperimentalPreferenceCloudSync {
        let session = smokeSession
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferenceDomain))
        guard ScoreCacheSyncEncryption.production(defaults: defaults).removeActiveKey(account: session.accountDirectoryName) else {
            throw NSError(domain: "BIT101.ICloudSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "遗留验收成绩密钥清理待完成，恢复标识已保留"])
        }
        defaults.removePersistentDomain(forName: preferenceDomain)
        let files = PreferenceMemoryFiles()
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(defaults: defaults, session: { session }),
            composerDrafts: ComposerDraftStore(files: files, applicationSupport: files.temporaryDirectoryURL,
                session: { session }, prepareImageData: { $0 }),
            scoreCache: ScoreCacheStore(
                files: files, storageRoot: files.temporaryDirectoryURL,
                defaults: defaults, session: { session }
            ),
            scoreFilterPreferences: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentSession: { session }, scoreSession: { session }
        )
        return ExperimentalPreferenceCloudSync(
            settings: AppSettingsStore(defaults: defaults, session: { session }),
            stores: stores, defaults: defaults, cloudStore: cloud, synchronizedDomains: Set(ExperimentalPreferenceSyncDomain.allCases)
        )
    }

    @MainActor
    private func scheduleFixture(stage: String) throws -> ScheduleCache {
        let token = try runID()
        let mac = stage == "mac"
        var cache = ScheduleCache()
        cache.iCloudSyncEnabled = true
        cache.primaryScheduleTitle = token + "-" + stage
        let course = CourseRecord(id: "smoke-course", term: "smoke-term", name: token + stage,
            teacher: "教师", classroom: "教室", description: "课程描述", weeks: [1, 3], weekday: 2,
            startSection: 1, endSection: 2, campus: "校区", number: "smoke", credit: 1, hour: 2,
            type: "选修", category: "自定义", department: "学院")
        cache.manualCourseRulesByTerm = ["smoke-term": [ScheduleCourseRule(id: "smoke-rule",
            sourceIdentity: "smoke-course", sourceCourses: [], replacementCourses: [course])]]
        cache.customSchedules = [CustomScheduleRecord(id: "smoke-custom", title: token + stage,
            subtitle: "地点", description: "日程描述", dateString: "2026-01-05", beginTime: "09:00", endTime: "10:00")]
        cache.ddlEvents = [DDLEventRecord(id: "smoke-ddl", group: "custom", title: token + stage,
            text: "DDL 正文", dueAt: Date(timeIntervalSince1970: 100), done: mac)]
        cache.lexueDDLCompletionByID = ["smoke-school-ddl": mac]
        cache.ddlBeforeDay = mac ? 3 : 2
        cache.showSunday = mac
        cache.selectedClassroomSectionIDs = mac ? [3, 4] : [1, 2]
        cache.isClassroomSectionFilterCustomized = true
        cache.updatedAt = Date()
        return cache
    }

    @MainActor
    private func configurePreferences(stage: String, coordinator: ExperimentalPreferenceCloudSync) {
        let mac = stage == "mac"
        coordinator.settings.updateGallerySettings(hideBotPosterInSearch: mac,
            hiddenUserIDs: [mac ? 202 : 101], hideAnonymousContent: mac, useWebView: mac)
        coordinator.stores.scoreFilterPreferences.save(selectedTerms: [stage], selectedCourseTypes: [stage],
            sortIndex: mac ? .credit : .score, sortOrder: mac ? .ascending : .descending)
        coordinator.stores.communityMessages.markSeen(ids: [mac ? 202 : 101], for: .comment)
    }

    @MainActor
    private func publishPreferences(coordinator: ExperimentalPreferenceCloudSync) async throws -> [String: Date] {
        let domains: [ExperimentalPreferenceSyncDomain] = [.appSettings, .scoreFilters, .galleryMessageRead]
        var versions: [String: Date] = [:]
        struct Version: Decodable { let updatedAt: Date }
        let uploaded = await waitUntil {
            for domain in domains {
                let key = "preference-sync.v2.\(self.smokeSession.accountDirectoryName).\(domain.rawValue)"
                guard let data = self.cloud.data(forKey: key), let remote = try? JSONDecoder().decode(Version.self, from: data),
                    remote.updatedAt == coordinator.synchronizedVersion(for: domain) else { return false }
                versions[domain.rawValue] = remote.updatedAt
            }
            return true
        }
        XCTAssertTrue(uploaded, "偏好、筛选和消息已读版本应上传至真实 KVS")
        return try XCTUnwrap(uploaded ? versions : nil)
    }

    @MainActor
    private func preferencesMatch(stage: String, versions: [String: Date], coordinator: ExperimentalPreferenceCloudSync) -> Bool {
        let mac = stage == "mac"
        let filters = coordinator.stores.scoreFilterPreferences.load()
        let seen = Set(coordinator.stores.communityMessages.syncSnapshot().seenIDsByType[GalleryMessageType.comment.rawValue] ?? [])
        return versions.count == 3 && versions.allSatisfy { name, version in
            ExperimentalPreferenceSyncDomain(rawValue: name).map { coordinator.synchronizedVersion(for: $0) == version } == true
        } && coordinator.settings.galleryHiddenUserIDs == [mac ? 202 : 101]
            && coordinator.settings.galleryHideBotPosterInSearch == mac
            && coordinator.settings.galleryHideAnonymousContent == mac && coordinator.settings.galleryUseWebView == mac
            && filters?.selectedTerms == [stage] && filters?.selectedCourseTypes == [stage]
            && filters?.sortIndex == (mac ? ScoreSortIndex.credit : .score).rawValue
            && filters?.sortOrder == (mac ? ScoreSortOrder.ascending : .descending).rawValue
            && seen == (mac ? [101, 202] : [101])
    }

    @MainActor
    private func publishScores(fingerprint: String, after previousVersion: Date, coordinator: ExperimentalPreferenceCloudSync) async throws -> Date {
        coordinator.localValueDidChange(in: .scoreCache)
        var publishedVersion: Date?
        let uploaded = await waitUntil {
            guard let envelope: ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload> =
                self.remoteEnvelope(account: coordinator.stores.currentSession().accountDirectoryName),
                envelope.updatedAt > previousVersion,
                ICloudSmokeEvidence.matches(
                    envelope.payload, fingerprint: fingerprint,
                    localVersion: coordinator.synchronizedVersion(for: .scoreCache),
                    expectedVersion: envelope.updatedAt
                )
            else { return false }
            publishedVersion = envelope.updatedAt
            return true
        }
        guard uploaded else {
            throw NSError(domain: "ICloudCrossDeviceSmokeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本次成绩载荷和业务版本上传超时"])
        }
        return try XCTUnwrap(publishedVersion)
    }

    @MainActor
    private func localScoresMatch(_ coordination: Coordination, version: Date, coordinator: ExperimentalPreferenceCloudSync) async -> Bool {
        let payload = await coordinator.stores.scoreCache.syncPayload(for: nil)
        return ICloudSmokeEvidence.matches(
            payload, fingerprint: coordination.scoreFingerprint,
            localVersion: coordinator.synchronizedVersion(for: .scoreCache), expectedVersion: version
        )
    }

    /// 清理独立验收账号的云端载荷、协调标记与本机偏好。
    @MainActor
    func testCleanup() async throws {
        try await restorePhoneState()
    }

    @MainActor
    private func restorePhoneState() async throws {
        let account = smokeSession.accountDirectoryName
        for domain in ExperimentalPreferenceSyncDomain.allCases {
            cloud.removeObject(forKey: "preference-sync.v2.\(account).\(domain.rawValue)")
        }
        try removeCoordination(account: account)
        clearLocalSmokePreferences()
        let name = ScheduleCloudAccount(studentID: smokeSession.accountIdentifier, session: smokeSession, generation: 1).recordName
        do {
            _ = try await CKContainer.default().privateCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: name))
        } catch let error as CKError where error.code == .unknownItem {
            print("CLOUDKIT_SMOKE_CLEANUP state=empty")
        }
        let deleted = try await cloudRecordWasDeleted()
        XCTAssertTrue(deleted, "验收 CloudKit 记录应在服务器删除后返回缺值")
    }

    @MainActor
    private func cloudRecordWasDeleted() async throws -> Bool {
        let name = ScheduleCloudAccount(studentID: smokeSession.accountIdentifier, session: smokeSession, generation: 1).recordName
        do {
            _ = try await CKContainer.default().privateCloudDatabase.record(for: CKRecord.ID(recordName: name))
            return false
        } catch let error as CKError where error.code == .unknownItem { return true }
    }

    @MainActor
    private func runID() throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["BIT101_ICLOUD_SMOKE_RUN_ID"])
        XCTAssertFalse(value.isEmpty)
        return value
    }

    @MainActor
    private func requireCoordination(stage: Stage, selectPhoneAccount: Bool = false) async throws -> Coordination {
        let account = smokeSession.accountDirectoryName
        guard selectPhoneAccount || (account != "guest" && account != "__default__") else {
            throw NSError(domain: "ICloudCrossDeviceSmokeTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "请先在真机登录 BIT101 账号"])
        }
        let token = try runID()
        var result: Coordination?
        let received = await waitUntil {
            let local = self.loadCoordination(account: account)
            let selected = local?.token == token ? local
                : (selectPhoneAccount ? self.loadCoordination(stage: stage, token: token) : nil)
            guard let value = selected, value.token == token, value.stage == stage else { return false }
            result = value
            return true
        }
        guard received else {
            throw NSError(domain: "ICloudCrossDeviceSmokeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "跨设备 Smoke 协调状态接收超时：\(stage.rawValue)"])
        }
        return try XCTUnwrap(result)
    }

    @MainActor
    private func waitUntil(condition: @escaping @MainActor () async -> Bool) async -> Bool {
        if propagationDeadline == nil {
            propagationDeadline = Date().addingTimeInterval(300)
            guard cloud.synchronize() else { XCTFail("iCloud KVS 同步请求失败"); return false }
        }
        let deadline = propagationDeadline ?? Date()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { _ in continuation.yield(()) }
        let keychainWakeups = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                continuation.yield(())
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            keychainWakeups.cancel()
            continuation.finish()
        }
        continuation.yield(())
        for await _ in events {
            guard !Task.isCancelled, Date() < deadline else { return false }
            if await condition() { return true }
        }
        return false
    }

    @MainActor
    private func clearLocalSmokePreferences() {
        guard let defaults = UserDefaults(suiteName: preferenceDomain) else { return }
        let deleted = ScoreCacheSyncEncryption.production(defaults: defaults).removeActiveKey(account: smokeSession.accountDirectoryName)
        XCTAssertTrue(deleted, "验收成绩密钥应从 iCloud 钥匙串删除")
        if deleted { defaults.removePersistentDomain(forName: preferenceDomain) }
    }

    @MainActor
    private func remoteEnvelope(account: String) -> ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>? {
        let key = "preference-sync.v2.\(account).\(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)"
        guard let data = cloud.data(forKey: key) else { return nil }
        guard let defaults = UserDefaults(suiteName: preferenceDomain),
              let clear = try? ScoreCacheSyncEncryption.production(defaults: defaults).open(data, account: account) else { return nil }
        return try? ScoreCacheSyncPayloadCodec.decode(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self, from: clear)
    }

    @MainActor
    private func coordinationKey(account: String) -> String {
        "manual.preference-cloud-sync.smoke.v1.\(account)"
    }

    @MainActor
    private func save(_ coordination: Coordination) throws {
        cloud.set(try JSONEncoder().encode(coordination), forKey: coordinationKey(account: coordination.account))
        guard cloud.synchronize() else { throw URLError(.cannotConnectToHost) }
    }

    @MainActor
    private func loadCoordination(account: String) -> Coordination? {
        guard let data = cloud.data(forKey: coordinationKey(account: account)) else { return nil }
        return try? JSONDecoder().decode(Coordination.self, from: data)
    }

    @MainActor
    private func loadCoordination(stage: Stage, token: String) -> Coordination? {
        let prefix = "manual.preference-cloud-sync.smoke.v1."
        let matches = cloud.dictionaryRepresentation.compactMap { key, value -> Coordination? in
            guard key.hasPrefix(prefix), let data = value as? Data,
                  let coordination = try? JSONDecoder().decode(Coordination.self, from: data),
                  coordination.stage == stage, coordination.token == token else { return nil }
            return coordination
        }
        return matches.count == 1 ? matches.first : nil
    }

    @MainActor
    private func removeCoordination(account: String) throws {
        cloud.removeObject(forKey: coordinationKey(account: account))
        guard cloud.synchronize() else { throw URLError(.cannotConnectToHost) }
    }
}
#endif
