import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import ToolRegistry
import CryptoKit
import NativeAgentShared
import TrustCenter
import PersonaEngine
import Privacy
// Blueprint: | `Parts.swift` | Parts and PartError; one ability owner, shared store access and JSON values |

public enum PartError: Error, LocalizedError {
    case invalid(String)
    case notFound(String)
    /// The version was staged by this call (committed: the write returned; else the write was attempted and may be on disk) and the call
    /// did not complete.
    case stagedButFailed(digest: String, committed: Bool, why: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let why): return why
        case .notFound(let name): return "No ability has id or name \(name). Use app {action:\"ability.list\"} to choose an exact id, or ability.save to create one."
        case .stagedButFailed(_, let committed, let why): return "\(committed ? "staged" : "staging attempted"), the call did not complete: \(why)"
        }
    }
}

/// A part is a part (docs/AGENT_IS_THE_APP.md): what it can do is what it declares, never which door made it. One save, one keep, one run,
/// one read and one lifecycle over the shared ability files, one signed admission re-verified on every run.
public struct Parts: Sendable {
    public typealias Outcome = (ok: Bool, text: String, fields: [String: JSONValue])
    public let root: URL
    public init(root: URL = PersistenceCore.defaultDataRoot()) { self.root = root }
    var store: OwnedProgramStore { OwnedProgramStore(root: root.appendingPathComponent("abilities")) }
    var abilities: AbilityStore { AbilityStore(dataRoot: root) }

    public static func fields(_ value: JSONValue) -> [String: JSONValue] { if case .object(let fields) = value { fields } else { [:] } }
    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let values)? = value { values.compactMap { if case .string(let text) = $0 { text } else { nil } } } else { [] }
    }
    public static func string(_ fields: [String: JSONValue], _ key: String) -> String? { if case .string(let text)? = fields[key] { text } else { nil } }
    public static func declaredStrings(_ value: JSONValue?, name: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value, values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
            throw PartError.invalid("\(name) must be an array of strings.")
        }
        return strings(value)
    }
    static func now() -> String { SwiftNativeToolRegistry.isoTimestamp(Date()) }
}
