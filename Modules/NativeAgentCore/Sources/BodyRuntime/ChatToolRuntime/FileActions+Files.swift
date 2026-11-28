import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
import Synchronization
// Blueprint: | `FileActions+Files.swift` | files action contracts and execution |

enum FileActions {}

struct ContextExpandArgs: DoorArgs {
    static let argumentReferences: [String: AppAction.ArgumentReference] = [
        "message_id": .init(parameter: "atom_id", prefix: "history:", qualifiers: ["agent"]),
        "history": .init(parameter: "atom_id", prefix: "history:", qualifiers: ["agent"]),
    ]
    static let atomIDField = DoorFieldDescriptor.string("atom_id", "Offered atom id, history:<message id>, or body:<joint>.", required: true)
    static let maxCharactersField = DoorFieldDescriptor.int("max_characters", "Optional bounded character limit.")
    static let offsetField = DoorFieldDescriptor.int("offset", "Optional character offset, default 0. Continue with next_offset until null.")
    static let doorFields: [DoorFieldDescriptor] = [atomIDField, maxCharactersField, offsetField]
    let atomID: String
    let maxCharacters: Int?
    let offset: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        atomID = try door.requiredString(Self.atomIDField)
        maxCharacters = try door.numberLiteral(Self.maxCharactersField)?.wire.exactIntegerValue
        offset = try door.numberLiteral(Self.offsetField)
    }
}

