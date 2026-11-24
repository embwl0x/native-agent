import Synchronization
import Foundation
import PersistenceCore
import SenseCore
import MindCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import DeskCore
// Blueprint: | `DoorNotesSnapshot.swift` | Script-owned inbox snapshot and nested batch versions, handed through `AppActionExecution` |
/// The script holds its latest inbox snapshot so each action reads the inbox only once, after itself.
final class DoorNotesSnapshot: Sendable {
    // Nested batches re-enter the tool chain with the same guarded page versions.
    @MainActor var versions: [String: JSONValue]?
    private let held = Mutex<[(id: String, title: String)]?>(nil)
    var notes: [(id: String, title: String)]? {
        get { held.withLock { $0 } }
        set { held.withLock { $0 = newValue } }
    }
}
