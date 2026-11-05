import Foundation
import os

// Blueprint: | `ModuleLogging.swift` | `ModuleLog`: shared public diagnostic formatting and credential scrubbing; `nativeLog` retains the Shared category |

/// Public diagnostics preserve category and severity while masking credentials.
public struct ModuleLog: Sendable {
    public static let app = ModuleLog(category: "NativeAgentApp")
    private let logger: Logger

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "NativeAgent", category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func callAsFunction(_ format: String, _ arguments: CVarArg..., level: OSLogType = .default) {
        let message = arguments.isEmpty ? format : String(format: format, arguments: arguments)
        let safeMessage = TurnSecretRedactor.redactText(message)
        logger.log(level: level, "\(safeMessage, privacy: .public)")
    }
}

let nativeLog = ModuleLog(category: "NativeAgentShared")
