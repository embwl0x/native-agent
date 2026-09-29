import Foundation
import PersistenceCore
import TrustPersistence

public struct NextGenStatusProjection {
    public let dataRoot: URL
    public init(dataRoot: URL) { self.dataRoot = dataRoot }
    private var nextGenStatusDataRoot: URL { dataRoot }
    private var nextGenPhasesPath: URL {
        dataRoot.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("nextgen_phases.json")
    }
    public func getNextGenSummary() async throws -> NextGenSummary {
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
        return NextGenSummary(
            status: status,
            readiness: status,
            roadmap: "Swift-native local next-gen snapshot",
            currentPhaseId: current?.id,
            currentPhaseName: current?.displayName,
            readyPhaseCount: readyPhases.count,
            totalPhaseCount: sortedPhases.count,
            actionCount: sortedPhases.reduce(0) { $0 + ($1.actions?.count ?? 0) },
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
    }

    public func getNextGenPhases() async throws -> [NextGenPhase] {
        // DAEMON-KILL P1: read <dataRoot>/runtime/nextgen_phases.json.
        let path = nextGenPhasesPath
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder.nativeAgent
        if let response = try? decoder.decode(NextGenPhasesResponse.self, from: data) {
            return response.phases
        }
        if let phases = try? decoder.decode([NextGenPhase].self, from: data) {
            return phases
        }
        throw NSError(
            domain: "NativeAgentNextGenStatus",
            code: -422,
            userInfo: [NSLocalizedDescriptionKey: "next-gen phase feed is malformed"]
        )
    }

    public func getNextGenReceipts() async throws -> [NextGenReceipt] {
        let root = nextGenStatusDataRoot
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
            let rows = try await persistence.tailJSONL(path, limit: 100, maxBytes: nil)
            for row in rows {
                guard let data = try? row.serializedData(pretty: false),
                      let receipt = try? JSONDecoder.nativeAgent.decode(NextGenReceipt.self, from: data) else {
                    continue
                }
                receipts.append(receipt)
            }
        }
        var seen = Set<String>()
        return receipts
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }
}
