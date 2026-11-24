import Foundation
// Blueprint: | `AbilityStore+Seed.swift` | `AbilityStore.seedFunction`: one function of a shipped seed, as its source shows it |

extension AbilityStore {
    /// One top-level function of a shipped seed (`function <name>(` through its closing line), with the comment lines just above it: what the agent is
    /// shown beside its own version. Nil when the seed or the function is absent.
    public static func seedFunction(_ name: String, of id: String, dataRoot: URL) async throws -> String? {
        guard let url = try seedCatalog().first(where: { try decode($0).id == id }) else { return nil }
        let body = try decode(url).body
        guard let span = try await OwnedProgramRunner(dataRoot: dataRoot).analyze(body).functions[name] else { return nil }
        return (body as NSString).substring(with: NSRange(location: span[0], length: span[1] - span[0]))
    }
}
