// swift-tools-version: 6.2
import PackageDescription

let mainActorIsolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "BIT101Modules",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "ScoreDomain", targets: ["ScoreDomain"]),
        .library(name: "ScorePorts", targets: ["ScorePorts"]),
        .library(name: "SchedulePorts", targets: ["SchedulePorts"]),
        .library(name: "ScheduleFeature", targets: ["ScheduleFeature"]),
        .library(name: "GalleryFeature", targets: ["GalleryFeature"]),
        .library(name: "CourseFeature", targets: ["CourseFeature"]),
        .library(name: "PaperFeature", targets: ["PaperFeature"]),
        .library(name: "MineFeature", targets: ["MineFeature"]),
        .library(name: "CommunityUI", targets: ["CommunityUI"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "ScoreFeature", targets: ["ScoreFeature"]),
        .library(name: "ScoreInfrastructure", targets: ["ScoreInfrastructure"]),
        .library(name: "MapFeature", targets: ["MapFeature"]),
        .library(name: "ScheduleDomain", targets: ["ScheduleDomain"]),
        .library(name: "ScheduleSync", targets: ["ScheduleSync"]),
        .library(name: "SchedulePersistence", targets: ["SchedulePersistence"]),
        .library(name: "ScheduleInfrastructure", targets: ["ScheduleInfrastructure"]),
        .library(name: "CommunityCore", targets: ["CommunityCore"]),
        .library(name: "CommunityPersistence", targets: ["CommunityPersistence"]),
        .library(name: "DesignSystemKit", targets: ["DesignSystemKit"]),
        .library(name: "ClientCore", targets: ["ClientCore"]),
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .library(name: "TransportCore", targets: ["TransportCore"]),
        .library(name: "CommunityTransport", targets: ["CommunityTransport"]),
        .library(name: "ScheduleActivityContracts", targets: ["ScheduleActivityContracts"]),
        .library(name: "ScheduleContracts", targets: ["ScheduleContracts"]),
        .library(name: "ScheduleSharedStore", targets: ["ScheduleSharedStore"]),
    ],
    targets: [
        .target(
            name: "SchedulePorts", dependencies: ["ClientCore", "ScheduleDomain", "StorageCore"],
            path: "Modules/SchedulePorts/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScorePorts",
            dependencies: ["ScoreDomain", "ClientCore", "StorageCore", "TransportCore"],
            path: "Modules/ScorePorts/Sources", swiftSettings: mainActorIsolation),
        .target(
            name: "ScoreDomain", dependencies: [], path: "Modules/ScoreDomain/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleFeature",
            dependencies: [
                "SchedulePorts", "ClientCore", "DesignSystemKit", "MediaKit", "ScheduleDomain",
                "ScheduleContracts", "StorageCore", "TransportCore",
            ], path: "Modules/ScheduleFeature/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "GalleryFeature",
            dependencies: [
                "CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit",
                "TransportCore",
            ],
            path: "Modules/GalleryFeature/Sources",
            swiftSettings: mainActorIsolation
        ),
        .target(
            name: "CourseFeature",
            dependencies: [
                "CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit",
                "TransportCore",
            ], path: "Modules/CourseFeature/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "PaperFeature",
            dependencies: [
                "CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit",
                "TransportCore",
            ], path: "Modules/PaperFeature/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "MineFeature",
            dependencies: [
                "CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit",
                "TransportCore",
            ], path: "Modules/MineFeature/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "CommunityUI",
            dependencies: ["TransportCore", "CommunityCore", "DesignSystemKit", "MediaKit"],
            path: "Modules/CommunityUI/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "MediaKit", dependencies: ["DesignSystemKit", "StorageCore", "TransportCore"],
            path: "Modules/MediaKit/Sources", swiftSettings: mainActorIsolation),
        .target(
            name: "ScoreInfrastructure",
            dependencies: [
                "ClientCore", "ScoreDomain", "ScorePorts", "StorageCore", "TransportCore",
            ], path: "Modules/ScoreInfrastructure/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScoreFeature",
            dependencies: [
                "ScoreDomain", "ScorePorts", "ClientCore", "DesignSystemKit", "MediaKit",
                "StorageCore", "TransportCore",
            ], path: "Modules/ScoreFeature/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "MapFeature",
            dependencies: ["DesignSystemKit", "ScheduleContracts", "TransportCore"],
            path: "Modules/MapFeature/Sources", swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleSync", dependencies: ["ScheduleDomain", "StorageCore"],
            path: "Modules/ScheduleSync/Sources", swiftSettings: mainActorIsolation
        ),
        .target(
            name: "SchedulePersistence", dependencies: ["ScheduleDomain", "StorageCore"],
            path: "Modules/SchedulePersistence/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleDomain", dependencies: ["ScheduleContracts"],
            path: "Modules/ScheduleDomain/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleInfrastructure",
            dependencies: [
                "SchedulePorts", "ClientCore", "ScheduleDomain", "ScheduleContracts",
                "TransportCore",
            ], path: "Modules/ScheduleInfrastructure/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "CommunityPersistence", dependencies: ["CommunityCore", "StorageCore"],
            path: "Modules/CommunityPersistence/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "CommunityCore", dependencies: ["StorageCore"],
            path: "Modules/CommunityCore/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "DesignSystemKit", path: "Modules/DesignSystemKit/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ClientCore", dependencies: ["TransportCore"], path: "Modules/ClientCore/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "StorageCore", path: "Modules/StorageCore/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "TransportCore", path: "Modules/TransportCore/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "CommunityTransport", dependencies: ["TransportCore"],
            path: "Modules/CommunityTransport/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleActivityContracts", path: "Modules/ScheduleActivityContracts/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleContracts", path: "Modules/ScheduleContracts/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "ScheduleSharedStore", dependencies: ["ScheduleContracts", "StorageCore"],
            path: "Modules/ScheduleSharedStore/Sources",
            swiftSettings: mainActorIsolation),
        .target(
            name: "BIT101TestSupport", dependencies: ["StorageCore"], path: "ModuleTests/Support",
            swiftSettings: mainActorIsolation),
        .testTarget(
            name: "TransportModuleTests",
            dependencies: [
                "BIT101TestSupport", "ClientCore", "CommunityTransport", "ScheduleDomain",
                "ScheduleFeature", "ScheduleInfrastructure", "SchedulePorts", "StorageCore",
                "TransportCore",
            ], path: "ModuleTests/Transport", swiftSettings: mainActorIsolation),
        .testTarget(
            name: "CommunityModuleTests",
            dependencies: [
                "BIT101TestSupport", "CommunityCore", "CommunityPersistence", "CommunityTransport",
                "CommunityUI", "CourseFeature", "DesignSystemKit", "GalleryFeature", "MediaKit",
                "MineFeature", "PaperFeature", "StorageCore", "TransportCore",
            ], path: "ModuleTests/Community", swiftSettings: mainActorIsolation),
        .testTarget(
            name: "ScheduleModuleTests",
            dependencies: [
                "BIT101TestSupport", "ClientCore", "ScheduleContracts", "ScheduleDomain",
                "ScheduleFeature", "SchedulePersistence", "SchedulePorts", "StorageCore",
                "TransportCore",
            ], path: "ModuleTests/Schedule", swiftSettings: mainActorIsolation),
        .testTarget(
            name: "ContractsModuleTests",
            dependencies: [
                "BIT101TestSupport", "ScheduleContracts", "ScheduleDomain", "ScheduleSharedStore",
                "StorageCore",
            ], path: "ModuleTests/Contracts", swiftSettings: mainActorIsolation),
        .testTarget(
            name: "ScoreModuleTests",
            dependencies: [
                "BIT101TestSupport", "ClientCore", "CommunityCore", "DesignSystemKit",
                "ScoreDomain", "ScoreFeature", "ScoreInfrastructure", "ScorePorts", "StorageCore",
                "TransportCore",
            ], path: "ModuleTests/Score", swiftSettings: mainActorIsolation),
        .testTarget(
            name: "MapModuleTests", dependencies: ["MapFeature"], path: "ModuleTests/Map",
            swiftSettings: mainActorIsolation),
        .testTarget(
            name: "SyncModuleTests",
            dependencies: [
                "BIT101TestSupport", "ScheduleDomain", "SchedulePersistence", "ScheduleSync",
                "StorageCore",
            ], path: "ModuleTests/Sync", swiftSettings: mainActorIsolation),
    ]
)
