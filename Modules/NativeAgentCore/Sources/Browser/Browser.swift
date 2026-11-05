// Read owner files without browser effects; full captures stay on disk while summaries retain paths.

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Browser.swift` | Owner recovery and damaged-run status; capture paths; WebKit owns website data |

public struct SwiftNativeBrowserClient: Sendable {
    public let runsPath: URL
    public let receiptsPath: URL
    public let sourcesDir: URL
    public let screenshotsDir: URL
    let now: @Sendable () -> Date

    /// Capped receipt feed; off-disk backup only, excluded from archive inputs and phone sync.
    public var nativeActionsReceiptsPath: URL {
        runsPath.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("actions/receipts.jsonl")
    }

    /// The data root whose record holds this browser's standalone receipts.
    var dataRoot: URL {
        runsPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    public init(
        runsPath: URL,
        receiptsPath: URL,
        sourcesDir: URL,
        screenshotsDir: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runsPath = runsPath
        self.receiptsPath = receiptsPath
        self.sourcesDir = sourcesDir
        self.screenshotsDir = screenshotsDir
        self.now = now
    }

    /// WebKit owns website data; the data-root client resolves only operation and capture files.
    public static func defaultClient(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> SwiftNativeBrowserClient {
        let browser = dataRoot
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
        return SwiftNativeBrowserClient(
            runsPath: browser.appendingPathComponent("runs.json"),
            receiptsPath: browser.appendingPathComponent("receipts.jsonl"),
            sourcesDir: browser.appendingPathComponent("sources", isDirectory: true),
            screenshotsDir: browser.appendingPathComponent("screenshots", isDirectory: true)
        )
    }

    public func browserStatus() async throws -> JSONValue {
        // Only a missing run feed is empty; malformed content is unavailable.
        async let runsRead = Self.readCanonicalRuns(at: runsPath, malformed: PersistenceCoreError.ioFailure("The browser run feed is malformed."))
        async let receiptsRead = SwiftNativePersistenceCore.tailJSONLReadReceipt(receiptsPath, limit: 20, maxBytes: 1_048_576)
        let runs = try await runsRead
        let recoveryIssue = self.recoveryIssue
        let admissionIssues = runs.filter { $0.objectValue?["blocksNewEffects"] == .bool(true) }

        let activeRuns: [JSONValue] = runs.filter { run in
            guard case .object(let obj) = run, case .string(let s)? = obj["status"] else {
                return false
            }
            return s == "running" || s == "waiting_approval"
        }

        // File order is oldest first; keep the bounded tail read.
        let receiptRead = try await receiptsRead
        guard receiptRead.malformedJSONRowCount == 0,
              receiptRead.rows.allSatisfy({ if case .object = $0 { return true }; return false }),
              receiptRead.physicalRowsScanned > 0 || receiptRead.bytesRead == 0 else {
            throw PersistenceCoreError.ioFailure("The browser receipt feed is malformed.")
        }
        let receipts = receiptRead.rows
        let artifactKeys: Set<String> = [
            "url", "title", "ipcUrl", "ipcTitle", "httpStatus", "textPath", "htmlPath", "linksPath", "pngPath", "path",
            "textChars", "linkCount", "captureRetention", "openError", "canceled"
        ]
        let receiptKeys = Set([
            "id", "transitionId", "domain", "status", "opened", "dryRun", "createdAt", "updatedAt", "completedAt", "verificationStatus",
            "outcomeKind", "errorCode", "sourceReceipt", "screenshotReceipt"
        ])
            .union(artifactKeys)
        let latestReceipt = receipts.last.map { value -> JSONValue in
            guard case .object(let row) = value else { return .null }
            return .object(row.filter { receiptKeys.contains($0.key) }.mapValues { value in
                guard case .object(let artifact) = value else { return value }
                return .object(artifact.filter { artifactKeys.contains($0.key) })
            })
        } ?? .null

        return .object([
            "status": .string(recoveryIssue == nil && admissionIssues.isEmpty ? "ready" : "unavailable"),
            "recoveryIssue": recoveryIssue.map(JSONValue.string) ?? .null,
            "admissionIssues": .array(admissionIssues),
            "unavailableRuns": .array(runs.filter { $0.objectValue?["status"] == .string("unavailable") }),
            "sourcePath": .string(sourcesDir.path),
            "screenshotPath": .string(screenshotsDir.path),
            "activeRuns": .array(activeRuns),
            "receiptCount": .int(Int64(receipts.count)),
            "receiptPath": .string(receiptsPath.path),
            "latestReceipt": latestReceipt,
            "createdAt": .string(Self.nowISO(now())),
        ])
    }

    /// ISO-8601 UTC with six fractional digits and a `+00:00` suffix.
    static func nowISO(_ date: Date) -> String {
        NativeTimestampFormat.sixDigitUTCOffset(date)
    }
}
