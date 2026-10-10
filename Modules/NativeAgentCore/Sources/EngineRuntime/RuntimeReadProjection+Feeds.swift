import Foundation
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import Browser
import NotificationInbox
import Skills

private enum NextGenStatusFeedAvailability: Equatable {
    case absent
    case measured
    case unavailable
}

extension RuntimeReadProjection {
    public static func getNotificationStatus(dataRoot: URL) async throws -> NotificationRuntimeStatus {
        // Subsystem #25b wave 38 W20 (2026-06-02): when .notificationStatus is ON,
        // the in-process SwiftNativeNotificationStatus reads the co-located
        // native_power/notifications/receipts.jsonl (tail 20, newest-first) +
        // counts the pending entries in workflows/approvals/requests.json and
        // serves the same notification_status() envelope without the HTTP
        // round-trip. The reader is a PURE read (no write-back): the daemon only
        // appends to receipts.jsonl (atomic line append) and read_json's the
        // approvals file (its R-M-W is approvals_lock-guarded + write_json is
        // tmp+os.replace atomic), so a status read never sees a torn file — no
        // flock prereq. A root with neither authoritative feed is unmeasured,
        // not a ready zero-count runtime.
        let root = dataRoot
        let receiptsPath = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        let approvalsPath = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let availability = Self.statusFeedAvailability([receiptsPath, approvalsPath])
        guard availability == .measured else {
            return NotificationRuntimeStatus(
                status: availability == .absent ? "unmeasured" : "unavailable",
                authorization: nil,
                pendingApprovals: nil,
                receiptCount: nil,
                latestReceipt: nil,
                createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
            )
        }
        let client = SwiftNativeNotificationStatus(
            receiptsPath: receiptsPath,
            approvalsPath: approvalsPath
        )
        do {
            if let envelope = try await client.notificationStatus() {
                return try Self.decodeJSONValue(envelope, as: NotificationRuntimeStatus.self, context: "getNotificationStatus(swiftNative)")
            }
        } catch {
            return NotificationRuntimeStatus(
                status: "unavailable", authorization: nil, pendingApprovals: nil,
                receiptCount: nil, latestReceipt: nil,
                createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
            )
        }
        // A reader that cannot produce an envelope has not measured status.
        return NotificationRuntimeStatus(
            status: "unmeasured",
            authorization: nil,
            pendingApprovals: nil,
            receiptCount: nil,
            latestReceipt: nil,
            createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

    public static func getBrowserStatus(dataRoot: URL) async throws -> BrowserRuntimeStatus {
        // Subsystem #27 wave 33 W17 (2026-06-01): when .browser is ON, the
        // in-process SwiftNativeBrowserClient reads the co-located
        // native_power/browser/{runs.json,receipts.jsonl} + trust-policy
        // approvedDomains and serves the same browser_status() envelope without
        // the HTTP round-trip. The reader is a PURE read (no write-back); the
        // daemon's run/cancel R-M-W of runs.json is flock-guarded this wave so a
        // status read never sees a torn file. A root with no browser run or
        // receipt feed is unmeasured rather than an idle zero-count runtime.
        let root = dataRoot
        let browserRoot = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
        let runsPath = browserRoot.appendingPathComponent("runs.json")
        let receiptsPath = browserRoot.appendingPathComponent("receipts.jsonl")
        let availability = Self.statusFeedAvailability([runsPath, receiptsPath])
        guard availability == .measured else {
            return BrowserRuntimeStatus(
                status: availability == .absent ? "unmeasured" : "unavailable",
                profilePath: nil,
                sourcePath: nil,
                screenshotPath: nil,
                approvedDomains: nil,
                domainPolicy: nil,
                activeRuns: nil,
                receiptCount: nil,
                latestReceipt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        let client = makeBrowserClient(dataRoot: root)
        do {
            if let envelope = try await client.browserStatus() {
                return try Self.decodeJSONValue(envelope, as: BrowserRuntimeStatus.self, context: "getBrowserStatus(swiftNative)")
            }
        } catch {
            return BrowserRuntimeStatus(
                status: "unavailable", profilePath: nil, sourcePath: nil,
                screenshotPath: nil, approvedDomains: nil, domainPolicy: nil,
                activeRuns: nil, receiptCount: nil, latestReceipt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        // The read boundary could not establish browser status.
        return BrowserRuntimeStatus(
            status: "unmeasured",
            profilePath: nil,
            sourcePath: nil,
            screenshotPath: nil,
            approvedDomains: nil,
            domainPolicy: nil,
            activeRuns: nil,
            receiptCount: nil,
            latestReceipt: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private static func statusFeedAvailability(_ paths: [URL]) -> NextGenStatusFeedAvailability {
        let fileManager = FileManager.default
        var foundEvidence = false
        for path in paths where fileManager.fileExists(atPath: path.path) {
            foundEvidence = true
            guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  fileManager.isReadableFile(atPath: path.path) else {
                return .unavailable
            }
        }
        return foundEvidence ? .measured : .absent
    }

    public static func decodeJSONValue<T: Decodable>(_ value: JSONValue, as type: T.Type, context: String) throws -> T {
        let data = try value.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(T.self, from: data)
    }

    /// The learned-skills registry, newest first. One malformed row drops
    /// that row instead of blanking the list; a list where every row is
    /// malformed throws, so it never reads as an empty registry.
    public static func skills(dataRoot: URL) async throws -> [SkillRecord] {
        let rows = try await makeSkillsClient(root: dataRoot).listSkills()
        var firstDropError: Error?
        let survivors = rows.compactMap { row -> SkillRecord? in
            do { return try SkillRecord(row: row) } catch {
                if firstDropError == nil { firstDropError = error }
                print("[NativeAgent] getSkills(swiftNative) dropped a malformed element: \(error)")
                return nil
            }
        }
        if !rows.isEmpty, survivors.isEmpty, let firstDropError { throw firstDropError }
        return survivors
    }

    /// `runs/runs.json`, newest first, at most 200. `[]` means the ledger
    /// doesn't exist (or holds no runs); nil means a ledger EXISTS but could
    /// not be read or decoded, so a snapshot writer can skip its write and a
    /// corrupt ledger never overwrites last-good runs with fabricated-empty
    /// state (sync-audit #1 discipline). The on-disk shape may be a bare
    /// array or `{"runs": [...]}`.
    public static func runs(dataRoot: URL) async -> [RunRecord]? {
        let path = dataRoot
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("runs.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder.nativeAgent
        var rows: [RunRecord]
        if let arr = try? decoder.decode([RunRecord].self, from: data) {
            rows = arr
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = obj["runs"],
                  let runsData = try? JSONSerialization.data(withJSONObject: runs),
                  let arr = try? decoder.decode([RunRecord].self, from: runsData) {
            rows = arr
        } else {
            return nil
        }
        rows.sort { $0.createdAt > $1.createdAt }
        return Array(rows.prefix(200))
    }

    /// The last `limit` rows of a JSONL file, each decoded on its own; a row
    /// that does not decode is skipped and a missing file reads as `[]`.
    /// Reads at most the last 1 MB, dropping the partial first line.
    public static func tailJSONL<T: Decodable>(path: URL, limit: Int) async -> [T] {
        guard limit > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return []
        }
        let size = sizeNumber.uint64Value
        guard size > 0 else { return [] }

        let toRead = min(size, 1_048_576)
        let seekFromEnd = size > toRead
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        if seekFromEnd {
            do {
                try handle.seek(toOffset: size - toRead)
            } catch {
                return []
            }
        }
        let data = handle.readData(ofLength: Int(toRead))
        let decoder = JSONDecoder.nativeAgent
        let tail = decodeTailLines(data, dropFirstPartial: seekFromEnd).suffix(limit)
        var out: [T] = []
        out.reserveCapacity(tail.count)
        for line in tail {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let lineData = trimmed.data(using: .utf8),
               let row = try? decoder.decode(T.self, from: lineData) {
                out.append(row)
            }
        }
        return out
    }

    public static func readLocalJSON<T: Decodable>(_ url: URL, fallbackJSON: String) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            data = Data(fallbackJSON.utf8)
        }
        return try JSONDecoder.nativeAgent.decode(T.self, from: data)
    }
}
