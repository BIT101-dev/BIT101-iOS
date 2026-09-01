#if RELEASE_NETWORK_SMOKE
import XCTest
@testable import BIT101_iOS

/// 发布前真机网络冒烟测试。
///
/// 这份测试仅作为共享 runner 的回归壳层；正式 App 的当前登录态冒烟由同一份 runner
/// 通过 `bit101://network-smoke/...` 在主进程内执行。
@MainActor
final class ReleaseNetworkSmokeTests: XCTestCase {
    private var scope: NetworkSmokeScope {
#if SMOKE_BIT101
        return .bit101
#elseif SMOKE_SCHOOL
        return .school
#else
        return NetworkSmokeScope(
            rawValue: ProcessInfo.processInfo.environment["BIT101_NETWORK_SMOKE_SCOPE"] ?? "all"
        ) ?? .all
#endif
    }

    func testReadOnlyUserNetworkFlows() async throws {
        let report = await ReleaseNetworkSmokeRunner().run(scope: scope)
        XCTAssertTrue(report.passed, report.failureMessage)
    }
}
#endif
