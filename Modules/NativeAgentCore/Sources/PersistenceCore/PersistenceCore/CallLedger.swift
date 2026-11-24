import CryptoKit
import Foundation
// Blueprint: | `CallLedger.swift` | `CallLedger`: the metadata a receipt's nested call keeps, its result's measured identity and its artifacts |

/// A receipt shows only what its call's own output is allowed to show. A nested call keeps its identity and outcome, never its raw result: raw
/// answers live only in the owned-program journal's private replay entries. The journal publishes its ledger through `published`, and a reader
/// of a row stored before this law reduces it the same way on the way out.
public enum CallLedger {
    /// Every field a published call row may carry. Anything else does not leave the journal.
    public static let kept: Set<String> = [
        // Position and identity: call number, source line, step, the carrying run, the action's label, returned ids and versions.
        "n", "line", "step", "run", "call", "ids", "version", "card_id", "reason_given",
        // Outcome: status and its reason, the failure's own words, expect_fail's match, execution and effects.
        "status", "reason", "detail", "expected", "execution", "effects", "changed", "side_effects",
        // Structured remedy.
        "try_instead", "remedy", "argument_path", "argument_form", "understood", "next_call",
        // Classes.
        "read_only", "irreversible", "effect", "captured", "would_card", "approver", "would_hand_back",
        // The raw result's measured identity, and the files and images the enclosing receipt may carry.
        "result_bytes", "result_digest", "artifacts",
    ]

    /// The row as a receipt may show it. A row that still holds a raw result keeps only that result's size and digest, and its file
    /// destinations and generated images travel in `artifacts`.
    public static func published(_ row: JSONValue) -> JSONValue {
        guard case .object(let fields) = row else { return .null }
        var kept = fields.filter { Self.kept.contains($0.key) || $0.key == "result" }
        if kept["artifacts"] == nil, let made = storedArtifacts(fields) { kept["artifacts"] = made }
        return .object(withoutResult(kept))
    }

    /// A row stored before `artifacts` kept its places in `at` and its images in `images`; for a write with no `at`, the place a reader found
    /// on the stored receipt itself.
    static func storedArtifacts(_ fields: [String: JSONValue]) -> JSONValue? {
        let at = fields["at"]?.objectValue.map(places) ?? [:]
        let outer = fields["read_only"] == .bool(false) ? fields["result"]?.objectValue.map(places) ?? [:] : [:]
        var made: [String: JSONValue] = [:]
        if !at.isEmpty || !outer.isEmpty { made["at"] = .object(at.isEmpty ? outer : at) }
        made["images"] = images(fields["images"])
        return made.isEmpty ? nil : .object(made)
    }

    /// Replace a raw `result` with its measured identity, keeping an identity already measured; a result that cannot be encoded keeps a null size.
    public static func withoutResult(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var fields = fields
        guard let result = fields.removeValue(forKey: "result") else { return fields }
        let identity = (try? measured(result)) ?? ["result_bytes": .null]
        return fields.merging(identity) { own, _ in own }
    }

    /// A result's measured identity: its encoded size and digest, never its content.
    public static func measured(_ result: JSONValue) throws -> [String: JSONValue] {
        let bytes = try result.serializedData(pretty: false)
        let digest = SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ["result_bytes": .int(Int64(bytes.count)), "result_digest": .string(digest)]
    }

    /// What a call made that the enclosing receipt may carry: the absolute file destinations and shell directory of a call that could write,
    /// and its generated image references. Nothing else of its result travels.
    public static func artifacts(of receipt: JSONValue) -> JSONValue? {
        guard case .object(let fields) = receipt else { return nil }
        // A folded tool's receipt is its own result; a door receipt holds it in result.
        let body = fields["action"] == nil ? fields : fields["result"]?.objectValue ?? [:]
        var made: [String: JSONValue] = [:]
        if fields["read_only"] != .bool(true) {
            let at = places(body).isEmpty ? places(fields) : places(body)
            if !at.isEmpty { made["at"] = .object(at) }
        }
        made["images"] = images(body["images"])
        return made.isEmpty ? nil : .object(made)
    }

    /// Every text the enclosing output says (keys and string values), for naming what its nested calls made.
    public static func texts(_ output: JSONValue) -> [String] {
        switch output {
        case .string(let text): return [text]
        case .array(let items): return items.flatMap(texts)
        case .object(let fields): return Array(fields.keys) + fields.values.flatMap(texts)
        default: return []
        }
    }

    /// A published row as the enclosing output lets it show: an image a nested call made travels only when that output names its path. Where a
    /// write landed always travels: it is the call's effect, not its output.
    public static func shown(_ row: JSONValue, naming said: [String]) -> JSONValue {
        guard case .object(var fields) = row, case .object(var made)? = fields["artifacts"], case .array(let images)? = made["images"] else { return row }
        let named = images.filter { image in
            guard case .string(let path)? = image.objectValue?["path"], !path.isEmpty else { return false }
            return said.contains { $0.contains(path) }
        }
        made["images"] = named.isEmpty ? nil : .array(named)
        fields["artifacts"] = made.isEmpty ? nil : .object(made)
        return .object(fields)
    }

    public static func places(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        fields.filter { key, value in
            guard ["path", "destination", "cwd"].contains(key), case .string(let place) = value else { return false }
            return place.hasPrefix("/")
        }
    }

    public static func images(_ value: JSONValue?) -> JSONValue? {
        guard case .array(let images)? = value else { return nil }
        let made = images.compactMap { image -> JSONValue? in
            guard case .object(let made) = image, let path = made["path"] else { return nil }
            return .object(["path": path])
        }
        return made.isEmpty ? nil : .array(made)
    }
}
