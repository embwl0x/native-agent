import Foundation
import NativeAgentCore
import os
import PersistenceCore

// Blueprint: | `ProviderOutputDiagnostics.swift` | Redacted provider-output diagnostics and checked retention |

/// Persist diagnostic evidence without changing provider output or deciding how a turn proceeds.
public enum ProviderOutputDiagnostics {
    private static let diagnosticLock = OSAllocatedUnfairLock(initialState: ())

    @discardableResult
    public static func writeDiagnostic(_ raw: String, reason: String, dataRoot: URL? = nil, call: LLMCall) -> Result<URL?, Error> {
        guard !call.preview else { return .success(nil) }
        return diagnosticLock.withLock { _ in
            do { return .success(try writeDiagnosticLocked(raw, reason: reason, dataRoot: dataRoot, call: call)) }
            catch {
                Logger(subsystem: "NativeAgent", category: "Cutoff").error("Could not save cutoff: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        }
    }

    private static func writeDiagnosticLocked(_ raw: String, reason: String, dataRoot: URL?, call: LLMCall) throws -> URL {
        let dir = (call.traceDataRoot ?? dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("diagnostics/cutoffs", isDirectory: true)
        let name = (call.turn?.id.filter { $0.isLetter || $0.isNumber || $0 == "-" })
            .flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        var file = dir.appendingPathComponent("\(name).txt")
        if FileManager.default.fileExists(atPath: file.path) {
            file = dir.appendingPathComponent("\(name)-\(UUID().uuidString).txt")
        }
        let safeReason = ContextSecretContentPolicy.redactedFragment(reason)
        let body = "reason: \(safeReason)\nchars: \(raw.count)\n\n" + ContextSecretContentPolicy.redactedFragment(raw)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: file, options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        var diagnostics: [(url: URL, modifiedAt: Date)] = []
        for url in files where url.pathExtension == "txt" {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard let modifiedAt = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            diagnostics.append((url, modifiedAt))
        }
        diagnostics.sort {
            $0.modifiedAt == $1.modifiedAt ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modifiedAt < $1.modifiedAt
        }
        for diagnostic in diagnostics.prefix(max(0, diagnostics.count - 100)) {
            try FileManager.default.removeItem(at: diagnostic.url)
        }
        Logger(subsystem: "NativeAgent", category: "Cutoff")
            .error("cutoff \(reason, privacy: .public) chars=\(raw.count, privacy: .public) raw=\(file.path, privacy: .public)")
        return file
    }
}
