import Foundation
import Network

/// One reliable, framed, typed message channel over an `NWConnection`.
/// Used identically by host and client. Callbacks fire on the channel's
/// private queue; UI code must hop to the main actor.
public final class ControlChannel: @unchecked Sendable {
    public enum Event: Sendable {
        case ready
        /// Connection ended. `error` is nil for a clean close.
        case closed(error: Error?)
    }

    public let connection: NWConnection
    private let queue = DispatchQueue(label: "macstream.control", qos: .userInitiated)
    private var framer = LengthPrefixedFramer()
    private var finished = false

    public var onEvent: (@Sendable (Event) -> Void)?
    public var onMessage: (@Sendable (ControlMessage) -> Void)?

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public var remoteDescription: String {
        connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "\(connection.endpoint)"
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent?(.ready)
                self.receiveNext()
            case .failed(let error):
                self.finish(error: error)
            case .cancelled:
                self.finish(error: nil)
            case .waiting(let error):
                // Typically "no route" or local-network permission denied.
                // Surface it as a failure rather than hanging forever.
                self.connection.cancel()
                self.finish(error: error)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: ControlMessage) {
        guard let payload = try? message.encoded() else { return }
        connection.send(content: LengthPrefixedFramer.frame(payload), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error: error) }
        })
    }

    public func cancel() {
        connection.cancel()
    }

    /// Sends a final message and closes once it has been handed to the network,
    /// so the peer sees the reason instead of a bare connection drop.
    public func sendAndClose(_ message: ControlMessage) {
        guard let payload = try? message.encoded() else { connection.cancel(); return }
        connection.send(content: LengthPrefixedFramer.frame(payload), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for payload in try self.framer.append(data) {
                        if let message = try? ControlMessage.decode(payload) {
                            self.onMessage?(message)
                        }
                    }
                } catch {
                    self.connection.cancel()
                    self.finish(error: error)
                    return
                }
            }
            if let error {
                self.finish(error: error)
            } else if isComplete {
                self.connection.cancel()
                self.finish(error: nil)
            } else {
                self.receiveNext()
            }
        }
    }

    private func finish(error: Error?) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            onEvent?(.closed(error: error))
        }
    }
}
