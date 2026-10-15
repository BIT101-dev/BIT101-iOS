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

private nonisolated final class DelayedSchoolCookieServer: Sendable {
    private struct State: Sendable {
        var connection: NWConnection?
        var request = ""
        var failure: NWError?
        var port: UInt16?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SchoolCookieIsolationTests")
    private let state = OSAllocatedUnfairLock(initialState: State())
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [listener, state] value in
            state.withLock {
                if case .ready = value { $0.port = listener.port?.rawValue }
                if case let .failed(error) = value { $0.failure = error }
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [self] data, _, complete, error in
            if let error { state.withLock { $0.failure = error }; return }
            var bytes = buffered
            if let data { bytes.append(data) }
            let request = String(decoding: bytes, as: UTF8.self)
            if request.contains("\r\n\r\n") { state.withLock { $0.connection = connection; $0.request = request } }
            else if !complete { receive(connection, buffered: bytes) }
        }
    }
    func url() async throws -> URL {
        try await waitForTestEvent {
            let snapshot = state.withLock { $0 }
            if let failure = snapshot.failure { throw failure }
            return snapshot.port != nil
        }
        let port = try #require(state.withLock { $0.port })
        return AppURL.required("http://127.0.0.1:\(port)/cookie-isolation")
    }
    func waitForRequest() async throws {
        try await waitForTestEvent {
            let snapshot = state.withLock { $0 }
            if let error = snapshot.failure { throw error }
            return snapshot.connection != nil
        }
    }
    func requestHasCookie() -> Bool { state.withLock { $0.request.lowercased().contains("\r\ncookie:") } }
    func finish() {
        let connection = state.withLock { value in let current = value.connection; value.connection = nil; return current }
        let response = Data("HTTP/1.1 200 OK\r\nSet-Cookie: school-test=retired-session; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection?.send(content: response, completion: .contentProcessed { _ in connection?.cancel() })
    }
    func stop() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        state.withLock { $0.connection?.cancel() }
        listener.cancel()
    }
}

@MainActor
struct SchoolCookieIsolationTests {
    @Test func smokeAuthenticationStartsWithIndependentCookieContainers() throws {
        let first = AppSchoolSession.isolatedState()
        let second = AppSchoolSession.isolatedState()
        let cookie = try #require(HTTPCookie(properties: [.domain: "sso.bit.edu.cn", .path: "/",
            .name: "smoke-fixture", .value: "first"] ))
        first.cookieStorage.setCookie(cookie)
        #expect(first.cookieStorage !== second.cookieStorage)
        #expect(second.cookieStorage.cookies?.contains(where: { $0.name == cookie.name }) == false)
        #expect(first.cookieStorage !== AppSchoolSession.teachingCenter.cookieStorage)
    }
    @Test(.timeLimit(.minutes(1)))
    func delayedSessionCookieWritesRemainInTheRetiredAccountContainer() async throws {
        let retiredCookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let currentCookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: retiredCookies)
        let server = try DelayedSchoolCookieServer()
        defer { server.stop() }
        var selections: [HTTPCookieStorage] = []
        let transport = SchoolCookieTransport(state: state) { cookies in
            selections.append(cookies)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = cookies
            configuration.httpCookieAcceptPolicy = .always
            return URLSessionTransport.make(configuration: configuration)
        }
        let request = URLRequest(url: try await server.url())
        let oldRequest = Task { try await transport.data(for: request) }
        defer { oldRequest.cancel() }
        try await server.waitForRequest()
        state.clearSchoolAuthenticationCookies()
        state.replaceCookieStorage(with: currentCookies)
        server.finish()
        _ = try await oldRequest.value
        #expect(retiredCookies.cookies?.contains(where: { $0.name == "school-test" }) == true)
        #expect(currentCookies.cookies?.isEmpty == true)
        #expect(state.hasUsableSession(for: "next-account") == false)
        let newRequest = Task { try await transport.data(for: request) }
        defer { newRequest.cancel() }
        try await server.waitForRequest()
        #expect(server.requestHasCookie() == false)
        server.finish()
        _ = try await newRequest.value
        #expect(selections.count == 2 && selections[0] === retiredCookies && selections[1] === currentCookies)
        currentCookies.setCookie(try #require(HTTPCookie(properties: [.domain: "webvpn.bit.edu.cn", .path: "/", .name: "school-owner", .value: "current-session"])))
        #expect(state.hasUsableSession(for: "next-account") == false)
        state.markAuthenticated(for: "next-account")
        #expect(state.hasUsableSession(for: "next-account"))
    }
}

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
struct NetworkSmokeSMSPromptTests {
    @Test(.timeLimit(.minutes(1))) func submissionResumesTheWaitingRequestAndKeepsOverlappingRequestsIsolated() async throws {
        let prompt = ReleaseNetworkSmokeSMSPrompt()
        let request = SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "jwb")
        let waiting = Task { try await prompt.requestCode(request) }
        try await waitForTestEvent { !(prompt.request == nil) }
        do {
            _ = try await prompt.requestCode(SchoolSMSCodeRequest(maskedPhone: "", purpose: "webvpn"))
            Issue.record("并行请求应保留当前验证码等待")
        } catch { #expect(TaskCancellation.matches(error)) }
        #expect(prompt.request?.id == request.id)
        prompt.submit("123456")
        #expect(try await waiting.value == "123456")
        #expect(prompt.request == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationReleasesTheWaitAndAllowsTheNextChallenge() async throws {
        let prompt = ReleaseNetworkSmokeSMSPrompt()
        let request = SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "jwb")
        let waiting = Task { try await prompt.requestCode(request) }
        try await waitForTestEvent { !(prompt.request == nil) }
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("取消应终止验证码等待") }
        catch { #expect(TaskCancellation.matches(error)) }
        #expect(prompt.request == nil)
        let next = Task { try await prompt.requestCode(request) }
        try await waitForTestEvent { !(prompt.request == nil) }
        prompt.submit("654321")
        #expect(try await next.value == "654321")
        #expect(prompt.request == nil)
    }
}
#endif

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
        settings.resetToDefaults()
        #expect(settings.storageIssue == nil)
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

