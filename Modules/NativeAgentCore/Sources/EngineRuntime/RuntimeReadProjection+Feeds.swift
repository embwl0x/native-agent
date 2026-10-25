import Foundation
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import Browser
import NotificationInbox
import ApprovalInbox
import PersonaEngine
import Desk
import StandingBots
import DreamREMCycle
import Observation
// Blueprint: | `RuntimeReadProjection+Feeds.swift` | Notification pending counts read only ApprovalInbox; the unwritten notification receipt input and inferred authorization are retired. Browser reads, checked skills with opt-in source/revision from the inventory body epoch, JSON decoding and JSONL tails; engine.runs retains rows and availability through LatestRead and returns its own read for DeviceSync, preserving rows on failure. Saved-things reads delegate to existing Desk, bot, memory and diary owners. |

extension RuntimeReadProjection {
    @MainActor @Observable
    public final class Runs {
        public private(set) var rows: [RunRecord] = []
        public private(set) var readSucceeded: Bool?
        @ObservationIgnored private let latest = LatestRead()
        public nonisolated init() {}
        @discardableResult
        public func refresh(dataRoot: URL) async throws -> [RunRecord] {
            let read = await latest.read({ await RuntimeReadProjection.runs(dataRoot: dataRoot) }, publish: { next in
                readSucceeded = next != nil
                if let next { rows = next }
            })
            guard let read else { throw RuntimeReadError.unreadableFeed("The run history could not be read. Refresh to try again.") }
            return read
        }
    }
}

private enum NextGenStatusFeedAvailability: Equatable {
    case absent
    case measured
    case unavailable
}

extension RuntimeReadProjection {
    public static func getNotificationStatus(dataRoot: URL) async throws -> NotificationRuntimeStatus {
        // The approval owner supplies the panel's pending count. The retired
        // notification receipt path has no producer and cannot measure it.
        let approvalsPath = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let availability = Self.statusFeedAvailability([approvalsPath])
        guard availability == .measured else {
            return NotificationRuntimeStatus(
                status: availability == .absent ? "unmeasured" : "unavailable",
                pendingApprovals: nil,
                createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
            )
        }
        do {
            let pendingApprovals = try SwiftNativeApprovalInbox(root: dataRoot)
                .recordsUnlocked().filter { $0.status == "pending" }.count
            return NotificationRuntimeStatus(
                status: "ready", pendingApprovals: pendingApprovals,
                createdAt: NativeTimestampFormat.sixDigitUTCOffset(Date())
            )
        } catch {
            return NotificationRuntimeStatus(
                status: "unavailable", pendingApprovals: nil,
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
                status: "unavailable", sourcePath: nil,
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

    /// Checked built-in guidance; source is loaded only for source review.
    public static func skills(dataRoot: URL, includingSource: Bool = false) async throws -> [SkillRecord] {
        let entries = try InstalledSkillInventory.entries(dataRoot: dataRoot)
        var survivors: [SkillRecord] = [], firstDropError: Error?
        for entry in entries {
            var skill: SkillRecord
            do { skill = try SkillRecord(row: .object(entry.row)) }
            catch {
                if firstDropError == nil { firstDropError = error }
                print("[NativeAgent] getSkills(swiftNative) dropped a malformed element: \(error)")
                continue
            }
            if includingSource {
                let body = entry.readme
                skill.body = body
                skill.bodyRevision = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            survivors.append(skill)
        }
        if !entries.isEmpty, survivors.isEmpty, let firstDropError { throw firstDropError }
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
            guard let line else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let lineData = trimmed.data(using: .utf8),
               let row = try? decoder.decode(T.self, from: lineData) {
                out.append(row)
            }
        }
        return out
    }
}
