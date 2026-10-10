import Foundation
import ScheduleContracts

public extension ScheduleOccurrenceResolver {
    /// 直接从共享仓库读取并解析。
    static func loadResolvedSnapshot(
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

    static func loadResolvedTimeline(
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

    private static func readFailure(_ error: Error) -> ScheduleExternalResolvedSnapshot {
        ScheduleExternalResolvedSnapshot(snapshot: nil, upcomingOccurrences: [],
            contentState: error as? ScheduleExternalSnapshotStoreError == .invalidSnapshot ? .invalid : .unavailable)
    }
}