@Suite("App deep links")
struct AppDeepLinkRouteTests {
    @Test("Universal links route gallery and course details")
    func universalLinks() throws {
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/gallery/123"))) == .gallery(123))
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/course/456"))) == .course(456))
    }

    @Test("Custom links remain supported and foreign hosts are rejected")
    func customAndForeignLinks() throws {
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/courses"))) == .scheduleCourses)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/ddl"))) == .scheduleDDL)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/schedule/ddl"))) == .scheduleDDL)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://paper/7"))) == .paper(7))
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://example.com/gallery/123"))) == nil)
    }
}

@Suite("Image cache disk quota")
struct ImageCacheDiskQuotaTests {
    @Test("Quota pruning evicts least-recently-used entries and protects active files", .timeLimit(.minutes(1)))
    func prunesOldestFilesAndProtectsActiveEntry() async throws {
        let files = AppFileDirectories.files
        let directory = files.temporaryDirectoryURL.appending(
            path: "image-cache-quota",
            directoryHint: .isDirectory
        )
        try files.removeItemIfPresent(at: directory)
        try files.createDirectory(at: directory)
        defer {
            do {
                try files.removeItem(at: directory)
                #expect(!files.fileExists(at: directory))
            } catch { Issue.record(error) }
        }

        let oldest = directory.appending(path: "oldest.jpg")
        let middle = directory.appending(path: "middle.jpg")
        let protected = directory.appending(path: "protected.jpg")
        let imageData = Data(repeating: 1, count: 600_000)
        for file in [oldest, middle, protected] {
            try files.writeData(imageData, to: file, options: [.atomic])
        }
        try files.setModificationDate(Date(timeIntervalSince1970: 1), at: oldest)
        try files.setModificationDate(Date(timeIntervalSince1970: 2), at: middle)
        try files.setModificationDate(Date(timeIntervalSince1970: 3), at: protected)

        let quota = ImageCacheDiskQuota(
            files: files,
            directories: [directory],
            cacheLimitMB: { 1 },
            pruneInterval: 0
        )
        await quota.enforce(force: true, protecting: Set([protected]))

        #expect(!files.fileExists(at: oldest))
        #expect(!files.fileExists(at: middle))
        #expect(files.fileExists(at: protected))
    }
}