struct ReadFileArgs: DoorArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        Workspace-relative path such as 'project/file.txt', a repo-relative path only when a verified source checkout exists, \
        or an absolute/~/ path under a Trust workspace root. Persona files must use app persona.doc or persona.read. Absolute \
        paths are literal; use ~/Documents/<name> for the user's Documents folder.
        """, required: true)
    static let matchField = DoorFieldDescriptor.string("match", "Glob for a folder path, e.g. '*-r4-*.png'.")
    static let queryField = DoorFieldDescriptor.string("query", """
        Search the whole text source for complete lines containing every whitespace-separated term, case-insensitively. Returns \
        records with line positions and full-source coverage, in source order. Pages fit 24000 serialized bytes; a larger \
        single record is refused, never split. Continue only with next; max_bytes and offset are byte-mode arguments.
        """)
    static let startLineField = DoorFieldDescriptor.int("start_line", """
        1-based source line. Without query it reads lines from here instead of a byte window; with query it is the search \
        continuation, omitted initially. Continue either with next unchanged.
        """)
    static let maxLinesField = DoorFieldDescriptor.int("max_lines", """
        Lines per read without query, or matching lines per search page with query; default 80, capped at 240.
        """)
    static let maxBytesField = DoorFieldDescriptor.int("max_bytes", """
        Optional source byte window: capped at 200,000 bytes; long handoff Markdown defaults to 12,000 bytes when omitted. This \
        is a file-read limit, not a one-response guarantee: large results are delivered through result.page. UTF-8 characters \
        stay whole, and a text window the file continues past ends at its last newline; use at least 4 bytes to ensure progress.
        """)
    static let offsetField = DoorFieldDescriptor.int("offset", """
        Byte offset, default 0. Continue with returned next arguments; positive offsets require version and a UTF-8 boundary.
        """)
    static let versionField = DoorFieldDescriptor.string("version", """
        Omit initially; copy next unchanged. file_changed means restart without version at offset 0 (bytes) or start_line 1 \
        (search); never combine versions.
        """)
    static let rawField = DoorFieldDescriptor.bool("raw", "Read the original view instead of its sense.")
    static let wrongField = DoorFieldDescriptor.bool("wrong", "Read the original view and offer sense repair after a successful read.")
    static let whyField = DoorFieldDescriptor.string("why", "Optional explanation of what is wrong with the sense view.")
    static let doorFields = [
        pathField, matchField, queryField, startLineField, maxLinesField, maxBytesField, offsetField,
        versionField, rawField, wrongField, whyField,
    ]
    let path: String
    let match: String?
    let query: String?
    let startLine: DoorNumberLiteral?
    let maxLines: DoorNumberLiteral?
    let maxBytes: DoorNumberLiteral?
    let offset: DoorNumberLiteral?
    let version: String?
    let raw: Bool?
    let wrong: Bool?
    let why: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
        match = try door.string(Self.matchField)
        query = try door.string(Self.queryField)
        startLine = try door.numberLiteral(Self.startLineField)
        maxLines = try door.numberLiteral(Self.maxLinesField)
        maxBytes = try door.numberLiteral(Self.maxBytesField)
        offset = try door.numberLiteral(Self.offsetField)
        version = try door.string(Self.versionField)
        raw = try door.bool(Self.rawField)
        wrong = try door.bool(Self.wrongField)
        why = try door.string(Self.whyField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(path)
        fields[Self.matchField.name] = match.map(JSONValue.string)
        fields[Self.queryField.name] = query.map(JSONValue.string)
        fields[Self.startLineField.name] = startLine?.wire
        fields[Self.maxLinesField.name] = maxLines?.wire
        fields[Self.maxBytesField.name] = maxBytes?.wire
        fields[Self.offsetField.name] = offset?.wire
        fields[Self.versionField.name] = version.map(JSONValue.string)
        fields[Self.rawField.name] = raw.map(JSONValue.bool)
        fields[Self.wrongField.name] = wrong.map(JSONValue.bool)
        fields[Self.whyField.name] = why.map(JSONValue.string)
        return fields
    }
}

protocol FileMetadataArgs: DoorArgs {
    var filePath: String { get }
    var wire: [String: JSONValue] { get }
}

protocol FileMutationArgs: DoorArgs {
    var path: String { get }
    var destinationForAdmission: String? { get }
    var wire: [String: JSONValue] { get }
}

extension FileMutationArgs {
    var destinationForAdmission: String? { nil }
}

struct ListDirArgs: FileMetadataArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        Directory path; omitted or empty lists the folder relative paths start from, as '.' does. Absolute paths are literal; \
        use ~/Documents/<name> for the user's Documents folder; a file_not_found result is a path miss, not a trust denial.
        """)
    static let nameContainsField = DoorFieldDescriptor.string("name_contains", "Optional literal filename substring, not glob or regex; empty means all names.")
    static let sortField = DoorFieldDescriptor.choice("sort", ["name", "newest", "added", "size"], """
        Ordering: name (default, folders first), newest (added then modified date), added (date added only to this folder, for \
        install/download recency, including app bundles; rows include added_at; unknown dates sort last), or size (observed \
        allocated bytes descending). Size scans return total allocated_bytes, size_complete, per-child sizes and partial_paths; \
        incomplete sizes are lower bounds. Size scans cannot be paged; narrow path for more detail.
        """)
    static let timeBudgetSecondsField = DoorFieldDescriptor.int("time_budget_seconds", """
        Disk usage scan budget for sort:size, default 5, range 1–20 seconds; checked between metadata reads.
        """)
    static let caseSensitiveField = DoorFieldDescriptor.bool("case_sensitive", "Whether filename matching is case-sensitive; default false (case-insensitive).")
    static let maxEntriesField = DoorFieldDescriptor.int("max_entries", "Entries per page, default and maximum 200; minimum 1.")
    static let offsetField = DoorFieldDescriptor.int("offset", "Start at 0. For continuation pass the returned next arguments unchanged.")
    static let snapshotField = DoorFieldDescriptor.string("snapshot", """
        Omit or empty on first page. Required with positive offset; copied from next. directory_changed means restart at offset \
        0 without snapshot.
        """)
    static let doorFields = [
        pathField, nameContainsField, sortField, timeBudgetSecondsField, caseSensitiveField, maxEntriesField,
        offsetField, snapshotField,
    ]
    let path: String?
    let nameContains: String?
    let sort: String?
    let timeBudgetSeconds: DoorNumberLiteral?
    let caseSensitive: Bool?
    let maxEntries: DoorNumberLiteral?
    let offset: DoorNumberLiteral?
    let snapshot: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.string(Self.pathField)
        nameContains = try door.string(Self.nameContainsField)
        sort = try door.string(Self.sortField)
        timeBudgetSeconds = try door.numberLiteral(Self.timeBudgetSecondsField)
        caseSensitive = try door.bool(Self.caseSensitiveField)
        maxEntries = try door.numberLiteral(Self.maxEntriesField)
        offset = try door.numberLiteral(Self.offsetField)
        snapshot = try door.string(Self.snapshotField)
    }

    var filePath: String { path.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "." }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(filePath)
        fields[Self.nameContainsField.name] = nameContains.map(JSONValue.string)
        fields[Self.sortField.name] = sort.map(JSONValue.string)
        fields[Self.timeBudgetSecondsField.name] = timeBudgetSeconds?.wire
        fields[Self.caseSensitiveField.name] = caseSensitive.map(JSONValue.bool)
        fields[Self.maxEntriesField.name] = maxEntries?.wire
        fields[Self.offsetField.name] = offset?.wire
        fields[Self.snapshotField.name] = snapshot.map(JSONValue.string)
        return fields
    }
}

