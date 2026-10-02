import Foundation
import Network
import Observation

public nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case checking, connected, disconnected
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
        self.snapshot = snapshot
    }

    deinit {
        monitor?.cancel()
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
            status: path.status == .satisfied ? .connected : .disconnected,
            interfaces: interfaces,
            virtualNetworkLikely: path.usesInterfaceType(.other)
        )
    }
}
