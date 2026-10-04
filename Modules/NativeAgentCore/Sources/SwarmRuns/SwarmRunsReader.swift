import Foundation
import NativeAgentCore
import PersistenceCore

/// Read-only inspection of retained swarm receipts.
public struct SwiftNativeSwarmRunsReader: Sendable {
    public static let maximumStoreBytes = 64 * 1_024 * 1_024
    /// Absolute path to `<dataRoot>/swarms/runs.json`.
    public let runsPath: URL

    public init(runsPath: URL) {
        self.runsPath = runsPath
    }

    /// The shared receipt path for execution and inspection.
    public static func defaultPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("swarms", isDirectory: true)
            .appendingPathComponent("runs.json")
    }

    /// Exact, read-only inspection of retained evidence. Corruption must not
    /// masquerade as an empty or missing result.
    public func inspectSwarm(runID: String, reportID: String? = nil, offset: Int = 0, limit: Int = 2_000) -> JSONValue {
        // Rows the strict shape check rejected. Counted, never silently dropped:
        // a skipped row is unreadable evidence, and the caller must see that a
        // run's absence here might be corruption rather than "never ran".
        var skippedMalformedRows = 0
        func envelope(_ status: String, _ reason: String) -> JSONValue {
            var object: [String: JSONValue] = [
                "status": .string(status), "reason": .string(reason), "run_id": .string(runID),
                "store": .string("swarms/runs.json"),
                "note": .string("Read-only retained receipts. Missing evidence does not prove work never ran; receipts may be disabled, not yet settled, or no longer retained."),
            ]
            if skippedMalformedRows > 0 { object["skipped_malformed_rows"] = .int(Int64(skippedMalformedRows)) }
            return .object(object)
        }
        let cap = Self.maximumStoreBytes
        let data: Data
        var identifiedFile = false
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: runsPath.path)
            identifiedFile = true
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return envelope("unavailable", "receipt_store_unreadable")
            }
            let handle = try FileHandle(forReadingFrom: runsPath)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            guard length <= UInt64(cap) else { return envelope("unavailable", "receipt_store_too_large") }
            try handle.seek(toOffset: 0)
            data = try handle.read(upToCount: Int(length) + 1) ?? Data()
            guard data.count == Int(length) else { return envelope("unavailable", "receipt_store_changed_during_read") }
        } catch {
            let error = error as NSError
            if !identifiedFile, error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                return envelope("not_found", "receipt_store_missing")
            }
            return envelope("unavailable", "receipt_store_unreadable")
        }
        guard let parsed = try? JSONValue.parse(data), case .array(let rows) = parsed else {
            return envelope("unavailable", "receipt_store_malformed")
        }
        var matching: [(receipt: [String: JSONValue], reports: [RetainedSwarmReport])] = []
        var validRows = 0
        for row in rows {
            guard case .object(let object) = row, case .string(let id)? = object["id"], !id.isEmpty,
                  case .string(_)? = object["status"],
                  let validated = Self.retainedReports(object) else {
                // A single legacy or partially-shaped row must not black out
                // inspection of every other run. Skip it per row — but the
                // REQUESTED run's own corrupt row still fails loud, since reporting
                // it as not-retained would misread corruption as absence.
                if case .object(let object) = row, case .string(let id)? = object["id"], id == runID {
                    return envelope("unavailable", "receipt_store_malformed")
                }
                skippedMalformedRows += 1
                continue
            }
            validRows += 1
            if id == runID { matching.append((object, validated)) }
        }
        // Nothing in the store survived the shape check: that is a malformed store,
        // not an empty one. (A genuinely empty array skips no rows and reads clean.)
        guard validRows > 0 || skippedMalformedRows == 0 else {
            return envelope("unavailable", "receipt_store_malformed")
        }
        guard matching.count <= 1 else { return envelope("unavailable", "receipt_id_ambiguous") }
        guard let selected = matching.first else { return envelope("not_found", "receipt_not_retained") }
        let receipt = selected.receipt
        let reports = selected.reports
        guard case .string(let status)? = receipt["status"] else {
            return envelope("unavailable", "receipt_malformed")
        }
        var result: [String: JSONValue] = [
            "status": .string("ok"), "agent": .string("swarm"), "run_id": .string(runID),
            "run_status": .string(String(status.prefix(64))), "retained_evidence_only": .bool(true),
            "worker_count": .int(Int64(reports.filter { $0.kind == "worker" }.count)), "reports": .array(reports.map(\.metadata)),
            "note": .string("These are retained worker/synthesis reports, not verified effects. Original text discarded by output or digest caps is not recoverable here. Select a report_id and follow next_offset to inspect retained text; this read never reruns work."),
        ]
        if skippedMalformedRows > 0 { result["skipped_malformed_rows"] = .int(Int64(skippedMalformedRows)) }
        for key in ["createdAt", "completedAt"] {
            if case .string(let value)? = receipt[key] { result[key] = .string(String(value.prefix(80))) }
        }
        if let reportID {
            guard let report = reports.first(where: { $0.id == reportID }) else {
                result["status"] = .string("not_found")
                result["reason"] = .string("report_not_retained")
                return .object(result)
            }
            let total = report.retainedChars
            let startOffset = min(max(0, offset), total)
            let page = report.page(offset: startOffset, limit: max(1, min(limit, 2_000)))
            let next = startOffset + page.count
            var selected = report.metadataObject
            selected["text"] = .string(page)
            selected["offset"] = .int(Int64(startOffset))
            selected["returned_chars"] = .int(Int64(page.count))
            selected["has_more"] = .bool(next < total)
            selected["page_truncated"] = .bool(startOffset > 0 || next < total)
            if next < total { selected["next_offset"] = .int(Int64(next)) }
            result["report"] = .object(selected)
        }
        return .object(result)
    }

    private static func retainedReports(_ receipt: [String: JSONValue]) -> [RetainedSwarmReport]? {
        guard case .array(let workers)? = receipt["workers"], workers.count <= AgentSwarmPolicy.hardMaxAgents else { return nil }
        var reports: [RetainedSwarmReport] = []
        var reportIDs = Set<String>()
        for worker in workers {
            guard case .object(let object) = worker, case .string(let id)? = object["id"],
                  !id.isEmpty, id.count <= 160, id != "synthesis", reportIDs.insert(id).inserted,
                  let report = RetainedSwarmReport(id: id, kind: "worker", object: object) else { return nil }
            reports.append(report)
        }
        if let synthesis = receipt["synthesis"], synthesis != .null {
            let object: [String: JSONValue]
            switch synthesis {
            case .object(let value): object = value
            case .string(let text):
                // The historical run-list preserved raw string synthesis.
                // Text alone proves neither completion nor clipping state;
                // even an empty string is not proof synthesis was skipped.
                object = ["status": .string("unknown"), "output": .string(text)]
            default: return nil
            }
            guard let report = RetainedSwarmReport(id: "synthesis", kind: "synthesis", object: object) else { return nil }
            reports.append(report)
        }
        return reports
    }
}

