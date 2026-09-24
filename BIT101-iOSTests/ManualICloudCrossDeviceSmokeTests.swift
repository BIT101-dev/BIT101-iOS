#if ICLOUD_CROSS_DEVICE_SMOKE
import Foundation
import XCTest
@testable import BIT101_iOS

/// Runs opt-in real-device and Mac Catalyst smoke tests.
///
/// The dedicated script compiles this file with `ICLOUD_CROSS_DEVICE_SMOKE`.
/// The app target and Release builds exclude these tests.
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
        var phoneSyncWasEnabled: Bool
        var phoneScoreCount: Int?
        var phoneScoreUpdatedAt: Date?
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let manager = ExperimentalPreferenceCloudSync.shared

    func testPhoneUpload() async {
        let account = ScheduleCacheStore.currentAccountIdentifier()
        guard account != "guest", account != "__default__" else {
            XCTFail("请先在真机登录账号")
            return
        }

        let scoreCount = ScoreCacheStore.loadRows()?.count
        let scoreUpdatedAt = ScoreCacheStore.loadUpdatedAt()

        var coordination = Coordination(
            token: UUID().uuidString,
            account: account,
            stage: .preparing,
            phoneSyncWasEnabled: manager.isEnabled,
            phoneScoreCount: scoreCount,
            phoneScoreUpdatedAt: scoreUpdatedAt
        )
        save(coordination)

        manager.setEnabled(true)

        let uploaded = await waitUntil {
            self.manager.refreshFromCloudIfNeeded()
            let scores: ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>? =
                self.remoteEnvelope(account: account, domain: .scoreCache)
            return self.scoreSnapshotMatches(
                scores,
                expectedCount: coordination.phoneScoreCount,
                expectedUpdatedAt: coordination.phoneScoreUpdatedAt
            )
        }
        guard uploaded else {
            manager.setEnabled(coordination.phoneSyncWasEnabled)
            removeCoordination(account: account)
            XCTFail("手机数据未在限定时间内上传到 iCloud KVS")
            return
        }

        coordination.stage = .phoneUploaded
        save(coordination)
        let scoreDescription = coordination.phoneScoreCount.map { String($0) } ?? "skipped"
        print("ICLOUD_SMOKE_PHONE_UPLOADED token=\(coordination.token) scores=\(scoreDescription)")
    }

    func testMacReceiveAndRestore() async throws {
        let coordination = try await requireCoordination(stage: .phoneUploaded)
        let currentStudentID = LoginStorage.shared.currentStudentID
        let currentPassword = LoginStorage.shared.currentPassword
        let currentFakeCookie = LoginStorage.shared.fakeCookie
        let usesTemporaryAccount = currentStudentID != coordination.account
        if usesTemporaryAccount {
            try LoginStorage.shared.saveLoginState(
                studentID: coordination.account,
                password: "icloud-smoke",
                fakeCookie: "icloud-smoke"
            )
        }
        defer {
            if usesTemporaryAccount {
                if currentStudentID.isEmpty {
                    LoginStorage.shared.clearAllLocalData()
                } else {
                    try? LoginStorage.shared.saveLoginState(
                        studentID: currentStudentID,
                        password: currentPassword,
                        fakeCookie: currentFakeCookie
                    )
                }
            }
        }

        let macSyncWasEnabled = manager.isEnabled
        manager.setEnabled(true)

        let received = await waitUntil {
            self.manager.refreshFromCloudIfNeeded()
            return self.localScoreSnapshotMatches(
                    expectedCount: coordination.phoneScoreCount,
                    expectedUpdatedAt: coordination.phoneScoreUpdatedAt
                )
        }
        guard received else {
            XCTFail("Mac 未收到手机上传的成绩缓存")
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
            return self.localScoreSnapshotMatches(
                    expectedCount: coordination.phoneScoreCount,
                    expectedUpdatedAt: coordination.phoneScoreUpdatedAt
                )
        }
        guard received else {
            manager.setEnabled(coordination.phoneSyncWasEnabled)
            removeCoordination(account: coordination.account)
            XCTFail("手机未收到 Mac 写回的成绩缓存")
            return
        }

        manager.setEnabled(coordination.phoneSyncWasEnabled)
        removeCoordination(account: coordination.account)
        let scoreDescription = coordination.phoneScoreCount.map { String($0) } ?? "skipped"
        print("ICLOUD_SMOKE_PHONE_VERIFIED token=\(coordination.token) scores=\(scoreDescription)")
    }

    private func scoreSnapshotMatches(
        _ envelope: ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>?,
        expectedCount: Int?,
        expectedUpdatedAt: Date?
    ) -> Bool {
        guard let expectedCount else { return true }
        return envelope?.payload.rows.count == expectedCount
            && envelope?.payload.updatedAt == expectedUpdatedAt
    }

    private func localScoreSnapshotMatches(expectedCount: Int?, expectedUpdatedAt: Date?) -> Bool {
        guard let expectedCount else { return true }
        return ScoreCacheStore.loadRows()?.count == expectedCount
            && ScoreCacheStore.loadUpdatedAt() == expectedUpdatedAt
    }

    /// 脚本异常退出后，测试在当前账号存在协调状态时恢复实验开关并清除协调标记。
    func testCleanup() async {
        let account = ScheduleCacheStore.currentAccountIdentifier()
        guard let coordination = loadCoordination(account: account) else { return }

        manager.setEnabled(coordination.phoneSyncWasEnabled)
        removeCoordination(account: account)
    }

    private func requireCoordination(stage: Stage) async throws -> Coordination {
        var result: Coordination?
        let received = await waitUntil {
            let account = ScheduleCacheStore.currentAccountIdentifier()
            let value = self.loadCoordination(account: account) ?? self.loadCoordination(stage: stage)
            guard let value, value.stage == stage else { return false }
            result = value
            return true
        }
        guard received else {
            throw NSError(
                domain: "ICloudCrossDeviceSmokeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未收到跨设备 Smoke 协调状态：\(stage.rawValue)"]
            )
        }
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

    private func loadCoordination(stage: Stage) -> Coordination? {
        let prefix = "manual.preference-cloud-sync.smoke.v1."
        var matches: [Coordination] = []
        for entry in cloud.dictionaryRepresentation where entry.key.hasPrefix(prefix) {
            guard let data = entry.value as? Data,
                  let coordination = try? JSONDecoder().decode(Coordination.self, from: data),
                  coordination.stage == stage
            else { continue }
            matches.append(coordination)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func removeCoordination(account: String) {
        cloud.removeObject(forKey: coordinationKey(account: account))
        cloud.synchronize()
    }
}
#endif
