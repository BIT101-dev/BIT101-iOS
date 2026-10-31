import Combine
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import ScheduleActivityContracts
import Foundation
import Network
import os
import Security
import Testing
import UIKit
import XCTest
@testable import BIT101_iOS

@Suite("Shared infrastructure")
struct InfrastructureTests {
    @Test(.timeLimit(.minutes(1))) func eventWaitEnforcesDeadlineCancellationAndActorIsolation() async throws {
        @MainActor func callerCondition() -> Bool {
            MainActor.assertIsolated()
            return true
        }
        try await waitForTestEvent { callerCondition() }
        try await waitForAsyncTestEvent { callerCondition() }
        try await waitForTestEvent(timeout: .zero) { true }
        await #expect(throws: URLError.self) { try await waitForTestEvent(timeout: .zero) { false } }
        await #expect(throws: URLError.self) { try await waitForTestEvent(timeout: .milliseconds(5)) { false } }
        try await waitForAsyncTestEvent(timeout: .zero) { true }
        await #expect(throws: URLError.self) { try await waitForAsyncTestEvent(timeout: .zero) { false } }
        await #expect(throws: URLError.self) {
            try await waitForAsyncTestEvent(timeout: .milliseconds(5)) { await Task.yield(); return false }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await waitForTestEvent { false }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let cancelledAsync = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await waitForAsyncTestEvent { true }
        }
        await #expect(throws: CancellationError.self) { try await cancelledAsync.value }
        actor State { var complete = true }
        let state = State()
        try await waitForTestEvent(isolation: state) { $0.complete }
        try await waitForAsyncTestEvent { await state.complete }
    }

    @Test("File backends share directory, recursive cleanup and failure contracts")
    func fileServiceContract() throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        try verifyFileServiceContract(files, root: URL(fileURLWithPath: "/file-service-contract"),
            setRemovalFailure: { files.setFailures(removal: $0) })
        try verifyFileServiceContract(LocalAppFileService(),
            root: FileManager.default.temporaryDirectory.appendingPathComponent("file-service-contract", isDirectory: true))
    }
#if BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING
    @Test("Behavior host uses isolated account resources and blocks external transport", .timeLimit(.minutes(1)))
    @MainActor
    func behaviorHostIsolation() async throws {
        #expect(AppFileDirectories.defaultsDomain == "harrybit.BIT101-iOS.tests")
        #expect(AppFileDirectories.files is ScopedAppFileService)
        #expect(AppAccountSession.storage.currentStudentID.isEmpty)
        #expect(AppAccountSession.storage.fakeCookie.isEmpty)
        #expect(AppAccountSession.currentSession.accountIdentifier.hasPrefix("__automated_tests__."))
        let encryption = ScoreCacheSyncEncryption.production(defaults: AppFileDirectories.defaults)
        defer { #expect(encryption.removeActiveKey(account: "host-isolation")) }
        let clear = Data("isolated-score".utf8)
        let sealed = try encryption.seal(clear, account: "host-isolation")
        let keyID = try #require(AppFileDirectories.defaults.string(forKey: "experimental.preference-cloud-sync.score-key.host-isolation"))
        #expect(try !AutomatedTestPreferenceCloudStore.shared.read(account: "host-isolation.\(keyID)").isEmpty)
        #expect(try encryption.open(sealed, account: "host-isolation") == clear)
        let request = URLRequest(url: try #require(URL(string: "https://example.com")))
        await #expect(throws: URLError(.notConnectedToInternet)) {
            _ = try await NetworkSessionPool.productionCommunity.data(for: request)
        }
    }
#endif

    @Test("Startup notice follows the installed version")
    func startupNoticeVersion() throws {
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(AppSettingsStore.currentStartupNoticeVersion == version)
    }

    @Test("Cancellation signals are normalized")
    func cancellationSignalsAreNormalized() {
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(!TaskCancellation.matches(URLError(.timedOut)))
    }

    @Test("Community timestamps use one parser and preserve fallback text")
    func communityDateText() {
        #expect(AppDateText.date(from: "2026-09-05T12:34:56.000+0800") != nil)
        #expect(AppDateText.date(from: "not-a-date") == nil)
        #expect(AppDateText.relativeText(from: "not-a-date", fallback: "未知时间") == "未知时间")
    }

    @Test("Codable snapshots are isolated by account")
    func codableSnapshotsAreIsolatedByAccount() throws {
        let suiteName = "AccountScopedCodableStoreTests"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            #expect((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
        }

        var session = AppStorageSession(accountIdentifier: "student-a")
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            defaults: defaults,
            session: { session }
        )

        let oldKey = session.legacyKey("test.snapshot")
        defaults.set(try JSONEncoder().encode(["A"]), forKey: oldKey)
        #expect(store.load() == ["A"])
        #expect(defaults.object(forKey: oldKey) == nil)
        store.save(["A"])
        #expect(store.load() == ["A"])

        session = AppStorageSession(accountIdentifier: "student-b")
        #expect(store.load() == nil)
        store.save(["B"])
        #expect(store.load() == ["B"])

        session = AppStorageSession(accountIdentifier: "student-a")
        #expect(store.load() == ["A"])
    }

    @Test("Blank accounts use the guest namespace")
    func blankAccountsUseGuestNamespace() {
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            session: { AppStorageSession(accountIdentifier: "  ") }
        )

        #expect(store.storageKey == "test.snapshot.guest")
    }

    @Test("Storage sessions centralize account keys and filesystem-safe names")
    func storageSessionNames() {
        let guest = AppStorageSession(accountIdentifier: " \n ")
        #expect(guest.key("test.snapshot") == "test.snapshot.guest")
        #expect(guest.accountDirectoryName == "__default__")

        let account = AppStorageSession(accountIdentifier: "student/a")
        let storageIdentifier = "account-f075dae4022cfb12f24efad0580c7d242ff6360fc0287305a8a399231e4a62ae"
        #expect(account.key("test.snapshot") == "test.snapshot.\(storageIdentifier)")
        #expect(account.accountStorageIdentifier == storageIdentifier)
        #expect(AccountStorageIdentity.stableToken(for: storageIdentifier) == storageIdentifier)
        #expect(!account.accountStorageIdentifier.contains("student"))
        #expect(account.accountDirectoryName == "__encoded__73747564656E742F61")
        #expect(account.legacyAccountDirectoryName == "student_a")
        #expect(account.legacyAccountDirectoryNameForMigration == account.accountDirectoryName)

        let underscoreAccount = AppStorageSession(accountIdentifier: "student_a")
        #expect(underscoreAccount.legacyAccountDirectoryName == "student_a")
        #expect(underscoreAccount.legacyAccountDirectoryNameForMigration == underscoreAccount.accountDirectoryName)
        #expect(account.accountDirectoryName != underscoreAccount.accountDirectoryName)
        #expect(account.accountStorageIdentifier != underscoreAccount.accountStorageIdentifier)
    }

    @Test("Keychain deletion status accepts completed and absent items")
    func keychainDeletionStatus() {
        #expect(KeychainLoginCredentials.keychainDeleteSucceeded(status: errSecSuccess))
        #expect(KeychainLoginCredentials.keychainDeleteSucceeded(status: errSecItemNotFound))
        #expect(!KeychainLoginCredentials.keychainDeleteSucceeded(status: errSecNotAvailable))
    }

}
