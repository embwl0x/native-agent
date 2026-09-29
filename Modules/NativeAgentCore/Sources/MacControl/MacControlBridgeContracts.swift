import Foundation
import CoreFoundation
import NativeAgentCore
import PersistenceCore

/// The complete response contract for `/macctl/info`. A zero port during
/// startup/teardown is unavailable, not a successful discovery receipt.
/// Keeping the whole response typed makes the mounted HTTP route and its
/// executable boundary proof share one policy and one wire meaning.
struct MacControlBridgeInfoRouteResponse: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case ready
        case methodNotAllowed = "method_not_allowed"
        case unavailable = "bridge_unavailable"
    }

    let state: State
    let port: UInt16?

    var statusCode: Int {
        switch state {
        case .ready: return 200
        case .methodNotAllowed: return 405
        case .unavailable: return 503
        }
    }

    var ok: Bool { state == .ready }

    func responseObject(bundleId: String) -> [String: Any] {
        var body: [String: Any] = ["ok": ok]
        switch state {
        case .ready:
            body["port"] = Int(port ?? 0)
            body["bundleId"] = bundleId
        case .methodNotAllowed, .unavailable:
            body["error"] = state.rawValue
        }
        return body
    }
}

/// The truthful readiness surface for `GET /macctl/health`. A bound listener
/// is not enough to call the bridge healthy: Trust policy must still allow the
/// capability and at least one execution slot must remain available.
struct MacControlBridgeHealthRouteResponse: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case ready
        case methodNotAllowed = "method_not_allowed"
        case policyDisabled = "policy_disabled"
        case execSaturated = "exec_saturated"
    }

    let state: State
    let startGateAllowed: Bool
    let execSlotLimit: Int
    let activeExecSlots: Int
    let freeExecSlots: Int

    var statusCode: Int {
        switch state {
        case .ready: return 200
        case .methodNotAllowed: return 405
        case .policyDisabled, .execSaturated: return 503
        }
    }
    var ok: Bool { state == .ready }

    func responseObject(bundleId: String) -> [String: Any] {
        var body: [String: Any] = [
            "ok": ok,
            "bundleId": bundleId,
            "state": state.rawValue,
            "startGateAllowed": startGateAllowed,
            "execSlots": [
                "limit": execSlotLimit,
                "active": activeExecSlots,
                "free": freeExecSlots,
            ],
        ]
        if !ok {
            body["error"] = state.rawValue
        }
        return body
    }
}

/// Outcome of one bridge-audit append. An audit append is advisory evidence,
/// never proof that the underlying subprocess effect happened, but failure to
/// retain that evidence must remain visible to the route that produced it.
public enum MacControlBridgeAuditAppendState: String, Sendable, Equatable {
    case appended
    case appendFailed = "append_failed"
    case retentionFailed = "retention_failed"
}

public struct MacControlBridgeAuditAppendReceipt: Sendable, Equatable {
    let state: MacControlBridgeAuditAppendState
    let path: String
    /// True once the new JSONL bytes were successfully appended and synced.
    /// This does not imply that the subsequent bounded-retention step ran.
    let lineStored: Bool
    /// True only when the post-append retention validation and cap completed.
    let retentionEnforced: Bool
    let retainedRowsDropped: Int
    let error: String?

    /// Compatibility shorthand for the physical append fact. A retention
    /// failure after append remains stored evidence with unenforced retention.
    var isStored: Bool { lineStored }

    func responseObject() -> [String: Any] {
        [
            "state": state.rawValue,
            "path": path,
            "lineStored": lineStored,
            "retentionEnforced": retentionEnforced,
            "retainedRowsDropped": retainedRowsDropped,
            "error": error ?? NSNull(),
        ]
    }
}

enum MacControlBridgeAuditEvidenceState: String, Sendable, Equatable {
    case missing
    case ready
    case incompleteEvidence = "incomplete_evidence"
    case unavailable
}

/// Read-only observation of the live bridge audit file. `physicalRowCount`
/// includes damaged rows, so a malformed file cannot masquerade as an empty
/// healthy feed merely because its parser skipped evidence.
struct MacControlBridgeAuditReport: Sendable, Equatable {
    let state: MacControlBridgeAuditEvidenceState
    let dataRoot: String
    let path: String
    let byteCount: Int?
    let physicalRowCount: Int?
    let validRowCount: Int?
    let malformedRowCount: Int
    let trailingPartialRow: Bool
    let argv0Counts: [String: Int]
    let statusCounts: [String: Int]
    let repeatedZeroEffectReasons: [String: Int]
    let leads: [String]
    let error: String?
}

/// One bounded owner for the bridge's terminal-exec audit evidence. The bridge
/// remains the producer; this store only makes write outcome, retention, and
/// read evidence explicit and testable.
enum MacControlBridgeAuditStore {
    static let filename = "mac_control_bridge_audit.jsonl"
    static let retentionLimit = 500
    static let dominantArgv0ShareLead = 0.80

    static func path(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(filename)
    }

