import Foundation
import NativeAgentShared
import PersistenceCore
import TrustPersistence
import TrustCenter
import Browser
import NotificationInbox

private enum NextGenStatusFeedAvailability: Equatable {
    case absent
    case measured
    case unavailable
}

struct LossyElement<T: Decodable>: Decodable {
    let result: Result<T, Error>

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            result = .success(try container.decode(T.self))
        } catch {
            result = .failure(error)
        }
    }
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
        if let envelope = try await client.notificationStatus() {
            return try Self.decodeJSONValue(envelope, as: NotificationRuntimeStatus.self, context: "getNotificationStatus(swiftNative)")
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
        if let envelope = try await client.browserStatus() {
            return try Self.decodeJSONValue(envelope, as: BrowserRuntimeStatus.self, context: "getBrowserStatus(swiftNative)")
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

    public static func decodeLossyArray<T: Decodable>(_ data: Data, context: String) throws -> [T] {
        let decoder = JSONDecoder.nativeAgent
        // Decode into an array of element containers; if the top level isn't an
        // array, fall back to the strict decode (preserves prior behavior for
        // dict-wrapped or otherwise-shaped responses).
        guard let elements = try? decoder.decode([LossyElement<T>].self, from: data) else {
            return try decoder.decode([T].self, from: data)
        }
        var firstDropError: Error? = nil
        let survivors: [T] = elements.compactMap { element in
            switch element.result {
            case .success(let value):
                return value
            case .failure(let error):
                if firstDropError == nil { firstDropError = error }
                print("[NativeAgent] \(context) dropped a malformed element: \(error)")
                return nil
            }
        }
        // FIX (B): partial success (some survivors) is fine and returns the good
        // elements. But if the raw array was non-empty and EVERY element failed
        // to decode (e.g. a server-side schema change), a silent [] would be
        // indistinguishable from a genuinely empty list. Throw so the caller's
        // decodeLogged records it in lastRefreshError; the caller still falls
        // back to an empty list, so the returned data is unchanged.
        if !elements.isEmpty && survivors.isEmpty {
            throw firstDropError ?? NSError(
                domain: "NativeAgent",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "\(context): all \(elements.count) element(s) failed to decode"]
            )
        }
        return survivors
    }

    public static func readLocalJSON<T: Decodable>(_ url: URL, fallbackJSON: String) throws -> T {
        let data: Data
        if FileManager.default.fileExists(atPath: url.path),
           let read = try? Data(contentsOf: url) {
            data = read
        } else {
            data = Data(fallbackJSON.utf8)
        }
        return try JSONDecoder.nativeAgent.decode(T.self, from: data)
    }
}