struct FileInfoArgs: FileMetadataArgs {
    static let pathField = DoorFieldDescriptor.string("path", "File or folder path, under the same approved roots as files.list.", required: true)
    static let doorFields: [DoorFieldDescriptor] = [pathField]
    let path: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
    }

    var filePath: String { path }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(path)
        return fields
    }
}

struct WriteFileArgs: FileMutationArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        A relative path such as project/file.txt (resolved inside the canonical NativeAgent workspace), \
        workspace/project/file.txt, or an absolute/~/ path inside another Trust workspace root. Full Mac mode also accepts \
        broader Mac paths, but intentional build/project artifacts belong in the canonical workspace rather than /tmp.
        """, required: true)
    static let contentField = DoorFieldDescriptor.string("content", "Content to write.", required: true)
    static let appendField = DoorFieldDescriptor.bool("append", "Append instead of replacing the file.")
    static let expectedContentSHA256Field = DoorFieldDescriptor.string("expected_content_sha256", """
        Optional SHA-256 of the complete existing UTF-8 file, up to 64 KiB. Before replacement, refuse a missing or changed \
        file with file_changed. Not supported with append.
        """)
    static let doorFields: [DoorFieldDescriptor] = [pathField, contentField, appendField, expectedContentSHA256Field]
    let path: String
    let content: String
    let append: Bool?
    let expectedContentSHA256: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
        content = try door.requiredString(Self.contentField)
        append = try door.bool(Self.appendField)
        expectedContentSHA256 = try door.string(Self.expectedContentSHA256Field)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(path)
        fields[Self.contentField.name] = .string(content)
        fields[Self.appendField.name] = append.map(JSONValue.bool)
        fields[Self.expectedContentSHA256Field.name] = expectedContentSHA256.map(JSONValue.string)
        return fields
    }
}

struct TrashFileArgs: FileMutationArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        File or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.
        """, required: true)
    static let doorFields: [DoorFieldDescriptor] = [pathField]
    let path: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(path)
        return fields
    }
}

struct MoveFileArgs: FileMutationArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        Existing file or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.
        """, required: true)
    static let destinationField = DoorFieldDescriptor.string("destination", """
        Complete new path including the filename or folder name, not just its containing folder. Missing parent folders are created.
        """, required: true)
    static let overwriteField = DoorFieldDescriptor.bool("overwrite", "Replace an existing destination only when explicitly requested. Default false.")
    static let doorFields: [DoorFieldDescriptor] = [pathField, destinationField, overwriteField]
    let path: String
    let destination: String
    let overwrite: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
        destination = try door.requiredString(Self.destinationField)
        overwrite = try door.bool(Self.overwriteField)
    }

    var destinationForAdmission: String? { destination }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(path)
        fields[Self.destinationField.name] = .string(destination)
        fields[Self.overwriteField.name] = overwrite.map(JSONValue.bool)
        return fields
    }
}

struct CopyFileArgs: FileMutationArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        Existing regular file path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.
        """, required: true)
    static let destinationField = DoorFieldDescriptor.string("destination", "Complete new file path including the filename. Missing parent folders are created.", required: true)
    static let overwriteField = DoorFieldDescriptor.bool("overwrite", "Replace an existing destination only when explicitly requested. Default false.")
    static let doorFields: [DoorFieldDescriptor] = [pathField, destinationField, overwriteField]
    let path: String
    let destination: String
    let overwrite: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
        destination = try door.requiredString(Self.destinationField)
        overwrite = try door.bool(Self.overwriteField)
    }

    var destinationForAdmission: String? { destination }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = .string(path)
        fields[Self.destinationField.name] = .string(destination)
        fields[Self.overwriteField.name] = overwrite.map(JSONValue.bool)
        return fields
    }
}

