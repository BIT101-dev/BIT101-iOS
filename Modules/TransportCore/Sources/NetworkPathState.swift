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

#if BIT101_UI_TESTING
/// UI 自动化在本机连接中更新场景夹具，App 进程持续运行。
public nonisolated final class UITestControlServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BIT101.UITestControl")

    public init(handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 19101)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data(), handle: handle)
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    private static func receive(
        _ connection: NWConnection, buffer: Data,
        handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            var content = buffer
            if let data { content.append(data) }
            if let end = content.firstIndex(of: 10) {
                handle(Data(content[..<end])) { response in
                    connection.send(content: response + Data([10]), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if error != nil || complete || content.count > 16_384 {
                connection.cancel()
            } else {
                receive(connection, buffer: content, handle: handle)
            }
        }
    }
}
#endif

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