@Suite("Score cache file safety")
struct ScoreCacheDiskRepositoryTests {
    @Test("Unreadable score snapshots block replacement and remain intact", .timeLimit(.minutes(1)))
    func preservesUnreadableSnapshot() async throws {
        let files = AppFileDirectories.files
        let root = files.temporaryDirectoryURL.appending(
            path: "score-cache-safety",
            directoryHint: .isDirectory
        )
        try files.removeItemIfPresent(at: root)
        let session = AppStorageSession(accountIdentifier: "score-store")
        let repository = ScoreCacheDiskRepository(files: files, storageRoot: root)
        defer {
            do {
                try files.removeItem(at: root)
                #expect(!files.fileExists(at: root))
            } catch { Issue.record(error) }
        }

        let rows = [ScoreRow(index: 0, headers: ["课程名称"], values: ["离散数学"])]
        let saved = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: .empty
        )
        #expect(saved.isSaved)

        let fileURL = root
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
        let corruptData = Data("invalid score cache".utf8)
        try files.writeData(corruptData, to: fileURL, options: [.atomic])

        let loadResult = await repository.load(for: session, legacyData: .empty)
        #expect(loadResult.isUnreadable)

        let replacement = await repository.mutate(
            .rows([]),
            for: session,
            legacyData: .empty
        )
        #expect(replacement.isUnreadable)
        #expect(try files.readData(at: fileURL) == corruptData)
    }
}

