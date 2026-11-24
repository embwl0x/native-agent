import Foundation
import Observation
import Network

/// NWPathMonitor proves only a usable device path; Mac/iCloud availability remains the bridge's responsibility.
@MainActor
@Observable
final class NetworkPathObserver {
    static let shared = NetworkPathObserver()

    /// Unknown path before the first update must not appear as an outage.
    private(set) var isOffline: Bool?

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "io.nativeagent.mobile.networkpath")
    @ObservationIgnored private var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    private struct Restored: NotificationCenter.MainActorMessage {
        typealias Subject = NetworkPathObserver
    }

    func onRestoration(_ action: @escaping @MainActor () -> Void) -> NotificationCenter.ObservationToken {
        let token = NotificationCenter.default.addObserver(of: self, for: Restored.self) { _ in action() }
        start()
        if isOffline == false { Task { action() } }
        return token
    }

    private func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOffline != offline else { return }
                self.isOffline = offline
                if !offline { NotificationCenter.default.post(Restored(), subject: self) }
            }
        }
        monitor.start(queue: queue)
    }

    static func offlineBannerMessage(isOffline: Bool?) -> String? {
        isOffline == true
            ? "This iPhone has no network connection. Messages are queued and will send when it returns."
            : nil
    }
}
