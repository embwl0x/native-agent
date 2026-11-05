import Foundation
import Network

/// NWPathMonitor proves only a usable device path; Mac/iCloud availability remains the bridge's responsibility.
@MainActor
final class NetworkPathObserver: ObservableObject {
    static let shared = NetworkPathObserver()

    /// Unknown path before the first update must not appear as an outage.
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

    static func offlineBannerMessage(isOffline: Bool?) -> String? {
        isOffline == true
            ? "This iPhone has no network connection. Messages are queued and will send when it returns."
            : nil
    }
}
