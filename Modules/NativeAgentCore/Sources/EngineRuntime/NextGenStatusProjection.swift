import Foundation
import PersistenceCore
import TrustPersistence
import NativeAgentCore
import Observation
// Blueprint: | `NextGenStatusProjection.swift` | Engine-owned observable NextGen snapshot: phases, summary, receipts, read failure and executor-backed eligible actions shared by Capabilities and Chat; receipts read only the executor-owned nextgen/actions/receipts.jsonl, with the unwritten runtime/nextgen_receipts.jsonl input retired; no UI receipt accumulation or secondary merging; LatestRead orders whole-snapshot/failure publication while returning each read's own snapshot. |

@MainActor
@Observable
public final class NextGenStatusProjection {
    public struct Snapshot: Equatable, Sendable {
        public let summary: NextGenSummary
        public let phases: [NextGenPhase]
        public let receipts: [NextGenReceipt]
        public let eligibleActions: [NextGenAction]
    }

    public private(set) var current: Snapshot?
    public private(set) var readError: String?
    @ObservationIgnored private let latest = LatestRead()
    public nonisolated let dataRoot: URL
    public nonisolated init(dataRoot: URL) { self.dataRoot = dataRoot }
    private nonisolated var nextGenPhasesPath: URL {
        dataRoot.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("nextgen_phases.json")
    }
    @discardableResult
    public func snapshot() async throws -> Snapshot {
        let result: Result<Snapshot, Error> = await latest.read({
            do { return .success(try await readSnapshot()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let snapshot): current = snapshot; readError = nil
            case .failure(let error): readError = error.localizedDescription
            }
        })
        return try result.get()
    }

    private nonisolated func readSnapshot() async throws -> Snapshot {
        let phases = try await getNextGenPhases()
        var seenPhases = Set<String>()
        let sortedPhases = phases.filter { seenPhases.insert($0.id).inserted }.sorted {
            (($0.phaseNumber ?? Int.max), $0.id) < (($1.phaseNumber ?? Int.max), $1.id)
        }
        var seenReceipts = Set<String>()
        let receipts = (try await getNextGenReceipts() + sortedPhases.compactMap(\.latestReceipt))
            .filter { seenReceipts.insert($0.id).inserted }
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
        var seenActions = Set<String>()
        let eligibleActions = actions.filter { action in
            let id = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return action.dryRunAvailable == true
                && action.status?.lowercased() != "completed"
                && NativeAgentEngine.isNextGenActionBacked(id)
                && seenActions.insert(id).inserted
        }
        var summary = NextGenSummary(
            status: status,
            readiness: status,
            roadmap: "Swift-native local next-gen snapshot",
            currentPhaseId: current?.id,
            currentPhaseName: current?.displayName,
            readyPhaseCount: readyPhases.count,
            totalPhaseCount: sortedPhases.count,
            actionCount: eligibleActions.count,
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
        let snapshot = Snapshot(summary: summary, phases: sortedPhases, receipts: receipts, eligibleActions: eligibleActions)
        return snapshot
    }

    public nonisolated func getNextGenPhases() async throws -> [NextGenPhase] {
        guard FileManager.default.fileExists(atPath: nextGenPhasesPath.path) else { return [] }
        let data = try Data(contentsOf: nextGenPhasesPath)
        return try JSONDecoder.nativeAgent.decode(NextGenPhasesResponse.self, from: data).phases
    }

    public nonisolated func getNextGenReceipts() async throws -> [NextGenReceipt] {
        let path = dataRoot.appendingPathComponent("nextgen/actions/receipts.jsonl")
        let persistence = SwiftNativePersistenceCore()
        var receipts: [NextGenReceipt] = []
        if FileManager.default.fileExists(atPath: path.path) {
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
