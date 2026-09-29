import Foundation
import NativeAgentShared
import PersistenceCore
import TurnTrace

/// Reads runs.json exactly as the Runs page does (bare array or {"runs": [...]}).
private enum DoctorRunLedgerRead {
    static func rowCount(root: URL) throws -> Int? {
        let path = root.appendingPathComponent("runs/runs.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 12 * 1024 * 1024 else { throw ReadError.oversized }
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601  // same as JSONDecoder.nativeAgent
        if let rows = try? decoder.decode([RunRecord].self, from: data) { return rows.count }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let runs = object["runs"],
           let runsData = try? JSONSerialization.data(withJSONObject: runs),
           let rows = try? decoder.decode([RunRecord].self, from: runsData) { return rows.count }
        throw ReadError.malformed
    }

    enum ReadError: Error { case oversized, malformed }
}

/// The ledger heals itself: the next append sets an unreadable file aside as
/// runs.json.corrupt-*.bak and starts fresh. Doctor reports; it never rewrites.
public struct RunLedgerIntegrityCheck: DoctorCheck {
    public let id = "runs.ledger_integrity"
    public let title = "Runs history"
    public let heartbeatEligible = false
    private let root: URL

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run() async -> CheckResult {
        do {
            guard let rowCount = try DoctorRunLedgerRead.rowCount(root: root) else {
                return CheckResult(id: id, title: title, status: "ok", detail: "No runs ledger exists yet.")
            }
            return CheckResult(id: id, title: title, status: "ok", detail: "Runs ledger readable (\(rowCount) retained rows).")
        } catch {
            return CheckResult(id: id, title: title, status: "warn",
                detail: "The runs ledger (data/runs/runs.json) cannot be read by the Runs page.",
                human_action: "If it is damaged JSON, the next recorded run moves it aside as runs.json.corrupt-*.bak and starts fresh. Otherwise move data/runs/runs.json aside yourself; the next run starts a fresh ledger.")
        }
    }
}

public struct TurnTraceIntegrityCheck: RepairingDoctorCheck {
    public let id = "inspector.trace_integrity"
    public let title = "Inspector saved traces"
    public let heartbeatEligible = false
    private let lane: TurnTracePersistLane
    private let now: @Sendable () -> Date

    public init(root: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lane = TurnTracePersistLane(dataRootOverride: root)
        self.now = now
    }

    public func run(repair: Bool) async -> CheckResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now())
        let firstDay = calendar.date(byAdding: .day, value: 1 - TurnTraceRetention.defaultKeepDays, to: today) ?? today
        let coverage = "Checked \(lane.path(for: firstDay).deletingPathExtension().lastPathComponent) through \(lane.path(for: today).deletingPathExtension().lastPathComponent); older Replay dates were not checked."
        let folder = lane.path(for: today).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path), !FileManager.default.isReadableFile(atPath: folder.path) {
            return CheckResult(id: id, title: title, status: "fail",
                detail: "The saved traces folder (\(folder.lastPathComponent)) exists but cannot be read, so Inspector Replay cannot open it.",
                human_action: "Restore read permission on data/turn_traces for your user, then run Doctor again.")
        }
        var inspected = 0
        var problems: [String] = []
        var unreadable: [String] = []
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
            } catch {
                problems.append("\(day): file could not be read")
                unreadable.append(day)
            }
        }
        let receipt = receipts.isEmpty ? nil : "Completed: " + receipts.joined(separator: "; ") + "."
        guard !problems.isEmpty else {
            return CheckResult(id: id, title: title, status: "ok",
                detail: "Saved traces readable across \(inspected) day file(s). \(coverage)",
                receipt: receipt)
        }
        let humanDays = unreadable + unsalvageable
        return CheckResult(id: id, title: title, status: unreadable.isEmpty ? "warn" : "fail",
            detail: "Saved trace problems: " + problems.joined(separator: "; ") + ". \(coverage)",
            repair: salvageable ? "Run Repair Safe Issues to back up each damaged trace and keep its readable rows." : nil,
            receipt: receipt,
            human_action: humanDays.isEmpty ? nil
                : "Open data/turn_traces and recover \(humanDays.map { "\($0).jsonl" }.joined(separator: ", ")) from your own backup, or fix its read permission or size; then run Doctor again.")
    }

    private enum TraceReadError: Error { case oversized }
}
