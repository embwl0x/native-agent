import Foundation
import Darwin
import PersistenceCore

// MARK: - SwiftNative impl (registry listing only)

public final class SwiftNativeWorkflowOrchestrationClient: WorkflowOrchestrationClient {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    private let now: @Sendable () -> String
    private let useFileLock: Bool

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> String = { WorkflowOrchestrationClock.nowISO() },
        useFileLock: Bool = true
    ) {
        self.root = root
        self.persistence = persistence
        self.now = now
        self.useFileLock = useFileLock
    }

    private var registryPath: URL { root.appendingPathComponent("workflows/registry.json") }

    /// Only an absent directory entry bootstraps defaults; damaged or unreadable
    /// saved workflows must survive a list attempt, including a dangling symlink.
    private static func readWorkflowRegistry(_ path: URL) throws -> [JSONValue] {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            var metadata = stat()
            if lstat(path.path, &metadata) != 0, errno == ENOENT { return [] }
            throw error
        }
        guard case .array(let rows) = try JSONValue.parse(data) else {
            throw NSError(domain: "WorkflowOrchestration", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Workflow registry is unavailable: expected a JSON array at \(path.path). Saved bytes were preserved."
            ])
        }
        return rows
    }

    public func listWorkflows() async throws -> [JSONValue] {
        // The entire read -> merge -> write-back shares the registry lock.
        let body: @Sendable () async throws -> [JSONValue] = { [persistence, registryPath, now] in
            let saved = try Self.readWorkflowRegistry(registryPath)
            let defaults = WorkflowDefaults.defaults(now: now())
            let (mergedUnsorted, sorted) = WorkflowMerge.mergeRegistry(defaults: defaults, saved: saved)
            // Persist newly introduced defaults/fields, but an ordinary list
            // read must not fsync identical bytes and wake registry observers.
            let merged = JSONValue.array(mergedUnsorted)
            if merged != .array(saved) {
                try await persistence.writeJSON(merged, to: registryPath)
            }
            return sorted
        }
        if useFileLock {
            return try await persistence.withFileLock(registryPath, body)
        }
        return try await body()
    }
}
