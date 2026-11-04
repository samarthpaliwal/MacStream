import Foundation
import Network

/// A Mac found on the local network via Bonjour.
public struct DiscoveredHost: Identifiable, Hashable {
    /// Stable per-install host identifier from the TXT record, when present.
    public let hostID: UUID?
    public let name: String
    public let endpoint: NWEndpoint
    /// True while the Mac is displaying a pairing code.
    public let isPairingMode: Bool

    public var id: String { hostID?.uuidString ?? "\(endpoint)" }

    public init(hostID: UUID?, name: String, endpoint: NWEndpoint, isPairingMode: Bool = false) {
        self.hostID = hostID
        self.name = name
        self.endpoint = endpoint
        self.isPairingMode = isPairingMode
    }
}

/// Browses for `_macstream._tcp` services and reports the current set.
public final class HostBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "macstream.browser")

    public var onUpdate: (@Sendable ([DiscoveredHost]) -> Void)?
    public var onError: (@Sendable (NWError) -> Void)?

    public init() {}

    public func start() {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: StreamService.bonjourType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: ControlTransport.browserParameters())
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                self?.onError?(error)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onUpdate?(results.compactMap(Self.host(from:)).sorted { $0.name < $1.name })
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func host(from result: NWBrowser.Result) -> DiscoveredHost? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var hostID: UUID?
        var pairing = false
        if case .bonjour(let txt) = result.metadata {
            hostID = txt[StreamService.txtHostID].flatMap(UUID.init(uuidString:))
            pairing = txt[StreamService.txtPairing] == "1"
        }
        return DiscoveredHost(hostID: hostID, name: name, endpoint: result.endpoint, isPairingMode: pairing)
    }
}
