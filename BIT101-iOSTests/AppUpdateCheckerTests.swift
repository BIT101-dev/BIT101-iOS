import Foundation
import Testing
import StorageCore
import CommunityTransport
@testable import BIT101_iOS

@MainActor
@Suite("App Store update reminder", .serialized)
struct AppUpdateCheckerTests {
    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func notificationPermissionChecksKeepTheirAccountGeneration(change: Int) async throws {
        var identity = CommunitySessionIdentity(accountIdentifier: "first", generation: 1)
        var pending: CheckedContinuation<Bool, Never>?
        let task = Task {
            await AppAccountLifecycle.scheduleNotificationPromptAccount(currentIdentity: { identity }, isDenied: {
                await withCheckedContinuation { pending = $0 }
            })
        }
        defer { task.cancel(); pending?.resume(returning: false) }
        try await waitForTestEvent { pending != nil }
        if change == 0 { identity = .init(accountIdentifier: "second", generation: 2) }
        if change == 1 { identity = .init(accountIdentifier: "first", generation: 2) }
        if change == 2 { task.cancel() }
        let continuation = try #require(pending); pending = nil
        continuation.resume(returning: true)
        #expect(await task.value == nil)
        #expect(await AppAccountLifecycle.scheduleNotificationPromptAccount(currentIdentity: { identity }, isDenied: { true }) == identity)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func launchChecksUseTheSelectedSettingsInstance(enabled: Bool) async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        let settings = AppSettingsStore(defaults: context.defaults)
        settings.setAutomaticUpdateChecksEnabled(enabled)
        var requests = 0
        let checker = AppUpdateChecker(defaults: context.defaults, now: { context.now }, installedVersion: { "1.7.0" },
            loadData: { request in
                requests += 1
                return try Self.lookupResponse(for: try #require(request.url))
            })
        let coordinator = AppUpdatePromptCoordinator(settings: settings, checker: checker,
            emergencyChecker: EmergencyUpdateChecker(defaults: context.defaults, endpointURL: { nil }))
        _ = await coordinator.noticeToPresentAtLaunch()
        #expect(requests == (enabled ? 1 : 0))
        #expect(await coordinator.noticeToPresentAtLaunch() == nil)
        #expect(requests == (enabled ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func overlappingLaunchAndManualLookupsPreserveTheLatestSuccessfulResponse(manualFails: Bool) async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var pending: CheckedContinuation<(Data, URLResponse), any Error>?
        var initialURL: URL?
        var requests = 0
        let checker = AppUpdateChecker(defaults: context.defaults, now: { context.now }, installedVersion: { "1.7.0" }, loadData: { request in
            requests += 1
            let url = try #require(request.url)
            if requests == 1 {
                initialURL = url
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            if manualFails { throw URLError(.notConnectedToInternet) }
            return try Self.lookupResponse(for: url, version: "1.8.0")
        })
        let launch = Task { await checker.releaseToPresentAtLaunch() }
        defer { pending?.resume(throwing: CancellationError()); launch.cancel() }
        try await waitForTestEvent { pending != nil }
        if manualFails {
            await #expect(throws: URLError.self) { try await checker.checkManually() }
        } else {
            guard case let .update(release) = try await checker.checkManually() else {
                Issue.record("手动检查应展示新版本"); return
            }
            #expect(release.version == "1.8.0")
        }
        let continuation = try #require(pending)
        pending = nil
        continuation.resume(returning: try Self.lookupResponse(for: try #require(initialURL), version: "1.7.1"))
        let expected = manualFails ? "1.7.1" : "1.8.0"
        let presented = await launch.value
        #expect(presented?.version == expected)
        let cached = try JSONDecoder().decode(AppStoreRelease.self, from: #require(context.defaults.data(forKey: AppUpdateChecker.cachedReleaseKey)))
        #expect(cached.version == expected)
        let subsequent = await checker.releaseToPresentAtLaunch()
        #expect(subsequent?.version == expected && requests == 2)
    }

    @Test func accountPromptsCancelQueuedAndActiveRequestsAcrossAccountChanges() throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let first = CommunitySessionIdentity(accountIdentifier: "first", generation: 1)
        let second = CommunitySessionIdentity(accountIdentifier: "second", generation: 2)
        var actions = 0, dismissals = 0
        func prompt(_ account: CommunitySessionIdentity, id: String = "thanks") -> AppPrompt {
            AppPrompt(id: id, title: "fixture", message: "fixture",
                actions: [AppPromptAction(id: "confirm", title: "fixture") { actions += 1 }],
                account: account, onDismiss: { dismissals += 1 })
        }
        let a = prompt(first)
        prompts.enqueue(a)
        prompts.enqueue(prompt(first, id: "queued"))
        prompts.enqueue(AppPrompt(id: "global", title: "fixture", message: "fixture", actions: []))
        prompts.accountDidChange(to: second)
        #expect(prompts.activePrompt?.id == "global")
        prompts.perform(try #require(a.actions.first), promptID: a.id)
        #expect(actions == 0 && dismissals == 0)
        prompts.alertPresentationChanged(isPresented: false, promptID: "global")
        #expect(prompts.activePrompt == nil)
        let b = prompt(second)
        prompts.enqueue(b)
        #expect(b.id != a.id && prompts.activePrompt?.id == b.id)
        prompts.perform(try #require(b.actions.first), promptID: b.id)
        #expect(actions == 1 && dismissals == 1)
        let returned = prompt(CommunitySessionIdentity(accountIdentifier: "first", generation: 3))
        prompts.enqueue(returned)
        prompts.alertPresentationChanged(isPresented: false, promptID: a.id)
        #expect(prompts.activePrompt?.id == returned.id)
    }

    @Test(.timeLimit(.minutes(1))) func accountChangesReleaseActiveAndQueuedPromptWaiters() async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        prompts.markHostReady()
        let account = CommunitySessionIdentity(accountIdentifier: "first", generation: 1)
        let active = AppPrompt(id: "active", title: "fixture", message: "fixture", actions: [], account: account)
        let queued = AppPrompt(id: "queued", title: "fixture", message: "fixture", actions: [], account: account)
        prompts.enqueue(active)
        var activeStarted = false, queuedStarted = false, completed = 0
        let activeWaiter = Task { @MainActor in
            activeStarted = true
            await prompts.enqueueAndWait(active)
            completed += 1
        }
        let queuedWaiter = Task { @MainActor in
            queuedStarted = true
            await prompts.enqueueAndWait(queued)
            completed += 1
        }
        try await waitForTestEvent { !(!activeStarted || !queuedStarted) }
        prompts.accountDidChange(to: CommunitySessionIdentity(accountIdentifier: "second", generation: 2))
        await activeWaiter.value
        await queuedWaiter.value
        #expect(completed == 2 && prompts.activePrompt == nil)
    }

    @Test func thanksAcknowledgmentKeepsItsCapturedAccount() throws {
        let domain = "bit101-prompt-account-contract"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = AppStorageSession(accountIdentifier: "first")
        let second = AppStorageSession(accountIdentifier: "second")
        var session = first
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        session = second
        settings.reloadForCurrentAccount()
        #expect(!settings.markLinuxDoThanksNoticeShown(for: first))
        #expect(!settings.snapshot.hasShownLinuxDoThanksNotice)
        #expect(settings.markLinuxDoThanksNoticeShown(for: second))
        #expect(settings.snapshot.hasShownLinuxDoThanksNotice)
        session = first
        settings.reloadForCurrentAccount()
        #expect(!settings.snapshot.hasShownLinuxDoThanksNotice)
        #expect(settings.markLinuxDoThanksNoticeShown(for: first))
        settings.reloadForCurrentAccount()
        #expect(settings.snapshot.hasShownLinuxDoThanksNotice)
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["foreign", "downgrade", "port", "credentials"])
    func updateJSONFromAnotherOriginKeepsBothPromptsUnpublished(_ scenario: String) async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        func redirected(_ url: URL) throws -> URL {
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            switch scenario {
            case "foreign": components.host = "foreign.invalid"
            case "downgrade": components.scheme = "http"
            case "port": components.port = 8443
            default: components.user = "unexpected"
            }
            return try #require(components.url)
        }
        let store = AppUpdateChecker(defaults: context.defaults, installedVersion: { "1.0" }, loadData: { request in
            try Self.lookupResponse(for: redirected(try #require(request.url)))
        })
        await #expect(throws: URLError.self) { try await store.checkManually() }
        #expect(context.defaults.data(forKey: AppUpdateChecker.cachedReleaseKey) == nil)
        let endpoint = try #require(URL(string: "https://example.com/emergency-update.json"))
        let emergency = EmergencyUpdateChecker(defaults: context.defaults, installedBuild: { 1 }, endpointURL: { endpoint }, loadData: { request in
            try Self.emergencyResponse(for: redirected(try #require(request.url)), maximumBuild: 2)
        })
        #expect(await emergency.noticeToPresentAtLaunch() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func dismissalDelayAndPromptIdentityProtectTheNextPrompt() async throws {
        let coordinator = AppPromptCoordinator()
        var performed: [String] = []
        func prompt(_ id: String) -> AppPrompt {
            AppPrompt(id: id, title: id, message: id,
                actions: [AppPromptAction(id: "confirm", title: "确定") { performed.append(id) }])
        }
        coordinator.enqueue(prompt("first"))
        let first = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(first, promptID: "first")
        coordinator.enqueue(prompt("second"))
        #expect(coordinator.activePrompt == nil)
        coordinator.alertPresentationChanged(isPresented: false, promptID: "first")
        try await waitForTestEvent { !(coordinator.activePrompt == nil) }
        #expect(coordinator.activePrompt?.id == "second")
        coordinator.alertPresentationChanged(isPresented: false, promptID: "first")
        coordinator.perform(first, promptID: "first")
        #expect(coordinator.activePrompt?.id == "second")
        #expect(performed == ["first"])
        coordinator.perform(try #require(coordinator.activePrompt?.actions.first), promptID: "second")
        #expect(performed == ["first", "second"])
    }

    @Test("Emergency notices target Build numbers and can only be ignored today", .timeLimit(.minutes(1)))
    func emergencyNoticeEligibility() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        let endpoint = try #require(URL(string: "https://example.com/emergency-update.json"))
        let checker = EmergencyUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedBuild: { 32 },
            endpointURL: { endpoint },
            loadData: { request in
                #expect(request.timeoutInterval == 5)
                return try Self.emergencyResponse(for: try #require(request.url), maximumBuild: 32)
            }
        )

        let notice = try #require(await checker.noticeToPresentAtLaunch())
        #expect(notice.noticeID == "network-fix")
        checker.ignoreForToday(noticeID: notice.noticeID)
        #expect(await checker.noticeToPresentAtLaunch() == nil)

        context.now.addTimeInterval(24 * 60 * 60)
        #expect(await checker.noticeToPresentAtLaunch()?.noticeID == "network-fix")
    }

    @Test("Emergency notice suppresses the ordinary App Store prompt", .timeLimit(.minutes(1)))
    func emergencyNoticeHasPriority() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        let endpoint = try #require(URL(string: "https://example.com/emergency-update.json"))
        let storeChecker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in try Self.lookupResponse(for: try #require(request.url)) }
        )
        let emergencyChecker = EmergencyUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedBuild: { 31 },
            endpointURL: { endpoint },
            loadData: { request in
                try Self.emergencyResponse(for: try #require(request.url), maximumBuild: 31)
            }
        )
        let coordinator = AppUpdatePromptCoordinator(
            settings: AppSettingsStore(defaults: context.defaults),
            checker: storeChecker,
            emergencyChecker: emergencyChecker
        )

        guard case let .emergency(notice) = await coordinator.noticeToPresentAtLaunch() else {
            Issue.record("Expected the emergency notice to win")
            return
        }
        #expect(notice.maximumAffectedBuild == 31)
        #expect(await coordinator.noticeToPresentAtLaunch() == nil)
    }

    @Test("Builds newer than the emergency threshold are unaffected", .timeLimit(.minutes(1)))
    func emergencyNoticeDoesNotAffectNewBuilds() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        let endpoint = try #require(URL(string: "https://example.com/emergency-update.json"))
        let checker = EmergencyUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedBuild: { 33 },
            endpointURL: { endpoint },
            loadData: { request in
                try Self.emergencyResponse(for: try #require(request.url), maximumBuild: 32)
            }
        )
        #expect(await checker.noticeToPresentAtLaunch() == nil)
    }

    @Test("Automatic App Store reminders wait until the release is seven days old", .timeLimit(.minutes(1)))
    func automaticReminderWaitsSevenDays() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var currentVersionReleaseDate = context.now.addingTimeInterval(-AppUpdateChecker.minimumReleaseAge + 1)

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in
                try Self.lookupResponse(
                    for: try #require(request.url),
                    currentVersionReleaseDate: ISO8601DateFormatter().string(from: currentVersionReleaseDate)
                )
            }
        )

        #expect(await checker.releaseToPresentAtLaunch() == nil)

        context.now.addTimeInterval(AppUpdateChecker.queryInterval + 1)
        currentVersionReleaseDate = context.now.addingTimeInterval(-AppUpdateChecker.minimumReleaseAge)
        #expect(await checker.releaseToPresentAtLaunch()?.version == "1.7.1")
    }

    @Test("Global prompt coordinator presents one prompt at a time in queue order")
    func promptQueueIsSerial() throws {
        let coordinator = AppPromptCoordinator(advanceDelay: .zero)
        var presented: [String] = []
        var performed: [String] = []

        func prompt(_ id: String) -> AppPrompt {
            AppPrompt(
                id: id,
                title: id,
                message: id,
                actions: [
                    AppPromptAction(id: "confirm", title: "确定") {
                        performed.append(id)
                    }
                ],
                onPresent: {
                    presented.append(id)
                }
            )
        }

        coordinator.enqueue(prompt("first"))
        coordinator.enqueue(prompt("second"))
        coordinator.enqueue(prompt("second"))

        #expect(coordinator.activePrompt?.id == "first")
        #expect(presented == ["first"])

        let firstAction = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(firstAction, promptID: coordinator.activePrompt?.id)

        #expect(coordinator.activePrompt?.id == "second")
        #expect(presented == ["first", "second"])
        #expect(performed == ["first"])

        let secondAction = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(secondAction, promptID: coordinator.activePrompt?.id)

        #expect(coordinator.activePrompt == nil)
        #expect(performed == ["first", "second"])
    }

    @Test("A network prompt gate releases its request after dismissal", .timeLimit(.minutes(1)))
    func promptGateWaitsForDismissal() async throws {
        let coordinator = AppPromptCoordinator(advanceDelay: .zero)
        coordinator.markHostReady()
        let prompt = AppPrompt(
            id: "network-gate",
            title: "检测到可能在使用魔法",
            message: "关闭食用效果更佳～",
            actions: [AppPromptAction(id: "dismiss", title: "知道了") {}]
        )

        let gate = Task { @MainActor in
            await coordinator.enqueueAndWait(prompt)
        }
        await Task.yield()
        #expect(coordinator.activePrompt?.id == "network-gate")
        #expect(!gate.isCancelled)

        let action = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(action, promptID: coordinator.activePrompt?.id)
        await gate.value
        #expect(coordinator.activePrompt == nil)
    }

    @Test("Version comparison treats each component numerically")
    func numericVersionComparison() {
        #expect(AppVersionComparison.isNewer("1.10.0", than: "1.9.9"))
        #expect(AppVersionComparison.isNewer("2.0.0", than: "1.99.99"))
        #expect(!AppVersionComparison.isNewer("1.7.1", than: "1.7.1"))
        #expect(!AppVersionComparison.isNewer("1.7.0", than: "1.7.1"))
    }

    @Test("A successful lookup caches release notes and avoids another request for 24 hours", .timeLimit(.minutes(1)))
    func lookupIsCachedForOneDay() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var requestCount = 0

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in
                requestCount += 1
                #expect(request.url?.host == "itunes.apple.com")
                #expect(request.url?.query?.contains("requestTime=") == true)
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                return try Self.lookupResponse(for: try #require(request.url))
            }
        )

        let first = await checker.releaseToPresentAtLaunch()
        let second = await checker.releaseToPresentAtLaunch()

        #expect(requestCount == 1)
        #expect(first?.version == "1.7.1")
        #expect(first?.updateMessage == "修复问题并优化体验。")
        #expect(second == first)

        context.now.addTimeInterval(AppUpdateChecker.queryInterval + 1)
        let third = await checker.releaseToPresentAtLaunch()

        #expect(requestCount == 2)
        #expect(third == first)
    }

    @Test("Once presented the same release stays hidden for 24 hours", .timeLimit(.minutes(1)))
    func presentationCooldown() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var requestCount = 0

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in
                requestCount += 1
                return try Self.lookupResponse(for: try #require(request.url))
            }
        )

