#if ICLOUD_CROSS_DEVICE_SMOKE
import Foundation
import XCTest
@testable import BIT101_iOS

/// Opt-in real-device/Mac Catalyst smoke tests.
///
/// These tests are excluded at compile time unless the dedicated script adds
/// `ICLOUD_CROSS_DEVICE_SMOKE`; they never enter the app or a Release build.
@MainActor
final class ICloudCrossDeviceSmokeTests: XCTestCase {
    private enum Stage: String, Codable {
        case preparing
        case phoneUploaded
        case macRestored
    }

    private struct Coordination: Codable {
        var token: String
        var account: String
        var stage: Stage
        var originalAutoRotate: Bool
        var phoneAutoRotate: Bool
        var phoneSyncWasEnabled: Bool
        var phoneScoreCount: Int
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let manager = ExperimentalPreferenceCloudSync.shared

    func testPhoneUpload() async throws {
        let account = ScheduleCacheStore.currentAccountIdentifier()
        guard account != "guest", account != "__default__" else {
            XCTFail("请先在真机登录账号")
            return
        }

        let original = AppSettingsStore.shared.autoRotate
        let rows = ScoreCacheStore.loadRows() ?? []
        guard !rows.isEmpty else {
            XCTFail("真机成绩缓存为空，无法验证成绩缓存同步")
            return
        }

        var coordination = Coordination(
            token: UUID().uuidString,
            account: account,
            stage: .preparing,
            originalAutoRotate: original,
            phoneAutoRotate: !original,
            phoneSyncWasEnabled: manager.isEnabled,
            phoneScoreCount: rows.count
        )
        save(coordination)

        manager.setEnabled(true)
        AppSettingsStore.shared.setAutoRotate(coordination.phoneAutoRotate)

        let uploaded = await waitUntil {
            self.manager.refreshFromCloudIfNeeded()
            let settings: ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>? =
                self.remoteEnvelope(account: account, domain: .appSettings)
            let scores: ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>? =
                self.remoteEnvelope(account: account, domain: .scoreCache)
            return settings?.payload.autoRotate == coordination.phoneAutoRotate
                && scores?.payload.rows.count == coordination.phoneScoreCount
        }
        guard uploaded else {
            XCTFail("手机数据未在限定时间内上传到 iCloud KVS")
            return
        }

        coordination.stage = .phoneUploaded
        save(coordination)
        print("ICLOUD_SMOKE_PHONE_UPLOADED token=\(coordination.token) scores=\(rows.count)")
    }

    func testMacReceiveAndRestore() async throws {
        let coordination = try await requireCoordination(stage: .phoneUploaded)
        guard ScheduleCacheStore.currentAccountIdentifier() == coordination.account else {
            XCTFail("Mac 与手机当前登录的 BIT101 学号不一致")
            return
        }

        let macSyncWasEnabled = manager.isEnabled
        manager.setEnabled(true)

        let received = await waitUntil {
            self.manager.refreshFromCloudIfNeeded()
            return AppSettingsStore.shared.autoRotate == coordination.phoneAutoRotate
                && ScoreCacheStore.loadRows()?.count == coordination.phoneScoreCount
        }
        guard received else {
            XCTFail("Mac 未收到手机上传的设置或成绩缓存")
            manager.setEnabled(macSyncWasEnabled)
            return
        }

        AppSettingsStore.shared.setAutoRotate(coordination.originalAutoRotate)
        let restoredRemotely = await waitUntil {
            let settings: ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>? =
                self.remoteEnvelope(account: coordination.account, domain: .appSettings)
            return settings?.payload.autoRotate == coordination.originalAutoRotate
        }
        guard restoredRemotely else {
            XCTFail("Mac 恢复值未上传到 iCloud KVS")
            manager.setEnabled(macSyncWasEnabled)
            return
        }

        var completed = coordination
        completed.stage = .macRestored
        save(completed)
        manager.setEnabled(macSyncWasEnabled)
        print("ICLOUD_SMOKE_MAC_RECEIVED_AND_RESTORED token=\(coordination.token)")
    }

    func testPhoneVerifyAndCleanup() async throws {
        let coordination = try await requireCoordination(stage: .macRestored)
        manager.setEnabled(true)

        let received = await waitUntil {
            self.manager.refreshFromCloudIfNeeded()
            return AppSettingsStore.shared.autoRotate == coordination.originalAutoRotate
                && ScoreCacheStore.loadRows()?.count == coordination.phoneScoreCount
        }
        XCTAssertTrue(received, "手机未收到 Mac 写回的设置或成绩缓存")

        manager.setEnabled(coordination.phoneSyncWasEnabled)
        removeCoordination(account: coordination.account)
        print("ICLOUD_SMOKE_PHONE_VERIFIED token=\(coordination.token) scores=\(coordination.phoneScoreCount)")
    }

    /// 脚本异常退出时调用；尽量恢复手机设置与实验开关，并清除协调标记。
    func testCleanup() async throws {
        let account = ScheduleCacheStore.currentAccountIdentifier()
        guard let coordination = loadCoordination(account: account) else { return }

        manager.setEnabled(true)
        AppSettingsStore.shared.setAutoRotate(coordination.originalAutoRotate)
        _ = await waitUntil(timeout: 10) {
            let settings: ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>? =
                self.remoteEnvelope(account: account, domain: .appSettings)
            return settings?.payload.autoRotate == coordination.originalAutoRotate
        }
        manager.setEnabled(coordination.phoneSyncWasEnabled)
        removeCoordination(account: account)
    }

    private func requireCoordination(stage: Stage) async throws -> Coordination {
        var result: Coordination?
        let received = await waitUntil {
            guard let value = self.loadCoordination(
                account: ScheduleCacheStore.currentAccountIdentifier()
            ), value.stage == stage else {
                return false
            }
            result = value
            return true
        }
        XCTAssertTrue(received, "未收到跨设备 Smoke 协调状态：\(stage.rawValue)")
        return try XCTUnwrap(result)
    }

    private func waitUntil(
        timeout: TimeInterval = 30,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            cloud.synchronize()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        return false
    }

    private func remoteEnvelope<Payload: Codable>(
        account: String,
        domain: ExperimentalPreferenceSyncDomain
    ) -> ExperimentalPreferenceSyncEnvelope<Payload>? {
        let key = "preference-sync.v1.\(account).\(domain.rawValue)"
        guard let data = cloud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<Payload>.self, from: data)
    }

    private func coordinationKey(account: String) -> String {
        "manual.preference-cloud-sync.smoke.v1.\(account)"
    }

    private func save(_ coordination: Coordination) {
        let data = try? JSONEncoder().encode(coordination)
        cloud.set(data, forKey: coordinationKey(account: coordination.account))
        cloud.synchronize()
    }

    private func loadCoordination(account: String) -> Coordination? {
        guard let data = cloud.data(forKey: coordinationKey(account: account)) else { return nil }
        return try? JSONDecoder().decode(Coordination.self, from: data)
    }

    private func removeCoordination(account: String) {
        cloud.removeObject(forKey: coordinationKey(account: account))
        cloud.synchronize()
    }
}
#endif
