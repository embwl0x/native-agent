import Foundation
import NativeAgentCore
import PersistenceCore

/// Shared crew projection and inspection of retained swarm receipts.
public struct SwiftNativeSwarmRunsReader: Sendable {
    public static let maximumStoreBytes = 64 * 1_024 * 1_024
    /// Absolute path to `<dataRoot>/swarms/runs.json`.
    public let runsPath: URL

    public init(runsPath: URL) {
        self.runsPath = runsPath
    }

    /// Recovery records uncertainty, never reruns a worker. Receipt durability
    /// precedes removal from the board; an interrupted rewrite is idempotent.
    public func readCrews(locked: Bool = true) throws -> [[String: Any]] {
        let live = try liveRows(locked: locked)
        let runs = try Self.rows(at: runsPath)
        let done = Set(runs.compactMap { $0["id"] as? String })
        return live.filter { !done.contains($0["id"] as? String ?? "") } + runs
    }

    func liveRows(locked: Bool = true) throws -> [[String: Any]] {
        let livePath = runsPath.deletingLastPathComponent().appendingPathComponent("live.json")
        func project() throws -> [[String: Any]] {
            let live = try Self.rows(at: livePath)
            var working: [[String: Any]] = []
            var ids = Set<String>()
            for row in live {
                guard let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                      let workers = row["workers"] as? [[String: Any]],
                      workers.allSatisfy({ worker in
                          guard let status = worker["status"] as? String else { return false }
                          return !["completed", "failed", "cancelled"].contains(status) || worker["output"] is String
                              || (status == "failed" && worker["error"] is String)
                      }) else {
                    throw PersistenceCoreError.ioFailure("Swarm live store malformed; repair swarms/live.json without discarding retained worker results.")
                }
                if row["pid"] == nil, ["completed", "partial", "failed", "cancelled", "interrupted"].contains(row["status"] as? String ?? "") {
                    if locked { try persist(JSONValue(fromFoundation: row)) }
                    else { working.append(row) }
                    continue
                }
                guard let pid = row["pid"] as? Int, pid > 0, pid <= Int(Int32.max) else {
                    throw PersistenceCoreError.ioFailure("Swarm live store malformed; repair swarms/live.json without discarding retained worker results.")
                }
                if kill(pid_t(pid), 0) == 0 || errno != ESRCH {
                    working.append(row)
                    continue
                }
                var receipt = row
                receipt.removeValue(forKey: "pid")
                receipt["status"] = "interrupted"
                receipt["completedAt"] = AgentSwarmClock.nowISO()
                receipt["error"] = "Crew process ended before its terminal receipt; unsettled worker effects and synthesis are unknown. Inspect retained reports before starting new work; workers were not replayed."
                receipt["workers"] = workers.enumerated().map { index, worker in
                    var result = worker
                    if result["id"] == nil { result["id"] = "\(id)-\(String(format: "%02d", index + 1))" }
                    if !["completed", "failed", "cancelled"].contains(result["status"] as? String ?? "") {
                        result["status"] = "unknown"
                        result["output"] = result["output"] ?? ""
                        result["error"] = "Worker did not settle before its crew process ended; effects are unknown."
                    }
                    return result
                }
                if row["synthesis"] == nil, row["synthesize"] as? Bool != false {
                    receipt["synthesis"] = ["status": "unknown", "output": "", "error": "Synthesis did not settle before its crew process ended; its outcome is unknown."]
                }
                if locked { try persist(JSONValue(fromFoundation: receipt)) }
                else { working.append(receipt) }
            }
            if locked, live.count != working.count {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue(fromFoundation: working).serializedData(pretty: true), to: livePath)
            }
            return working
        }
        if locked { return try CredentialFileLock.withLock(livePath, project) }
        return try project()
    }

    static func rows(at path: URL) throws -> [[String: Any]] {
        let values: [Any]
        do { values = try readArray(at: path) ?? [] }
        catch PersistenceCoreError.ioFailure("receipt_store_malformed") {
            throw PersistenceCoreError.ioFailure("Swarm store malformed at \(path.path); repair the retained store before continuing.")
        }
        catch {
            throw PersistenceCoreError.ioFailure("Swarm store unreadable at \(path.path); restore access before continuing.")
        }
        guard let rows = values as? [[String: Any]] else {
            throw PersistenceCoreError.ioFailure("Swarm store malformed at \(path.path); repair the retained store before continuing.")
        }
        return rows
    }

    private static func readArray(at path: URL) throws -> [Any]? {
        let data: Data
        var identifiedFile = false
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            identifiedFile = true
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PersistenceCoreError.ioFailure("receipt_store_unreadable")
            }
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            guard length <= UInt64(maximumStoreBytes) else { throw PersistenceCoreError.ioFailure("receipt_store_too_large") }
            try handle.seek(toOffset: 0)
            data = try handle.read(upToCount: Int(length) + 1) ?? Data()
            guard data.count == Int(length) else { throw PersistenceCoreError.ioFailure("receipt_store_changed_during_read") }
        }
        catch let error as PersistenceCoreError { throw error }
        catch {
            let error = error as NSError
            if !identifiedFile, error.domain == NSCocoaErrorDomain, [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return nil }
            throw PersistenceCoreError.ioFailure("receipt_store_unreadable")
        }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw PersistenceCoreError.ioFailure("receipt_store_malformed")
        }
        return rows
    }

    func persist(_ record: JSONValue) throws {
        try CredentialFileLock.withLock(runsPath) {
            var existing = try Self.rows(at: runsPath).map { JSONValue(fromFoundation: $0) }
            if case .object(let object) = record, existing.contains(where: {
                if case .object(let saved) = $0 { return saved["id"] == object["id"] }
                return false
            }) { return }
            existing.insert(record, at: 0)
            var bytes = 2, retained = 0
            for row in existing.prefix(1_000) {
                let data = try row.serializedData(pretty: true)
                let lines = data.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
                let rowBytes = data.count + 2 * lines + 2
                guard bytes + rowBytes <= Self.maximumStoreBytes else { break }
                bytes += rowBytes
                retained += 1
            }
            guard retained > 0 else {
                throw PersistenceCoreError.ioFailure("Swarm receipt exceeds the retained evidence byte budget; existing evidence was not replaced.")
            }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue.array(Array(existing.prefix(retained))).serializedData(pretty: true), to: runsPath)
        }
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
        let rows: [JSONValue]
        do {
            guard let values = try Self.readArray(at: runsPath) else { return envelope("not_found", "receipt_store_missing") }
            rows = values.map { JSONValue(fromFoundation: $0) }
        } catch PersistenceCoreError.ioFailure(let reason) {
            return envelope("unavailable", reason)
        } catch {
            return envelope("unavailable", "receipt_store_unreadable")
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
