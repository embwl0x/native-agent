import Foundation

// Blueprint: | `ICloudSyncStatePaths.swift` | `ICloudSyncStatePaths`; Local bookkeeping and read-only bridge health. |

/// Read-only view of the running bridge. No probing, persisted mirror, or sync authority.
public struct ICloudBridgeHealthSnapshot: Sendable {
    public enum Transport: Sendable { case cloudKit, iCloudDrive }
    public enum Health: Sendable {
        case unmeasured, available, signedOut, notEntitled, quotaExceeded
        case accountFailure(code: Int, detail: String)
        case unavailable(String)
        /// Another Mac on this Apple Account holds the phone's pairing.
        case pairedElsewhere
    }

    public let transport: Transport
    public let health: Health
    public let documentsURL: URL?
    public let sendMeasured: Bool
    public let sendFailures: [String: Health]
    /// Phones paired with this Mac, as the pairing owner reads them; nil when that read failed. With none, phone sync was never set up here.
    public let pairedPhones: Int?

    public init(transport: Transport, health: Health, documentsURL: URL? = nil,
                sendMeasured: Bool = false, sendFailures: [String: Health] = [:], pairedPhones: Int? = nil) {
        self.transport = transport
        self.health = health
        self.documentsURL = documentsURL
        self.sendMeasured = sendMeasured
        self.sendFailures = sendFailures
        self.pairedPhones = pairedPhones
    }
}

/// The bridge installs a weak reader; Doctor consumes its current state on demand.
@MainActor
public enum ICloudBridgeHealthReader {
    private static var readers: [String: @MainActor () -> ICloudBridgeHealthSnapshot?] = [:]

    public static func register(dataRoot: URL, read: @escaping @MainActor () -> ICloudBridgeHealthSnapshot?) {
        readers[dataRoot.standardizedFileURL.path] = read
    }

    public static func snapshot(dataRoot: URL) -> ICloudBridgeHealthSnapshot? {
        readers[dataRoot.standardizedFileURL.path]?()
    }
}

/// Keep bookkeeping local so iCloud faults cannot erase the evidence needed to repair them. A dependency-free state target lets sync and Doctor share paths
/// without a runtime cycle.
public enum ICloudSyncStatePaths {
    public static func stateDirectory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("icloud", isDirectory: true)
    }

    /// The last account rejection stays visible locally until a successful pull.
    public static func accountFailure(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("account_failure.json")
    }

    /// Processed IDs prevent restart from redispatching an executed phone command.
    public static func processedIds(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("processed_ids.json")
    }

    /// Preserve damaged processed-ID bytes so Doctor can report the lost replay window.
    public static func processedIdsCorruptBackup(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("processed_ids.corrupt.json")
    }

    /// Completion markers forbid redispatch when a response landed but processed-ID saving or archival failed.
    public static func completedUnarchivedDirectory(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot)
            .appendingPathComponent("completed-unarchived", isDirectory: true)
    }

    public static let completedUnarchivedExtension = "completed-unarchived"

    public static func completedUnarchivedMarker(dataRoot: URL, msgId: String) -> URL {
        completedUnarchivedDirectory(dataRoot: dataRoot)
            .appendingPathComponent("\(msgId).\(completedUnarchivedExtension)")
    }

    /// Persist skipped-group reasons so Doctor can distinguish stale phone projections from current state.
    public static func snapshotSkips(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("snapshot_skips.json")
    }

    /// A missing marker directory is normal absence, not a read failure.
    public static func completedUnarchivedMsgIds(dataRoot: URL) throws -> [String] {
        let dir = completedUnarchivedDirectory(dataRoot: dataRoot)
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return items
            .filter { $0.pathExtension == completedUnarchivedExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
