import Foundation
import PersistenceCore
import TrustPersistence

public struct NextGenStatusProjection {
    public static func merging(_ receipts: [NextGenReceipt], into existing: [NextGenReceipt]) -> [NextGenReceipt] {
        var seen = Set<String>()
        return (receipts + existing).filter { seen.insert($0.id).inserted }
    }

    public let dataRoot: URL
    public init(dataRoot: URL) { self.dataRoot = dataRoot }
    private var nextGenPhasesPath: URL {
        dataRoot.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("nextgen_phases.json")
    }
    public func snapshot() async throws -> (summary: NextGenSummary, phases: [NextGenPhase], receipts: [NextGenReceipt]) {
        let phases = try await getNextGenPhases()
        let receipts = try await getNextGenReceipts()
        let sortedPhases = phases.sorted {
            (($0.phaseNumber ?? Int.max), $0.id) < (($1.phaseNumber ?? Int.max), $1.id)
        }
        let readyPhases = sortedPhases.filter {
            $0.ready == true || ["ready", "ok", "passed", "complete", "completed"].contains($0.displayStatus.lowercased())
        }
        let current = sortedPhases.first {
            !readyPhases.contains($0)
        } ?? sortedPhases.last
        let phaseNumbers = sortedPhases.compactMap(\.phaseNumber)
        let status: String = {
            guard !sortedPhases.isEmpty else {
                return FileManager.default.fileExists(atPath: nextGenPhasesPath.path)
                    ? "unavailable"
                    : "unmeasured"
            }
            return readyPhases.count == sortedPhases.count ? "ready" : "warn"
        }()
        var phaseRange: NextGenPhaseRange?
        if let minPhase = phaseNumbers.min(), let maxPhase = phaseNumbers.max() {
            phaseRange = NextGenPhaseRange(start: minPhase, end: maxPhase)
        }
        let actions = sortedPhases.flatMap { $0.actions ?? [] }
        var summary = NextGenSummary(
            status: status,
            readiness: status,
            roadmap: "Swift-native local next-gen snapshot",
            currentPhaseId: current?.id,
            currentPhaseName: current?.displayName,
            readyPhaseCount: readyPhases.count,
            totalPhaseCount: sortedPhases.count,
            actionCount: actions.count,
            receiptCount: receipts.count,
            phaseRange: phaseRange,
            latestReceipts: receipts.prefix(10).map { receipt in
                var receipt = receipt
                receipt.receiptId = receipt.receiptId ?? receipt.id
                return receipt
            },
            createdAt: ISO8601DateFormatter().string(from: Date()),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        summary.actions = actions
        return (summary, phases, receipts)
    }

    public func getNextGenPhases() async throws -> [NextGenPhase] {
        guard FileManager.default.fileExists(atPath: nextGenPhasesPath.path) else { return [] }
        let data = try Data(contentsOf: nextGenPhasesPath)
        return try JSONDecoder.nativeAgent.decode(NextGenPhasesResponse.self, from: data).phases
    }

    public func getNextGenReceipts() async throws -> [NextGenReceipt] {
        let root = dataRoot
        let paths = [
            root
                .appendingPathComponent("nextgen", isDirectory: true)
                .appendingPathComponent("actions", isDirectory: true)
                .appendingPathComponent("receipts.jsonl"),
            root
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("nextgen_receipts.jsonl"),
        ]
        let persistence = SwiftNativePersistenceCore()
        var receipts: [NextGenReceipt] = []
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            // U5 W-A item 1 (:5682): propagate — a swallowed read rendered
            // as "no receipts" (healthy-empty) instead of the real error.
            let tail = try await persistence.tailJSONLReadReceipt(path, limit: 100, maxBytes: nil)
            guard tail.malformedJSONRowCount == 0 else {
                throw NSError(domain: "NativeAgentNextGenStatus", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Next-gen receipts contain malformed JSON at \(path.path). Repair the feed before refreshing."
                ])
            }
            for row in tail.rows {
                let data = try row.serializedData(pretty: false)
                receipts.append(try JSONDecoder.nativeAgent.decode(NextGenReceipt.self, from: data))
            }
        }
        var seen = Set<String>()
        return receipts
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }
}