nonisolated final class PreferenceMemoryFiles: AppFileService, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let requireExistingParentDirectories: Bool
    private let separatesDirectories: Bool
    private struct State {
        var data: [URL: Data] = [:]
        var revisions: [URL: UInt64] = [:]
        var revision: UInt64 = 0
        var reads: [URL: Int] = [:]
        var metadataScans = 0
        var directories: Set<URL> = []
        var failsRemoval = false
        var failsWriting = false
        var failsReading = false
        var failsMetadata = false
        var nextRead: (@Sendable () -> Void)?
        var nextWrite: (@Sendable () -> Void)?
        var nextEnumeration: (@Sendable () -> Void)?
    }
    init(requireExistingParentDirectories: Bool = false, separatesDirectories: Bool = false) {
        self.requireExistingParentDirectories = requireExistingParentDirectories
        self.separatesDirectories = separatesDirectories
    }
    func setFailures(removal: Bool = false, writing: Bool = false, reading: Bool = false, metadata: Bool = false) {
        state.withLock {
            $0.failsRemoval = removal; $0.failsWriting = writing; $0.failsReading = reading; $0.failsMetadata = metadata
        }
    }
    private var root: URL { URL(fileURLWithPath: "/preference-sync") }
    var temporaryDirectoryURL: URL { separatesDirectories ? root.appending(path: "Temporary") : root }
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        separatesDirectories ? root.appending(path: String(directory.rawValue)) : root
    }
    func appGroupContainerURL(identifier: String) -> URL? { temporaryDirectoryURL }
    func fileExists(at url: URL) -> Bool {
        state.withLock { !$0.failsMetadata && ($0.data[url] != nil || $0.directories.contains { $0.path == url.path }) }
    }
    func readData(at url: URL) throws -> Data {
        let intercept = state.withLock { state in
            let callback = state.nextRead
            state.nextRead = nil
            return callback
        }
        intercept?()
        return try state.withLock { state in
            state.reads[url, default: 0] += 1
            if state.failsReading { throw CocoaError(.fileReadNoPermission) }
            guard let value = state.data[url] else { throw CocoaError(.fileReadNoSuchFile) }
            return value
        }
    }
    func interceptNextRead(_ callback: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextRead = callback }
    }
    func writeData(_ value: Data, to url: URL, options: Data.WritingOptions) throws {
        let intercept = try state.withLock { state -> (@Sendable () -> Void)? in
            if state.failsWriting { throw CocoaError(.fileWriteNoPermission) }
            if requireExistingParentDirectories && !state.directories.contains(url.deletingLastPathComponent()) {
                throw CocoaError(.fileNoSuchFile)
            }
            state.data[url] = value
            state.revision &+= 1
            state.revisions[url] = state.revision
            let callback = state.nextWrite
            state.nextWrite = nil
            return callback
        }
        intercept?()
    }
    func interceptNextWrite(_ callback: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextWrite = callback }
    }
    func removeItem(at url: URL) throws {
        try state.withLock { state in
            if state.failsRemoval { throw CocoaError(.fileWriteNoPermission) }
            let prefix = url.path + "/"
            state.data = state.data.filter { $0.key.path != url.path && !$0.key.path.hasPrefix(prefix) }
            state.revisions = state.revisions.filter { state.data[$0.key] != nil }
            state.directories = state.directories.filter { $0.path != url.path && !$0.path.hasPrefix(prefix) }
        }
    }
    func createDirectory(at url: URL) throws {
        state.withLock { state in
            var directory = url
            while directory.path != "/" {
                state.directories.insert(directory)
                directory.deleteLastPathComponent()
            }
        }
    }
    func setPrivateFileProtection(at url: URL) throws {}
    func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws {}
    func beforeNextEnumeration(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextEnumeration = action }
    }
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        let intercept = state.withLock { state in
            let callback = state.nextEnumeration
            state.nextEnumeration = nil
            return callback
        }
        intercept?()
        return state.withLock { state in
            Array(Set(state.data.keys).union(state.directories)).filter {
                $0.deletingLastPathComponent().path == url.path &&
                    (!options.contains(.skipsHiddenFiles) || !$0.lastPathComponent.hasPrefix("."))
            }
        }
    }
    func regularFileSize(at url: URL) -> Int? { state.withLock { $0.data[url]?.count } }
    var metadataScanCount: Int { state.withLock { $0.metadataScans } }
    func regularFileMetadata(in directory: URL) throws -> [AppRegularFileMetadata] {
        state.withLock { $0.metadataScans += 1 }
        return try contentsOfDirectory(at: directory, options: .skipsHiddenFiles).compactMap { url in
            regularFileSize(at: url).map { AppRegularFileMetadata(url: canonicalFileURL(url), size: $0,
                modificationDate: modificationDate(at: url) ?? .distantPast) }
        }
    }
    func isRegularFile(at url: URL) -> Bool { regularFileSize(at: url) != nil }
    func readCount(at url: URL) -> Int { state.withLock { $0.reads[url] ?? 0 } }
    func atomicFileIdentity(at url: URL) -> String? {
        state.withLock { state in state.data[url].flatMap { _ in state.revisions[url].map(String.init) } }
    }
    func modificationDate(at url: URL) -> Date? { nil }
    func setModificationDate(_ date: Date, at url: URL) throws {}
    func removeContents(of directory: URL) -> Bool {
        return state.withLock { state in
            let hasContents = state.data.keys.contains { $0.path.hasPrefix(directory.path + "/") } ||
                state.directories.contains { $0.path.hasPrefix(directory.path + "/") }
            guard hasContents else { return true }
            guard !state.failsRemoval else { return false }
            state.data = state.data.filter { !$0.key.path.hasPrefix(directory.path + "/") }
            state.revisions = state.revisions.filter { state.data[$0.key] != nil }
            state.directories = state.directories.filter { !$0.path.hasPrefix(directory.path + "/") }
            return true
        }
    }
    func totalRegularFileSize(at directory: URL) -> Int64 {
        return state.withLock { state in
            return state.data.filter { $0.key.path.hasPrefix(directory.path + "/") }.values.reduce(0) { $0 + Int64($1.count) }
        }
    }
}

@Suite("Login bootstrap behavior")
struct LoginBootstrapTests {
    private final class LoginServiceStub: LoginServicing {
        var sessionChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        enum CheckResult {
            case signedOut
            case failed
        }

        let savedStudentID: String
        let savedPassword = "saved-password"
        let hasCachedSession: Bool
        let checkResult: CheckResult
        private(set) var checkLoginCalls = 0

        init(
            studentID: String = "1120260001",
            hasCachedSession: Bool = true,
            checkResult: CheckResult
        ) {
            savedStudentID = studentID
            self.hasCachedSession = hasCachedSession
            self.checkResult = checkResult
        }

        func checkLogin() async throws -> String? {
            checkLoginCalls += 1
            switch checkResult {
            case .signedOut: return nil
            case .failed: throw URLError(.notConnectedToInternet)
            }
        }

        func login(studentID: String, password: String) async throws -> String { studentID }
        func loginCommunity(studentID: String, password: String) async throws -> String { studentID }
        func logout() {}
    }

