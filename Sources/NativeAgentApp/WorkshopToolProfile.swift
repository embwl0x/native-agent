import Foundation
import Darwin
import NativeAgentCore
import ChatOrchestration
import PersistenceCore

// Wave B — the Workshop membrane (H1, L12), enforced IN CODE, never in a prompt.
//
// A workshop work session runs through the SAME chat orchestration a normal
// turn does, but its tool surface is a HARD ALLOWLIST wrapped around the real
// SwiftToolDispatcher: read-only tools + desk writes + a single, containment-
// checked artifact writer. Everything else — mac_control, shell, generic
// write_file, external sends, persona/memory writes, workshop_submit, sub-agent
// spawn — is refused BY NAME before the call reaches any backend. This is the
// ceiling: even if the model, the system prompt, or a future surface tries a
// forbidden tool, the dispatcher says no (H1: workshop sessions never inherit
// the generic mission path's `fileAccess:auto` + full dispatcher).
//
// Because ChatOrchestration builds a turn's tool schemas from the dispatcher's
// `listAvailableToolSchemas()` (ChatOrchestration+TurnEngine.swift:583), this
// wrapper ALSO decides what the model even sees: the allowlisted read/desk
// tools plus `workshop_artifact_write`. Anything outward is not a tool here —
// it is a desk approval ref (M6), filed through the normal approval queue by a
// later wave, never executed inline.

/// Records the artifact paths a session wrote, so the pump can put them on the
/// session receipt. One collector per session (the profile is built per run).
public actor WorkshopArtifactCollector {
    private var paths: [String] = []
    public init() {}
    func record(_ path: String) { paths.append(path) }
    public func written() -> [String] { paths }
}

/// The membrane. A `ToolDispatchClient` that ceilings a workshop session's tool
/// use to a hard allowlist and implements the one workshop-only write tool with
/// canonical-path containment.
public struct WorkshopToolProfile: ToolDispatchClient {
    /// The real dispatcher the allowlisted read/desk tools delegate to.
    let inner: any ToolDispatchClient
    /// The artifact writer for `workshop_artifact_write` (handle-scoped root,
    /// containment-checked). Handled IN this wrapper — never delegated to
    /// `inner`, so a generic `write_file` is unreachable.
    let artifactWriter: WorkshopArtifactWriter
    let collector: WorkshopArtifactCollector

    public init(
        inner: any ToolDispatchClient,
        artifactWriter: WorkshopArtifactWriter,
        collector: WorkshopArtifactCollector = WorkshopArtifactCollector()
    ) {
        self.inner = inner
        self.artifactWriter = artifactWriter
        self.collector = collector
    }

    /// The dedicated workshop write tool — the ONLY write beyond desk ops.
    public static let artifactToolName = "workshop_artifact_write"

    /// The hard read/desk allowlist. Snake_case to match the dispatcher's
    /// built-in names. Conservative on purpose: anything not here (and not the
    /// artifact tool) is refused, so a future tool is unavailable to workshop
    /// until someone deliberately adds it — no silent privilege creep. Mirrors
    /// the mission synthesize read-only surface, plus desk read + desk_work_log.
    public static let allowed: Set<String> = [
        // filesystem READS
        "read_file", "list_dir",
        // memory / knowledge READS
        "recall_memory", "recall_search", "search_kg", "context_lookup",
        // prior-conversation READS
        "search_chat_history", "session_search",
        // bounded skill reads / introspection. Generic tool discovery is
        // intentionally absent: tool_catalog/list_tools describe the inner
        // dispatcher's full surface and are not a workshop capability.
        "read_skill", "list_skills", "time_now",
        // trace READS (observability, read-only)
        "recent_trace_summary",
        // desk: read the live board + log a work receipt onto a pursuit
        "desk_read", "desk_work_log",
    ]