        let release = try #require(await checker.releaseToPresentAtLaunch())
        checker.markPresented(version: release.version)
        #expect(await checker.releaseToPresentAtLaunch() == nil)
        #expect(requestCount == 1)

        context.now.addTimeInterval(AppUpdateChecker.queryInterval + 1)
        #expect(await checker.releaseToPresentAtLaunch()?.version == "1.7.1")
        #expect(requestCount == 2)
    }

    @Test("Ignoring one store version keeps it hidden but does not hide a later version", .timeLimit(.minutes(1)))
    func ignoredVersionIsScopedToThatRelease() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var storeVersion = "1.7.1"

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in
                try Self.lookupResponse(for: try #require(request.url), version: storeVersion)
            }
        )

        let release = try #require(await checker.releaseToPresentAtLaunch())
        checker.ignore(version: release.version)
        #expect(await checker.releaseToPresentAtLaunch() == nil)

        storeVersion = "1.7.2"
        context.now.addTimeInterval(AppUpdateChecker.queryInterval + 1)
        #expect(await checker.releaseToPresentAtLaunch()?.version == "1.7.2")
    }

    @Test("Failed lookups are throttled and never block startup", .timeLimit(.minutes(1)))
    func failedLookupIsThrottled() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var requestCount = 0

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { _ in
                requestCount += 1
                throw URLError(.notConnectedToInternet)
            }
        )

        #expect(await checker.releaseToPresentAtLaunch() == nil)
        #expect(await checker.releaseToPresentAtLaunch() == nil)
        #expect(requestCount == 1)
    }

    @Test("Manual lookup bypasses the automatic 24-hour query gate", .timeLimit(.minutes(1)))
    func manualLookupBypassesAutomaticQueryGate() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var requestCount = 0

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in
                requestCount += 1
                return try Self.lookupResponse(for: try #require(request.url))
            }
        )

        _ = await checker.releaseToPresentAtLaunch()
        let result = try await checker.checkManually()

        #expect(result == .update(AppStoreRelease(
            version: "1.7.1",
            releaseNotes: "修复问题并优化体验。",
            currentVersionReleaseDate: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"),
            trackViewURL: URL(string: "https://apps.apple.com/cn/app/bit101/id6761147125?uo=4")
        )))
        #expect(requestCount == 2)
    }

    @Test("Manual lookup reports the installed version as current", .timeLimit(.minutes(1)))
    func manualLookupReportsCurrentVersion() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.1" },
            loadData: { request in
                try Self.lookupResponse(for: try #require(request.url), version: "1.7.1")
            }
        )

        let result = try await checker.checkManually()
        #expect(result == .current)
    }

    @Test(.timeLimit(.minutes(1))) func cachedInitialStorePublicationDateRequiresARefreshBeforeAutomaticPresentation() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        let old = try JSONSerialization.data(withJSONObject: ["version": "9.0", "releaseDate": 0,
            "trackViewURL": BIT101AppStore.url.absoluteString])
        context.defaults.set(old, forKey: AppUpdateChecker.cachedReleaseKey)
        context.defaults.set(context.now, forKey: AppUpdateChecker.lastAttemptKey)
        var requests = 0
        let checker = AppUpdateChecker(defaults: context.defaults, now: { context.now }, installedVersion: { "1.0" },
            loadData: { request in
                requests += 1
                return try Self.lookupResponse(for: try #require(request.url))
            })
        #expect(await checker.releaseToPresentAtLaunch() == nil)
        #expect(requests == 0)
    }

    @Test func lookupParserRequiresTheCurrentVersionDateUsedByProductionAndSmoke() throws {
        let data = try Self.lookupResponse(for: BIT101AppStore.url).0
        let parsed = try AppStoreLookup.parse(data)
        #expect(parsed.release.currentVersionReleaseDate == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let invalid = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "2026-01-01T00:00:00Z", with: "invalid-date").utf8)
        #expect(throws: URLError.self) { try AppStoreLookup.parse(invalid) }
    }

    private static func lookupResponse(
        for url: URL,
        version: String = "1.7.1",
        currentVersionReleaseDate: String = "2026-01-01T00:00:00Z"
    ) throws -> (Data, URLResponse) {
        let data = Data("""
        {
          "resultCount": 1,
          "results": [{
            "version": "\(version)",
            "releaseNotes": "修复问题并优化体验。",
            "releaseDate": "2025-01-01T00:00:00Z",
            "currentVersionReleaseDate": "\(currentVersionReleaseDate)",
            "bundleId": "BIT101-dev.BIT101-iOS",
            "trackViewUrl": "https://apps.apple.com/cn/app/bit101/id6761147125?uo=4"
          }]
        }
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }

    private static func emergencyResponse(
        for url: URL,
        maximumBuild: Int
    ) throws -> (Data, URLResponse) {
        let data = Data("""
        {
          "schema_version": 1,
          "enabled": true,
          "notice_id": "network-fix",
          "maximum_affected_build": \(maximumBuild),
          "title": "发现重要功能更新",
          "message": "请尽快更新。",
          "update_url": "https://apps.apple.com/cn/app/bit101/id6761147125"
        }
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }

    private final class TestContext {
        let suiteName = "AppUpdateCheckerTests"
        let defaults: UserDefaults
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
