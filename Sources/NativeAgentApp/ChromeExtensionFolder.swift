import Foundation
import BodyRuntime
import AppKit
import MacNerves
import PersistenceCore
import NativeAgentCore
import DeskCore
import MindCore
// Blueprint: | `ChromeExtensionFolder.swift` | App-bound `ChromeExtensionFolder.setUp`, `setupMessage` |

extension ChromeExtensionFolder {
    @MainActor
    static func setUp(turn: Turn, context: MacOperationContext) async throws -> URL {
        let origin = turn.chromeOrigin ?? SecurityOriginContext.currentTurn(
            turn: turn, surface: turn.envelope?.surface ?? "native_actions")
        return try await setUp(chrome: NativeAgentEngine.forRoot(context.dataRoot).chrome,
            dataRoot: context.dataRoot, origin: origin, turn: turn, context: context)
    }

    static func setupMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix { $0 != "\n" })
            + ((error as? ToolFailureError)?.tap.map { " Open \($0)." } ?? "")
    }
}
