import StorageCore
import ScheduleDomain
import ScheduleContracts
import ScheduleSharedStore
//
//  ScheduleWidgetSupport.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

import Foundation
import WidgetKit

nonisolated enum ScheduleSnapshotExportPolicy {
    static func isCurrent(
        capturedSession: AppStorageSession,
        currentSession: AppStorageSession,
        generation: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        capturedSession == currentSession && generation == currentGeneration
    }

    static func acceptsWrite(generation: UInt64, latestGeneration: UInt64) -> Bool {
        generation >= latestGeneration
    }

    static func requiresAccountReset(snapshot: ScheduleExternalSnapshot?, session: AppStorageSession, isLoggedIn: Bool) -> Bool {
        guard let snapshot else { return false }
        return AccountStorageIdentity.stableToken(for: snapshot.studentID) != session.accountStorageIdentifier
            || snapshot.isLoggedIn != isLoggedIn
    }
}

/// 把当前账号课表缓存导出为 `ScheduleExternalSnapshot`，供 Widget 和 Watch 读取。
///
/// 桌面 widget、锁屏组件和 Apple Watch 共享这份快照；Live Activity 采用 ActivityKit 的状态更新链路，
/// 外部 target 从快照读取课表所需的最小字段。
enum ScheduleWidgetExporter {
    private static var exportGeneration: UInt64 = 0
    private static var lastPublishedContent: ScheduleExternalSnapshot?
    private static var snapshotRevision: UInt64 = 0

    /// 重新读取当前账号缓存，并同步到共享容器。
    ///
    /// 应用生命周期、登录切换等需要重新读取当前缓存的场景使用此入口。
    static func syncFromCurrentCache() async {
        let session = AppFileDirectories.currentSession
        let generation = nextExportGeneration()
        let storedSnapshot = PlatformScheduleSnapshotStorage.store.load()
        let isLoggedIn = !AppAccountSession.storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ScheduleSnapshotExportPolicy.requiresAccountReset(snapshot: storedSnapshot, session: session, isLoggedIn: isLoggedIn) {
            lastPublishedContent = nil
            guard let emptySnapshot = makeSnapshot(courses: ScheduleCache().courseSnapshot, session: session) else { return }
            // 账号切换先更新共享展示的身份，再读取当前账号缓存。
            let didWriteEmptySnapshot = await ScheduleExternalSnapshotWriteQueue.shared.write(emptySnapshot, generation: generation)
            guard isCurrent(session: session, generation: generation) else { return }
            if didWriteEmptySnapshot {
                publish(emptySnapshot)
            } else {
                _ = await ScheduleExternalSnapshotWriteQueue.shared.clear(generation: generation)
                guard isCurrent(session: session, generation: generation) else { return }
                WatchScheduleSyncManager.shared.push(snapshot: emptySnapshot)
                WidgetCenter.shared.reloadAllTimelines()
            }
        } else {
            lastPublishedContent = storedSnapshot.map(content)
        }

        let result = await ScheduleCacheStore.loadResultAsync(for: session)
        guard isCurrent(session: session, generation: generation) else { return }
        switch result {
        case .loaded(let cache):
            await export(courses: cache.courseSnapshot, session: session, generation: generation)
        case .missing:
            await export(courses: ScheduleCache().courseSnapshot, session: session, generation: generation)
        case .unreadable:
            // 保留同账号已发布快照，账号切换沿用身份重置后的快照。
            break
        }
    }

    /// 把指定缓存同步给外部展示层，并主动刷新 widget 时间线。
    ///
    /// 这里仅导出课表、小节次和首周信息，保持共享层边界最小化。
    static func sync(courses: ScheduleCourseSnapshot) {
        let session = AppFileDirectories.currentSession
        let generation = nextExportGeneration()
        Task { await export(courses: courses, session: session, generation: generation) }
    }

    /// 写入共享快照的磁盘操作运行在独立任务，完成后回到 MainActor 更新 Watch 与 Widget。
    static func syncAsync(courses: ScheduleCourseSnapshot, session: AppStorageSession? = nil) async {
        let session = session ?? AppFileDirectories.currentSession
        let generation = nextExportGeneration()
        await export(courses: courses, session: session, generation: generation)
    }

    /// 清除外部快照并使已排队的旧账号导出失效。
    @discardableResult
    static func clearSharedSnapshot() async -> Bool {
        await clearSharedSnapshot(
            clearSnapshot: { await ScheduleExternalSnapshotWriteQueue.shared.clear(generation: $0) },
            publishSnapshot: publish
        )
    }