    /// A tool the workshop session may invoke: the read/desk allowlist plus the
    /// artifact writer. `workshop_artifact_write` is deliberately NOT in
    /// `allowed` (that set gates delegation to `inner`); it is handled here.
    static func isPermitted(_ tool: String) -> Bool {
        tool == artifactToolName || allowed.contains(tool)
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if tool == Self.artifactToolName {
            return try await handleArtifactWrite(input)
        }
        guard Self.allowed.contains(tool) else {
            throw WorkshopMembraneError.toolNotPermitted(tool)
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    public func listAvailableTools() async throws -> [String] {
        let names = (try? await inner.listAvailableTools()) ?? []
        var out = names.filter { Self.allowed.contains($0) }
        out.append(Self.artifactToolName)
        return out
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let schemas = (try? await inner.listAvailableToolSchemas()) ?? []
        var out = schemas.filter { Self.allowed.contains($0.name) }
        out.append(Self.artifactWriteSchema)
        return out
    }

    /// The `workshop_artifact_write` tool schema surfaced to the model.
    static let artifactWriteSchema: LLMToolSchema = {
        let dict: [String: Any] = [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description":
                        "Relative path UNDER this pursuit's workshop folder "
                        + "(data/workshop/<handle>/). No leading '/', no '..', no separators that escape.",
                ],
                "content": [
                    "type": "string",
                    "description": "UTF-8 text to write (overwrites any existing file at that path).",
                ],
            ],
            "required": ["path", "content"],
            "additionalProperties": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return LLMToolSchema(
            name: artifactToolName,
            description:
                "Write a workshop artifact (notes, findings, drafts) into this pursuit's own "
                + "folder. The ONLY file write available in a workshop session — sandboxed to "
                + "data/workshop/<handle>/. Anything outward requires a desk approval, not this tool.",
            parametersJSON: data
        )
    }()

    private func handleArtifactWrite(_ input: [String: JSONValue]) async throws -> JSONValue {
        guard Set(input.keys) == Set(["path", "content"]) else {
            throw WorkshopMembraneError.badArtifactArgs("only 'path' and 'content' are accepted")
        }
        guard case .string(let rawPath)? = input["path"] else {
            throw WorkshopMembraneError.badArtifactArgs("'path' (string) is required")
        }
        guard case .string(let content)? = input["content"] else {
            throw WorkshopMembraneError.badArtifactArgs("'content' (string) is required")
        }
        let written = try artifactWriter.write(relativePath: rawPath, content: content)
        await collector.record(written.relativePath)
        return .object([
            "status": .string("ok"),
            "path": .string(written.relativePath),
            "bytes": .int(Int64(content.utf8.count)),
        ])
    }
}

public enum WorkshopMembraneError: Error, LocalizedError, Equatable {
    case toolNotPermitted(String)
    case badArtifactArgs(String)
    case pathEscapesRoot(String)
    case unsafeComponent(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotPermitted(let tool):
            return "tool '\(tool)' is not permitted in a workshop session "
                + "(allowlist: \(WorkshopToolProfile.allowed.sorted().joined(separator: ", ")), "
                + "plus \(WorkshopToolProfile.artifactToolName)). Anything outward is a desk approval, not a tool call."
        case .badArtifactArgs(let why):
            return "workshop_artifact_write: \(why)"
        case .pathEscapesRoot(let p):
            return "workshop_artifact_write: path '\(p)' escapes the pursuit's workshop folder"
        case .unsafeComponent(let p):
            return "workshop_artifact_write: path '\(p)' contains an unsafe segment (.., separator, NUL, or control char)"
        }
    }
}

/// Containment-checked writer for a single pursuit's workshop folder
/// (`data/workshop/<handle>/`). Mirrors the mission-checkpoint path guard
/// (Missions+Checkpoints.swift:143): reject `..`, path separators, NUL, and
/// control characters, then assert the canonicalized target stays under the
/// handle root. Belt-and-suspenders — the component check AND the resolved-path
/// prefix check both have to pass.
public struct WorkshopArtifactWriter: Sendable {
    /// The app data root (e.g. `.../data`); artifacts live under
    /// `<dataRoot>/workshop/<handle>/`.
    let dataRoot: URL
    let handle: String

    public init(dataRoot: URL, handle: String) {
        self.dataRoot = dataRoot
        self.handle = handle
    }

    /// The absolute root for this pursuit's artifacts. The handle is validated
    /// as a safe single component so it can never itself traverse.
    public func rootURL() throws -> URL {
        let safeHandle = try Self.validateSafeComponent(handle)
        return dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent(safeHandle, isDirectory: true)
    }

    public struct Written: Equatable { public let relativePath: String; public let url: URL }

    /// Resolve a caller-supplied relative path against the handle root with full
/// containment. Does NOT write — pure, so the containment rule is unit-
    /// testable without touching disk.
    public func containedURL(relativePath rawPath: String) throws -> Written {
        let root = try rootURL()
        let components = try Self.validatedPathComponents(rawPath)
        var candidate = root
        for component in components {
            candidate = candidate.appendingPathComponent(component)
        }
        // Canonicalize both sides and assert the target is strictly under root.
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedTarget = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedTarget.hasPrefix(rootPrefix) else {
            throw WorkshopMembraneError.pathEscapesRoot(rawPath)
        }
        return Written(relativePath: components.joined(separator: "/"), url: candidate)
    }

