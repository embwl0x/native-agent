import Foundation
import os

// Blueprint: | `ModuleLogging.swift` | `ModuleLog`: shared public diagnostic formatting and credential scrubbing; `nativeLog` retains the Shared category |

/// Public diagnostics preserve category and severity while masking credentials.
public struct ModuleLog: Sendable {
    public static let app = ModuleLog(category: "NativeAgentApp")
    private let logger: Logger
    /// A measurement also lands in a file I can read: `<data root>/diagnostics/<category>.log`, kept under 512 KB.
    private var trail: URL?

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "NativeAgent", category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public init(category: String, trail: Bool) {
        self.init(category: category)
        if trail {
            self.trail = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("NativeAgent/diagnostics/\(category).log")
        }
    }

    public func callAsFunction(_ format: String, _ arguments: CVarArg..., level: OSLogType = .default) {
        let message = arguments.isEmpty ? format : String(format: format, arguments: arguments)
        let safeMessage = TurnSecretRedactor.redactText(message)
        logger.log(level: level, "\(safeMessage, privacy: .public)")
        if let trail { ModuleLogTrail.append(safeMessage, to: trail) }
    }
}

private enum ModuleLogTrail {
    private static let lock = NSLock()
    static func append(_ line: String, to url: URL) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 512 * 1024 {
            try? fm.removeItem(at: url)
        }
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(stamped.utf8))
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}

let nativeLog = ModuleLog(category: "NativeAgentShared")