    @discardableResult
    static func clearSharedSnapshot(
        clearSnapshot: @MainActor (UInt64) async -> Bool,
        publishSnapshot: @MainActor (ScheduleExternalSnapshot) -> Void
    ) async -> Bool {
        let session = AppFileDirectories.currentSession
        let generation = nextExportGeneration()
        guard let emptySnapshot = makeSnapshot(courses: ScheduleCache().courseSnapshot, session: session) else { return false }
        lastPublishedContent = nil
        let didClear = await clearSnapshot(generation)
        guard isCurrent(session: session, generation: generation) else { return didClear }
        if didClear {
            publishSnapshot(emptySnapshot)
        }
        return didClear
    }

    private static func export(
        courses: ScheduleCourseSnapshot,
        session: AppStorageSession,
        generation: UInt64
    ) async {
        guard isCurrent(session: session, generation: generation),
              let snapshot = makeSnapshot(courses: courses, session: session)
        else { return }

        guard content(of: snapshot) != lastPublishedContent else { return }
        let didSave = await ScheduleExternalSnapshotWriteQueue.shared.write(
            snapshot,
            generation: generation
        )
        guard didSave, isCurrent(session: session, generation: generation) else { return }
        publish(snapshot)
    }

    private static func content(of snapshot: ScheduleExternalSnapshot) -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: .distantPast, isLoggedIn: snapshot.isLoggedIn, studentID: snapshot.studentID,
            firstDayString: snapshot.firstDayString, timeTable: snapshot.timeTable, courses: snapshot.courses
        )
    }

    private static func publish(_ snapshot: ScheduleExternalSnapshot) {
        lastPublishedContent = content(of: snapshot)
        WatchScheduleSyncManager.shared.push(snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func makeSnapshot(
        courses: ScheduleCourseSnapshot,
        session: AppStorageSession
    ) -> ScheduleExternalSnapshot? {
        guard session == AppFileDirectories.currentSession else { return nil }
        let isLoggedIn = !AppAccountSession.storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let storedRevision = PlatformScheduleSnapshotStorage.store.load()?.revision ?? 0
        let clockRevision = UInt64(max(Date().timeIntervalSince1970 * 1_000_000, 0))
        snapshotRevision = max(snapshotRevision, storedRevision, clockRevision) + 1

        return ScheduleExternalSnapshot(
            revision: snapshotRevision,
            isLoggedIn: isLoggedIn,
            studentID: session.accountStorageIdentifier,
            firstDayString: courses.firstDayString,
            timeTable: courses.timeTable.map {
                ScheduleExternalTimeSlotSnapshot(id: $0.id, start: $0.start, end: $0.end)
            },
            courses: courses.courses.map {
                ScheduleExternalCourseSnapshot(
                    id: $0.id,
                    name: $0.name,
                    classroom: $0.classroom,
                    teacher: $0.teacher,
                    weeks: $0.weeks,
                    weekday: $0.weekday,
                    startSection: $0.startSection,
                    endSection: $0.endSection
                )
            }
        )
    }

    private static func nextExportGeneration() -> UInt64 {
        exportGeneration &+= 1
        return exportGeneration
    }

    private static func isCurrent(session: AppStorageSession, generation: UInt64) -> Bool {
        ScheduleSnapshotExportPolicy.isCurrent(
            capturedSession: session,
            currentSession: AppFileDirectories.currentSession,
            generation: generation,
            currentGeneration: exportGeneration
        )
    }
}

/// 串行写入 App Group 快照，并丢弃迟到的旧账号导出。
private actor ScheduleExternalSnapshotWriteQueue {
    static let shared = ScheduleExternalSnapshotWriteQueue()

    private var latestGeneration: UInt64 = 0

    func write(_ snapshot: ScheduleExternalSnapshot, generation: UInt64) -> Bool {
        guard ScheduleSnapshotExportPolicy.acceptsWrite(
            generation: generation,
            latestGeneration: latestGeneration
        ) else { return false }
        latestGeneration = generation
        return PlatformScheduleSnapshotStorage.store.save(snapshot)
    }

    func clear(generation: UInt64) -> Bool {
        guard ScheduleSnapshotExportPolicy.acceptsWrite(
            generation: generation,
            latestGeneration: latestGeneration
        ) else { return false }
        latestGeneration = generation
        return PlatformScheduleSnapshotStorage.store.clear()
    }
}
