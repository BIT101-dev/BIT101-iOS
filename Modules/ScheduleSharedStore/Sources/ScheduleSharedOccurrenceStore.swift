import Foundation
import ScheduleContracts

public extension ScheduleOccurrenceResolver {
    /// 直接从共享仓库读取并解析。
    static func loadResolvedSnapshot(
        store: ScheduleExternalSnapshotStore = .shared,
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration,
        limit: Int? = nil
    ) -> ScheduleExternalResolvedSnapshot {
        resolvedSnapshot(
            from: store.load(),
            now: now,
            currentCourseDisplayDuration: currentCourseDisplayDuration,
            limit: limit
        )
    }
}
