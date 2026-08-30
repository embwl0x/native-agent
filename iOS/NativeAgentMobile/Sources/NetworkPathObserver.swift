// E8 (upgrade-sweep 2026-08): `NWPathMonitor` appeared zero times in the iOS
// target, so the app could not tell "this phone has no network" from "the Mac
// is asleep" — every failure funnelled into `.macUnreachable` or a 180s chat
// timeout whose banner blamed the Mac.
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
    /// Fires each time the path transitions from offline to satisfied.
    var onPathRestored: (() -> Void)?

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
                self?.apply(isOffline: offline)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    /// Test seam: the same transition logic the path handler drives.
    func apply(isOffline offline: Bool) {
        let wasOffline = isOffline
        isOffline = offline
        // nil -> online counts as restored: a cold launch that comes up
        // already connected must still resume persisted queued sends, or they
        // sit until the network flaps (review fix, 2026-08-28). Resuming with
        // an empty queue is a no-op, so the extra fire is free.
        if wasOffline != false, !offline {
            onPathRestored?()
        }
    }

    /// Copy for the offline banner. nil while online or still unknown.
    static func offlineBannerMessage(isOffline: Bool?) -> String? {
        isOffline == true
            ? "This iPhone has no network connection. Messages are queued and will send when it returns."
            : nil
    }
}
