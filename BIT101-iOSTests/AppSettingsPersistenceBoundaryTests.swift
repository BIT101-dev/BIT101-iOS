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
@testable import MineFeature

@MainActor
struct AppSettingsPersistenceBoundaryTests {
    @Test(arguments: [false, true])
    func settingsEditsRetainFutureFieldsAcrossLegacyMigration(legacy: Bool) throws {
        let domain = "BIT101AppTests.settings-format"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "settings-format")
        let key = session.key(AppSettingsStore.storageKeyPrefix)
        defaults.set(Data(#"{"galleryUseWebView":true,"futureSetting":{"values":[1,2]}}"#.utf8),
            forKey: legacy ? AppSettingsStore.legacyStorageKey : key)
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        settings.updateGallerySettings(hideAnonymousContent: true)
        settings.markSharedScheduleImportGuideSeen()
        #expect(settings.storageIssue == nil && settings.galleryUseWebView)
        let data = try #require(defaults.data(forKey: key))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["galleryStrictUserFilter"] as? Bool == true)
        #expect((object["futureSetting"] as? [String: Any])?["values"] as? [Int] == [1, 2])
        if legacy { #expect(defaults.object(forKey: AppSettingsStore.legacyStorageKey) == nil) }
    }

    @Test(arguments: ["99", "true", "null", "\"1\""], [false, true])
    func unsupportedSettingsFormatsRetainTheirBytes(version: String, unscopedLegacy: Bool) throws {
        let domain = "BIT101AppTests.settings-future"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "future-settings")
        let scopedKey = session.key(AppSettingsStore.storageKeyPrefix)
        let key = unscopedLegacy ? AppSettingsStore.legacyStorageKey : scopedKey
        let source = Data(("{\"schemaVersion\":" + version + ",\"galleryUseWebView\":true}").utf8)
        defaults.set(source, forKey: key)
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        let previous = settings.snapshot
        #expect(settings.storageIssue != nil)
        #expect(!settings.markLinuxDoThanksNoticeShown(for: session))
        #expect(!settings.snapshot.hasShownLinuxDoThanksNotice)
        settings.updateGallerySettings(hiddenUserIDs: [42], hideAnonymousContent: true, useWebView: true)
        settings.markSharedScheduleImportGuideSeen()
        var synced = AppSettingsSnapshot()
        synced.galleryHiddenUserIDs = [43]
        synced.galleryUseWebView = true
        #expect(!settings.applySyncedPreferences(AppSettingsSyncPayload(snapshot: synced)))
        #expect(settings.snapshot == previous)
        settings.reloadForCurrentAccount()
        #expect(settings.storageIssue != nil && defaults.data(forKey: key) == source)
        if unscopedLegacy { #expect(defaults.object(forKey: scopedKey) == nil) }
    }

    @Test(arguments: [false, true])
    func corruptSettingsRetainTheirSourceThroughLoadEditsAndAccountReload(_ legacy: Bool) throws {
        let domain = "BIT101AppTests.settings-corruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "damaged-settings")
        let key = legacy ? session.legacyKey(AppSettingsStore.storageKeyPrefix) : session.key(AppSettingsStore.storageKeyPrefix)
        let damaged = Data("damaged-settings".utf8)
        defaults.set(damaged, forKey: key)
        defaults.set(try JSONEncoder().encode(AppSettingsSnapshot()), forKey: AppSettingsStore.legacyStorageKey)
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        settings.setAutomaticUpdateChecksEnabled(false)
        settings.setHidesCourseHistoryMakeupOutliers(false)
        defaults.set("retained", forKey: "unrelated-account-data")
        #expect(settings.storageIssue != nil)
        settings.updateGallerySettings(hideAnonymousContent: true)
        settings.markSharedScheduleImportGuideSeen()
        #expect(defaults.data(forKey: key) == damaged)
        session = AppStorageSession(accountIdentifier: "valid-settings")
        settings.reloadForCurrentAccount()
        #expect(settings.storageIssue == nil)
        session = AppStorageSession(accountIdentifier: "damaged-settings")
        settings.reloadForCurrentAccount()
        #expect(settings.storageIssue != nil)
        #expect(defaults.data(forKey: key) == damaged)
        settings.restoreAccountPreferences()
        #expect(settings.storageIssue == nil)
        #expect(!settings.automaticUpdateChecksEnabled && !settings.hidesCourseHistoryMakeupOutliers)
        #expect(defaults.string(forKey: "unrelated-account-data") == "retained")
        #expect(settings.markLinuxDoThanksNoticeShown(for: session))
        settings.reloadForCurrentAccount()
        #expect(settings.snapshot.hasShownLinuxDoThanksNotice)
        #expect(AppSettingsStore.loadSnapshotFromDefaults(for: session.accountIdentifier, defaults: defaults) != nil)
    }

    @Test func settingsSnapshotsShareGuestKeysAndAccountMigrations() throws {
        let domain = "BIT101AppTests.settings-boundary"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "")
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        settings.markSharedScheduleImportGuideSeen()
        let guest = try #require(AppSettingsStore.loadSnapshotFromDefaults(
            for: AppSettingsStore.defaultAccountIdentifier, defaults: defaults
        ))
        #expect(guest.hasSeenSharedScheduleImportGuide)
        #expect(defaults.data(forKey: "app.settings.snapshot.__default__") != nil)

        session = AppStorageSession(accountIdentifier: "settings-a")
        var legacy = AppSettingsSnapshot()
        legacy.hasSeenSharedScheduleImportGuide = true
        let encoded = try JSONEncoder().encode(legacy)
        let oldKey = session.legacyKey(AppSettingsStore.storageKeyPrefix)
        defaults.set(encoded, forKey: oldKey)
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide)
        #expect(defaults.data(forKey: oldKey) == nil)
        #expect(defaults.data(forKey: session.key(AppSettingsStore.storageKeyPrefix)) != nil)

        session = AppStorageSession(accountIdentifier: "settings-b")
        defaults.set(encoded, forKey: AppSettingsStore.legacyStorageKey)
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide)
        #expect(defaults.data(forKey: AppSettingsStore.legacyStorageKey) == nil)
        session = AppStorageSession(accountIdentifier: "settings-c")
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide == false)
        session = AppStorageSession(accountIdentifier: "")
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide)
    }
}

