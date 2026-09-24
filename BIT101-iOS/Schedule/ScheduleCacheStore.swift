//
//  ScheduleCacheStore.swift
//  BIT101-iOS
//
import Foundation
import OSLog

nonisolated enum ScheduleCacheTimestamp {
    static func next(after previous: Date, now: Date) -> Date {
        max(now, previous.addingTimeInterval(0.001))
    }

    static func restored(recordDate: Date, payloadDate: Date) -> Date? {
        guard abs(recordDate.timeIntervalSince(payloadDate)) <= 1.1 else { return nil }
        return recordDate
    }
}

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    nonisolated enum SaveSource: Sendable {
        case local
        case localWithoutCloudPush
        case cloud
    }

    fileprivate nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    fileprivate nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScheduleCache")
    private static let writeQueue = ScheduleCacheWriteQueue()

    /// 当前账号对应的缓存文件路径。
    ///
    /// 路径按当前学号区分账号缓存。
    private static var fileURL: URL {
        cacheFileURL(for: currentAccountIdentifier())
    }

    /// 把当前学号转换成目录名。
    static func currentAccountIdentifier() -> String {
        let raw = rawAccountIdentifier()
        if raw.isEmpty {
            return "__default__"
        }

        let invalid = CharacterSet.alphanumerics.inverted
        guard raw.rangeOfCharacter(from: invalid) != nil else { return raw }
        return "__encoded__" + raw.utf8.map { String(format: "%02X", $0) }.joined()
    }

    /// 读取当前账号的缓存快照。
    static func load() -> ScheduleCache {
        load(
            accountIdentifier: currentAccountIdentifier(),
            legacyAccountIdentifier: legacyAccountIdentifier()
        )
    }

    /// 将缓存文件读取与解码移到独立任务，避免页面恢复阶段阻塞 MainActor。
    static func loadAsync() async -> ScheduleCache {
        let accountIdentifier = currentAccountIdentifier()
        let legacyIdentifier = legacyAccountIdentifier()
        return await Task.detached(priority: .utility) {
            Self.load(
                accountIdentifier: accountIdentifier,
                legacyAccountIdentifier: legacyIdentifier
            )
        }.value
    }

    /// 写回缓存，并导出小组件快照、发送全局变更通知。
    static func save(_ cache: ScheduleCache, source: SaveSource = .local) {
        var cacheToSave = cache
        if source == .local {
            cacheToSave.updatedAt = ScheduleCacheTimestamp.next(after: cache.updatedAt, now: Date())
        }
        let accountIdentifier = currentAccountIdentifier()
        Task {
            await writeQueue.save(
                cacheToSave,
                accountIdentifier: accountIdentifier,
                source: source
            )
        }
    }

    /// 清空当前账号的日程缓存。
    ///
    /// 清空操作定位当前账号目录，并保留其它账号目录。
    static func clear() {
        do {
            for url in cacheURLs() {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }

            for directory in Set(cacheURLs().map { $0.deletingLastPathComponent() }) {
                if FileManager.default.fileExists(atPath: directory.path),
                   (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                    try FileManager.default.removeItem(at: directory)
                }
            }

            Task {
                await ScheduleWidgetExporter.syncFromCurrentCache()
            }
            postCacheDidChange()
        } catch {
            logger.error("清理课表缓存失败：\(String(describing: error), privacy: .public)")
        }
    }

    private static func rawAccountIdentifier() -> String {
        LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func load(
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) -> ScheduleCache {
        let currentURL = cacheFileURL(for: accountIdentifier)
        if let data = try? Data(contentsOf: currentURL),
           let cache = try? makeDecoder().decode(ScheduleCache.self, from: data)
        {
            return cache
        }

        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard legacyURL != currentURL,
              let data = try? Data(contentsOf: legacyURL),
              let cache = try? makeDecoder().decode(ScheduleCache.self, from: data)
        else {
            return ScheduleCache()
        }
        return cache
    }

    private static func cacheData() -> Data? {
        if let data = try? Data(contentsOf: fileURL) {
            return data
        }

        let legacyURL = cacheFileURL(for: legacyAccountIdentifier())
        guard legacyURL != fileURL else { return nil }
        return try? Data(contentsOf: legacyURL)
    }

    private static func cacheURLs() -> [URL] {
        let current = fileURL
        let legacy = cacheFileURL(for: legacyAccountIdentifier())
        return current == legacy ? [current] : [current, legacy]
    }

    fileprivate nonisolated static func cacheFileURL(for accountIdentifier: String) -> URL {
        let directory = AppFileDirectories.applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: accountIdentifier, directoryHint: .isDirectory)
        return directory.appending(path: "schedule-cache.json")
    }

    private static func legacyAccountIdentifier() -> String {
        let raw = rawAccountIdentifier()
        if raw.isEmpty { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        return raw.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 在主线程广播“课表缓存已变化”。
    ///
    /// 保存与清空缓存后都要发送这条通知，两个入口共用这一实现。
    fileprivate static func postCacheDidChange() {
        let accountIdentifier = currentAccountIdentifier()
        DispatchQueue.main.async {
            guard currentAccountIdentifier() == accountIdentifier else { return }
            NotificationCenter.default.post(name: .scheduleCacheDidChange, object: accountIdentifier)
        }
    }
}

/// 串行处理缓存文件写入，保持快速连续编辑的保存顺序，并把编码和磁盘操作移出 MainActor。
private actor ScheduleCacheWriteQueue {
    func save(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        source: ScheduleCacheStore.SaveSource
    ) async {
        let url = ScheduleCacheStore.cacheFileURL(for: accountIdentifier)
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try ScheduleCacheStore.makeEncoder().encode(cache)
            try data.write(to: url, options: [.atomic])
        } catch {
            ScheduleCacheStore.logger.error("保存课表缓存失败：\(String(describing: error), privacy: .public)")
            return
        }

        let isCurrentAccount = await MainActor.run {
            ScheduleCacheStore.currentAccountIdentifier() == accountIdentifier
        }
        guard isCurrentAccount else { return }
        await ScheduleWidgetExporter.syncAsync(cache: cache)
        await MainActor.run {
            ScheduleCacheStore.postCacheDidChange()
        }

        #if canImport(CloudKit)
        if source == .local, cache.iCloudSyncEnabled {
            await ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()
        }
        #endif

    }
}
