import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ModelCompensationsCheck.swift` | Bounded Doctor-only `shim.fired` counts since launch; no judgment or repair |

/// Explicit Doctor reads share the bounded prefix-health window; neither turns nor unattended checks may trigger them.
public struct ModelCompensationsCheck: DoctorCheck {
    public let id: String = "model.shims"
    public let title: String = "Model compensations"
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let cache: DoctorScanCache

    /// Count only in-build shim.fired sites; silence measures receipt count, never mechanism health.
    private static let censusIDs = [
        "P10", "P11",
        "C02", "C04", "C09",
        "L01", "L10", "L12", "L13",
        "L22", "L23",
        "T01", "T05", "T16", "T17", "T21",
        "M20",
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
        guard let window = DoctorWindowFloor.resolve(root: root, now: now) else {
            return CheckResult(source: root.appendingPathComponent(NativeAgentBuildIdentity.launchStampFilename).path,
                id: id, title: title, status: "unmeasured",
                detail: """
                    This launch's build stamp is unavailable or invalid. Repair build_launch.json through the app launch owner before measuring \
                    this build.
                    """)
        }
        var turns = Set<String>()
        var counts: [String: Int] = [:]
        let summary: TurnTraceScanSummary
        do {
            summary = try await TurnTraceWindowReader.scan(
                root: root,
                now: now,
                floor: window.floor,
                kinds: ["llm.call", "shim.fired"]
            ) { row in
                let payload = row.payload.objectValue ?? [:]
                guard !row.turnId.isEmpty else { return }
                if row.kind == "llm.call", payload["shapeVersion"]?.stringValue == "v2Prefix" {
                    turns.insert(row.turnId)
                } else if row.kind == "shim.fired", let id = payload["id"]?.stringValue {
                    counts[id, default: 0] += 1
                }
            }
        } catch {
            return CheckResult(source: TurnTraceWindowReader.source,
                id: id, title: title, status: "fail",
                detail: "Model compensations could not be measured \(window.describedAs): the experience record could not be read: \(error).")
        }

        let coverageDetail = summary.coverageDetail
        guard !turns.isEmpty else {
            return CheckResult(source: TurnTraceWindowReader.source, id: id, title: title, status: "unmeasured",
                detail: "Model compensations UNMEASURED \(window.describedAs): no v2 turn was recorded in the queried window"
                    + coverageDetail + ".")
        }

        let total = counts.values.reduce(0, +)
        let fired = counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        let silent = Self.censusIDs.filter { counts[$0, default: 0] == 0 }.joined(separator: ", ")
        let silence = summary.coverageParts.isEmpty ? "no receipt in the scanned window"
            : "no receipt in the scanned rows (coverage incomplete, so silence beyond them is not established)"
        return CheckResult(source: TurnTraceWindowReader.source, id: id, title: title,
            status: summary.unreadableRows == 0 ? "ok" : "unmeasured",
            detail: "\(total) compensations in \(turns.count) turns in the scanned window: \(fired.isEmpty ? "none" : fired);"
                + " \(silence): \(silent.isEmpty ? "none" : silent); \(window.describedAs)"
                + coverageDetail + ".")
    }
}
