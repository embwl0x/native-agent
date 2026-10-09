import Foundation

/// Read-only view of the running bridge. No probing, persisted mirror, or sync authority.
public struct ICloudBridgeHealthSnapshot: Sendable {
    public enum Transport: Sendable { case cloudKit, iCloudDrive }
    public enum Health: Sendable {
        case unmeasured, available, signedOut, notEntitled, quotaExceeded
        case accountFailure(code: Int, detail: String)
        case unavailable(String)
    }

    public let transport: Transport
    public let health: Health
    public let documentsURL: URL?
    public let sendMeasured: Bool
    public let sendFailures: [String: Health]

    public init(transport: Transport, health: Health, documentsURL: URL? = nil,
                sendMeasured: Bool = false, sendFailures: [String: Health] = [:]) {
        self.transport = transport
        self.health = health
        self.documentsURL = documentsURL
        self.sendMeasured = sendMeasured
        self.sendFailures = sendFailures
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

/// Canonical LOCAL paths for the Mac↔iOS sync engine's own bookkeeping.
///
/// These live under `<dataRoot>/icloud/` — deliberately on local disk, not in
/// the iCloud container. The failures they exist to survive (disk full, iCloud
/// permission denial, file-provider hiccup) are exactly the ones that make the
/// iCloud container unwritable, so a marker written there would be lost by the
/// same fault it is meant to record.
///
/// DeviceSync's dependency-free state target lets `MacSyncEngine` and
/// `DoctorChecks` share these paths without a runtime dependency cycle.
public enum ICloudSyncStatePaths {
    public static func stateDirectory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("icloud", isDirectory: true)
    }

    /// The last account rejection stays visible locally until a successful pull.
    public static func accountFailure(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("account_failure.json")
    }

    /// The processed-message-id window that stops a restart from re-dispatching
    /// an already-executed iOS command.
    public static func processedIds(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("processed_ids.json")
    }

    /// Where an UNREADABLE `processed_ids.json` is preserved before it is
    /// replaced, so the evidence survives and Doctor can say the window was
    /// lost rather than silently starting from an empty set.
    public static func processedIdsCorruptBackup(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("processed_ids.corrupt.json")
    }

    /// Directory of `<msgId>.completed-unarchived` markers: iOS commands that
    /// RAN and whose response landed, but whose completion could not be
    /// recorded (processed-id save failed and/or the pending file could not be
    /// archived). A marker is a durable "never dispatch this again".
    public static func completedUnarchivedDirectory(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot)
            .appendingPathComponent("completed-unarchived", isDirectory: true)
    }

    public static let completedUnarchivedExtension = "completed-unarchived"

    public static func completedUnarchivedMarker(dataRoot: URL, msgId: String) -> URL {
        completedUnarchivedDirectory(dataRoot: dataRoot)
            .appendingPathComponent("\(msgId).\(completedUnarchivedExtension)")
    }

    /// Snapshot groups the last publish pass could not build, so Doctor can say
    /// the phone is holding stale approvals/inbox/model-preferences rather than
    /// current state. Rewritten every pass; absent means "nothing skipped".
    public static func snapshotSkips(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("snapshot_skips.json")
    }

    /// Marker msgIds currently on disk. Missing directory = none, which is the
    /// normal case and never an error.
    public static func completedUnarchivedMsgIds(dataRoot: URL) -> [String] {
        let dir = completedUnarchivedDirectory(dataRoot: dataRoot)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == completedUnarchivedExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
