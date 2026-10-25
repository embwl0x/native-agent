import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CapabilityPackParts.swift` | Capability-pack part admission, installation/removal and the save inversion bound by EngineRuntime; drafts retain pack origin and ToolExecution owns Parts.save |

/// The parts a capability pack carries. Their owner (ToolExecution's
/// `Parts.save`, with the pack's origin) is bound at launch; a pack's part
/// lands a draft, which only the owner keeps.
public enum CapabilityPackParts {
    public typealias Save = @Sendable (_ item: [String: JSONValue], _ dataRoot: URL, _ pack: String) async throws -> Void
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bound: Save?
    public static var save: Save? {
        get { lock.withLock { bound } }
        set { lock.withLock { bound = newValue } }
    }

    public static func id(_ item: [String: JSONValue]) -> String {
        AbilityStore.normalizedID(string(item["id"]).flatMap { $0.isEmpty ? nil : $0 } ?? string(item["name"]) ?? "")
    }

    /// Each part's id is fresh and its code present, before anything is written.
    public static func preflight(_ items: [[String: JSONValue]], installID: String, dataRoot: URL) throws {
        let ids = items.map(id)
        guard Set(ids.map { $0.lowercased() }).count == ids.count else { throw failure("Capability pack abilities repeat an id.") }
        let store = AbilityStore(dataRoot: dataRoot)
        for (item, id) in zip(items, ids) {
            guard AbilityStore.isAbilityID(id) else { throw failure("Capability pack ability id \(id) is not an ability id.") }
            if try store.contains(id: id, name: string(item["name"]), replacingInstallID: installID) {
                throw failure("Capability pack ability \(id) collides with an ability of hers.")
            }
            guard case .string(let code)? = item["code"] ?? (item["script"].flatMap { if case .object(let script) = $0 { script["source"] } else { nil } }), !code.isEmpty else {
                throw failure("Capability pack ability \(id) has no code.")
            }
        }
    }

    public static func install(_ items: [[String: JSONValue]], installID: String, pack: String, dataRoot: URL) async throws {
        guard !items.isEmpty else { return }
        guard let save else { throw failure("Capability pack abilities install through the app's abilities owner, which is not running.") }
        try preflight(items, installID: installID, dataRoot: dataRoot)
        for item in items {
            var fields = item
            fields["id"] = .string(id(item)); fields["capabilityPackInstallId"] = .string(installID)
            try await save(fields, dataRoot, pack)
        }
    }

    public static func remove(_ ids: [String], installID: String, dataRoot: URL) throws {
        let store = AbilityStore(dataRoot: dataRoot)
        for id in ids {
            try AbilityStore.withLock {
                guard let file = try store.read(id: id) ?? store.read(id: id, slot: .next),
                      file.metadata["record"].flatMap({ if case .object(let row) = $0 { row["capabilityPackInstallId"] } else { nil } }) == .string(installID) else { return }
                try store.remove(id: id, ownerAuthorized: true)
            }
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func failure(_ detail: String) -> NSError {
        NSError(domain: "NativeAgent.CapabilityPack", code: -422, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
