import Foundation
// Blueprint: | `AbilityStore+Seed.swift` | `AbilityStore.seedFunction`: one function of a shipped seed, as its source shows it |

extension AbilityStore {
    /// One top-level function of a shipped seed (`function <name>(` through its closing line), with the comment lines just above it: what the agent is
    /// shown beside its own version. Nil when the seed or the function is absent.
    public static func seedFunction(_ name: String, of id: String) throws -> String? {
        guard let url = try seedCatalog().first(where: { try decode($0).id == id }) else { return nil }
        let lines = try decode(url).body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("function " + name + "(") }),
              let end = lines[start...].firstIndex(where: { $0 == "}" }) else { return nil }
        var first = start
        while first > 0, lines[first - 1].hasPrefix("//") { first -= 1 }
        return lines[first...end].joined(separator: "\n")
    }
}
