import Foundation
import Observation
import os

/// 记录被观察属性的变化次数；每次变化后在下一个主线程周期重新登记观察。
@MainActor
public final class ObservationCounter {
    private let read: @MainActor () -> Void
    private let changes = OSAllocatedUnfairLock(initialState: 0)

    public var count: Int { changes.withLock { $0 } }

    public init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        arm()
    }

    /// 让待执行的重新登记完成，之后再读取次数。
    public func settle() async {
        await Task.yield()
    }

    private func arm() {
        withObservationTracking {
            read()
        } onChange: { [self] in
            changes.withLock { $0 += 1 }
            Task { @MainActor in arm() }
        }
    }
}
