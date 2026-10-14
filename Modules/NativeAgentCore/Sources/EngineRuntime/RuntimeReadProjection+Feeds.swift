import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import Browser
import NotificationInbox
import ApprovalInbox
import Skills
import Desk
import StandingBots
import DreamREMCycle

private enum NextGenStatusFeedAvailability: Equatable {
    case absent
    case measured
    case unavailable
}

extension RuntimeReadProjection {
    public static func savedThings(dataRoot: URL) async -> (
        desk: [DeskItem], botReplies: [(BotsShelfRecord, ShelfEntry)], dreams: [DreamEntry]
    ) {
        let desk = ((try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }.prefix(40)
        let records = await Task.detached(priority: .utility) {
            (try? BotsShelfRecord.read(root: dataRoot)) ?? []
        }.value
        var replies: [(BotsShelfRecord, ShelfEntry)] = []
        for record in records {
            for entry in record.sortedEntries where !entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                replies.append((record, entry))
            }
        }
        let botReplies = replies.sorted { $0.1.runAt > $1.1.runAt }.prefix(40)
        let dreams = await Task.detached(priority: .utility) {
            FileBackedDreamDiary(dataRoot: dataRoot).listEntries(limit: 40)
        }.value
        return (Array(desk), Array(botReplies), dreams)
    }

    public static func getNotificationStatus(dataRoot: URL) async throws -> NotificationRuntimeStatus {
        // Neither authoritative feed means unmeasured; damaged authority is
        // unavailable rather than a ready zero-count runtime.
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
        do {
            let receiptRead = try await SwiftNativePersistenceCore()
                .tailJSONLReadReceipt(receiptsPath, limit: 20, maxBytes: 1_048_576)
            guard receiptRead.malformedJSONRowCount == 0,
                  receiptRead.rows.allSatisfy({ if case .object = $0 { return true }; return false }),
                  receiptRead.physicalRowsScanned > 0 || receiptRead.bytesRead == 0 else {
                throw PersistenceCoreError.ioFailure("The notification receipt feed is malformed.")
            }
            let approvals = try SwiftNativeApprovalInbox.loadApprovalRowsChecked(at: approvalsPath)
            let pendingApprovals = approvals.filter {
                guard case .object(let row) = $0 else { return false }
                return row["status"] == .string("pending")
            }.count
            let latestReceipt = try receiptRead.rows.last.map {
                try Self.decodeJSONValue($0, as: NativeActionReceipt.self, context: "getNotificationStatus(swiftNative)")
            }
            return NotificationRuntimeStatus(
                status: "ready", authorization: "app_requested", pendingApprovals: pendingApprovals,
                receiptCount: receiptRead.rows.count, latestReceipt: latestReceipt,
                createdAt: NativeTimestampFormat.sixDigitUTCOffset(Date())
            )
        } catch {
            return NotificationRuntimeStatus(
                status: "unavailable", authorization: nil, pendingApprovals: nil,
                receiptCount: nil, latestReceipt: nil,
                createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
            )
        }
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
        let client = SwiftNativeBrowserClient.defaultClient(dataRoot: root)
        do {
            let envelope = try await client.browserStatus()
            return try Self.decodeJSONValue(envelope, as: BrowserRuntimeStatus.self, context: "getBrowserStatus(swiftNative)")
        } catch {
            return BrowserRuntimeStatus(
                status: "unavailable", profilePath: nil, sourcePath: nil,
                screenshotPath: nil, approvedDomains: nil, domainPolicy: nil,
                activeRuns: nil, receiptCount: nil, latestReceipt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
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
        guard let read = try? SwiftNativePersistenceCore.tailPhysicalLines(
            path, limit: limit, maxBytes: 1_048_576
        ) else { return [] }
        let decoder = JSONDecoder.nativeAgent
        let tail = read.lines
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
