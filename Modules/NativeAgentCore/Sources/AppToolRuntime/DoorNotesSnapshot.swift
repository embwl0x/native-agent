import Foundation
import PersistenceCore
import Experiences
import AgentWorkspace
import Agents
import TurnTrace
import AuthoredCapabilities
import AttentionRouting
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import CryptoKit
import Privacy
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import ToolRegistry
import ToolExecution
import TrustCenter
import Senses
import PersonaEngine
import Desk
// Blueprint: | `DoorNotesSnapshot.swift` | Task-local script inbox snapshot and nested batch versions |
/// The inbox as the last action in a script left it, bound around the script
/// so each of its actions reads the inbox once, after itself.
final class DoorNotesSnapshot: @unchecked Sendable {
    @TaskLocal static var current: DoorNotesSnapshot?
    // Nested batches re-enter the tool chain with the same guarded page versions.
    @MainActor var versions: [String: JSONValue]?
    private let lock = NSLock()
    private var held: [(id: String, title: String)]?
    var notes: [(id: String, title: String)]? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}
