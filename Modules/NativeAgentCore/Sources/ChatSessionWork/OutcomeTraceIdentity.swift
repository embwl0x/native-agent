import Foundation

/// Closed validation for the opaque correlation token stored on canonical
/// assistant completions. It intentionally rejects whitespace, paths, prose,
/// and unbounded identifiers.
package enum OutcomeTraceIdentity {
    private static let allowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._:")
    )

    package static func normalized(_ raw: String?) -> String? {
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
