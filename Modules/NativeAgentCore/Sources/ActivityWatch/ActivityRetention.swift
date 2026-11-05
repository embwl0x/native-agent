import Foundation
import PersistenceCore

// Blueprint: | `ActivityRetention.swift` | `ActivityRetentionRunner`: checked prune cadence; unavailable state pauses cleanup; completion is durable |

/// Persist the prune cadence so laptops that restart within a day still enforce retention.
public struct ActivityRetentionRunner: Sendable {
    /// Hourly enforcement adds needless VACUUM work to a 30-day retention window.
    public static let defaultInterval: TimeInterval = 6 * 3600

    public let stateURL: URL
    private struct Cadence: Codable {
        let last_run_at: Double
    }

    public init(dataRoot: URL) {
        self.stateURL = ActivityWatchPaths.retentionStateURL(dataRoot: dataRoot)
    }

    /// Unavailable state throws: scheduling pauses until its exact file changes.
    public func nextRunDelay(now: Double = Date().timeIntervalSince1970) throws -> TimeInterval {
        guard let last = try lastRunAt(), last <= now,
              last + Self.defaultInterval > now else { return 0 }
        return last + Self.defaultInterval - now
    }

    /// Missing state is fresh; existing unreadable or corrupt state is a fault.
    public func lastRunAt() throws -> Double? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch CocoaError.fileNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: stateURL.path])
        }
        let data = try Data(contentsOf: stateURL)
        let stamp = try JSONDecoder().decode(Cadence.self, from: data).last_run_at
        guard stamp.isFinite else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: stateURL.path])
        }
        return stamp
    }

    public func isDue(now: Double) throws -> Bool {
        guard let last = try lastRunAt() else { return true }
        // A backwards clock step must not defer pruning until a future stamp catches up.
        if last > now { return true }
        return now - last >= Self.defaultInterval
    }

    /// Read cadence before pruning; failure preserves its bytes and cannot count as due.
    public func runIfDue(
        store: ActivitySpanStore,
        policy: ActivityPolicy,
        now: Double = Date().timeIntervalSince1970
    ) async throws {
        guard try isDue(now: now) else { return }
        let retention = Double(max(1, policy.retentionDays)) * 86_400
        try await store.prune(olderThan: retention, now: now)
        try recordRun(at: now)
    }

    public func recordRun(at timestamp: Double) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Cadence(last_run_at: timestamp))
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: stateURL)
    }
}
