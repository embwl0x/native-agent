import Foundation
import Desk
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MyQueueCarried.swift` | MY QUEUE's per-moment run reservations and owed Desk settlements. |

/// What MY QUEUE's reflexes did for one moment, kept at desk/my-queue-carried.json. A habit's run is kept before its effects, so an interrupted run is
/// handed to the agent and never repeated; a delivered effect keeps its Desk notes and once-close owed until they land. A file restored into another data
/// root life neither settles nor matches here.
package enum MyQueueCarried {
    /// One moment's reflex: the habit's receipt (an unknown outcome until the call returns), and whether its effect was delivered and settled.
    package struct Run: Codable, Sendable, Equatable {
        /// `carry.<handle>`: one kept run per step, its latest moment.
        package var key: String?
        /// The moment's once key, `queue:<handle>:<occurrence epoch>`.
        package var once: String?
        package var lifeID: String?
        package var habitReceipt: JSONValue?
        /// The moment's effect was delivered and its settlement kept: the moment is spent.
        package var done: Bool?
    }

    /// Delivered effects whose Desk notes and once-close are still owed.
    package struct Settlement: Codable, Sendable, Equatable {
        package let id: String
        package let lifeID: String
        package let item: JSONValue
        package let fingerprint: String
        package let notes: [String]
        package let reason: String
    }

    struct Ledger: Codable, Sendable, Equatable {
        var carriedRuns: [Run]?
        var carriedSettlements: [Settlement]?
    }

    package static func url(_ root: URL) -> URL { root.appendingPathComponent("desk/my-queue-carried.json") }

    /// The run kept for this moment in the current life.
    package static func run(once: String, dataRoot: URL) async throws -> Run? {
        let life = try DataRootLife.current(in: dataRoot)
        return try await edit(dataRoot) { ledger in
            ledger.carriedRuns?.last { $0.once == once && DataRootLife.life(of: $0.lifeID) == life }
        }
    }

    /// Keep this moment's habit receipt (its unknown outcome before the call, the real one after), replacing the step's earlier run.
    package static func keep(handle: String, once: String, receipt: JSONValue, dataRoot: URL) async throws {
        let life = try DataRootLife.current(in: dataRoot)
        try await edit(dataRoot) { ledger in
            var runs = ledger.carriedRuns ?? []
            runs.removeAll { $0.key == "carry." + handle }
            runs.append(Run(key: "carry." + handle, once: once, lifeID: life, habitReceipt: receipt))
            ledger.carriedRuns = Array(runs.suffix(256))
        }
    }

    /// Admission changed while saving the pre-call reservation. No effect began; remove only the exact unstarted reservation in this life.
    package static func withdrawUnstarted(once: String, receipt: JSONValue, dataRoot: URL) async throws {
        let life = try DataRootLife.current(in: dataRoot)
        try await edit(dataRoot) { ledger in
            ledger.carriedRuns?.removeAll {
                $0.once == once && DataRootLife.life(of: $0.lifeID) == life && $0.done != true && $0.habitReceipt == receipt
            }
        }
    }

    /// The moment's effect was delivered: it is spent, and its Desk notes and once-close are owed until they land. A second delivery of the same
    /// moment returns the settlement already owed.
    package static func delivered(_ item: DeskItem, once: String, notes: [String], reason: String, dataRoot: URL) async throws -> Settlement {
        let life = try DataRootLife.current(in: dataRoot)
        let debt = Settlement(id: UUID().uuidString, lifeID: life, item: item.toJSON(), fingerprint: once, notes: notes, reason: reason)
        return try await edit(dataRoot) { ledger in
            var runs = ledger.carriedRuns ?? []
            let kept = runs.last { $0.once == once && DataRootLife.life(of: $0.lifeID) == life }
            runs.removeAll { $0.key == "carry." + item.handle }
            runs.append(Run(key: "carry." + item.handle, once: once, lifeID: life, habitReceipt: kept?.habitReceipt, done: true))
            ledger.carriedRuns = Array(runs.suffix(256))
            if let owed = ledger.carriedSettlements?.first(where: {
                $0.lifeID == life && $0.item.objectValue?["handle"] == .string(item.handle) && $0.fingerprint == once
            }) { return owed }
            ledger.carriedSettlements = (ledger.carriedSettlements ?? []) + [debt]
            return debt
        }
    }

    package static func owedSettlements(dataRoot: URL) async throws -> [Settlement] {
        let life = try DataRootLife.current(in: dataRoot)
        return try await edit(dataRoot) { ledger in ledger.carriedSettlements?.filter { $0.lifeID == life } ?? [] }
    }

    package static func settled(_ debt: Settlement, dataRoot: URL) async throws {
        try await edit(dataRoot) { ledger in ledger.carriedSettlements?.removeAll { $0.id == debt.id } }
    }

    /// Read, change and keep the ledger under its file lock; a ledger the change left as it was is not written.
    @discardableResult
    private static func edit<T: Sendable>(_ root: URL, _ change: @escaping @Sendable (inout Ledger) -> T) async throws -> T {
        let url = url(root)
        return try await SwiftNativePersistenceCore.withFileLock(url) {
            var ledger = try read(root)
            let before = ledger
            let result = change(&ledger)
            if ledger != before { try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(ledger), to: url) }
            return result
        }
    }

    /// Only an absent current ledger begins an empty history; unreadable saved bytes remain an error.
    private static func read(_ root: URL) throws -> Ledger {
        let url = url(root)
        do { return try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return Ledger() }
    }
}
