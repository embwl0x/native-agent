import Foundation
import NativeAgentCore

// Blueprint: | `RepairOwed.swift` | `RepairOwed`: experience-backed repair claims and settlement; retries, restarts and unrelated successes cannot settle another operation's debt |

/// Repair owed (User 10-18: "No fallbacks: it works and it works right, and
/// never can the agent say I can't fix it"). A no whose cause lies outside the
/// call that met it names its owner and carries its lever: her call, or the
/// person's exact control where the law gives him the decision. The experience
/// that met it owes `repair` until that operation, or its lever, works again,
/// or its owner lets it go with a reason. Retries, restarts and unrelated
/// successes are evidence, never settlement. The same claims carry it for a
/// tool's act and for a no met anywhere else (a Doctor check, a part's wake, a
/// background job), so one projection (her home's OWED lines) shows them all.
public enum RepairOwed {
    /// What an owed repair carries: who decided, which operation failed, and the lever.
    /// The one reader of a claim the builder below wrote ("key: value").
    public static func claim(_ experience: Experience, _ key: String) -> String? {
        experience.claims.first { $0.claim.hasPrefix(key + ": ") }.map { String($0.claim.dropFirst(key.count + 2)) }
    }

    public static func claims(owner: String, operation: String, lever: String? = nil,
                              nextCall: String? = nil, tap: String? = nil) -> [Experience.Claim] {
        var lines = ["owner: " + owner, "operation: " + operation]
        if let lever { lines.append("lever: " + lever) }
        if let nextCall { lines.append("next_call: " + nextCall) }
        if let tap { lines.append("tap: " + tap) }
        return lines.map { .init(claim: $0, evidence: []) }
    }

    /// The debt still open for this operation and owner, if any. Meeting the
    /// same no again while it is owed is evidence on that debt, not a second
    /// one; once it settled, meeting it again is a new debt.
    public static func openDebt(_ store: ExperienceStore, operation: String, owner: String) async throws -> Experience? {
        try await store.open().first { owed in
            owed.owes["repair"]?.phase.isSettled == false
                && owed.claims.contains { $0.claim == "operation: " + operation }
                && owed.claims.contains { $0.claim == "owner: " + owner }
        }
    }

    /// A no met outside a tool call owes repair the way an act does. `id` is
    /// minted by the owner; a repeat while the debt is open folds into it.
    @discardableResult
    public static func owe(_ dataRoot: URL, id: String, kind: Experience.Kind, cause: [String] = [],
                           evidence: [Experience.Ref] = [], operation: String, owner: String, words: String,
                           lever: String? = nil, nextCall: String? = nil, tap: String? = nil) -> Task<Void, Never> {
        // One queue per operation for owe and settle, so a settle never overtakes the debt it settles.
        ExperienceStore.record(dataRoot, "repair:" + operation) { store in
            try await owe(store, id: id, kind: kind, cause: cause, evidence: evidence,
                          operation: operation, owner: owner, words: words,
                          lever: lever, nextCall: nextCall, tap: tap)
        }
    }

    /// Already inside this operation's `repair:` queue: do not enqueue and
    /// await another write behind the caller itself.
    public static func owe(_ store: ExperienceStore, id: String, kind: Experience.Kind, cause: [String] = [],
                           evidence: [Experience.Ref] = [], operation: String, owner: String, words: String,
                           lever: String? = nil, nextCall: String? = nil, tap: String? = nil) async throws {
        var met = Experience(id: id, kind: kind, cause: cause, evidence: evidence,
                             outcome: .init(domain: operation, status: "failed", effects: Experience.Effects.none),
                             face: .init(words: words, artifacts: []),
                             owes: ["repair": .init(to: tap == nil ? "self" : "person")],
                             claims: claims(owner: owner, operation: operation, lever: lever, nextCall: nextCall, tap: tap))
        met.addressedTo = [tap == nil ? "self" : "person"]
        if let open = try await openDebt(store, operation: operation, owner: owner) {
            try await store.append([.evidence(.init(source: "repeat", id: met.id))], to: open.id)
        } else {
            try await store.begin(met)
        }
    }

    /// The operation worked: every repair owed for it, or for a lever that is
    /// this operation, is accepted on that evidence.
    public static func settle(_ store: ExperienceStore, operation: String, evidence: Experience.Ref) async throws {
        for owed in try await store.open() where owed.owes["repair"]?.phase.isSettled == false
            && owed.claims.contains(where: { $0.claim == "operation: " + operation || $0.claim == "lever: " + operation }) {
            try await store.append([.obligation(key: "repair", phase: .accepted, evidence: evidence)], to: owed.id)
        }
    }

    /// The operation worked, from a domain outside the tool loop.
    @discardableResult
    public static func settle(_ dataRoot: URL, operation: String, evidence: Experience.Ref) -> Task<Void, Never> {
        ExperienceStore.record(dataRoot, "repair:" + operation) { store in
            try await settle(store, operation: operation, evidence: evidence)
        }
    }
}
