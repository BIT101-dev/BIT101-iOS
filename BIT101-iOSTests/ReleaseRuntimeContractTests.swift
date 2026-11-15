import ClientCore
import Foundation
import Testing
import TransportCore

@testable import BIT101_iOS

#if DEBUG
@Suite("Release runtime composition")
@MainActor
struct ReleaseRuntimeContractTests {
    @Test func scoreStorageUsesTheCurrentAccount() {
        #expect(AppFileDirectories.scoreCacheSession == AppFileDirectories.currentSession)
        #expect(AppAccountStores.shared.scoreSession() == AppFileDirectories.currentSession)
    }

    @Test(.timeLimit(.minutes(1)))
    func diagnosticsReceiveTheSystemNetworkPath() async throws {
        let state = AppNetworkPath.makeState(isolated: false)
        while state.snapshot.status == .checking {
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = state.snapshot
        if snapshot.status == .connected { #expect(!snapshot.interfaces.isEmpty) }
    }

    @Test func schoolWarningsUseTheProductionCoordinator() {
        #expect(
            HTTPClient.makeDefaultNetworkWarningCenter(isolated: false)
                === NetworkMagicWarningCenter.shared)
    }

    @Test func feedbackIdentifiesTheDevelopmentBuild() {
        #expect(AppBuildEnvironment.isDevelopment == true)
    }
}
#endif
