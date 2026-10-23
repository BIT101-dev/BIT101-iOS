import Foundation
import Network
import Observation

public nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case checking, connected, requiresConnection, disconnected

        init(pathStatus: NWPath.Status) {
            switch pathStatus {
            case .satisfied: self = .connected
            case .requiresConnection: self = .requiresConnection
            case .unsatisfied: self = .disconnected
            @unknown default: self = .checking
            }
        }
    }

    public enum Interface: Equatable, Sendable {
        case wifi, cellular, wiredEthernet, other, loopback, unknown
    }

    public let status: Status
    public let interfaces: [Interface]
    public let virtualNetworkLikely: Bool

    public init(status: Status, interfaces: [Interface] = [], virtualNetworkLikely: Bool = false) {
        self.status = status
        self.interfaces = interfaces
        self.virtualNetworkLikely = virtualNetworkLikely
    }

    public var isReachable: Bool { status != .disconnected }
}


/// Hosts share one path state across request diagnostics and feature recovery.
@MainActor
@Observable
public final class NetworkPathState {
    public private(set) var snapshot: NetworkPathSnapshot
    public var isReachable: Bool { snapshot.isReachable }
    private let monitor: NWPathMonitor?
    private var recoveryContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {
        snapshot = NetworkPathSnapshot(status: .checking)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Self.snapshot(for: path)
            Task { @MainActor [weak self] in
                self?.update(snapshot: snapshot)
            }
        }
        monitor.start(queue: DispatchQueue(label: "BIT101.NetworkPath"))
    }

    /// A fixed path snapshot lets offline hosts select their own connection state.
    public init(snapshot: NetworkPathSnapshot) {
        self.snapshot = snapshot
        monitor = nil
    }

    func update(snapshot: NetworkPathSnapshot) {
        let previous = self.snapshot.status
        self.snapshot = snapshot
        if previous != .connected, snapshot.status == .connected {
            for continuation in recoveryContinuations.values { continuation.yield(()) }
        }
    }

    public func connectionRecoveries() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            recoveryContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.recoveryContinuations[id] = nil }
            }
        }
    }

    isolated deinit {
        monitor?.cancel()
        for continuation in recoveryContinuations.values { continuation.finish() }
    }

    private nonisolated static func snapshot(for path: NWPath) -> NetworkPathSnapshot {
        var interfaces: [NetworkPathSnapshot.Interface] = []
        for interface in path.availableInterfaces {
            let value: NetworkPathSnapshot.Interface
            switch interface.type {
            case .wifi: value = .wifi
            case .cellular: value = .cellular
            case .wiredEthernet: value = .wiredEthernet
            case .other: value = .other
            case .loopback: value = .loopback
            @unknown default: value = .unknown
            }
            if !interfaces.contains(value) { interfaces.append(value) }
        }
        return NetworkPathSnapshot(
            status: NetworkPathSnapshot.Status(pathStatus: path.status),
            interfaces: interfaces,
            virtualNetworkLikely: path.usesInterfaceType(.other)
        )
    }
}
