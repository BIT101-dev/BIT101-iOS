//
//  ScheduleCacheStore.swift
//  BIT101-iOS
//
import Foundation
import OSLog

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    enum SaveSource {
        case local
        case localWithoutCloudPush
        case cloud
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let logger = Logger(subsystem: "BIT101", category: "ScheduleCache")

    /// 当前账号对应的缓存文件路径。
    ///
    /// 路径按当前学号区分账号缓存。
    private static var fileURL: URL {
        let directory = AppFileDirectories.applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: currentAccountIdentifier(), directoryHint: .isDirectory)
        return directory.appending(path: "schedule-cache.json")
    }

    /// 把当前学号转换成目录名。
    static func currentAccountIdentifier() -> String {
        let raw = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "__default__"
        }

        let invalid = CharacterSet.alphanumerics.inverted
        return raw.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 读取当前账号的缓存快照。
    static func load() -> ScheduleCache {
        guard
            let data = try? Data(contentsOf: fileURL),
            let cache = try? decoder.decode(ScheduleCache.self, from: data)
        else {
            return ScheduleCache()
        }

        return cache
    }

    /// 写回缓存，并导出小组件快照、发送全局变更通知。
    static func save(_ cache: ScheduleCache, source: SaveSource = .local) {
        let url = fileURL
        let directory = url.deletingLastPathComponent()
        var cacheToSave = cache

        if source == .local {
            cacheToSave.updatedAt = Date()
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(cacheToSave)
            try data.write(to: url, options: [.atomic])
            ScheduleWidgetExporter.sync(cache: cacheToSave)
            postCacheDidChange()
            #if canImport(CloudKit)
            if source == .local, cacheToSave.iCloudSyncEnabled {
                Task {
                    await ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()
                }
            }
            #endif
        } catch {
            logger.error("保存课表缓存失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 清空当前账号的日程缓存。
    ///
    /// 清空操作定位当前账号目录，并保留其它账号目录。
    static func clear() {
        let url = fileURL
        let directory = url.deletingLastPathComponent()

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            if FileManager.default.fileExists(atPath: directory.path),
               (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try FileManager.default.removeItem(at: directory)
            }

            ScheduleWidgetExporter.syncFromCurrentCache()
            postCacheDidChange()
        } catch {
            logger.error("清理课表缓存失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 在主线程广播“课表缓存已变化”。
    ///
    /// 保存与清空缓存后都要发送这条通知，两个入口共用这一实现。
    private static func postCacheDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scheduleCacheDidChange, object: nil)
        }
    }
}
