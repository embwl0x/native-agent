import Foundation
import PersistenceCore

// MARK: - Native connector-action registry
//
// NativeActionDispatch composes the shipped read-only registries unconditionally.
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

    public var toolNames: Set<String> { Set(handlers.keys) }

    /// All file, repository and persona/system handlers available in this module.
    /// Production NativeActionDispatch composes the read-only subsets below.

    public static let fileSystemDefault = LocalConnectorActions(
        handlers: [
            // Wave 29 W3
            "read_file":    { FileSystemActions.readFile($0, $1) },
            "file_excerpt": { FileSystemActions.fileExcerpt($0, $1) },
            "write_file":   { FileSystemActions.writeFile($0, $1) },
            "list_dir":     { FileSystemActions.listDir($0, $1) },
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
        // Only write_file mutates the filesystem.
        sideEffecting: ["write_file"],
        // Successful read-only results are sufficient verification.
        trivialVerify: [
            "read_file", "file_excerpt", "list_dir", "system_info",
            "grep", "git_status", "git_diff", "git_log", "repo_dirty_summary",
            "persona_read", "persona_list_skills", "workspace_list", "time_now",
        ]
    )

    /// Read-only persona document and skill-body reader.
    public static let personaReadOnly = LocalConnectorActions(
        handlers: [
            "persona_read": { PersonaSystemActions.personaRead($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["persona_read"]
    )

    /// Read-only workspace directory listing; never creates directories.
    public static let workspaceListReadOnly = LocalConnectorActions(
        handlers: [
            "workspace_list": { PersonaSystemActions.workspaceList($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["workspace_list"]
    )

    /// Read-only clock and timezone lookup.
    public static let timeNowReadOnly = LocalConnectorActions(
        handlers: [
            "time_now": { PersonaSystemActions.timeNow($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["time_now"]
    )

    /// Read-only checked skill inventory with pagination.
    public static let personaListSkillsReadOnly = LocalConnectorActions(
        handlers: [
            "persona_list_skills": { PersonaSystemActions.personaListSkills($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["persona_list_skills"]
    )

    /// Read-only text and image reader with sandbox and sensitive-path fences.
    public static let readFileReadOnly = LocalConnectorActions(
        handlers: [
            "read_file": { FileSystemActions.readFile($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["read_file"]
    )

    /// Read-only line-window reader with the same file-path fences.
    public static let fileExcerptReadOnly = LocalConnectorActions(
        handlers: [
            "file_excerpt": { FileSystemActions.fileExcerpt($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["file_excerpt"]
    )

    /// Read-only macOS system-state probe.
    public static let systemInfoReadOnly = LocalConnectorActions(
        handlers: [
            "system_info": { FileSystemActions.systemInfo($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["system_info"]
    )
}
