import Foundation
// Blueprint: | `Browser+ActiveRuns.swift` | process-local run cancellation registry and attachment latch |

// MARK: - Active browser run ownership

/// Remember cancellation between running persistence and WebKit task attachment so the exact task is cancelled on arrival.
@MainActor
public final class BrowserRunCancellationLatch {
    public nonisolated init() {}
    private var cancellationRequested = false
    private var cancelAction: (@MainActor () -> Void)?

    public func install(_ action: @escaping @MainActor () -> Void) {
        guard !cancellationRequested else {
            action()
            return
        }
        cancelAction = action
    }

    public func cancel() {
        cancellationRequested = true
        let action = cancelAction
        cancelAction = nil
        action?()
    }
}

/// Durable lifecycle stays in runs.json; this registry targets only the live task and navigation. Tokens prevent stale cleanup from unregistering a newer run
/// with the same id.
@MainActor
public final class BrowserActiveRunRegistry {
    public static let shared = BrowserActiveRunRegistry()

    private struct Entry {
        var token: UUID
        var cancel: @MainActor () -> Void
    }

    private var entries: [String: Entry] = [:]

    @discardableResult
    public func register(runID: String, cancel: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        entries[runID] = Entry(token: token, cancel: cancel)
        return token
    }

    public func unregister(runID: String, token: UUID) {
        guard entries[runID]?.token == token else { return }
        entries.removeValue(forKey: runID)
    }

    @discardableResult
    public func cancel(runID: String?) -> Bool {
        let key: String?
        if let runID, !runID.isEmpty {
            key = entries[runID] == nil ? nil : runID
        } else {
            key = entries.keys.sorted().first
        }
        guard let key, let entry = entries[key] else { return false }
        entry.cancel()
        return true
    }

    public func contains(runID: String) -> Bool {
        entries[runID] != nil
    }
}
