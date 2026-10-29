import Foundation
import ChatTurnContracts
import NativeAgentCore
import PersistenceCore
import Desk
import ToolRegistry
// Blueprint: | `WorkshopToolProfile.swift` | `WorkshopToolProfile` struct; `permits` |

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
    /// After the worker settles, seal and return its artifact set in one hop.
    /// This is the collector's only read; later writes are refused.
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
        // A valid report supersedes earlier recording failures.
        failures.removeAll()
    }
    /// Only the RECORDING channel's failures are evidence about the report; a
    /// failed read or an unrelated tool is the model's problem to route around.
    static let recordingToolNames: Set<String> = [
        WorkshopToolProfile.progressToolName,
        WorkshopToolProfile.artifactToolName,
        "desk_work_log",
    ]
    /// Retain recording failures so a receipt can distinguish them from no output.
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
    /// desk_work_log accepts only pursuits; workshop_progress accepts both lanes.
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
        // Drop only trusted dispatch session metadata before exact-key validation.
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
            toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
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
            toolClass: .read, reach: .his,
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
            toolClass: .write, reach: .his,
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
        // The sealed collector refuses writes after the session receipt is filed.
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
