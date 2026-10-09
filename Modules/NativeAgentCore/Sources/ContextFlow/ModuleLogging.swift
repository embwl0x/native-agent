import Foundation
import NativeAgentCore
import os

private let nativeModuleLogger = Logger(
    subsystem: "com.example.nativeagent",
    category: "ContextFlow"
)

/// Module diagnostics. Callers must keep credential values out of messages.
func nativeLog(_ format: String, _ arguments: CVarArg...) {
    let message = arguments.isEmpty ? format : String(format: format, arguments: arguments)
    let safeMessage = TurnSecretRedactor.redactText(message)
    nativeModuleLogger.log("\(safeMessage, privacy: .public)")
}
