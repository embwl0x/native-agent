import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import SwarmRuns
// Blueprint: | `DoctorRunsInspectorChecks.swift` | Inspector health verdict from the engine's persisted-trace observation state |

/// Reads runs.json exactly as the Runs page does (bare array or {"runs": [...]}).
private enum DoctorRunLedgerRead {
    static func rowCount(root: URL) throws -> Int? {
        let path = root.appendingPathComponent("runs/runs.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 12 * 1024 * 1024 else { throw ReadError.oversized }
        let data = try Data(contentsOf: path)
        return try RunLedger.records(from: data).count
    }

    enum ReadError: Error { case oversized }
}

/// Doctor reports damaged history without rewriting its retained rows.
public struct RunLedgerIntegrityCheck: DoctorCheck {
    public let id = "runs.ledger_integrity"
    public let title = "Runs history"
    public let heartbeatEligible = false
    private let root: URL

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run() async -> CheckResult {
        do {
            guard let rowCount = try DoctorRunLedgerRead.rowCount(root: root) else {
                return CheckResult(source: "runs/runs.json", id: id, title: title, status: "ok", detail: "No runs ledger exists yet.")
            }
            return CheckResult(source: "runs/runs.json", id: id, title: title, status: "ok", detail: "Runs ledger readable (\(rowCount) retained rows).")
        } catch DoctorRunLedgerRead.ReadError.oversized {
            return CheckResult(source: "runs/runs.json", id: id, title: title, status: "unmeasured",
                detail: "Runs ledger size is unavailable or exceeds the 12 MiB read budget; its rows were not measured.")
        } catch {
            return CheckResult(source: "runs/runs.json",
                id: id, title: title, status: "warn",
                detail: "The runs ledger (data/runs/runs.json) cannot be read by the Runs page.",
                harm: "Past runs cannot be reviewed in Runs.",
                human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent("runs/runs.json"),
                    shape: "This ledger holds RunRecord objects in a JSON array or in an object with a runs array. Preserve every retained run and its original fields."))
        }
    }
}

public struct TurnTraceIntegrityCheck: RepairingDoctorCheck {
    public let id = "inspector.trace_integrity"
    public let title = "Inspector saved traces"
    public let heartbeatEligible = false
    private let lane: TurnTracePersistLane

    public init(root: URL? = nil) {
        self.lane = TurnTracePersistLane(dataRootOverride: root)
    }

    public func run(repair: Bool) async -> CheckResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let firstDay = calendar.date(byAdding: .day, value: 1 - TurnTraceRetention.defaultKeepDays, to: today) ?? today
        let coverage = "checked \(lane.path(for: firstDay).deletingPathExtension().lastPathComponent) through \(lane.path(for: today).deletingPathExtension().lastPathComponent); older Replay dates were not checked"
        let folder = lane.path(for: today).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path), !FileManager.default.isReadableFile(atPath: folder.path) {
            return CheckResult(source: folder.path,
                nextCall: ToolFailureError.call("app", ["action": .string("shell.run"), "args": .object([
                    "cmd": .string("chmod u+rX '" + folder.path.replacingOccurrences(of: "'", with: "'\\''") + "'"),
                ])]), id: id, title: title, status: "fail",
                detail: "The saved traces folder (\(folder.lastPathComponent)) exists but cannot be read, so Inspector Replay cannot open it.",
                harm: "Saved turns cannot be reviewed in Inspector Replay.",
                human_action: "Restore read permission on data/turn_traces for your user, then run Doctor again.")
        }
        var inspected = 0
        var problems: [String] = []
        var unreadable: [String] = []
        var oversized: [String] = []
        var unsalvageable: [String] = []
        var salvageable = false
        var receipts: [String] = []
        for offset in 0..<TurnTraceRetention.defaultKeepDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let path = lane.path(for: date)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let day = path.deletingPathExtension().lastPathComponent
            inspected += 1
            do {
                guard let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 16 * 1024 * 1024 else { throw TraceReadError.oversized }
                let data = try Data(contentsOf: path)
                var valid = 0
                var malformed = 0
                for line in data.split(separator: 10, omittingEmptySubsequences: false) where !line.isEmpty {
                    let bytes = Data(line)
                    if let row = try? JSONValue.parse(bytes),
                       TurnTraceEvent(persistedJSONRow: row, physicalByteCount: bytes.count + 1) != nil { valid += 1 }
                    else { malformed += 1 }
                }
                guard malformed > 0 else { continue }
                if repair, valid > 0,
                   let removed = try? await lane.salvageValidRows(for: date) {
                    receipts.append("\(day): preserved original bytes and removed \(removed) unreadable rows")
                    continue
                }
                problems.append("\(day): \(malformed) unreadable, \(valid) readable row(s)")
                if valid > 0 { salvageable = true } else { unsalvageable.append(day) }
            } catch TraceReadError.oversized {
                oversized.append(day)
            } catch {
                problems.append("\(day): file could not be read")
                unreadable.append(day)
            }
        }
        let receipt = receipts.isEmpty ? nil : "Completed: " + receipts.joined(separator: "; ") + "."
        let scope = coverage + (oversized.isEmpty ? "" : "; size unavailable or beyond the 16 MiB read budget, unmeasured: \(oversized.joined(separator: ", "))")
        guard !problems.isEmpty else {
            return CheckResult(source: "turn_traces/", id: id, title: title, status: oversized.isEmpty ? "ok" : "unmeasured",
                detail: "Saved traces readable across \(inspected - oversized.count) day file(s); \(scope).",
                receipt: receipt, repairApplied: !receipts.isEmpty)
        }
        let humanDays = unreadable + unsalvageable
        let file = humanDays.first.map { folder.appendingPathComponent($0 + ".jsonl") }
        return CheckResult(source: file?.path ?? "turn_traces/",
            id: id, title: title, status: unreadable.isEmpty ? "warn" : "fail",
            detail: "Saved trace problems: " + problems.joined(separator: "; ") + "; \(scope).",
            harm: "Parts of saved turns cannot be reviewed in Inspector Replay.",
            repair: salvageable ? "Press Repair in Diagnostics → Health checks to back up each damaged trace and keep its readable rows." : nil,
            receipt: receipt, repairApplied: !receipts.isEmpty,
            human_action: file.map { ToolFailureError.fileRepairInstruction($0,
                shape: "This day file holds one persisted TurnTraceEvent JSON object per line, with its original event identity, timestamp and payload.") },
            repair_available: salvageable)
    }

    private enum TraceReadError: Error { case oversized }
}

/// Health of the engine's exact observation of persisted Inspector evidence.
public enum InspectorFeedHealth {
    public static func check(isOpen: Bool, observationActive: Bool) -> CheckResult {
        guard isOpen else {
            return CheckResult(source: "turn_traces/", id: "live.inspector_feed", title: "Inspector live feed", status: "not needed",
                detail: "Inspector is closed; its evidence remains owned by the engine.")
        }
        return CheckResult(source: "turn_traces/", id: "live.inspector_feed", title: "Inspector live feed",
            status: observationActive ? "ok" : "fail",
            detail: observationActive
                ? "Inspector observes the persisted traces shared with phone summaries."
                : "Inspector cannot observe changes to its persisted traces.",
            harm: observationActive ? nil : "New saved turn events may not appear in Inspector.")
    }
}