private struct RetainedSwarmReport {
    let id: String
    let kind: String
    let status: String
    let name: String?
    let output: String
    let outputAvailable: Bool
    let error: String?
    let outputTruncated: JSONValue

    init?(id: String, kind: String, object: [String: JSONValue]) {
        guard case .string(let status)? = object["status"] else { return nil }
        let error: String?
        switch object["error"] {
        case .string(let value): error = value
        case nil, .null: error = nil
        default: return nil
        }
        let output: String
        switch object["output"] {
        case .string(let value):
            output = value
            outputAvailable = true
        case nil where kind == "worker" && status == "failed" && error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false:
            // Older failed-worker receipts retained the error but omitted
            // output entirely. Do not present that absence as an empty result.
            output = ""
            outputAvailable = false
        default: return nil
        }
        self.id = id
        self.kind = kind
        self.status = status
        if case .string(let value)? = object["name"] { name = String(value.prefix(80)) } else { name = nil }
        self.output = output
        self.error = error
        if case .bool(let value)? = object["outputTruncated"] { outputTruncated = .bool(value) } else { outputTruncated = .null }
    }

    private var textParts: [Substring] {
        var parts: [Substring] = []
        let hasError = error?.isEmpty == false
        // Count and page the same grapheme sequence as the concatenated text.
        // A trailing CR combines with the separator's first LF; keep that
        // CRLF together without copying or normalizing the retained output.
        let joinsSeparator = hasError && output.last == "\r"
        if !output.isEmpty {
            parts.append("Output:\n")
            parts.append(joinsSeparator ? output.dropLast() : output[...])
        }
        if let error, !error.isEmpty {
            if !parts.isEmpty { parts.append(joinsSeparator ? "\r\n\n" : "\n\n") }
            parts.append(contentsOf: ["Error:\n", error[...]])
        }
        return parts
    }

    var retainedChars: Int { textParts.reduce(0) { $0 + $1.count } }

    func page(offset: Int, limit: Int) -> String {
        var skip = offset
        var remaining = limit
        var page = ""
        for part in textParts where remaining > 0 {
            if skip >= part.count { skip -= part.count; continue }
            let start = part.index(part.startIndex, offsetBy: skip)
            let piece = part[start...].prefix(remaining)
            page.append(contentsOf: piece)
            remaining -= piece.count
            skip = 0
        }
        return page
    }

    var metadataObject: [String: JSONValue] {
        var object: [String: JSONValue] = [
            "report_id": .string(id), "kind": .string(kind), "status": .string(String(status.prefix(64))),
            "stored_output_truncated": outputTruncated, "retained_chars": .int(Int64(retainedChars)),
            "output_available": .bool(outputAvailable),
            "has_error": .bool(error?.isEmpty == false),
        ]
        if let name { object["name"] = .string(name) }
        if !outputAvailable { object["output_unavailable_reason"] = .string("legacy_failed_worker_omitted_output") }
        if let error, !error.isEmpty { object["error_preview"] = .string(String(error.prefix(160))) }
        return object
    }

    var metadata: JSONValue { .object(metadataObject) }
}
