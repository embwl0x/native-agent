import Foundation
import PersistenceCore
import Darwin
// Blueprint: | `LocalConnectorActions.swift` | Canonical file/system handlers and verification flags; `nativeReadOnly` selects the exact seven native/slash tools |

// MARK: - Native connector-action registry
//
// NativeActionDispatch uses the shipped read-only selection unconditionally.
// SwiftNativeDispatcher runs registered handlers in-process and writes a dispatch
// receipt. An absent registry or missing handler fails closed; no HTTP fallback.

/// A single native action handler. Pure-ish: takes the input dict + a
/// connector context, returns the result payload (the value that becomes
/// `Receipt.output` / the `output` field of a DispatchResult).
public typealias ConnectorActionHandler =
    @Sendable (_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue

/// Registry of natively-executable connector actions, keyed by tool name.
public struct LocalConnectorActions: Sendable {
    private let handlers: [String: ConnectorActionHandler]
    /// Tool names whose handler mutates the filesystem and needs autonomy admission.
    private let sideEffecting: Set<String>
    /// Read-only handlers whose successful result is sufficient verification.
    private let trivialVerify: Set<String>

    public init(
        handlers: [String: ConnectorActionHandler],
        sideEffecting: Set<String> = [],
        trivialVerify: Set<String> = []
    ) {
        self.handlers = handlers
        self.sideEffecting = sideEffecting
        self.trivialVerify = trivialVerify
    }

    public func canHandle(_ tool: String) -> Bool { handlers[tool] != nil }

    public func isSideEffecting(_ tool: String) -> Bool { sideEffecting.contains(tool) }

    /// Whether a successful handler result should carry `verifyPassed=true`.
    /// Failed results and handlers requiring effect verification leave it unset.
    public func isTrivialVerify(_ tool: String) -> Bool { trivialVerify.contains(tool) }

    public func run(_ tool: String, input: [String: JSONValue], ctx: ConnectorActionContext) -> JSONValue? {
        guard let h = handlers[tool] else { return nil }
        return h(input, ctx)
    }

    public static func saveAttachment(_ attachment: (filename: String, data: Data),
        input: [String: JSONValue], ctx: ConnectorActionContext) -> JSONValue {
        let folder = FileSystemActions.resolvePath(FileSystemActions.stringField(input, "path"), repoRoot: ctx.repoRoot)
        let filename = attachment.filename
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\0") else {
            return FileSystemActions.errResult("Attachment filename is not a safe file name.", code: "bad_input")
        }
        let name = filename as NSString
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " \(number)"
            let target = folder.appendingPathComponent(number == 1 ? filename
                : (name.pathExtension.isEmpty ? filename : name.deletingPathExtension) + suffix
                    + (name.pathExtension.isEmpty ? "" : "." + name.pathExtension))
            if let refusal = FileSystemActions.mutationRefusal(target, ctx) { return refusal }
            do {
                let parent = try VerifiedPath.openParent(of: target, createIntermediates: true)
                defer { parent.release() }
                let fd = try VerifiedPath.openFinal(parent, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o666)
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: attachment.data)
                return .object(["status": .string("completed"), "path": .string(target.path),
                    "size": .int(Int64(attachment.data.count))])
            } catch VerifiedPath.Failure.posix(EEXIST) { number += 1 }
            catch let failure as VerifiedPath.Failure { return FileSystemActions.errResult(failure.message, code: failure.code) }
            catch { return FileSystemActions.errResult(error.localizedDescription, code: "attachment_save_failed") }
        }
    }

    /// All file, repository and persona/system handlers available in this module.
    /// Production NativeActionDispatch uses the read-only selection below.

    public static let fileSystemDefault = LocalConnectorActions(
        handlers: [
            // Wave 29 W3
            "read_file":    { FileSystemActions.readFile($0, $1) },
            "file_excerpt": { FileSystemActions.fileExcerpt($0, $1) },
            "write_file":   { FileSystemActions.writeFile($0, $1) },
            "move_file":    { FileSystemActions.transferFile($0, $1, copy: false) },
            "copy_file":    { FileSystemActions.transferFile($0, $1, copy: true) },
            "trash_file":   { FileSystemActions.trashFile($0, $1) },
            "list_dir":     { FileSystemActions.listDir($0, $1) },
            "file_info":    { FileSystemActions.fileInfo($0, $1) },
            "system_info":  { FileSystemActions.systemInfo($0, $1) },
            // Wave 32 W08 — read-only repo introspection
            "grep":               { FileSystemActions.grep($0, $1) },
            "git_status":         { FileSystemActions.gitStatus($0, $1) },
            "git_diff":           { FileSystemActions.gitDiff($0, $1) },
            "git_log":            { FileSystemActions.gitLog($0, $1) },
            "repo_dirty_summary": { FileSystemActions.repoDirtySummary($0, $1) },
            // Wave 34 W06 — read-only persona/system introspection
            "persona_read":        { PersonaSystemActions.personaRead($0, $1) },
            "persona_list_skills": { PersonaSystemActions.personaListSkills($0, $1) },
            "workspace_list":      { PersonaSystemActions.workspaceList($0, $1) },
            "time_now":            { PersonaSystemActions.timeNow($0, $1) },
        ],
        sideEffecting: ["write_file", "move_file", "copy_file", "trash_file"],
        // Successful read-only results are sufficient verification.
        trivialVerify: [
            "read_file", "file_excerpt", "list_dir", "file_info", "system_info",
            "grep", "git_status", "git_diff", "git_log", "repo_dirty_summary",
            "persona_read", "persona_list_skills", "workspace_list", "time_now",
        ]
    )

    /// The exact read-only tools exposed by native actions and slash commands.
    public static let nativeReadOnly: LocalConnectorActions = {
        let names: Set<String> = [
            "persona_read", "workspace_list", "time_now", "persona_list_skills",
            "read_file", "file_excerpt", "system_info",
        ]
        return LocalConnectorActions(
            handlers: fileSystemDefault.handlers.filter { names.contains($0.key) },
            sideEffecting: fileSystemDefault.sideEffecting.intersection(names),
            trivialVerify: fileSystemDefault.trivialVerify.intersection(names)
        )
    }()
}
