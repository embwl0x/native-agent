import Foundation
import ChatTurnContracts
import Darwin
import NativeAgentCore
import PersistenceCore
import Desk
import ToolRegistry

// The Workshop membrane. A workshop work session runs through the SAME chat
// orchestration and gated chain a normal turn does, with the same tools and
// the same answers (the permission law: User's posture decides, and a sub-agent
// is her hands, not a lesser user). The membrane adds the session's own
// handle-scoped artifact writer, its artifact reader and its progress report.

/// Records the artifact paths a session wrote, so the pump can put them on the
/// session receipt. One collector per session (the profile is built per run).
public actor WorkshopArtifactCollector {
    private var paths: [String] = []
    private var closed = false
    public init() {}
    func write(relativePath: String, content: String, using writer: WorkshopArtifactWriter) throws -> String {
        guard !closed else { throw WorkshopMembraneError.sessionClosed }
        let written = try writer.write(relativePath: relativePath, content: content)
        paths.append(written.relativePath)
        return written.relativePath
    }
    public func written() -> [String] { paths }
    /// User, 2026-09-06: seal the session's artifact set and hand back what it
    /// wrote, in one hop. The deadline racer cancels the turn but cannot stop
    /// a detached executor that ignores cancellation, so an uncancelled tool
    /// loop kept writing artifacts after the terminal receipt was built and
    /// saved — the receipt's `artifactPaths` then described a folder that had
    /// since grown. Once closed, `workshop_artifact_write` is refused, so the
    /// receipt stays the truth about what the session produced.
    public func close() -> [String] {
        closed = true
        return paths
    }
}

public actor WorkshopProgressCollector {
    public struct Report: Sendable, Equatable {
        public let disposition: DeskWorkDisposition
        public let summary: String
    }
    private var report: Report?
    private var failures: [String] = []
    public init() {}
    func record(disposition: DeskWorkDisposition, summary: String) {
        let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        report = Report(disposition: disposition, summary: String(clean.prefix(600)))
        // A valid report supersedes earlier recording failures: the session
        // recovered and said its outcome (GPT-5.6 review of lane1 #2).
        failures.removeAll()
    }
    /// Only the RECORDING channel's failures are evidence about the report; a
    /// failed read or an unrelated tool is the model's problem to route around.
    static let recordingToolNames: Set<String> = [
        WorkshopToolProfile.progressToolName,
        WorkshopToolProfile.artifactToolName,
        "desk_work_log",
    ]
    /// Tool-outcome evidence (lane1 finding 2): a receipt must be able to say
    /// that the recording channel itself failed, instead of an empty result
    /// reading as a deliberately artifact-free observation.
    func recordFailure(tool: String, reason: String) {
        guard Self.recordingToolNames.contains(tool), failures.count < 8 else { return }
        failures.append("\(tool): \(String(reason.prefix(160)))")
    }
    public func latest() -> Report? { report }
    public func failedCalls() -> [String] { failures }
}

/// The membrane. A `ToolDispatchClient` that adds a workshop session's own
/// tools to the dispatcher it wraps, the artifact writer with canonical-path
/// containment among them.
public struct WorkshopToolProfile: ToolDispatchClient {
    /// The real dispatcher every other tool goes to.
    let inner: any ToolDispatchClient
    /// The artifact writer for `workshop_artifact_write` (handle-scoped root,
    /// containment-checked). Handled IN this wrapper, never delegated to `inner`.
    let artifactWriter: WorkshopArtifactWriter
    let collector: WorkshopArtifactCollector
    let progressCollector: WorkshopProgressCollector
    /// `desk_work_log`'s store method refuses every non-pursuit target
    /// (DeskStore.appendWorkReceipt), so an owner-cadence job used to be handed
    /// a progress tool that could only fail on the very item it was given
    /// (lane1 finding 3). The tool is exposed only where it can accept the
    /// admitted handle; `workshop_progress` is the route for both.
    let allowsDeskWorkLog: Bool

    public init(
        inner: any ToolDispatchClient,
        artifactWriter: WorkshopArtifactWriter,
        collector: WorkshopArtifactCollector = WorkshopArtifactCollector(),
        progressCollector: WorkshopProgressCollector = WorkshopProgressCollector(),
        allowsDeskWorkLog: Bool = true
    ) {
        self.inner = inner
        self.artifactWriter = artifactWriter
        self.collector = collector
        self.progressCollector = progressCollector
        self.allowsDeskWorkLog = allowsDeskWorkLog
        _ = Self.registered
    }

    /// Her own handle-scoped tools, declared to Trust like every other tool.
    private static let registered: Void = AppActionBinding.registerTools(
        [artifactWriteSchema, artifactReadSchema, progressSchema].map { ToolDescriptor(schema: $0, bucket: .core) })

