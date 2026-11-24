import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import Synchronization
// Blueprint: | `AgentMade.swift` | `AgentMade`: what the agent's own creates made and no removal has taken away, so removing one is undoing its own act |

/// What the agent's own declared creates (`LLMToolSchema.makes`) brought into being and no removal has taken away yet, by the id each create's
/// receipt declares. It is kept in `trust/made.json`, a protected store the agent's file reach never writes, so it outlives the turn and the
/// app: a later turn removing one of these is still the agent undoing its own act. A successful removal (`LLMToolSchema.removes`) forgets it.
public enum AgentMade {
    /// One thing the agent made: its id, the create that made it, and when.
    public struct Thing: Sendable {
        public let id: String
        public let madeBy: String
        public let at: String
    }

    private static let lock = Mutex(())

    static func url(root: URL) -> URL {
        root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("made.json")
    }

    /// The thing the agent made with this id, if it made it and has not removed it.
    public static func thing(_ id: String, root: URL) throws -> Thing? {
        try lock.withLock { _ in
            guard let row = try read(root: root)[id]?.objectValue else { return nil }
            return Thing(id: id, madeBy: row["made_by"]?.stringValue ?? "", at: row["at"]?.stringValue ?? "")
        }
    }

    /// The agent's own create made this id.
    public static func note(_ id: String, madeBy tool: String, root: URL) throws {
        try lock.withLock { _ in
            var made = try read(root: root)
            made[id] = .object(["made_by": .string(tool), "at": .string(ISO8601DateFormatter().string(from: Date()))])
            try write(made, root: root)
        }
    }

    /// A removal took this id away; whoever removed it, it is no longer the agent's to undo.
    public static func forget(_ id: String, root: URL) throws {
        try lock.withLock { _ in
            var made = try read(root: root)
            guard made.removeValue(forKey: id) != nil else { return }
            try write(made, root: root)
        }
    }

    /// The one judgment the gate and the door's preview (`would_card`) both read: the words saying this call is the agent undoing its own
    /// act, or nil. It is when no untrusted contact steers the turn, nothing but autonomy asks (`security` is judged without autonomy), the
    /// call's declared removal (`removes`) names what the agent's own create made, and that create would run without a card for this same
    /// turn now. Safe's refusal is a block, never this.
    @concurrent public static func undoing(tool: String, input: [String: JSONValue], origin: SecurityOriginContext,
                               security: SecurityToolEnvelope, turn: Turn, securityCenter: SwiftNativeSecurityCenter,
                               peerRequester: String?) async -> String? {
        guard security.decision == .allow, peerRequester == nil else { return nil }
        let ran = ToolNameAliases.ranCall(tool, input: input)
        guard let key = AppActionBinding.declaredSchema(ran.tool)?.removes, let id = ran.input[key]?.stringValue,
              let made = try? thing(id, root: securityCenter.dataRoot) else { return nil }
        let maker = await securityCenter.evaluateTool(tool: made.madeBy, input: [:], origin: origin, enforceAutonomy: false, turn: turn)
        guard maker.decision == .allow, case .allow = AutonomyGate.map(level: maker.autonomyLevel, toolName: made.madeBy) else { return nil }
        return "The agent is undoing its own act: it made \(id) with " + (ToolNameAliases.appAction(made.madeBy, input: [:]) ?? made.madeBy)
            + (made.at.isEmpty ? "" : " at \(made.at)") + "."
    }

    private static func read(root: URL) throws -> [String: JSONValue] {
        let data: Data
        do { data = try Data(contentsOf: url(root: root)) }
        catch let error as CocoaError where error.isFileAbsent { return [:] }
        return try JSONValue.parse(data).objectValue ?? [:]
    }

    private static func write(_ made: [String: JSONValue], root: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONValue.object(made).serializedData(pretty: true), to: url(root: root))
    }
}
