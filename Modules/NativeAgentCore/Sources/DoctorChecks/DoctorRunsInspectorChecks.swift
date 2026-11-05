import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SwarmRuns
// Blueprint: | `DoctorRunsInspectorChecks.swift` | Inspector health verdict from the engine's persisted-trace observation state |

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
                    shape: """
                        This ledger holds RunRecord objects in a JSON array or in an object with a runs array. Preserve every retained run and its \
                        original fields.
                        """))
        }
    }
}

public enum InspectorFeedHealth {
    public static func check(isOpen: Bool, observationActive: Bool) -> CheckResult {
        guard isOpen else {
            return CheckResult(source: TurnTraceWindowReader.source, id: "live.inspector_feed", title: "Inspector live feed", status: "not needed",
                detail: "Inspector is closed; its evidence remains owned by the engine.")
        }
        return CheckResult(source: TurnTraceWindowReader.source, id: "live.inspector_feed", title: "Inspector live feed",
            status: observationActive ? "ok" : "fail",
            detail: observationActive
                ? "Inspector observes the persisted traces shared with phone summaries."
                : "Inspector cannot observe changes to its persisted traces.",
            harm: observationActive ? nil : "New saved turn events may not appear in Inspector.")
    }
}
