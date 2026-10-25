import Foundation
import os
// Blueprint: | `ModuleLogging.swift` | `ModuleLog`: shared formatted, credential-redacted public diagnostics with each module's existing category |

/// Module diagnostics. Callers must keep credential values out of messages.
public struct ModuleLog: Sendable {
    public static let app = ModuleLog(category: "NativeAgentApp")
    private let logger: Logger

    public init(category: String) {
        logger = Logger(
            subsystem: "com.example.nativeagent",
            category: category
        )
    }

    public func callAsFunction(_ format: String, _ arguments: CVarArg...) {
        let message = arguments.isEmpty ? format : String(format: format, arguments: arguments)
        let safeMessage = TurnSecretRedactor.redactText(message)
        logger.log("\(safeMessage, privacy: .public)")
    }
}
