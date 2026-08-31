import Foundation
import Testing
@testable import BIT101_iOS

@MainActor
@Suite("App Store update reminder")
struct AppUpdateCheckerTests {
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
        coordinator.perform(firstAction)

        #expect(coordinator.activePrompt?.id == "second")
        #expect(presented == ["first", "second"])
        #expect(performed == ["first"])

        let secondAction = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(secondAction)

        #expect(coordinator.activePrompt == nil)
        #expect(performed == ["first", "second"])
    }

    @Test("Version comparison treats each component numerically")
    func numericVersionComparison() {
        #expect(AppVersionComparison.isNewer("1.10.0", than: "1.9.9"))
        #expect(AppVersionComparison.isNewer("2.0.0", than: "1.99.99"))
        #expect(!AppVersionComparison.isNewer("1.7.1", than: "1.7.1"))
        #expect(!AppVersionComparison.isNewer("1.7.0", than: "1.7.1"))
    }

    @Test("A successful lookup caches release notes and avoids another request for 24 hours")
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
                return try Self.lookupResponse(for: request.url!)
            }
        )

        let first = await checker.releaseToPresentAtLaunch()
        let second = await checker.releaseToPresentAtLaunch()

        #expect(requestCount == 1)
        #expect(first?.version == "1.7.1")
        #expect(first?.updateMessage == "修复问题并优化体验。")
        #expect(second == first)
    }

    @Test("Once presented the same release stays hidden for 24 hours")
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
                return try Self.lookupResponse(for: request.url!)
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

    @Test("Ignoring one store version keeps it hidden but does not hide a later version")
    func ignoredVersionIsScopedToThatRelease() async throws {
        let context = try TestContext()
        defer { context.cleanUp() }
        var storeVersion = "1.7.1"

        let checker = AppUpdateChecker(
            defaults: context.defaults,
            now: { context.now },
            installedVersion: { "1.7.0" },
            loadData: { request in
                try Self.lookupResponse(for: request.url!, version: storeVersion)
            }
        )

        let release = try #require(await checker.releaseToPresentAtLaunch())
        checker.ignore(version: release.version)
        #expect(await checker.releaseToPresentAtLaunch() == nil)

        storeVersion = "1.7.2"
        context.now.addTimeInterval(AppUpdateChecker.queryInterval + 1)
        #expect(await checker.releaseToPresentAtLaunch()?.version == "1.7.2")
    }

    @Test("Failed lookups are throttled and never block startup")
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

    private static func lookupResponse(
        for url: URL,
        version: String = "1.7.1"
    ) throws -> (Data, URLResponse) {
        let data = Data("""
        {
          "resultCount": 1,
          "results": [{
            "version": "\(version)",
            "releaseNotes": "修复问题并优化体验。",
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

    private final class TestContext {
        let suiteName = "AppUpdateCheckerTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