@MainActor
struct AccountSettingsTests {
    private struct UploadTransport: HTTPTransport {
        let mid: String
        let fails: Bool
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if fails { throw NSError(domain: "fixture.upload", code: 503) }
            let body = try JSONSerialization.data(withJSONObject: ["mid": mid, "url": "", "low_url": ""])
            let url = try #require(request.url)
            return (body, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["", "  ", "image", "transport"])
    func avatarUploadsValidateResourceIdentityAndPreserveTransportErrors(mode: String) async throws {
        let client = HTTPClient(transport: UploadTransport(mid: mode, fails: mode == "transport"), observer: nil)
        let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://fixture.invalid"),
            credentials: { credentials() }, refresh: { _ in })
        let service = SettingsNetworkService(session: session, checkLogin: { true })
        if mode == "image" { #expect(try await service.uploadAvatar(data: Data([1])).mid == "image") }
        else if mode == "transport" {
            do { _ = try await service.uploadAvatar(data: Data([1])); Issue.record("上传错误应沿原错误链传播。") }
            catch { #expect((error as NSError).domain == "fixture.upload" && (error as NSError).code == 503) }
        } else {
            await #expect(throws: SettingsServiceError.self) { try await service.uploadAvatar(data: Data([1])) }
        }
    }

    private final class Service: AccountSettingsServicing {
        var stored = MineUserInfo(user: .placeholder(id: 1, nickname: "昵称 A"), followingNum: 2,
            followerNum: 3, following: false, follower: false, own: true)
        var failsReads = false
        var failsWrites = false
        var writes: [(String?, String?, String?)] = []
        var beforeUpdate: () -> Void = {}
        var beforeCheck: () -> Void = {}
        var read: (() async -> MineUserInfo)?
        let image = CommunityImage(mid: "new-avatar", url: "https://fixture.invalid/avatar", lowUrl: "")
        func fetchMyInfo() async throws -> MineUserInfo {
            if failsReads { throw URLError(.timedOut) }
            if let read { return await read() }
            return stored
        }
        func updateUser(nickname: String?, motto: String?, avatarMid: String?) async throws {
            writes.append((nickname, motto, avatarMid))
            beforeUpdate()
            if failsWrites { throw URLError(.cannotConnectToHost) }
            stored = stored.updatingUser(nickname: nickname, motto: motto, avatar: avatarMid == image.mid ? image : nil)
        }
        func uploadAvatar(data: Data, filename: String) async throws -> CommunityImage { image }
        func checkLogin() async throws -> Bool { beforeCheck(); return true }
    }

    @Test(.timeLimit(.minutes(1))) func recoveredCommunityCredentialsPopulateTheAccountProfile() async {
        let service = Service(), restored = credentials()
        var owner = CommunityCredentials(identity: restored.identity, cookie: "")
        let model = AccountSettingsModel(dependencies: .init(service: service, credentials: { owner }))
        service.beforeCheck = { owner = restored }
        await model.checkLogin()
        #expect(model.isLoggedIn && model.profile?.user.nickname == "昵称 A" && model.profileLoadError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func anEarlierProfileReadKeepsTheLaterConfirmedEdit() async throws {
        let service = Service()
        let model = AccountSettingsModel(dependencies: .init(service: service, credentials: { credentials() }))
        await model.loadProfile()
        let old = service.stored
        var pending: CheckedContinuation<MineUserInfo, Never>?
        service.read = { await withCheckedContinuation { pending = $0 } }
        let reading = Task { await model.loadProfile() }
        defer { reading.cancel(); pending?.resume(returning: old); pending = nil }
        try await waitForTestEvent { pending != nil }
        service.failsReads = true
        #expect(await model.updateProfile(nickname: "昵称 B", motto: nil))
        pending?.resume(returning: old); pending = nil
        await reading.value
        #expect(model.profile?.user.nickname == "昵称 B" && model.profileLoadError != nil && !model.isLoadingProfile)
    }

    @Test(.timeLimit(.minutes(1))) func aDifferentAccountKeepsThePreviousProfileOutOfItsUpdates() async {
        let service = Service()
        var owner = credentials()
        let model = AccountSettingsModel(dependencies: .init(service: service, credentials: { owner }))
        await model.loadProfile()
        owner = credentials("other")
        #expect(await model.updateProfile(nickname: "昵称 B", motto: nil) == false)
        await model.updateAvatar { Data([1]) }
        #expect(service.writes.isEmpty)
    }
    private func credentials(_ account: String = "owner") -> CommunityCredentials {
        .init(identity: .init(accountIdentifier: account, generation: 0), cookie: "cookie")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func confirmedProfileEditsSurviveReadFailureAndTheNextEdit(avatar: Bool) async {
        let service = Service()
        let model = AccountSettingsModel(dependencies: .init(service: service, credentials: { credentials() }))
        await model.loadProfile()
        service.failsReads = true
        if avatar { await model.updateAvatar { Data([1]) } }
        else { #expect(await model.updateProfile(nickname: "昵称 B", motto: nil)) }
        #expect(model.profileLoadError != nil)
        #expect(await model.updateProfile(nickname: nil, motto: "新签名"))
        #expect(service.writes.last?.0 == (avatar ? "昵称 A" : "昵称 B"))
        #expect(service.writes.last?.2 == (avatar ? service.image.mid : ""))
        #expect(model.profile?.user.motto == "新签名")
        #expect(model.profile?.followingNum == 2 && model.profile?.followerNum == 3)
    }

    @Test(.timeLimit(.minutes(1))) func loginCheckReloadsProfileAfterTheInitialReadFailure() async {
        let service = Service(); service.failsReads = true
        let model = AccountSettingsModel(dependencies: .init(service: service, credentials: { credentials() }))
        await model.loadProfile()
        #expect(model.profile == nil && model.profileLoadError != nil && !model.isLoadingProfile)
        service.failsReads = false
        await model.checkLogin()
        #expect(model.isLoggedIn && model.profile?.user.nickname == "昵称 A" && model.profileLoadError == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedOrReownedProfileUpdatesPreserveDisplayedFields(accountChanges: Bool) async {
        let service = Service()
        var owner = credentials()
        let model = AccountSettingsModel(dependencies: .init(service: service, credentials: { owner }))
        await model.loadProfile()
        if accountChanges { service.beforeUpdate = { owner = credentials("other") } }
        else { service.failsWrites = true }
        #expect(await model.updateProfile(nickname: "昵称 B", motto: nil) == false)
        #expect(model.profile?.user.nickname == "昵称 A")
        #expect(accountChanges ? model.alert == nil : model.alert?.title == "更新失败")
    }
}

@MainActor
struct AccountProfileMutationTests {
    @Test(.timeLimit(.minutes(1)))
    func loginChecksPublishTheSharedBusyStateBeforeSchedulingAndReleaseItForProfileEdits() async throws {
        let mutation = AccountProfileMutation()
        var pending: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        #expect(mutation.start {
            await withCheckedContinuation { pending = $0 }
        })
        #expect(mutation.isBusy && !mutation.isUpdating)
        #expect(mutation.start { writes.append("overlap") } == false)
        try await waitForTestEvent { pending != nil }
        #expect(mutation.isBusy && !mutation.isUpdating)
        pending?.resume()
        try await waitForTestEvent { !mutation.isBusy }
        #expect(mutation.start {
            try? await mutation.perform { writes.append("profile") }
        })
        #expect(mutation.isBusy)
        try await waitForTestEvent { !mutation.isBusy }
        #expect(writes == ["profile"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func profileMutationsKeepOneOwnerThroughSuccessFailureAndRetry(fails: Bool) async throws {
        let mutation = AccountProfileMutation()
        var pending: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        let first = Task {
            do {
                try await mutation.perform {
                    writes.append("first")
                    await withCheckedContinuation { pending = $0 }
                    if fails { throw URLError(.timedOut) }
                }
                return !fails
            } catch { return fails && (error as? URLError)?.code == .timedOut }
        }
        try await waitForTestEvent { !(pending == nil) }
        #expect(mutation.isUpdating && mutation.isBusy)
        #expect(mutation.start { writes.append("overlap") } == false)
        try await mutation.perform { writes.append("duplicate") }
        #expect(mutation.isUpdating && writes == ["first"])
        pending?.resume()
        #expect(await first.value)
        #expect(!mutation.isUpdating)
        try await mutation.perform { writes.append("retry") }
        #expect(writes == ["first", "retry"] && !mutation.isUpdating)
    }

    @Test(.timeLimit(.minutes(1))) func leavingAProfilePageCancelsItsTaskAndRetainsTheSharedMutationLock() async throws {
        let mutation = AccountProfileMutation()
        var pending: CheckedContinuation<Void, Never>?
        var finished = false, rebound = false
        mutation.start {
            do {
                try await mutation.perform {
                    await withCheckedContinuation { pending = $0 }
                    try Task.checkCancellation()
                    rebound = true
                }
            } catch { #expect(error is CancellationError) }
            finished = true
        }
        try await waitForTestEvent { pending != nil }
        mutation.cancel()
        mutation.start { rebound = true }
        #expect(mutation.isUpdating)
        pending?.resume()
        try await waitForTestEvent { finished }
        #expect(!mutation.isUpdating && !rebound)
        mutation.start { rebound = true }
        try await waitForTestEvent { rebound }
    }

}