    public static let deskWorkLogToolName = "desk_work_log"

    /// Every tool, but desk_work_log only where it can accept this session's item.
    func permits(_ tool: String) -> Bool {
        allowsDeskWorkLog || tool != Self.deskWorkLogToolName
    }

    /// The session's own handle-scoped tools.
    public static let artifactToolName = "workshop_artifact_write"
    public static let artifactReadToolName = "workshop_artifact_read"
    public static let progressToolName = "workshop_progress"

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        do {
            return try await route(tool: tool, input: input, surface: surface)
        } catch {
            // Evidence, not interpretation: the session's own receipt decides
            // what a failed recording call means.
            await progressCollector.recordFailure(
                tool: tool,
                reason: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            throw error
        }
    }

    private func route(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // 2026-09-11: the harness always injects `__session_id`
        // (ChatOrchestrationClient+DispatchWrappers.swift:682), and the three
        // local handlers guard exact key-set equality — so every workshop
        // dispatch failed on an argument the model never sent. Only the key the
        // harness is known to inject is dropped (Agent's ruling: trusted harness
        // metadata, never arbitrary unknown keys); anything else the caller
        // sends still faces the guards.
        let args = input.filter { $0.key != "__session_id" }
        if tool == Self.artifactToolName {
            return try await handleArtifactWrite(args)
        }
        if tool == Self.artifactReadToolName {
            return try handleArtifactRead(args)
        }
        if tool == Self.progressToolName {
            return try await handleProgress(args)
        }
        if !permits(tool) {
            throw WorkshopMembraneError.deskWorkLogNotAvailable
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    public func listAvailableTools() async throws -> [String] {
        let names = try await inner.listAvailableTools()
        var out = names.filter { permits($0) }
        out.append(Self.artifactToolName)
        out.append(Self.artifactReadToolName)
        out.append(Self.progressToolName)
        return out
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let schemas = try await inner.listAvailableToolSchemas()
        var out = schemas.filter { permits($0.name) }
        out.append(Self.artifactWriteSchema)
        out.append(Self.artifactReadSchema)
        out.append(Self.progressSchema)
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
            toolClass: .write,
            description:
                "Write a workshop artifact (notes, findings, drafts) into this pursuit's own "
                + "folder, data/workshop/<handle>/.",
            parametersJSON: data
        )
    }()

    static let artifactReadSchema: LLMToolSchema = {
        let dict: [String: Any] = [
            "type": "object",
            "properties": ["path": [
                "type": "string",
                "description": "Relative path under this same Desk handle's Workshop folder.",
            ]],
            "required": ["path"],
            "additionalProperties": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return LLMToolSchema(
            name: artifactReadToolName,
            toolClass: .read,
            description: "Read one prior artifact owned by this Desk handle (maximum 64 KiB).",
            parametersJSON: data
        )
    }()

    static let progressSchema: LLMToolSchema = {
        let dict: [String: Any] = [
            "type": "object",
            "properties": [
                "disposition": [
                    "type": "string",
                    "enum": ["progress", "goal_satisfied", "blocked", "abandon"],
                    "description": "The honest state of the Desk pursuit after this bounded session.",
                ],
                "summary": ["type": "string", "description": "A compact factual receipt (maximum 600 characters)."],
            ],
            "required": ["disposition", "summary"],
            "additionalProperties": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return LLMToolSchema(
            name: progressToolName,
            toolClass: .write,
            description: "Record a typed Desk-owned progress disposition. Call once near the end of the session.",
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
        // User, 2026-09-06: the session's receipt is already written once the
        // deadline passes; a write accepted after that would not be on it.
        let path = try await collector.write(relativePath: rawPath, content: content, using: artifactWriter)
        return .object([
            "status": .string("ok"),
            "path": .string(path),
            "bytes": .int(Int64(content.utf8.count)),
        ])
    }

    private func handleArtifactRead(_ input: [String: JSONValue]) throws -> JSONValue {
        guard Set(input.keys) == Set(["path"]), case .string(let path)? = input["path"] else {
            throw WorkshopMembraneError.badArtifactArgs("workshop_artifact_read requires only 'path'")
        }
        let read = try artifactWriter.read(relativePath: path)
        return .object([
            "status": .string("ok"),
            "path": .string(read.relativePath),
            "content": .string(read.content),
            "bytes": .int(Int64(read.bytes)),
            "truncated": .bool(read.truncated),
        ])
    }

    private func handleProgress(_ input: [String: JSONValue]) async throws -> JSONValue {
        guard Set(input.keys) == Set(["disposition", "summary"]),
              case .string(let raw)? = input["disposition"],
              let disposition = DeskWorkDisposition(rawValue: raw),
              disposition != .unstarted,
              case .string(let summary)? = input["summary"],
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkshopMembraneError.badArtifactArgs("workshop_progress requires a valid disposition and non-empty summary")
        }
        await progressCollector.record(disposition: disposition, summary: summary)
        return .object(["status": .string("ok"), "disposition": .string(disposition.rawValue)])
    }
}

public enum WorkshopMembraneError: Error, LocalizedError, Equatable {
    case badArtifactArgs(String)
    case pathEscapesRoot(String)
    case unsafeComponent(String)
    case sessionClosed
    case deskWorkLogNotAvailable

    public var errorDescription: String? {
        switch self {
        case .deskWorkLogNotAvailable:
            return "desk_work_log only accepts an agent-owned pursuit, and this session's Desk item "
                + "is not one — record this session's outcome with \(WorkshopToolProfile.progressToolName)."
        case .sessionClosed:
            return "this Desk work session has ended (its deadline passed and its receipt is "
                + "already filed) — no further artifact writes are accepted."
        case .badArtifactArgs(let why):
            return "workshop_artifact_write: \(why)"
        case .pathEscapesRoot(let p):
            return "workshop_artifact_write: path '\(p)' escapes the pursuit's work folder"
        case .unsafeComponent(let p):
            return "workshop_artifact_write: path '\(p)' contains an unsafe segment (.., separator, NUL, or control char)"
        }
    }
}

/// Containment-checked writer for a single pursuit's workshop folder
/// (`data/workshop/<handle>/`). Mirrors the execution-checkpoint path guard
/// (Executions+Checkpoints.swift:143): reject `..`, path separators, NUL, and
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
    public struct Read: Equatable {
        public let relativePath: String
        public let content: String
        public let bytes: Int
        public let truncated: Bool
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

    /// Check bounded byte access without interpreting a partial UTF-8 scalar.
    public func isReadable(relativePath: String) -> Bool {
        (try? readBytes(relativePath: relativePath, maximumBytes: 1)) != nil
    }

    public func read(relativePath: String, maximumBytes: Int = 65_536) throws -> Read {
        let result = try readBytes(relativePath: relativePath, maximumBytes: maximumBytes)
        guard let content = String(data: result.data, encoding: .utf8) else {
            throw WorkshopMembraneError.badArtifactArgs("artifact is not UTF-8 text")
        }
        return Read(relativePath: result.relativePath, content: content, bytes: result.data.count, truncated: result.truncated)
    }

    private func readBytes(relativePath: String, maximumBytes: Int) throws -> (relativePath: String, data: Data, truncated: Bool) {
        let components = try Self.validatedPathComponents(relativePath)
        let dataFD = Darwin.open(dataRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dataFD >= 0 else { throw Self.posixError("open data root") }
        defer { Darwin.close(dataFD) }
        var directoryFD = try Self.openDirectoryComponent("workshop", parentFD: dataFD, create: false)
        defer { Darwin.close(directoryFD) }
        let handleFD = try Self.openDirectoryComponent(try Self.validateSafeComponent(handle), parentFD: directoryFD, create: false)
        Darwin.close(directoryFD)
        directoryFD = handleFD
        for component in components.dropLast() {
            let next = try Self.openDirectoryComponent(component, parentFD: directoryFD, create: false)
            Darwin.close(directoryFD)
            directoryFD = next
        }
        let leaf = components[components.count - 1]
        let fileFD = leaf.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fileFD >= 0 else { throw Self.posixError("open artifact") }
        defer { Darwin.close(fileFD) }
        var statValue = stat()
        guard Darwin.fstat(fileFD, &statValue) == 0, (statValue.st_mode & S_IFMT) == S_IFREG else {
            throw WorkshopMembraneError.badArtifactArgs("artifact is not a regular file")
        }
        let limit = max(1, maximumBytes)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(8192, limit + 1))
        while data.count <= limit {
            let requested = min(buffer.count, limit + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fileFD, raw.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError("read artifact")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let truncated = data.count > limit
        if truncated {
            data = data.prefix(limit)
            // Remove only a scalar cut by the byte limit; invalid text elsewhere
            // still fails the UTF-8 decode at the artifact boundary.
            var start = data.count - 1
            while start > 0, data[start] & 0xC0 == 0x80 { start -= 1 }
            let lead = data[start]
            let width = lead < 0x80 ? 1
                : (0xC2...0xDF).contains(lead) ? 2
                : (0xE0...0xEF).contains(lead) ? 3
                : (0xF0...0xF4).contains(lead) ? 4 : 0
            if width > data.count - start { data = data.prefix(start) }
        }
        return (relativePath: components.joined(separator: "/"), data: data, truncated: truncated)
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

    /// The membrane's single-component path-safety guard.
    public static func validateSafeComponent(_ raw: String) throws -> String {
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
