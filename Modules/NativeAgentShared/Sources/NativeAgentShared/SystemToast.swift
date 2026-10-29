import Foundation
import Combine
// Blueprint: | `SystemToast.swift` | `SystemToast` and `SystemToastCenter`: shared replace-by-ID notice values, severity defaults, queue and owned dismissal timers; each platform owns its queue instance |

@MainActor
public struct SystemToast: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: Kind
    public let text: String
    public let createdAt: Date
    public let autoDismissAfter: TimeInterval?

    public enum Kind: String, Sendable { case info, warn, error, success }

    public init(kind: Kind, text: String, autoDismissAfter: TimeInterval? = 3, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.autoDismissAfter = autoDismissAfter
    }

    public nonisolated static func == (lhs: SystemToast, rhs: SystemToast) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class SystemToastCenter: ObservableObject {
    public static let shared = SystemToastCenter()

    @Published public private(set) var queue: [SystemToast] = []

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func push(_ toast: SystemToast) {
        // Replacement retires the previous notice and its timer together.
        dismissTasks.removeValue(forKey: toast.id)?.cancel()
        queue.removeAll { $0.id == toast.id }
        queue.append(toast)

        guard let after = toast.autoDismissAfter else { return }
        guard after.isFinite,
              let nanoseconds = UInt64(exactly: max(0, after * 1_000_000_000).rounded(.towardZero)) else {
            #if os(macOS)
            queue.removeAll { $0.id == toast.id }
            queue.append(SystemToast(kind: .error, text: "\(toast.text) — Auto-dismiss unavailable: invalid duration.",
                                     autoDismissAfter: nil, id: toast.id))
            #endif
            return
        }
        guard after > 0 else { return }
        dismissTasks[toast.id] = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            self.dismiss(toast.id)
        }
    }

    public func push(info text: String, autoDismissAfter: TimeInterval? = 3) {
        push(SystemToast(kind: .info, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(warn text: String, autoDismissAfter: TimeInterval? = 5) {
        push(SystemToast(kind: .warn, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(error text: String, autoDismissAfter: TimeInterval? = 8) {
        push(SystemToast(kind: .error, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(success text: String, autoDismissAfter: TimeInterval? = 3) {
        push(SystemToast(kind: .success, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func dismiss(_ id: UUID) {
        dismissTasks.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0.id == id }
    }

    public func dismissAll() {
        for task in dismissTasks.values { task.cancel() }
        dismissTasks.removeAll()
        queue.removeAll()
    }
}
