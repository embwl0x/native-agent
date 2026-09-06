import Foundation
import PersistenceCore

/// Structured chat can run beneath an outer streaming task that already owns
/// the turn trace identity. Reusing that ambient identity is required so the
/// plan, provider call, tool dispatches, and outcome remain one story.
/// Direct non-streaming callers still mint one identity.
enum StructuredTurnTraceIdentity {
    static func currentOrMint() -> String {
        TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
    }
}

/// Closed validation for the opaque correlation token stored on canonical
/// assistant completions. It intentionally rejects whitespace, paths, prose,
/// and unbounded identifiers.
enum OutcomeTraceIdentity {
    private static let allowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._:")
    )

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == value,
              !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return value
    }
}
