import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SwarmRunsReader.swift` | `SwiftNativeSwarmRunsReader`: owns live-board and receipt storage and worker report IDs; one read-only recovery projection for crews, report inspection and the live board; inspection gives pending live workers their deterministic IDs and marks absent output unavailable, preserving strict terminal-report validation; durable receipts win, interrupted completion time stays unknown, and `SwarmCrew.liveness(of:)` classifies every crew view without promoting unknown to running or replaying work; its writer records recoveryObservedAt once when committing projected recovery before the next board write and removes it only after receipt durability |

/// Shared crew projection and inspection of live and retained swarm evidence.
/// JSON run array: off-disk backup only; no local backup/export/raw phone sync.
/// PrivacyMap: swarms. The phone's runs/runs.json is a separate owner.
public struct SwiftNativeSwarmRunsReader: Sendable {
    public static let maximumStoreBytes = 64 * 1_024 * 1_024
    /// Absolute path to `<dataRoot>/swarms/runs.json`.
    public let runsPath: URL

    public init(runsPath: URL) {
        self.runsPath = runsPath
    }

    private var livePath: URL { runsPath.deletingLastPathComponent().appendingPathComponent("live.json") }

    /// The shared writer commits projected recovery before changing live progress.
    func updateLive(id: String, record: JSONValue?) throws {
        try CredentialFileLock.withLock(livePath) {
            let projected = try projection().live
            for row in projected where row["pid"] == nil { try persist(JSONValue(fromFoundation: row)) }
            var rows = projected.filter { $0["pid"] != nil && $0["id"] as? String != id }.map { JSONValue(fromFoundation: $0) }
            if let record { rows.append(record) }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue.array(rows).serializedData(pretty: true), to: livePath)
        }
    }

    func persist(_ record: JSONValue) throws {
        try CredentialFileLock.withLock(runsPath) {
            var existing = try Self.rows(at: runsPath).map { JSONValue(fromFoundation: $0) }
            if case .object(let object) = record, existing.contains(where: {
                if case .object(let saved) = $0 { return saved["id"] == object["id"] }
                return false
            }) { return }
            var record = record
            if case .object(var object) = record, object["status"] == .string("interrupted"), object["recoveryObservedAt"] == nil {
                object["recoveryObservedAt"] = .string(AgentSwarmClock.nowISO())
                record = .object(object)
            }
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

    /// Read-only projection; updateLive commits recovery before its next write.
    public func readCrews() throws -> [[String: Any]] {
        do {
            let (live, runs) = try projection()
            guard let runs = runs as? [[String: Any]] else { throw PersistenceCoreError.ioFailure("receipt_store_malformed") }
            return live + runs
        } catch PersistenceCoreError.ioFailure(let reason) where reason.hasPrefix("receipt_store_") {
            throw PersistenceCoreError.ioFailure(reason == "receipt_store_malformed"
                ? "Swarm store malformed at \(runsPath.path); repair the retained store before continuing."
                : "Swarm store unreadable at \(runsPath.path); restore access before continuing.")
        }
    }

    /// One recovery read for every reader; durable receipts win, completion stays unknown.
    func projection() throws -> (live: [[String: Any]], runs: [Any]) {
        let livePath = runsPath.deletingLastPathComponent().appendingPathComponent("live.json")
        let live = try Self.rows(at: livePath)
        let runs = try Self.readArray(at: runsPath) ?? []
        let done = Set(runs.compactMap { ($0 as? [String: Any])?["id"] as? String })
        var working: [[String: Any]] = []
        var ids = Set<String>()
        for row in live {
            if let id = row["id"] as? String, done.contains(id) { continue }
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
                working.append(row)
                continue
            }
            guard let pid = row["pid"] as? Int, pid > 0, pid <= Int(Int32.max) else {
                throw PersistenceCoreError.ioFailure("Swarm live store malformed; repair swarms/live.json without discarding retained worker results.")
            }
            // A matching start time identifies the process incarnation;
            // unreadable identity stays unknown and unsettled on the board.
            let stamp = row["pidStartedAt"] as? Double
            switch Self.processStart(pid_t(pid)) {
            case .started(let started) where stamp.map({ abs($0 - started) < 0.001 }) == true:
                working.append(row)
                continue
            case .unreadable, .started where stamp == nil:
                var unknown = row
                unknown["status"] = "unknown"
                unknown["liveness"] = "Whether crew process \(pid) is still this crew's cannot be established; it was not settled or replayed."
                working.append(unknown)
                continue
            case .started, .gone:
                break
            }
            var receipt = row
            receipt.removeValue(forKey: "pid")
            receipt["status"] = "interrupted"
            receipt.removeValue(forKey: "completedAt")
            receipt["error"] = "Crew process ended before its terminal receipt; unsettled worker effects and synthesis are unknown. Inspect retained reports before starting new work; workers were not replayed."
            receipt["workers"] = workers.enumerated().map { index, worker in
                var result = worker
                if result["id"] == nil { result["id"] = Self.workerReportID(runID: id, index: index) }
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
            working.append(receipt)
        }
        return (working, runs)
    }

    enum ProcessStart { case started(Double), gone, unreadable }

    /// Pid and start time identify one incarnation; `gone` needs process-table evidence.
    static func processStart(_ pid: pid_t) -> ProcessStart {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .unreadable }
        guard size > 0 else { return .gone }
        let start = info.kp_proc.p_un.__p_starttime
        return .started(Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
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

    /// The shared receipt path for execution and inspection.
    public static func defaultPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("swarms", isDirectory: true)
            .appendingPathComponent("runs.json")
    }

    /// Exact, read-only inspection; corrupt evidence is unavailable, never missing.
    public func inspectSwarm(runID: String, reportID: String? = nil, offset: Int = 0, limit: Int = 2_000) -> JSONValue {
        // Keep malformed evidence visible without hiding unrelated valid runs.
        var skippedMalformedRows = 0
        func envelope(_ status: String, _ reason: String) -> JSONValue {
            var object: [String: JSONValue] = [
                "status": .string(status), "reason": .string(reason), "run_id": .string(runID),
                "store": .string("swarms"),
                "note": .string("Read-only retained receipts. Missing evidence does not prove work never ran; receipts may be disabled, not yet settled, or no longer retained."),
            ]
            if skippedMalformedRows > 0 { object["skipped_malformed_rows"] = .int(Int64(skippedMalformedRows)) }
            return .object(object)
        }
        let rows: [JSONValue]
        do {
            let (live, runs) = try projection()
            rows = (live + runs).map { JSONValue(fromFoundation: $0) }
        } catch PersistenceCoreError.ioFailure(let reason) {
            return envelope("unavailable", reason)
        } catch {
            return envelope("unavailable", "receipt_store_unreadable")
        }
        var matching: [(receipt: [String: JSONValue], status: String, reports: [RetainedSwarmReport])] = []
        for row in rows {
            guard case .object(let object) = row, case .string(let id)? = object["id"], !id.isEmpty,
                  case .string(let status)? = object["status"],
                  let validated = Self.retainedReports(object, runID: id) else {
                if case .object(let object) = row, case .string(let id)? = object["id"], id == runID {
                    return envelope("unavailable", "receipt_store_malformed")
                }
                skippedMalformedRows += 1
                continue
            }
            if id == runID { matching.append((object, status, validated)) }
        }
        guard rows.isEmpty || skippedMalformedRows < rows.count else {
            return envelope("unavailable", "receipt_store_malformed")
        }
        guard matching.count <= 1 else { return envelope("unavailable", "receipt_id_ambiguous") }
        guard let selected = matching.first else { return envelope("not_found", "receipt_not_retained") }
        let receipt = selected.receipt
        let reports = selected.reports
        var result: [String: JSONValue] = [
            "status": .string("ok"), "agent": .string("swarm"), "run_id": .string(runID),
            "run_status": .string(String(selected.status.prefix(64))), "retained_evidence_only": .bool(true),
            "worker_count": .int(Int64(reports.filter { $0.kind == "worker" }.count)), "reports": .array(reports.map(\.metadata)),
            "note": .string("These are retained worker/synthesis reports, not verified effects. Original text discarded by output or digest caps is not recoverable here. Select a report_id and follow next_offset to inspect retained text; this read never reruns work."),
        ]
        if skippedMalformedRows > 0 { result["skipped_malformed_rows"] = .int(Int64(skippedMalformedRows)) }
        for key in ["createdAt", "completedAt", "recoveryObservedAt"] {
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

    static func workerReportID(runID: String, index: Int) -> String { "\(runID)-\(String(format: "%02d", index + 1))" }

    private static func retainedReports(_ receipt: [String: JSONValue], runID: String) -> [RetainedSwarmReport]? {
        guard case .array(let workers)? = receipt["workers"], workers.count <= AgentSwarmPolicy.hardMaxAgents else { return nil }
        var reports: [RetainedSwarmReport] = []
        var reportIDs = Set<String>()
        for (index, worker) in workers.enumerated() {
            guard case .object(var object) = worker else { return nil }
            let pending = receipt["pid"] != nil && object["status"] == .string("working")
            if pending, object["id"] == nil { object["id"] = .string(workerReportID(runID: runID, index: index)) }
            guard case .string(let id)? = object["id"],
                  !id.isEmpty, id.count <= 160, id != "synthesis", reportIDs.insert(id).inserted,
                  let report = RetainedSwarmReport(id: id, kind: "worker", object: object, pending: pending) else { return nil }
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
    let outputUnavailableReason: String?
    let error: String?
    let outputTruncated: JSONValue

    init?(id: String, kind: String, object: [String: JSONValue], pending: Bool = false) {
        guard case .string(let status)? = object["status"],
              object["error"] == nil || object["error"] == .null || object["error"]?.stringValue != nil else { return nil }
        let error = object["error"]?.stringValue
        switch object["output"] {
        case .string(let value):
            output = value
            outputUnavailableReason = nil
        case nil where pending || (kind == "worker" && status == "failed" && error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false):
            // Pending work and older error-only failures have no retained output.
            output = ""
            outputUnavailableReason = pending ? "worker_not_settled" : "legacy_failed_worker_omitted_output"
        default: return nil
        }
        self.id = id
        self.kind = kind
        self.status = status
        if case .string(let value)? = object["name"] { name = String(value.prefix(80)) } else { name = nil }
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
            "output_available": .bool(outputUnavailableReason == nil),
            "has_error": .bool(error?.isEmpty == false),
        ]
        if let name { object["name"] = .string(name) }
        if let outputUnavailableReason { object["output_unavailable_reason"] = .string(outputUnavailableReason) }
        if let error, !error.isEmpty { object["error_preview"] = .string(String(error.prefix(160))) }
        return object
    }

    var metadata: JSONValue { .object(metadataObject) }
}

/// A crew the agent sent out (`agent_swarm`): a few workers on one task, for
/// as long as it runs, then its finished receipt. Uses the shared runs owner's
/// read-only projection of live progress and retained receipts.
public struct SwarmCrew: Identifiable, Equatable, Sendable {
    public let id: String
    /// The task, in its first line.
    public let task: String
    public enum Liveness: Equatable, Sendable { case running, unknown, settled }
    public let liveness: Liveness
    package nonisolated static func liveness(of row: [String: Any]) -> Liveness {
        row["status"] as? String == "unknown" ? .unknown : row["pid"] == nil ? .settled : .running
    }
    public var live: Bool { liveness == .running }
    /// The run's own status: running, unknown, completed, partial, failed, cancelled or interrupted.
    public let status: String
    public let at: Date
    public let workers: [Worker]
    /// The workers' findings pulled together, when the run asked for it.
    public let synthesis: String?

    public struct Worker: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        /// working, completed, failed, cancelled or unknown.
        public let status: String
        public let text: String
    }

    public var settled: Bool { workers.allSatisfy { $0.status != "working" } }

    /// Unsettled crews (including unknown liveness), then three settled crews by completion or creation.
    public nonisolated static func read(root: URL) throws -> [SwarmCrew] {
        let all = try SwiftNativeSwarmRunsReader(runsPath: root.appendingPathComponent("swarms/runs.json")).readCrews()
        let projected = all.compactMap(crew)
        let finished = projected.filter { $0.liveness == .settled }
        let live = projected.filter { $0.liveness != .settled }
        return live.sorted { $0.at > $1.at } + finished.sorted { $0.at > $1.at }.prefix(3)
    }

    nonisolated private static func crew(_ row: [String: Any]) -> SwarmCrew? {
        guard let id = row["id"] as? String, let objective = row["objective"] as? String else { return nil }
        let at = (row["completedAt"] as? String ?? row["createdAt"] as? String)
            .flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) ?? .distantPast
        let workers = (row["workers"] as? [[String: Any]] ?? []).enumerated().map { index, worker in
            let role = (worker["role"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? worker["name"] as? String ?? "Worker \(index + 1)"
            let output = (worker["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Worker(id: index, name: role.prefix(1).uppercased() + role.dropFirst(),
                          status: worker["status"] as? String ?? "working",
                          text: output.isEmpty ? worker["error"] as? String ?? "" : output)
        }
        let synthesis = ((row["synthesis"] as? [String: Any])?["output"] as? String ?? row["synthesis"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let task = String(objective.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }?.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>-* ")) .prefix(120) ?? "")
        return SwarmCrew(id: id, task: task.isEmpty ? "A task" : task, liveness: Self.liveness(of: row),
                          status: row["status"] as? String ?? "running", at: at, workers: workers, synthesis: synthesis)
    }
}
