import Foundation

/// Owns the detached-window preference subscription. It deliberately accepts a
/// notification center so its single-subscription and teardown guarantees can
/// be exercised without observing the user's real defaults domain.
final class DarkModePreferenceObserver {
    private let center: NotificationCenter
    private let name: Notification.Name
    private let object: AnyObject?
    private var token: NSObjectProtocol?

    init(
        center: NotificationCenter = .default,
        name: Notification.Name = UserDefaults.didChangeNotification,
        object: AnyObject? = UserDefaults.standard
    ) {
        self.center = center
        self.name = name
        self.object = object
    }

    var isObserving: Bool { token != nil }

    func start(_ handler: @escaping @MainActor () -> Void) {
        guard token == nil else { return }
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
    }

    func stop() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }

    deinit {
        if let token {
            center.removeObserver(token)
        }
    }
}
