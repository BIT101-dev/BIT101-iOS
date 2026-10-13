import Foundation
import ScheduleContracts

public extension ScheduleOccurrenceResolver {
    /// 文件读取、解码和学期展开在后台执行，取消由所属刷新任务传递。
    nonisolated static func loadResolvedSnapshotAsync(
        store: ScheduleExternalSnapshotStore,
        now: Date = Date(),
        limit: Int? = nil
    ) async -> ScheduleExternalResolvedSnapshot {
        let operation = Task.detached {
            loadResolvedSnapshot(store: store, now: now, limit: limit)
        }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
    }

    /// 直接从共享仓库读取并解析。
    nonisolated static func loadResolvedSnapshot(
        store: ScheduleExternalSnapshotStore,
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration,
        limit: Int? = nil
    ) -> ScheduleExternalResolvedSnapshot {
        do {
            return resolvedSnapshot(from: try store.read(), now: now,
                currentCourseDisplayDuration: currentCourseDisplayDuration, limit: limit)
        } catch {
            return readFailure(error)
        }
    }

    nonisolated static func loadResolvedTimeline(
        store: ScheduleExternalSnapshotStore, now: Date = Date(), includeDisplayUntilDates: Bool,
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration, limit: Int? = nil
    ) -> [ScheduleExternalTimelineEntry] {
        do {
            return resolvedTimeline(from: try store.read(), now: now, includeDisplayUntilDates: includeDisplayUntilDates,
                currentCourseDisplayDuration: currentCourseDisplayDuration, limit: limit)
        } catch {
            return [ScheduleExternalTimelineEntry(date: now, resolved: readFailure(error))]
        }
    }

    private nonisolated static func readFailure(_ error: Error) -> ScheduleExternalResolvedSnapshot {
        ScheduleExternalResolvedSnapshot(snapshot: nil, upcomingOccurrences: [],
            contentState: error as? ScheduleExternalSnapshotStoreError == .invalidSnapshot ? .invalid : .unavailable)
    }
}