    @Test("Cached sessions show the app shell before network validation")
    func cachedSessionIsOptimistic() {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .failed))
        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
    }

    @Test("Without a cached session the app starts signed out")
    func missingCachedSessionStartsSignedOut() {
        let service = LoginServiceStub(hasCachedSession: false, checkResult: .failed)
        let viewModel = LoginViewModel(service: service)

        #expect(viewModel.screenState == .signedOut)
        #expect(service.checkLoginCalls == 0)
    }

    @Test("Transient validation failures stay silent and signed in", .timeLimit(.minutes(1)))
    func transientFailureKeepsSession() async {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .failed))
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
        #expect(viewModel.alert == nil)
    }

    @Test("Only an explicit signed-out response dismisses the app shell", .timeLimit(.minutes(1)))
    func explicitSignOutDismissesSession() async {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .signedOut))
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.screenState == .signedOut)
    }
}

@Suite("Shared infrastructure")
struct InfrastructureTests {
    @Test(.timeLimit(.minutes(1))) func eventWaitEnforcesDeadlineCancellationAndActorIsolation() async throws {
        await #expect(throws: URLError.self) { try await waitForTestEvent(timeout: .zero) { true } }
        await #expect(throws: URLError.self) { try await waitForTestEvent(timeout: .milliseconds(5)) { false } }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await waitForTestEvent { false }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        actor State { var complete = true }
        try await waitForTestEvent(isolation: State()) { $0.complete }
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

    private nonisolated struct TestItem: Identifiable, Equatable {
        let id: Int
    }

    private struct TestPagedState: PagedItemsState {
        var pagedItems = CommunityPagedItems<TestItem>()
        var nextPage = 0
        var isLoadingMore = false
        var canLoadMore = true
    }

    private struct TestCursorState: CursorPagedItemsState {
        var pagedItems = CommunityPagedItems<TestItem>()
        var nextCursor: Int?
        var isLoadingMore = false
        var canLoadMore = true
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

    @Test("Paged state advances and stops on an empty page")
    func pagedStateAdvancesAndStops() {
        var state = TestPagedState()

        state.applyFirstPage([TestItem(id: 1), TestItem(id: 2)])
        #expect(state.nextPage == 1)
        #expect(state.shouldLoadMore(currentID: 2))

        state.isLoadingMore = true
        #expect(!state.shouldLoadMore(currentID: 2))

        state.appendPage([])
        #expect(state.nextPage == 2)
        #expect(!state.canLoadMore)

        state.resetPagination()
        #expect(state.items.isEmpty)
        #expect(state.nextPage == 0)
        #expect(state.canLoadMore)
    }

    @Test("Cursor state preserves backend cursor semantics")
    func cursorStateAdvancesAndStops() {
        var state = TestCursorState()

        state.applyFirstCursorPage([TestItem(id: 10), TestItem(id: 9)])
        #expect(state.nextCursor == 9)
        #expect(state.shouldLoadMore(currentID: 9))

        state.appendCursorPage([TestItem(id: 9), TestItem(id: 8), TestItem(id: 8)])
        #expect(state.items.map(\.id) == [10, 9, 8])
        #expect(state.nextCursor == 8)

        state.appendCursorPage([TestItem(id: 8)])
        #expect(state.items.map(\.id) == [10, 9, 8])
        #expect(!state.canLoadMore)
        state.appendCursorPage([])
        #expect(state.nextCursor == 8)
        #expect(!state.canLoadMore)

        state.resetCursorPagination()
        #expect(state.items.isEmpty)
        #expect(state.nextCursor == nil)
        #expect(state.canLoadMore)
    }
}

@Suite("Composer draft storage")
struct ComposerDraftStorageTests {
    @Test("Persisted image assets are bounded JPEG data")
    func persistedImageSizeAndEncoding() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let source = renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }

        let persisted = try ComposerDraftImageCompressor.compress(source)
        #expect(persisted.count <= ComposerDraftImageCompressor.maximumBytes)
        #expect(UIImage(data: persisted) != nil)
    }
}

