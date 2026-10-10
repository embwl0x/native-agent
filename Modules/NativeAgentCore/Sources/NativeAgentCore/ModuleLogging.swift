import Foundation
import os

/// Module diagnostics. Callers must keep credential values out of messages.
public struct ModuleLog: Sendable {
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