    @discardableResult
    public func write(relativePath: String, content: String) throws -> Written {
        let components = try Self.validatedPathComponents(relativePath)
        let root = try rootURL()
        let target = Written(
            relativePath: components.joined(separator: "/"),
            url: components.reduce(root) { $0.appendingPathComponent($1) }
        )

        // Anchor the whole operation at an O_NOFOLLOW descriptor for dataRoot,
        // then walk/create every directory with openat/mkdirat. The final file
        // is written to an O_EXCL temporary sibling and renameat'd within the
        // already-open parent. No path component is resolved a second time, so
        // a parent symlink cannot be swapped in between validation and write.
        let dataFD = Darwin.open(
            dataRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard dataFD >= 0 else { throw Self.posixError("open data root") }
        defer { Darwin.close(dataFD) }

        var directoryFD = try Self.openDirectoryComponent("workshop", parentFD: dataFD, create: true)
        defer { Darwin.close(directoryFD) }
        let safeHandle = try Self.validateSafeComponent(handle)
        let handleFD = try Self.openDirectoryComponent(safeHandle, parentFD: directoryFD, create: true)
        Darwin.close(directoryFD)
        directoryFD = handleFD

        for component in components.dropLast() {
            let next = try Self.openDirectoryComponent(component, parentFD: directoryFD, create: true)
            Darwin.close(directoryFD)
            directoryFD = next
        }

        let leaf = components[components.count - 1]
        let temporary = ".workshop-write-\(UUID().uuidString.lowercased()).tmp"
        let fileFD = temporary.withCString { name in
            Darwin.openat(
                directoryFD,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard fileFD >= 0 else { throw Self.posixError("open artifact temp") }
        var fileIsOpen = true
        var temporaryExists = true
        defer {
            if fileIsOpen { Darwin.close(fileFD) }
            if temporaryExists {
                temporary.withCString { _ = Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        let bytes = Data(content.utf8)
        try bytes.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(fileFD, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError("write artifact temp")
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        guard Darwin.fsync(fileFD) == 0 else { throw Self.posixError("fsync artifact temp") }
        guard Darwin.close(fileFD) == 0 else { throw Self.posixError("close artifact temp") }
        fileIsOpen = false

        let renameResult = temporary.withCString { temporaryName in
            leaf.withCString { leafName in
                Darwin.renameat(directoryFD, temporaryName, directoryFD, leafName)
            }
        }
        guard renameResult == 0 else { throw Self.posixError("rename artifact") }
        temporaryExists = false
        guard Darwin.fsync(directoryFD) == 0 else { throw Self.posixError("fsync artifact directory") }
        return target
    }

    private static func validatedPathComponents(_ rawPath: String) throws -> [String] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkshopMembraneError.badArtifactArgs("'path' must be non-empty")
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw WorkshopMembraneError.unsafeComponent(rawPath)
        }
        if trimmed.hasPrefix("/") || trimmed.contains("\\") {
            throw WorkshopMembraneError.pathEscapesRoot(rawPath)
        }
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        for component in components where component.isEmpty || component == "." || component == ".." {
            throw WorkshopMembraneError.unsafeComponent(rawPath)
        }
        return components
    }

    /// Descriptor-anchored directory walk shared with the reservation-claim
    /// ledger. Keeping both Workshop writers on `openat` + `O_NOFOLLOW` avoids
    /// reintroducing a path-based symlink parent between the two boundaries.
    static func openDirectoryComponent(
        _ component: String,
        parentFD: Int32,
        create: Bool
    ) throws -> Int32 {
        func openDirectory() -> Int32 {
            component.withCString {
                Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        var fd = openDirectory()
        if fd < 0, create, errno == ENOENT {
            let made = component.withCString { Darwin.mkdirat(parentFD, $0, 0o700) }
            if made != 0, errno != EEXIST {
                throw posixError("mkdir artifact component")
            }
            fd = openDirectory()
        }
        guard fd >= 0 else { throw posixError("open artifact component") }
        return fd
    }

    private static func posixError(_ operation: String) -> Error {
        let code = errno
        return NSError(
            domain: "WorkshopArtifactWriter",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
        )
    }

    /// The single-component safety guard, mirroring
    /// `SwiftNativeWorkshopCheckpointStore.validateMissionIdAsSafeComponent`.
    static func validateSafeComponent(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw WorkshopMembraneError.unsafeComponent(raw) }
        if id == "." || id == ".." { throw WorkshopMembraneError.unsafeComponent(raw) }
        if id.contains("/") || id.contains("\\") || id.contains("\0") {
            throw WorkshopMembraneError.unsafeComponent(raw)
        }
        if id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw WorkshopMembraneError.unsafeComponent(raw)
        }
        return id
    }
}
