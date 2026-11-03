import Foundation
import os
import Darwin

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
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Create-or-append is one filesystem operation. An unreadable or
            // unwritable existing log never selects a whole-file replacement.
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                do { try handle.close() }
                catch { ModuleLog(category: "ModuleLogTrail")("Diagnostic trail close failed: %@", error.localizedDescription, level: .error) }
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if info.st_size > 512 * 1024 {
                try handle.truncate(atOffset: 0)
            }
            let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
            try handle.write(contentsOf: Data(stamped.utf8))
        } catch {
            ModuleLog(category: "ModuleLogTrail")("Diagnostic trail append failed: %@. Repair the diagnostics directory's access; the existing log was not replaced.", error.localizedDescription, level: .error)
        }
    }
}

let nativeLog = ModuleLog(category: "NativeAgentShared")
