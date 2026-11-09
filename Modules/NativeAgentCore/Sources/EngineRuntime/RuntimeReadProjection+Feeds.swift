import Foundation
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
import SwarmRuns
// Blueprint: | `RuntimeReadProjection+Feeds.swift` | Checked owner-backed guidance, history, approval counts and bounded evidence tails |

extension RuntimeReadouts {
    @MainActor @Observable
    public final class Runs {
        @ObservationIgnored var diagnosticsDidChange: (@MainActor () -> Void)?
        public private(set) var rows: [RunRecord] = []
        public private(set) var readSucceeded: Bool?
        public private(set) var readIssue: String?
        public private(set) var observationIssue: String?
        public func setObservationIssue(_ issue: String?) { observationIssue = issue }
        @ObservationIgnored private let latest = LatestRead()
        public nonisolated init() {}
        @discardableResult
        public func refresh(dataRoot: URL) async throws -> [RunRecord] {
            let read: Result<[RunRecord], Error> = await latest.read({
                do { return .success(try await RuntimeReadouts.readRunHistory(dataRoot: dataRoot)) }
                catch { return .failure(error) }
            }, publish: { next in
                switch next {
                case .success(let value): rows = value; readSucceeded = true; readIssue = nil
                case .failure(let error): readSucceeded = false; readIssue = error.localizedDescription
                }
                diagnosticsDidChange?()
            })
            return try read.get()
        }
    }
}

private enum StatusFeedAvailability: Equatable {
    case absent
    case measured
    case unavailable
}

extension RuntimeReadouts {
    @concurrent public static func readRunHistory(dataRoot: URL) async throws -> [RunRecord] {
        Array(try await readRunLedger(dataRoot: dataRoot).sorted { $0.createdAt > $1.createdAt }.prefix(200))
    }

    /// A detail lookup reads the ledger, without the history list's display limit.
    @concurrent public static func readRunLedger(dataRoot: URL) async throws -> [RunRecord] {
        let path = dataRoot.appendingPathComponent("runs/runs.json")
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return try RunLedger.records(from: data)
    }

    public static func getNotificationStatus(dataRoot: URL) async throws -> NotificationRuntimeStatus {
        // Read pending counts from the approval owner.
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
        // Read without write-back; absent feeds stay unmeasured until owner recovery succeeds.
        let root = dataRoot
        let browserRoot = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
        let runsPath = browserRoot.appendingPathComponent("runs.json")
        let receiptsPath = browserRoot.appendingPathComponent("receipts.jsonl")
        let client = SwiftNativeBrowserClient.defaultClient(dataRoot: root)
        let recoveryIssue = client.recoveryIssue
        let availability = Self.statusFeedAvailability([runsPath, receiptsPath])
        guard availability == .measured else {
            return BrowserRuntimeStatus(
                status: availability == .absent && recoveryIssue == nil ? "unmeasured" : "unavailable",
                sourcePath: nil,
                screenshotPath: nil,
                activeRuns: nil,
                receiptCount: nil,
                latestReceipt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                recoveryIssue: recoveryIssue
            )
        }
        do {
            let envelope = try await client.browserStatus()
            return try Self.decodeJSONValue(envelope, as: BrowserRuntimeStatus.self, context: "getBrowserStatus(swiftNative)")
        } catch {
            return BrowserRuntimeStatus(
                status: "unavailable", sourcePath: nil,
                screenshotPath: nil,
                activeRuns: nil, receiptCount: nil, latestReceipt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                recoveryIssue: recoveryIssue
            )
        }
    }

    private static func statusFeedAvailability(_ paths: [URL]) -> StatusFeedAvailability {
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

    /// Load guidance source only for source review.
    public static func skills(dataRoot: URL, includingSource: Bool = false) async throws -> [SkillRecord] {
        try InstalledSkillInventory.entries(dataRoot: dataRoot, includingSource: includingSource)
    }

    /// Require a bare array; nil means unreadable and preserves proven rows, while `[]` is checked absence or emptiness.
    public static func runs(dataRoot: URL) async -> [RunRecord]? {
        let path = dataRoot
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("runs.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard var rows = try? RunLedger.records(from: data) else { return nil }
        rows.sort { $0.createdAt > $1.createdAt }
        return Array(rows.prefix(200))
    }

    /// Retain tail coverage: missing is empty, malformed or unreadable evidence fails even with valid siblings, and consumers decide blank-row policy.
    public static func tailJSONL<T: Decodable>(path: URL, limit: Int) async ->
        (rows: [T], malformedRows: Int, blankRows: Int, truncated: Bool, readFailed: Bool, failure: String?) {
        let read: (lines: [Data], bytesRead: Int, truncatedToByteWindow: Bool, leadingFragment: Bool)
        do { read = try SwiftNativePersistenceCore.tailPhysicalLines(path, limit: limit, maxBytes: 1_048_576) ?? ([], 0, false, false) }
        catch { return ([], 0, 0, false, true, "Could not read \(path.lastPathComponent): \(error.localizedDescription)") }
        let decoder = JSONDecoder.nativeAgent
        let tail = read.lines.dropFirst(read.leadingFragment ? 1 : 0)
        var out: [T] = []
        var malformed = 0
        var blank = 0
        var cause: String?
        out.reserveCapacity(tail.count)
        for line in tail {
            guard let line = String(data: line, encoding: .utf8) else {
                malformed += 1
                cause = cause ?? "Invalid UTF-8"
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { blank += 1; continue }
            do { out.append(try decoder.decode(T.self, from: Data(trimmed.utf8))) }
            catch {
                malformed += 1
                cause = cause ?? error.localizedDescription
            }
        }
        let failure = cause.map { "\(path.lastPathComponent) has \(malformed) malformed receipt row(s): \($0)" }
        return (out, malformed, blank, read.truncatedToByteWindow, false, failure)
    }
}