    static func append(
        argv: [String],
        status: String,
        reason: String?,
        operationId: String?,
        dataRoot: URL
    ) -> MacControlBridgeAuditAppendReceipt {
        let auditPath = path(dataRoot: dataRoot)
        let event: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "argv0": argv.first ?? "",
            "argc": argv.count,
            "operationId": operationId ?? "",
            "status": status,
            "reason": reason ?? "",
        ]
        do {
            try FileManager.default.createDirectory(
                at: auditPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = try JSONSerialization.data(withJSONObject: event)
            if FileManager.default.fileExists(atPath: auditPath.path) {
                let handle = try FileHandle(forWritingTo: auditPath)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.write(contentsOf: Data([0x0A]))
                try handle.synchronize()
            } else {
                var firstLine = line
                firstLine.append(0x0A)
                try firstLine.write(to: auditPath, options: .atomic)
            }
        } catch {
            return MacControlBridgeAuditAppendReceipt(
                state: .appendFailed,
                path: auditPath.path,
                lineStored: false,
                retentionEnforced: false,
                retainedRowsDropped: 0,
                error: error.localizedDescription
            )
        }
        do {
            // `enforceJSONLLineCap` correctly refuses to guess at malformed
            // bytes. Surface that condition here before calling it: otherwise
            // a successfully appended line could receive an ordinary receipt
            // even though the requested bounded-retention step was skipped.
            let raw = try Data(contentsOf: auditPath)
            guard let text = String(data: raw, encoding: .utf8) else {
                return MacControlBridgeAuditAppendReceipt(
                    state: .retentionFailed,
                    path: auditPath.path,
                    lineStored: true,
                    retentionEnforced: false,
                    retainedRowsDropped: 0,
                    error: "bridge audit is not valid UTF-8; retention was not enforced"
                )
            }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            for line in lines where (try? JSONValue.parse(Data(line.utf8))) == nil {
                return MacControlBridgeAuditAppendReceipt(
                    state: .retentionFailed,
                    path: auditPath.path,
                    lineStored: true,
                    retentionEnforced: false,
                    retainedRowsDropped: 0,
                    error: "bridge audit contains malformed JSON; retention was not enforced"
                )
            }
            let dropped = try enforceJSONLLineCap(at: auditPath, maxLines: retentionLimit)
            return MacControlBridgeAuditAppendReceipt(
                state: .appended,
                path: auditPath.path,
                lineStored: true,
                retentionEnforced: true,
                retainedRowsDropped: dropped,
                error: nil
            )
        } catch {
            // The line reached the file, but its retention outcome is unknown;
            // never flatten that into an ordinary successful audit receipt.
            return MacControlBridgeAuditAppendReceipt(
                state: .retentionFailed,
                path: auditPath.path,
                lineStored: true,
                retentionEnforced: false,
                retainedRowsDropped: 0,
                error: error.localizedDescription
            )
        }
    }

    static func readReport(dataRoot: URL) async -> MacControlBridgeAuditReport {
        let auditPath = path(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: auditPath.path) else {
            return MacControlBridgeAuditReport(
                state: .missing,
                dataRoot: dataRoot.path,
                path: auditPath.path,
                byteCount: 0,
                physicalRowCount: 0,
                validRowCount: 0,
                malformedRowCount: 0,
                trailingPartialRow: false,
                argv0Counts: [:],
                statusCounts: [:],
                repeatedZeroEffectReasons: [:],
                leads: [],
                error: nil
            )
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: auditPath.path)
            if (attributes[.type] as? FileAttributeType) == .typeDirectory {
                throw PersistenceCoreError.ioFailure("bridge audit path is a directory")
            }
            guard let byteCount = (attributes[.size] as? NSNumber)?.intValue else {
                throw PersistenceCoreError.ioFailure("bridge audit size is unavailable")
            }
            let scan = try await SwiftNativePersistenceCore().readJSONLReporting(auditPath)
            var argv0Counts: [String: Int] = [:]
            var statusCounts: [String: Int] = [:]
            var zeroEffectReasons: [String: Int] = [:]
            for row in scan.rows {
                guard case .object(let object) = row else { continue }
                let argv0 = string(object["argv0"]) ?? "<missing>"
                let status = string(object["status"]) ?? "<missing>"
                argv0Counts[argv0, default: 0] += 1
                statusCounts[status, default: 0] += 1
                if let reason = string(object["reason"]), reason.hasSuffix(": 0") {
                    zeroEffectReasons["\(argv0) / \(status) / \(reason)", default: 0] += 1
                }
            }
            let repeats = zeroEffectReasons.filter { $0.value > 1 }
            var leads: [String] = repeats.keys.sorted().map { "repeated_zero_effect: \($0)" }
            if let dominant = argv0Counts.max(by: { $0.value < $1.value }),
               !scan.rows.isEmpty,
               Double(dominant.value) / Double(scan.rows.count) >= dominantArgv0ShareLead {
                leads.append("argv0_dominates: \(dominant.key) \(dominant.value)/\(scan.rows.count)")
            }
            let evidenceState: MacControlBridgeAuditEvidenceState = scan.report.isClean
                ? .ready
                : .incompleteEvidence
            return MacControlBridgeAuditReport(
                state: evidenceState,
                dataRoot: dataRoot.path,
                path: auditPath.path,
                byteCount: byteCount,
                physicalRowCount: scan.report.physicalLineCount,
                validRowCount: scan.rows.count,
                malformedRowCount: scan.report.malformedLineCount,
                trailingPartialRow: scan.report.trailingPartialLine,
                argv0Counts: argv0Counts,
                statusCounts: statusCounts,
                repeatedZeroEffectReasons: repeats,
                leads: leads.sorted(),
                error: nil
            )
        } catch {
            return MacControlBridgeAuditReport(
                state: .unavailable,
                dataRoot: dataRoot.path,
                path: auditPath.path,
                byteCount: nil,
                physicalRowCount: nil,
                validRowCount: nil,
                malformedRowCount: 0,
                trailingPartialRow: false,
                argv0Counts: [:],
                statusCounts: [:],
                repeatedZeroEffectReasons: [:],
                leads: [],
                error: error.localizedDescription
            )
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value, !value.isEmpty else { return nil }
        return value
    }
}
