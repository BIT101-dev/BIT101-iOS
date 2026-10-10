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
            return ScheduleExternalResolvedSnapshot(snapshot: nil, upcomingOccurrences: [],
                contentState: error as? ScheduleExternalSnapshotStoreError == .invalidSnapshot ? .invalid : .unavailable)
        }
    }
}
