import Foundation
import PersistenceCore

/// Bounded projection for agent-facing knowledge-graph search tools.
///
/// The canonical graph retains complete entities. Tool continuations need the
/// useful search surface, not unbounded provenance arrays or nested metadata
/// repeated into every later request in the same turn.
public enum KnowledgeGraphSearchProjection {
    public static let defaultLimit = 12
    public static let maximumLimit = 25

    public static func bounded(
        _ envelope: JSONValue,
        requestedLimit: Int? = nil
    ) -> JSONValue {
        guard case .object(let object) = envelope,
              case .array(let results)? = object["results"] else {
            return .object([
                "results": .array([]),
                "total_results": .int(0),
                "returned_results": .int(0),
                "truncated": .bool(false),
            ])
        }

        let limit = min(max(requestedLimit ?? defaultLimit, 1), maximumLimit)
        let projected = results.prefix(limit).map(projectEntity)
        return .object([
            "results": .array(projected),
            "total_results": .int(Int64(results.count)),
            "returned_results": .int(Int64(projected.count)),
            "truncated": .bool(results.count > projected.count),
        ])
    }

    private static func projectEntity(_ value: JSONValue) -> JSONValue {
        guard case .object(let object) = value else { return value }

        var projected: [String: JSONValue] = [:]
        for (key, field) in object {
            switch field {
            case .string(let text):
                projected[key] = .string(cap(text, maximumCharacters: key == "summary" ? 1_200 : 500))
            case .int, .double, .bool, .null:
                projected[key] = field
            case .array(let values) where key == "aliases":
                projected[key] = .array(values.prefix(10).compactMap { alias in
                    guard case .string(let text) = alias else { return nil }
                    return .string(cap(text, maximumCharacters: 200))
                })
            case .array, .object:
                continue
            }
        }
        return .object(projected)
    }

    private static func cap(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "..."
    }
}
