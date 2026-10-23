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