@Suite("Score presentation logic", .serialized)
struct ScorePresentationTests {
    @Test func serviceFailuresProvidePresentationDetails() {
        let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token",
            status: "sms_required", maskedPhone: nil, expiresIn: 120)
        for error in [ScoreServiceError.missingCredentials, .invalidResponse, .requestTimedOut, .secondFactorRequired(challenge)] {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(ScoreServiceError.challengeInvalid("认证上下文已变化").errorDescription == "认证上下文已变化")
        #expect(ScoreServiceError.queryFailed("课程查询失败").errorDescription == "课程查询失败")
    }

    @Test("Successful empty score response returns an empty result")
    func successfulEmptyScoreResponse() throws {
        let response = Data(#"{"msg":"查询成功OvO","data":[]}"#.utf8)

        #expect(try ScoreService.decodeScoreRows(response).isEmpty)
    }

    @Test("Empty score response preserves the server failure message")
    func emptyScoreFailureMessage() {
        let response = Data(#"{"msg":"成绩服务暂不可用","data":[]}"#.utf8)

        #expect(throws: ScoreServiceError.self) {
            try ScoreService.decodeScoreRows(response)
        }
    }

}

nonisolated final class KeyboardAccessoryOwnershipTests: XCTestCase {
    @MainActor
    func testAccessoryActionSurvivesCoordinatorReplacement() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let inputs: [UIView & UITextInput] = [
            UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44)),
            UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
        ]
        for input in inputs {
            var owner: KeyboardBackgroundTapInstaller.Coordinator? = .init()
            owner?.attach(to: window)
            window.addSubview(input)
            defer { input.resignFirstResponder(); input.removeFromSuperview() }
            XCTAssertTrue(input.becomeFirstResponder())
            try await waitForTestEvent { input.inputAccessoryView is UIToolbar }
            let toolbar = try XCTUnwrap(input.inputAccessoryView as? UIToolbar)
            let button = try XCTUnwrap(toolbar.items?.first { $0.accessibilityIdentifier == "keyboard.dismiss" })
            owner?.detach()
            owner = nil
            var replacement: KeyboardBackgroundTapInstaller.Coordinator? = .init()
            replacement?.attach(to: window)
            await Task.yield()
            replacement?.detach()
            replacement = nil
            XCTAssertNotNil(button.customView, "键盘附件动作应与输入控件共享存活期。")
            XCTAssertTrue(input.inputAccessoryView === toolbar)
            try XCTUnwrap(button.customView as? UIButton).sendActions(for: .touchUpInside)
            XCTAssertFalse(input.isFirstResponder)
        }
    }
    @MainActor
    func testGlobalKeyboardAccessory() async throws {
        let coordinator = KeyboardBackgroundTapInstaller.Coordinator()
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        )
        coordinator.attach(to: window)
        defer { coordinator.detach() }
        let inputs: [UIView & UITextInput] = [
            UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44)),
            UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
        ]
        for input in inputs {
            window.addSubview(input)
            defer {
                input.resignFirstResponder()
                input.removeFromSuperview()
            }
            XCTAssertTrue(input.becomeFirstResponder())
            await Task.yield()
            XCTAssertTrue(input.inputAccessoryView is UIToolbar)
            let original = try XCTUnwrap(input.inputAccessoryView as? UIToolbar)
            XCTAssertTrue(input.resignFirstResponder())
            if let field = input as? UITextField { field.inputAccessoryView = nil }
            if let view = input as? UITextView { view.inputAccessoryView = nil }
            XCTAssertTrue(input.becomeFirstResponder())
            try await waitForTestEvent { input.inputAccessoryView is UIToolbar }
            let toolbar = try XCTUnwrap(input.inputAccessoryView as? UIToolbar)
            XCTAssertTrue(toolbar === original, "键盘附件恢复应保留原控件及其动作身份。")
            NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
            await Task.yield()
            XCTAssertTrue(input.inputAccessoryView === toolbar, "键盘显示周期应保留已安装的附件。")
            let buttons = toolbar.items?.filter { $0.accessibilityIdentifier == "keyboard.dismiss" } ?? []
            XCTAssertEqual(buttons.count, 1)
            let button = try XCTUnwrap(buttons.first)
            try XCTUnwrap(button.customView as? UIButton).sendActions(for: .touchUpInside)
            XCTAssertFalse(input.isFirstResponder)
        }
    }

}
