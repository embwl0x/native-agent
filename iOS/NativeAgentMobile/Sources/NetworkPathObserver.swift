import Foundation
import Network

/// Publishes coarse device reachability. Deliberately reports only what
/// NWPathMonitor actually knows: whether a usable path exists. It never claims
/// anything about the Mac or about iCloud, which is a separate question the
/// bridge already answers.
@MainActor
final class NetworkPathObserver: ObservableObject {
    static let shared = NetworkPathObserver()

    /// nil until the first path update lands — an unknown path must not be
    /// painted as an outage.
    @Published private(set) var isOffline: Bool?

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "io.nativeagent.mobile.networkpath")
    private var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                self?.isOffline = offline
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    /// Copy for the offline banner. nil while online or still unknown.
    static func offlineBannerMessage(isOffline: Bool?) -> String? {
        isOffline == true
            ? "This iPhone has no network connection. Messages are queued and will send when it returns."
            : nil
    }
}
