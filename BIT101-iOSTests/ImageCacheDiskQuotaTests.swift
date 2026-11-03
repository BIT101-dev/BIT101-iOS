import ClientCore
import Combine
import CommunityCore
import CommunityTransport
import Foundation
import Network
import ScheduleActivityContracts
import ScheduleContracts
import ScheduleDomain
import SchedulePorts
import ScoreDomain
import ScorePorts
import Security
import StorageCore
import Testing
import TransportCore
import UIKit
import XCTest
import os

@testable import BIT101_iOS
@testable import CommunityUI
@testable import GalleryFeature
@testable import MediaKit
@testable import ScheduleFeature
@testable import ScoreFeature
@testable import ScoreInfrastructure

@Suite("Image cache disk quota")
struct ImageCacheDiskQuotaTests {
    @Test(
        "Quota pruning evicts least-recently-used entries and protects active files",
        .timeLimit(.minutes(1)))
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
