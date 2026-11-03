import Foundation
import Testing

@testable import BIT101_iOS

@MainActor
@Suite(.serialized)
struct PersistentBackupPreparationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func migrationRunsOnce(failFirst: Bool) async throws {
        let domain = "BIT101Tests.persistent-backup-migration"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let files = PreferenceMemoryFiles(separatesDirectories: true)
        for directory in [
            FileManager.SearchPathDirectory.libraryDirectory, .documentDirectory,
            .applicationSupportDirectory,
        ] {
            try files.createDirectory(at: #require(files.directoryURL(directory)))
        }
        files.failBackupMetadata(failFirst)
        await AppFileDirectories.migrateBackupMetadata(files: files, defaultsDomain: domain)
        #expect(files.backupMetadataWriteCount == 3)
        #expect(defaults.bool(forKey: "storage.persistent-backup-metadata.prepared") == !failFirst)
        files.failBackupMetadata(false)
        await AppFileDirectories.migrateBackupMetadata(files: files, defaultsDomain: domain)
        let completedWrites = files.backupMetadataWriteCount
        #expect(completedWrites == (failFirst ? 6 : 3))
        #expect(defaults.bool(forKey: "storage.persistent-backup-metadata.prepared"))
        await AppFileDirectories.migrateBackupMetadata(files: files, defaultsDomain: domain)
        #expect(files.backupMetadataWriteCount == completedWrites)
    }
}
