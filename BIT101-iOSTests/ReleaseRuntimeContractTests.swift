import ClientCore
import Foundation
import Testing
import TransportCore
@testable import BIT101_iOS

#if !DEBUG && !BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING && !RELEASE_NETWORK_SMOKE && !ICLOUD_CROSS_DEVICE_SMOKE
@Suite("Release runtime composition")
@MainActor
struct ReleaseRuntimeContractTests {
    @Test func scoreStorageUsesTheCurrentAccount() {
        #expect(AppFileDirectories.scoreCacheSession == AppFileDirectories.currentSession)
        #expect(AppAccountStores.shared.scoreSession() == AppFileDirectories.currentSession)
    }

    @Test(.timeLimit(.minutes(1)))
    func diagnosticsReceiveTheSystemNetworkPath() async throws {
        while AppNetworkPath.state.snapshot.status == .checking { try await Task.sleep(for: .milliseconds(20)) }
        let snapshot = AppNetworkPath.state.snapshot
        if snapshot.status == .connected { #expect(!snapshot.interfaces.isEmpty) }
        #expect(NetworkConnectionDescription.shared.snapshot.virtualNetworkLikely == snapshot.virtualNetworkLikely)
        #expect(FeedbackDeviceContext.current.networkStatus == NetworkConnectionDescription.shared.current)
    }

    @Test func schoolWarningsUseTheProductionCoordinator() {
        #expect(HTTPClient.defaultNetworkWarningCenter === NetworkMagicWarningCenter.shared)
    }
    @Test func feedbackIdentifiesTheReleaseBuild() {
        #expect(AppBuildEnvironment.isDevelopment == false)
    }
}
#endif
