import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ToolNoticeBus.swift` | A turn's explicit notice sink; no ambient notice route |

/// Notice sinks belong to the turn that produced them.
extension Turn {
    public func notice(_ kind: String, _ text: String) async { await notices?(kind, text) }
}
