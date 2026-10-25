import Foundation
// Blueprint: | `Browser+ActiveRuns.swift` | process-local run cancellation registry and attachment latch |

// MARK: - Active browser run ownership

/// Closes the short interval between canonical `running` persistence and the
/// WebKit task becoming cancellable. A cancel that arrives before attachment
/// is remembered and applied immediately when the exact task is installed.
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

/// Process-local owner for live visible-browser work. Canonical lifecycle still
/// lives in Browser/runs.json; this registry exists only so a persisted cancel
/// can target the exact in-flight Task and WebKit navigation before a late
/// capture or success receipt is produced. Tokens prevent stale defer cleanup
/// from unregistering a newer run that reused the same id.
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
