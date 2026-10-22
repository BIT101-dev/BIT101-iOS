import Foundation

#if DEBUG || RELEASE_NETWORK_SMOKE

/// 网络冒烟共用执行队列，各等待者独立取消。
@MainActor
final class NetworkSmokeExecutionGate {
    private var isRunning = false
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isRunning else { isRunning = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.0 == id }) else { return }
                self.waiting.remove(at: index).1.resume(returning: false)
            }
        }
    }

    func release() {
        if waiting.isEmpty { isRunning = false }
        else { waiting.removeFirst().1.resume(returning: true) }
    }
}

#endif