extension FileActions {
    private static let canonicalContextExpand = ActionDescriptor(ContextExpandArgs.self,
        name: "context_expand",
        run: { context, input in
            try await context.client.impl_context_expand(turn: context.turn, invocation: context.invocation, input: input)
        },
        toolClass: .read, capabilities: [.toolCall],
        description: """
            Read an offered atom, a history: message id, or a live body: joint (front, browser, files, threads, somatic). Context atoms are pinned to this turn's \
            generation; an exact history id reads its saved message across conversations.
            """
    )

    static let fileActions: [ActionDescriptor] = {
        [
            ActionDescriptor(ReadFileArgs.self, name: "read_file",
                run: { context, input in
                    try await context.client.dispatchNormalizedFileRead(turn: context.turn, invocation: context.invocation, tool: context.tool, input: input, metadata: context.transportMetadata, surface: context.surface)
                }, toolClass: .read,
                description: """
                    Read a regular workspace/user-approved file; pipes/devices/sockets return unsupported_file_type. Text: byte windows \
                    (bytes=source size; offset/returned_bytes=current window; max_bytes=limit); follow next/has_more. Images: \
                    PNG/JPEG/WebP/GIF/HEIC/TIFF/BMP pixels, not OCR; ≤8 MiB/40 MP, first frame oriented/resized to 2048 px. Folder+match: ≤8 files. \
                    Read image paths to view; names/consult refs are not viewing. Relative paths use the canonical workspace; verified development \
                    checkouts also allow repo-relative paths. Full Mac file access admits absolute Mac paths except NativeAgent \
                    trust/secrets/provider paths; Absolute paths are literal; use ~/Documents/... for Documents. Long handoff Markdown defaults to \
                    a compact leading window unless max_bytes is explicit.
                    """
            ),
            canonicalContextExpand,
            ActionDescriptor(ListDirArgs.self, name: "list_dir",
                run: { context, args in
                    try await context.client.dispatchNormalizedFileMetadata(turn: context.turn, invocation: context.invocation, tool: context.tool, input: args, surface: context.surface)
                }, toolClass: .read,
                description: """
                    List/filter immediate names in an approved folder. sort:size reads allocated disk usage for the folder and its children within \
                    a time budget, naming partial paths and lower bounds. Ordinary listings return bounded pages and next arguments; read selected \
                    text with files.excerpt. Public/app-only relative paths use the canonical workspace; verified development checkouts also accept \
                    repo-relative paths. Full Mac permits absolute paths except NativeAgent trust/secrets/provider paths.
                    """
            ),
            ActionDescriptor(FileInfoArgs.self, name: "file_info",
                run: { context, args in
                    try await context.client.dispatchNormalizedFileMetadata(turn: context.turn, invocation: context.invocation, tool: context.tool, input: args, surface: context.surface)
                }, toolClass: .read,
                description: """
                    Read one approved path's name, directory and regular flags, size in bytes and modified ISO 8601 date. Does not follow the final \
                    symbolic link. Uses the same file access as files.list.
                    """
            ),
            ActionDescriptor(WriteFileArgs.self, name: "write_file",
                run: { context, args in
                    try await context.client.dispatchNormalizedFileMutation(turn: context.turn, invocation: context.invocation, tool: context.tool, input: args, surface: context.surface)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: """
                    Create or write a UTF-8 file, creating missing parent folders automatically; append is optional. Ordinary project work belongs \
                    in NativeAgent's canonical workspace/ (public installs: ~/Library/Application Support/NativeAgent/workspace). Without Full Mac, \
                    stay within that workspace or a user-added Trust workspace root. Active Full Mac file access permits broader Mac writes except \
                    NativeAgent trust/secrets/provider paths and protected system mutations.
                    """
            ),
            ActionDescriptor(TrashFileArgs.self, name: "trash_file",
                run: { context, args in
                    try await context.client.dispatchNormalizedFileMutation(turn: context.turn, invocation: context.invocation, tool: context.tool, input: args, surface: context.surface)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: """
                    Move a file or folder to the Trash for delete, remove or clean-up requests. Reversible: returns the original path and \
                    trash_path; restore from the Trash if needed. Uses the same workspace or Full Mac file access as writing files.
                    """
            ),
            ActionDescriptor(MoveFileArgs.self, name: "move_file",
                run: { context, args in
                    try await context.client.dispatchNormalizedFileMutation(turn: context.turn, invocation: context.invocation, tool: context.tool, input: args, surface: context.surface)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: """
                    Move or rename a file or folder on the same filesystem, creating missing destination parent folders. Uses the same writable \
                    roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; no screen or \
                    Finder interaction needed.
                    """
            ),
            ActionDescriptor(CopyFileArgs.self, name: "copy_file",
                run: { context, args in
                    try await context.client.dispatchNormalizedFileMutation(turn: context.turn, invocation: context.invocation, tool: context.tool, input: args, surface: context.surface)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: """
                    Copy a regular file, preserving its data and metadata and creating missing destination parent folders. Uses the same writable \
                    roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; folder copies \
                    are not supported. No screen or Finder interaction needed.
                    """
            ),
        ]
    }()
}

extension SwiftToolDispatcher {

    /// Basic reads retain the same sensitive-subtree fence as Full Mac reads.
    func requireNonSensitiveReadPath(turn: Turn, _ url: URL, tool: String) throws {
        guard connectorPathIsSensitiveData(url, dataRoot: dataRoot, turn: turn) else { return }
        throw AutonomyGateError.toolDenied(
            reason: "\(tool): '\(url.path)' is under a sensitive data sub-tree "
                + "(OAuth tokens, pairing secrets, provider credentials, trust policy). "
                + "Use the app's own actions such as app agent.introspect or memory.recall instead."
        )
    }

    func dispatchNormalizedFileRead(turn: Turn, invocation: ChatToolInvocation, tool: String, input: ReadFileArgs,
        metadata: [String: JSONValue], surface: String) async throws -> JSONValue {
        do {
            return try await impl_read_file(turn: turn, invocation: invocation, input: input, metadata: metadata, surface: surface)
        } catch {
            guard let need = fileOpsNeedEnvelope(invocation: invocation,
                tool: tool, mode: .read, path: input.path, error: error
            ) else { throw error }
            return need
        }
    }

    func dispatchNormalizedFileMetadata(turn: Turn, invocation: ChatToolInvocation, tool: String, input: some FileMetadataArgs,
        surface: String) async throws -> JSONValue {
        if try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed {
            return tool == "list_dir" ? try await impl_full_mac_list_dir(turn: turn, invocation: invocation, input: input, surface: surface)
                : try await impl_local_connector_tool(turn: turn, invocation: invocation, tool: tool, input: input.wire, surface: surface)
        }
        do {
            return try await impl_file_metadata(turn: turn, invocation: invocation, tool: tool, input: input)
        } catch {
            guard let need = fileOpsNeedEnvelope(invocation: invocation,
                tool: tool, mode: .read, path: input.filePath, error: error
            ) else { throw error }
            return need
        }
    }

    func dispatchNormalizedFileMutation(turn: Turn, invocation: ChatToolInvocation, tool: String, input: some FileMutationArgs,
        surface: String) async throws -> JSONValue {
        if try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed {
            return try await impl_local_connector_tool(turn: turn, invocation: invocation, tool: tool, input: input.wire,
                surface: surface)
        }
        do {
            return try await impl_trusted_file_mutation(turn: turn, invocation: invocation, tool: tool, input: input)
        } catch {
            guard let need = fileOpsNeedEnvelope(invocation: invocation,
                tool: tool, mode: .write, path: input.path, error: error
            ) else { throw error }
            return need
        }
    }

    func impl_read_file(turn: Turn, invocation: ChatToolInvocation, input: ReadFileArgs, metadata: [String: JSONValue], surface: String? = nil) async throws -> JSONValue {
        let fullMac = if let surface { try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed } else { false }
        let path = input.path, wire = input.wire.merging(metadata) { value, _ in value }
        let address: String
        let raw: @Sendable (SenseReadOperation) async throws -> JSONValue
        if fullMac, let surface {
            address = path
            raw = { operation in
                try await self.impl_local_connector_tool(turn: turn, invocation: invocation.serving(sense: operation),
                    tool: "read_file", input: wire, surface: surface)
            }
        } else {
            let url = try await resolveTrustedFilePath(turn: turn, path)
            try requireNonSensitiveReadPath(turn: turn, url, tool: "read_file")
            address = url.path
            let fileInput = wire.merging(["path": .string(url.path)]) { _, new in new }
            let ctx = ConnectorActionContext(repoRoot: url.deletingLastPathComponent(), dataRoot: dataRoot,
                turn: turn, readOptions: .init(metadataOnly: invocation.metadataOnly, imageSink: invocation.imageSink))
            raw = { operation in
                var ctx = ctx
                ctx.turn = operation.turn
                guard let result = LocalConnectorActions.fileSystemDefault.run("read_file", input: fileInput, ctx: ctx) else {
                    throw AutonomyGateError.toolDenied(reason: "read_file has no Swift local connector implementation")
                }
                return result
            }
        }
        if invocation.metadataOnly { return try await raw(invocation.senseOperation(turn: turn)) }
        let sources = Mutex(Set<String>())
        let studio = MakeStudio(dataRoot: dataRoot)
        let nativeReadSupported = FileReadSourceMaterial.nativeReadSupported(path: address)
        let result = try await SenseDoor.read(corner: .fileKind(URL(fileURLWithPath: address).pathExtension.lowercased()), address: address, input: wire,
            scope: turn.verifiedSessionID ?? "",
            nativeReadSupported: nativeReadSupported,
            fileAlreadyReadable: nativeReadSupported,
            operation: invocation.senseOperation(turn: turn),
            raw: { operation in
                let read = try await raw(operation)
                let files = read.objectValue?["files"]?.arrayValue?.compactMap { $0.objectValue?["result"] } ?? [read]
                for file in files {
                    guard let fields = file.objectValue, fields["ok"] != .bool(false),
                          let path = fields["path"]?.stringValue,
                          ["content", "excerpt"].contains(where: { fields[$0]?.stringValue?.isEmpty == false })
                              || fields["records"]?.arrayValue?.isEmpty == false,
                          let peer = try studio.version(at: URL(fileURLWithPath: path))?.peerID else { continue }
                    sources.withLock { _ = $0.insert("peer:" + peer) }
                }
                return read
            }, material: { result, _ in try Self.senseFileMaterial(result) })
        if ChatToolOutcome.outputLooksSuccessful(result) {
            for source in sources.withLock({ $0.sorted() }) { turn.peerSteering?.mark(dataRoot: dataRoot, peer: source) }
        }
        let reply = ToolResult(result)
        if input.raw == true || input.wrong == true || invocation.readingRaw { return result }
        guard case .object(let object) = result else { return result }
        if fullMac {
            // A sense's own failure returns as itself: identity, provenance and repair.
            if object["ok"] == .bool(false), object["sense_provenance"] != nil { return result }
            if case .string? = object["content"] { return Self.fileReadPresentation(result, callerPath: path) }
            if case .string(let code)? = object["error_code"],
               ["file_changed", "bad_input", "window_too_small", "continuation_unavailable", "read_failed", "unsupported_file_type",
                   "invalid_utf8"].contains(code) { return result }
        }
        if let pathMiss = filePathMissEnvelope(tool: "read_file", path: path, resultObject: object) {
            return pathMiss
        }
        if fullMac, case .string? = object["error"] { throw AutonomyGateError.toolDenied(reason: reply.failure ?? "") }
        return Self.fileReadPresentation(result, callerPath: path)
    }

    /// Keep the range receipt and replay the authorized caller path spelling.
    static func fileReadPresentation(_ result: JSONValue, callerPath: String) -> JSONValue {
        guard case .object(var object) = result else { return result }
        if case .object(var next)? = object["next"] {
            next["path"] = .string(callerPath)
            object["next"] = .object(next)
        }
        return .object(object)
    }

    func impl_file_metadata(turn: Turn, invocation: ChatToolInvocation, tool: String, input: some FileMetadataArgs) async throws -> JSONValue {
        let path = input.filePath
        let url = try await resolveTrustedFilePath(turn: turn, path, followFinalLink: tool != "file_info")
        try requireNonSensitiveReadPath(turn: turn, url, tool: tool)
        var patchedInput = input.wire
        patchedInput["path"] = .string(url.path)
        // Share bounded listing only after read-root and sensitive-path admission; connector routing must not widen approved roots.
        let ctx = ConnectorActionContext(
            repoRoot: tool == "file_info" ? url.deletingLastPathComponent() : url,
            dataRoot: dataRoot, turn: turn, readOptions: .init(metadataOnly: invocation.metadataOnly, imageSink: invocation.imageSink)
        )
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            tool, input: patchedInput, ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(reason: "\(tool) has no Swift local connector implementation")
        }
        // Workspace-relative and absolute paths have different trust resolution. Continue with the spelling that passed the gate; the connector snapshot
        // remains bound to the resolved directory.
        if case .object(var object) = result, case .object(var next)? = object["next"] {
            next["path"] = .string(path)
            object["next"] = .object(next)
            return .object(object)
        }
        return result
    }

    /// Preview checks through the file reader's own fences and parser. No sense growth, image delivery, dispatch ledger, provider, command or write runs.
    func fileReadPreviewRefusal(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue], surface: String) async -> JSONValue? {
        guard ["read_file", "list_dir", "file_info", "file_excerpt"].contains(tool) else { return nil }
        var path = input["path"]?.stringValue
        if tool == "list_dir", path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { path = "." }
        do {
            let invocation = invocation.with(\.metadataOnly, true)
            let read: () async throws -> JSONValue = {
                if tool == "read_file" {
                    let args = try DoorSchemaBuilder<ReadFileArgs>().decode(input)
                    return try await self.impl_read_file(turn: turn, invocation: invocation, input: args,
                                                        metadata: input.filter { $0.key.hasPrefix("__") }, surface: surface)
                }
                if try await self.fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed || tool == "file_excerpt" {
                    let wire = tool == "list_dir" ? try DoorSchemaBuilder<ListDirArgs>().decode(input).wire : input
                    return try await self.impl_local_connector_tool(turn: turn, invocation: invocation, tool: tool, input: wire, surface: surface)
                }
                if tool == "list_dir" {
                    let args = try DoorSchemaBuilder<ListDirArgs>().decode(input)
                    return try await self.impl_file_metadata(turn: turn, invocation: invocation, tool: tool, input: args)
                }
                let args = try DoorSchemaBuilder<FileInfoArgs>().decode(input)
                return try await self.impl_file_metadata(turn: turn, invocation: invocation, tool: tool, input: args)
            }
            let result = try await read()
            return ChatToolOutcome.outputLooksSuccessful(result) ? nil : ChatToolOutcome.normalizedFailure(result, tool: tool)
        } catch {
            if let need = fileOpsNeedEnvelope(invocation: invocation, tool: tool, mode: .read, path: path, error: error) { return need }
            return ChatToolOutcome.failure(error: error, tool: tool)
        }
    }

    func impl_trusted_file_mutation(turn: Turn, invocation: ChatToolInvocation, tool: String, input: some FileMutationArgs) async throws -> JSONValue {
        try await trustedFileMutation(turn: turn, invocation: invocation, tool: tool, path: input.path,
                                      destination: input.destinationForAdmission, wire: input.wire)
    }

    func impl_trusted_file_mutation(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue],
                                    attachment: (filename: String, data: Data)) async throws -> JSONValue {
        try await trustedFileMutation(turn: turn, invocation: invocation, tool: tool, path: requireString(input, "path"),
                                      destination: nil, wire: input, attachment: attachment)
    }

    private func trustedFileMutation(turn: Turn, invocation: ChatToolInvocation, tool: String, path: String, destination: String?,
                                     wire: [String: JSONValue], attachment: (filename: String, data: Data)? = nil) async throws -> JSONValue {
        let roots = try await trustedWorkspaceRoots()
        let url = try await resolveTrustedFilePath(turn: turn, path, write: true, trustedRoots: roots)
        if let destination {
            _ = try await resolveTrustedFilePath(turn: turn, destination, write: true, trustedRoots: roots)
        }
        let ctx = ConnectorActionContext(
            repoRoot: nil,
            fileAccess: [
                "mode": .string("workspace"),
                "sandbox": .string("workspace"),
            ],
            dataRoot: dataRoot,
            extraAllowedRoots: roots,
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot),
            workspaceRoot: NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot),
            turn: turn, readOptions: .init(metadataOnly: invocation.metadataOnly, imageSink: invocation.imageSink)
        )
        if let attachment {
            var attachmentInput = wire
            attachmentInput["path"] = .string(url.path)
            return LocalConnectorActions.saveAttachment(attachment, input: attachmentInput, ctx: ctx)
        }
        // I/O keeps the caller's spelling and this operation's admitted roots.
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            tool,
            input: wire,
            ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: \(tool) has no Swift local connector implementation"
            )
        }
        return result
    }
}
