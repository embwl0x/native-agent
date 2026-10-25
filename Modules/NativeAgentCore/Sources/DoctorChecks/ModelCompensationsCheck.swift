import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ModelCompensationsCheck.swift` | Doctor-only, read-only counts of `shim.fired` by census ID since the current build launched; no compensation judgment or repair |

/// Read-only counts over the same bounded day-file window as prefix health.
/// Doctor runs this row explicitly; no turn hook or unattended sweep reads it.
public struct ModelCompensationsCheck: DoctorCheck {
    public let id: String = "model.shims"
    public let title: String = "Model compensations"
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let cache: DoctorScanCache
    private let maximumDayFiles = 7

    /// Census IDs with shim.fired sites in this build. Off-turn-only lanes and
    /// the deleted mechanisms are excluded; silence here means zero receipts.
    private static let censusIDs = [
        "P10", "P11", "P15", "P16",
        "C02", "C04", "C06", "C07", "C09",
        "L01", "L10", "L12", "L13",
        "L22", "L23", "L24",
        "T01", "T04", "T05", "T06",
        "T11", "T12", "T16", "T17",
        "T19", "T21",
        "M10", "M13", "M20",
    ]

    public init(root: URL = defaultDataRoot(), cacheTTL: TimeInterval = 60) {
        self.root = root
        self.cache = DoctorScanCache(ttl: cacheTTL)
    }

    public func run() async -> CheckResult {
        let moment = Date()
        if let memo = await cache.fresh(now: moment) { return memo }
        let result = await measure(now: moment)
        await cache.store(result, at: moment)
        return result
    }

    private func measure(now: Date) async -> CheckResult {
        let window = DoctorWindowFloor.resolve(root: root, now: now)
        var turns = Set<String>()
        var counts: [String: Int] = [:]
        let summary = await TurnTraceWindowReader.scan(
            root: root,
            now: now,
            days: window.dayFilesToRead(now: now, maximum: maximumDayFiles),
            floor: window.floor,
            kinds: ["llm.call", "shim.fired"]
        ) { row in
            guard !row.turnId.isEmpty else { return }
            if row.kind == "llm.call", row.payload["shapeVersion"]?.stringValue == "v2Prefix" {
                turns.insert(row.turnId)
            } else if row.kind == "shim.fired", let id = row.payload["id"]?.stringValue {
                counts[id, default: 0] += 1
            }
        }

        if !summary.unreadableDays.isEmpty {
            let files = summary.unreadableDays.map { "turn_traces/\($0).jsonl" }
            return CheckResult(source: root.appendingPathComponent(files[0]).path,
                id: id, title: title, status: "fail",
                detail: "Model compensations could not be measured \(window.describedAs):"
                    + " day file(s) exist but will not read: \(files.joined(separator: ", ")).")
        }

        var coverage: [String] = []
        if now.timeIntervalSince(window.floor) >= Double(maximumDayFiles - 1) * 86_400 {
            coverage.append("read bounded to the newest \(maximumDayFiles) day files; earlier launch history may be outside the scan")
        }
        if !summary.truncatedDays.isEmpty {
            coverage.append("day files tailed to the read budget: \(summary.truncatedDays.joined(separator: ", ")); earlier rows were not scanned")
        }
        if summary.malformedLines > 0 {
            coverage.append("\(summary.malformedLines) matching trace line(s) did not parse")
        }
        let coverageDetail = coverage.isEmpty ? "" : "; " + coverage.joined(separator: "; ")
        guard !turns.isEmpty else {
            return CheckResult(source: "turn_traces/", id: id, title: title, status: "unmeasured",
                detail: "Model compensations UNMEASURED \(window.describedAs): no v2 turn exists in the scanned window"
                    + coverageDetail + ".")
        }

        let total = counts.values.reduce(0, +)
        let fired = counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        let silent = Self.censusIDs.filter { counts[$0, default: 0] == 0 }.joined(separator: ", ")
        let silence = coverage.isEmpty ? "no receipt in the scanned window" : "no receipt in the scanned rows (coverage incomplete, so silence beyond them is not established)"
        return CheckResult(source: "turn_traces/", id: id, title: title, status: "ok",
            detail: "\(total) compensations in \(turns.count) turns in the scanned window: \(fired.isEmpty ? "none" : fired);"
                + " \(silence): \(silent.isEmpty ? "none" : silent); \(window.describedAs)"
                + coverageDetail + ".")
    }
}
