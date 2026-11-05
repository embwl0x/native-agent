import Foundation
import EngineRuntime
import AppKit
import ChromeControl
import PersistenceCore
import NativeAgentCore
import TrustCenter
import ChatTurnContracts
import ChatToolRuntime
import MacControl
// Blueprint: | `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` alias to `ChromeControl.ChromeExtensionFolder`; app-bound `setUp`, `setupMessage` |

typealias ChromeExtensionFolder = ChromeControl.ChromeExtensionFolder

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
