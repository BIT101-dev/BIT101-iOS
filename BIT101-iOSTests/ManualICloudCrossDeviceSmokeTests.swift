import ScoreDomain
#if DEBUG || ICLOUD_CROSS_DEVICE_SMOKE
import CryptoKit
import Foundation
import Testing
@testable import BIT101_iOS

/// 同步证据同时核对完整载荷和本次业务域版本。
nonisolated enum ICloudSmokeEvidence {
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
import CommunityPersistence
import ScoreInfrastructure
import StorageCore
import XCTest

/// 真机与 Catalyst 使用同一账号，验证生产协调器接收本次完整成绩载荷和业务版本。
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
        var phoneSyncWasEnabled: Bool
        var scoreFingerprint: String
        var phoneVersion: Date?
        var macVersion: Date?
    }

    @MainActor private var cloud: NSUbiquitousKeyValueStore { .default }
    @MainActor private var manager: ExperimentalPreferenceCloudSync { .shared }

    @MainActor
    func testPhoneUpload() async throws {
        let account = AppFileDirectories.currentSession.accountDirectoryName
        guard account != "guest", account != "__default__" else {
            XCTFail("请先在真机登录账号")
            return
        }
        guard let payload = await AppAccountStores.shared.scoreCache.syncPayload(), !payload.rows.isEmpty else {
            XCTFail("请先在真机保存成绩缓存")
            return
        }
        try restorePhoneState()
        manager.reloadForCurrentAccount()
        var coordination = Coordination(
            token: try runID(), account: account,
            accountIdentifier: AppFileDirectories.currentSession.accountIdentifier, stage: .preparing,
            phoneSyncWasEnabled: manager.isEnabled,
            scoreFingerprint: try ICloudSmokeEvidence.fingerprint(payload)
        )
        try save(coordination)
        manager.setEnabled(true)
        coordination.phoneVersion = try await publishScores(
            fingerprint: coordination.scoreFingerprint, after: Date(), coordinator: manager
        )
        coordination.stage = .phoneUploaded
        try save(coordination)
        print("ICLOUD_SMOKE_PHONE_UPLOADED token=\(coordination.token) scores=\(payload.rows.count)")
    }

    @MainActor
    func testMacReceiveAndRestore() async throws {
        let coordination = try await requireCoordination(stage: .phoneUploaded, selectPhoneAccount: true)
        let phoneVersion = try XCTUnwrap(coordination.phoneVersion)
        let coordinator = macCoordinator(for: coordination)
        let macSyncWasEnabled = coordinator.isEnabled
        defer { coordinator.setEnabled(macSyncWasEnabled) }
        coordinator.setEnabled(true)
        let received = await waitUntil {
            coordinator.refreshFromCloudIfNeeded()
            return await self.localScoresMatch(coordination, version: phoneVersion, coordinator: coordinator)
        }
        guard received else {
            XCTFail("Mac 接收本次成绩载荷和业务版本超时")
            return
        }
        var completed = coordination
        completed.macVersion = try await publishScores(
            fingerprint: coordination.scoreFingerprint, after: phoneVersion, coordinator: coordinator
        )
        completed.stage = .macRestored
        try save(completed)
        print("ICLOUD_SMOKE_MAC_RECEIVED_AND_PUBLISHED token=\(coordination.token)")
    }

    @MainActor
    func testPhoneVerifyAndCleanup() async throws {
        let coordination = try await requireCoordination(stage: .macRestored)
        let macVersion = try XCTUnwrap(coordination.macVersion)
        let phoneVersion = try XCTUnwrap(coordination.phoneVersion)
        XCTAssertGreaterThan(macVersion, phoneVersion)
        manager.setEnabled(true)
        let received = await waitUntil {
            self.manager.refreshFromCloudIfNeeded()
            return await self.localScoresMatch(coordination, version: macVersion, coordinator: self.manager)
        }
        guard received else {
            XCTFail("手机接收 Mac 发布的成绩载荷和业务版本超时")
            return
        }
        manager.setEnabled(coordination.phoneSyncWasEnabled)
        removeCoordination(account: coordination.account)
        print("ICLOUD_SMOKE_PHONE_VERIFIED token=\(coordination.token)")
    }

    @MainActor
    private func macCoordinator(for coordination: Coordination) -> ExperimentalPreferenceCloudSync {
        let session = AppStorageSession(accountIdentifier: coordination.accountIdentifier)
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(defaults: AppFileDirectories.defaults, session: { session }),
            composerDrafts: AppAccountStores.shared.composerDrafts,
            scoreCache: ScoreCacheStore(
                files: AppFileDirectories.files,
                storageRoot: AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS"),
                defaults: AppFileDirectories.defaults, session: { session }
            ),
            scoreFilterPreferences: ScoreFilterPreferenceStore(defaults: AppFileDirectories.defaults, session: { session }),
            currentSession: { session }, scoreSession: { session }
        )
        return ExperimentalPreferenceCloudSync(
            settings: AppSettingsStore(defaults: AppFileDirectories.defaults, session: { session }),
            stores: stores, defaults: AppFileDirectories.defaults, cloudStore: cloud
        )
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
        let payload = await coordinator.stores.scoreCache.syncPayload()
        return ICloudSmokeEvidence.matches(
            payload, fingerprint: coordination.scoreFingerprint,
            localVersion: coordinator.synchronizedVersion(for: .scoreCache), expectedVersion: version
        )
    }

    /// 异常退出时恢复当前账号的实验开关并清理协调标记。
    @MainActor
    func testCleanup() async throws {
        try restorePhoneState()
    }

    @MainActor
    private func restorePhoneState() throws {
        struct Recovery: Decodable { let phoneSyncWasEnabled: Bool }
        let account = AppFileDirectories.currentSession.accountDirectoryName
        guard let data = cloud.data(forKey: coordinationKey(account: account)) else { return }
        let recovery = try JSONDecoder().decode(Recovery.self, from: data)
        manager.setEnabled(recovery.phoneSyncWasEnabled)
        removeCoordination(account: account)
    }

    @MainActor
    private func runID() throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["BIT101_ICLOUD_SMOKE_RUN_ID"])
        XCTAssertFalse(value.isEmpty)
        return value
    }

    @MainActor
    private func requireCoordination(stage: Stage, selectPhoneAccount: Bool = false) async throws -> Coordination {
        let account = AppFileDirectories.currentSession.accountDirectoryName
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
    private func waitUntil(timeout: TimeInterval = 30, condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            cloud.synchronize()
            if await condition() { return true }
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return false }
        } while Date() < deadline
        return false
    }

    @MainActor
    private func remoteEnvelope(account: String) -> ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>? {
        let key = "preference-sync.v1.\(account).\(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)"
        guard let data = cloud.data(forKey: key) else { return nil }
        return try? ScoreCacheSyncPayloadCodec.decode(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self, from: data)
    }

    @MainActor
    private func coordinationKey(account: String) -> String {
        "manual.preference-cloud-sync.smoke.v1.\(account)"
    }

    @MainActor
    private func save(_ coordination: Coordination) throws {
        cloud.set(try JSONEncoder().encode(coordination), forKey: coordinationKey(account: coordination.account))
        cloud.synchronize()
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
    private func removeCoordination(account: String) {
        cloud.removeObject(forKey: coordinationKey(account: account))
        cloud.synchronize()
    }
}
#endif
