// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BIT101Modules",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "CommunityCore", targets: ["CommunityCore"]),
        .library(name: "DesignSystemKit", targets: ["DesignSystemKit"]),
        .library(name: "ClientCore", targets: ["ClientCore"]),
        .library(name: "ScheduleContracts", targets: ["ScheduleContracts"]),
    ],
    targets: [
        .target(
            name: "CommunityCore",
            dependencies: ["ClientCore"],
            path: "BIT101-iOS/Shared/CommunityCore",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "DesignSystemKit",
            path: "BIT101-iOS/Shared/DesignSystem",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "ClientCore",
            path: "BIT101-iOS/Shared",
            exclude: [
                "DesignSystem", "CommunityCore", "CommunityUI", "Media", "CommunityDestinations.swift", "ScheduleSharedSnapshot.swift",
                "ScheduleSharedOccurrence.swift", "ScheduleSharedLiveActivity.swift",
                "Client/KeyboardDismissSupport.swift",
                "Client/AppErrorPresentation.swift",
                "Client/ErrorReportSupport.swift",
                "Client/ReleaseNetworkSmokeModels.swift",
                "Client/AppDeepLinkCoordinator.swift",
                "Client/AppAlert.swift",
                "Client/BITLoginChallengeSupport.swift",
                "Client/AppFileDirectories.swift",
                "Client/EmergencyUpdateChecker.swift",
                "Client/HorizontalSwitchGesture.swift",
                "Client/ReleaseNetworkSmoke.swift",
                "Client/AppUpdateChecker.swift",
                "Client/NetworkDiagnostics.swift",
                "Client/AppDateText.swift",
            ],
            sources: [
                "AppFileService.swift",
                "Client/AccountScopedCodableStore.swift",
                "Client/AppStorageSession.swift",
                "Client/HTTPClient.swift",
                "Client/PagedItemsState.swift",
                "Client/CommunityAPIClient.swift",
                "Client/SecureURLTransport.swift",
                "Client/TaskCancellation.swift",
                "Client/AppURL.swift",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "ScheduleContracts",
            dependencies: ["ClientCore"],
            path: "BIT101-iOS/Shared",
            exclude: ["Client", "DesignSystem", "CommunityCore", "CommunityUI", "Media", "CommunityDestinations.swift", "AppFileService.swift"],
            sources: [
                "ScheduleSharedSnapshot.swift", "ScheduleSharedOccurrence.swift",
                "ScheduleSharedLiveActivity.swift",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "BIT101ModulesTests",
            dependencies: ["ClientCore", "ScheduleContracts", "CommunityCore"],
            path: "ModuleTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
