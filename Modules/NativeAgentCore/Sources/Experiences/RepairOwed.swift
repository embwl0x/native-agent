import Foundation
import NativeAgentCore

// Blueprint: | `RepairOwed.swift` | `RepairOwed`, `attempt`, `isOwed`. |

/// A refusal with an external cause names its owner and an actionable repair lever.
/// Keep repair owed until that operation or lever works, or its owner explicitly lets it go with a reason.
/// Retries, restarts and unrelated successes supply evidence without settling debt.
/// Use the same repair projection for tools, Doctor, part wakes and background work.
public enum RepairOwed {
    /// Saved probe failures are evidence rather than new debt; derive that classification without rewriting experiences.
    public static func isOwed(_ experience: Experience) -> Bool {
        guard experience.owes["repair"]?.phase.isSettled == false else { return false }
        if experience.kind == .act, experience.outcome?.effects == Experience.Effects.none {
            if experience.outcome?.domain == "agent.verify" { return false }
            if ["refused", "not_run", "invalid_arguments", "unknown_contact"].contains(experience.outcome?.status ?? "") { return false }
        }
        return true
    }
    /// Fold repeated refusals into existing debt; a refusal after settlement creates a new obligation.
    public static func openDebt(_ store: ExperienceStore, operation: String, owner: String) async throws -> Experience? {
        try await store.open().first { owed in
            isOwed(owed) && RepairDebt(owed).matches(operation: operation, owner: owner)
        }
    }

    /// Use the owner's identity for non-tool repair too; repeat failures join open debt.
    @discardableResult
    public static func owe(_ dataRoot: URL, id: String, kind: Experience.Kind, cause: [String] = [],
                           evidence: [Experience.Ref] = [], operation: String, owner: String, words: String,
                           lever: String? = nil, nextCall: String? = nil, tap: String? = nil) -> Task<Void, Never> {
        // Serialize owe and settle per operation so settlement cannot overtake the obligation it closes.
        ExperienceStore.record(dataRoot, "repair:" + operation) { store in
            try await owe(store, id: id, kind: kind, cause: cause, evidence: evidence,
                          operation: operation, owner: owner, words: words,
                          lever: lever, nextCall: nextCall, tap: tap)
        }
    }

    /// Inside this repair queue, never enqueue and await a write behind the caller itself.
    public static func owe(_ store: ExperienceStore, id: String, kind: Experience.Kind, cause: [String] = [],
                           evidence: [Experience.Ref] = [], operation: String, owner: String, words: String,
                           lever: String? = nil, nextCall: String? = nil, tap: String? = nil) async throws {
        // The caller's key names the failure source, not an immutable birth that can be reopened after settlement.
        var met = Experience(id: id + ":" + UUID().uuidString.lowercased(), kind: kind, cause: cause, evidence: evidence,
                             outcome: .init(domain: operation, status: "failed", effects: Experience.Effects.none),
                             face: .init(words: words, artifacts: []),
                             owes: ["repair": .init(to: tap == nil ? "self" : "person")],
                             claims: RepairDebt(owner: owner, operation: operation, lever: lever, nextCall: nextCall, tap: tap).claims)
        met.addressedTo = [tap == nil ? "self" : "person"]
        if let open = try await openDebt(store, operation: operation, owner: owner) {
            try await store.append([.evidence(.init(source: "repeat", id: met.id))], to: open.id)
        } else {
            try await store.begin(met)
        }
    }

    /// Wrap work in the same obligation boundary: throws owe repair and rethrow; success settles operation-linked debt.
    @discardableResult
    public static func attempt<T>(_ dataRoot: URL, operation: String, owner: String, lever: String? = nil,
                                  nextCall: String? = nil, tap: String? = nil,
                                  words: (any Error) -> String, _ body: () throws -> T) rethrows -> T {
        do {
            let value = try body()
            settle(dataRoot, operation: operation, evidence: .init(source: "attempt", id: UUID().uuidString.lowercased()))
            return value
        } catch {
            owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .act, operation: operation, owner: owner,
                words: words(error), lever: lever, nextCall: nextCall, tap: tap)
            throw error
        }
    }

    @discardableResult
    public static func attempt<T>(_ dataRoot: URL, operation: String, owner: String, lever: String? = nil,
                                  nextCall: String? = nil, tap: String? = nil,
                                  words: (any Error) -> String, _ body: () async throws -> T) async rethrows -> T {
        do {
            let value = try await body()
            settle(dataRoot, operation: operation, evidence: .init(source: "attempt", id: UUID().uuidString.lowercased()))
            return value
        } catch {
            owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .act, operation: operation, owner: owner,
                words: words(error), lever: lever, nextCall: nextCall, tap: tap)
            throw error
        }
    }

    /// Settle operation or lever-linked debt only on that operation's successful evidence.
    public static func settle(_ store: ExperienceStore, operation: String, evidence: Experience.Ref) async throws {
        for owed in try await store.open() where owed.owes["repair"]?.phase.isSettled == false
            && RepairDebt(owed).isSettled(by: operation) {
            try await store.append([.obligation(key: "repair", phase: .accepted, evidence: evidence)], to: owed.id)
        }
    }

    /// Use the same successful-operation evidence for domains outside the tool loop.
    @discardableResult
    public static func settle(_ dataRoot: URL, operation: String, evidence: Experience.Ref) -> Task<Void, Never> {
        ExperienceStore.record(dataRoot, "repair:" + operation) { store in
            try await settle(store, operation: operation, evidence: evidence)
        }
    }
}
