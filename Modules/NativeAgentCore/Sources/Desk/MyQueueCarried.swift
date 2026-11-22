import Foundation
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
        /// The moment's once key, with an optional habit revision after the occurrence time.
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
        /// Keep the finished action's note while the still-current step waits to say its words.
        let awaitsSpeech: Bool?
    }

    struct Ledger: Codable, Sendable, Equatable {
        var carriedRuns: [Run]?
        var carriedSettlements: [Settlement]?
    }

    package static func url(_ root: URL) -> URL { root.appendingPathComponent("desk/my-queue-carried.json") }

    static func occurrenceDate(_ once: String) -> Date? {
        let parts = once.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "queue", !parts[1].isEmpty,
              let epoch = TimeInterval(parts[2]), epoch.isFinite else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// A run is kept while its step is open (it is that step's only guard against running the same moment twice); a closed step's runs go.
    private static func openHandles(_ store: SwiftNativeDeskStore) async throws -> Set<String> {
        Set(MyQueue.entries(try await store.liveState()).map { $0.item.handle })
    }

    private static func kept(_ runs: [Run], open: Set<String>) -> [Run] {
        runs.filter { run in
            guard let key = run.key, key.hasPrefix("carry.") else { return true }
            return open.contains(String(key.dropFirst("carry.".count)))
        }
    }

    /// The run kept for this moment in the current life.
    package static func run(once: String, dataRoot: URL) async throws -> Run? {
        let life = try DataRootLife.current(in: dataRoot)
        return try await edit(dataRoot) { ledger in
            ledger.carriedRuns?.last { $0.once == once && DataRootLife.life(of: $0.lifeID) == life }
        }
    }

    /// Keep the receipt and, when speech is still to come, save the action's own evidence in the same write.
    @discardableResult
    package static func keep(_ item: DeskItem, once: String, receipt: JSONValue, noteAwaitingSpeech: String? = nil,
                             store: SwiftNativeDeskStore) async throws -> Settlement? {
        let dataRoot = store.dataRoot
        let life = try DataRootLife.current(in: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            let open = try await openHandles(store)
            return try await edit(dataRoot) { ledger in
                var runs = ledger.carriedRuns ?? []
                runs.removeAll { $0.key == "carry." + item.handle }
                runs.append(Run(key: "carry." + item.handle, once: once, lifeID: life, habitReceipt: receipt))
                ledger.carriedRuns = kept(runs, open: open)
                guard let noteAwaitingSpeech else { return nil }
                if let owed = ledger.carriedSettlements?.first(where: {
                    $0.lifeID == life && $0.item.objectValue?["handle"] == .string(item.handle) && $0.fingerprint == once
                }) {
                    return owed
                }
                let debt = Settlement(id: UUID().uuidString, lifeID: life, item: item.toJSON(), fingerprint: once,
                    notes: [noteAwaitingSpeech], reason: "habit finished", awaitsSpeech: true)
                ledger.carriedSettlements = (ledger.carriedSettlements ?? []) + [debt]
                return debt
            }
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
    package static func delivered(_ item: DeskItem, once: String, notes: [String], reason: String,
                                  store: SwiftNativeDeskStore) async throws -> Settlement {
        let life = try DataRootLife.current(in: store.dataRoot)
        let debt = Settlement(id: UUID().uuidString, lifeID: life, item: item.toJSON(), fingerprint: once,
                              notes: notes, reason: reason, awaitsSpeech: nil)
        return try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            let open = try await openHandles(store)
            return try await edit(store.dataRoot) { ledger in
                var runs = ledger.carriedRuns ?? []
                let earlier = runs.last { $0.once == once && DataRootLife.life(of: $0.lifeID) == life }
                runs.removeAll { $0.key == "carry." + item.handle }
                runs.append(Run(key: "carry." + item.handle, once: once, lifeID: life, habitReceipt: earlier?.habitReceipt, done: true))
                ledger.carriedRuns = kept(runs, open: open)
                if let owed = ledger.carriedSettlements?.first(where: {
                    $0.lifeID == life && $0.item.objectValue?["handle"] == .string(item.handle) && $0.fingerprint == once
                }) {
                    if owed.awaitsSpeech != true { return owed }
                    ledger.carriedSettlements?.removeAll { $0.id == owed.id }
                }
                ledger.carriedSettlements = (ledger.carriedSettlements ?? []) + [debt]
                return debt
            }
        }
    }

    package static func owedSettlements(dataRoot: URL) async throws -> [Settlement] {
        let life = try DataRootLife.current(in: dataRoot)
        return try await edit(dataRoot) { ledger in ledger.carriedSettlements?.filter { $0.lifeID == life } ?? [] }
    }

    /// Land the deed's evidence even if the step changed or closed while delivery was in flight.
    package static func finish(_ debt: Settlement, store: SwiftNativeDeskStore, closingStep: Bool = false) async throws {
        try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            guard try await owedSettlements(dataRoot: store.dataRoot).contains(debt) else { return }
            guard let item = DeskItem.fromJSON(debt.item), let entry = MyQueue.entry(item) else {
                throw PersistenceCoreError.ioFailure("The intention's settlement snapshot is unreadable.")
            }
            if debt.awaitsSpeech == true, !closingStep,
               let current = try await MyQueue.entry(item.handle, store: store), current.step == entry.step,
               try await run(once: debt.fingerprint, dataRoot: store.dataRoot) != nil { return }
            try await store.recordCarriedNotes(debt.notes, for: item, once: debt.fingerprint)
            if debt.awaitsSpeech != true, debt.reason != "said", case .once = MyQueue.until(entry),
               let current = try await MyQueue.entry(item.handle, store: store), current.step == entry.step {
                try await MyQueue.close(current, dropped: false, why: debt.reason, store: store)
            }
            try await edit(store.dataRoot) { ledger in ledger.carriedSettlements?.removeAll { $0.id == debt.id } }
        }
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
