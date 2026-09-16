import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Dispatcher

// MARK: - Basic file tools

extension SwiftToolDispatcher {

    static let maxFileBytes: Int = 64 * 1024

    /// 2026-09-06: the same sensitive-subtree fence the Full Mac file tools
    /// apply. Full Mac being OFF chose these basic readers instead, and they
    /// checked nothing — `data/secrets`, `data/providers` and `data/trust` are
    /// reachable through the repo sandbox because `data` is an allowed top
    /// level. Turning a capability off must not open a subtree.
    func requireNonSensitiveReadPath(_ url: URL, tool: String) throws {
        guard connectorPathIsSensitiveData(url, dataRoot: dataRoot) else { return }
        throw AutonomyGateError.toolDenied(
            reason: "\(tool): '\(url.path)' is under a sensitive data sub-tree "
                + "(OAuth tokens, pairing secrets, provider credentials, trust policy). "
                + "Use dedicated runtime tools such as agent_introspect or recall_search instead."
        )
    }

    func impl_read_file(input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(path)
        try requireNonSensitiveReadPath(url, tool: "read_file")
        let window: Int
        switch Self.readFileMaxBytes(input["max_bytes"]) {
        case .omitted: window = Self.maxFileBytes
        case .bytes(let n): window = min(max(0, n), Self.maxFileBytes)
        case .invalid:
            return .object([
                "ok": .bool(false), "error_code": .string("bad_input"),
                "reason": .string("max_bytes must be an integer."),
            ])
        }
        var patchedInput = input
        patchedInput["path"] = .string(url.path)
        patchedInput["max_bytes"] = .int(Int64(window))
        let ctx = ConnectorActionContext(repoRoot: url.deletingLastPathComponent().path, dataRoot: dataRoot.path)
        guard let result = LocalConnectorActions.fileSystemDefault.run("read_file", input: patchedInput, ctx: ctx) else {
            throw AutonomyGateError.toolDenied(reason: "read_file has no Swift local connector implementation")
        }
        if case .object(let object) = result,
           let pathMiss = filePathMissEnvelope(tool: "read_file", input: input, resultObject: object) {
            return pathMiss
        }
        return Self.fileReadPresentation(result, callerPath: path, continuing: jsonString(input["version"])?.isEmpty == false)
    }

    /// Keep small initial reads compatible, while every partial/continued
    /// window exposes its scope. Replay the authorized caller path spelling.
    static func fileReadPresentation(_ result: JSONValue, callerPath: String, continuing: Bool) -> JSONValue {
        guard case .object(var object) = result, case .string(let content)? = object["content"] else { return result }
        if !continuing, object["truncated"] == .bool(false), object["offset"] == .int(0) { return .string(content) }
        if case .object(var next)? = object["next"] {
            next["path"] = .string(callerPath)
            object["next"] = .object(next)
        }
        return .object(object)
    }

    /// `max_bytes` as the schema declares it. Numeric strings are accepted
    /// because compiled procedures serialise every field as one; anything else
    /// is bad_input rather than a silently-ignored field.
    enum ReadFileWindow { case omitted, bytes(Int), invalid }

    static func readFileMaxBytes(_ value: JSONValue?) -> ReadFileWindow {
        switch value ?? .null {
        case .null: return .omitted
        case .int(let i): return .bytes(Int(i))
        case .double(let d):
            // User, 2026-09-06: a byte count is a whole number. Rounding 10.9
            // down to 10 silently answered a question nobody asked; a caller
            // that means 10.9 means something this tool cannot do, so say so.
            guard let i = Int(exactly: d) else { return .invalid }
            return .bytes(i)
        case .string(let s):
            if s.isEmpty { return .omitted }
            guard let i = Int(s) else { return .invalid }
            return .bytes(i)
        default: return .invalid
        }
    }

    func impl_list_dir(input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(path)
        try requireNonSensitiveReadPath(url, tool: "list_dir")
        var patchedInput = input
        patchedInput["path"] = .string(url.path)
        // The path has already passed the ordinary read-root and sensitive
        // fences. Share the bounded listing implementation without invoking
        // the Full Mac-only connector route or widening the approved roots.
        let ctx = ConnectorActionContext(
            repoRoot: url.path,
            dataRoot: dataRoot.path
        )
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            "list_dir", input: patchedInput, ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(reason: "list_dir has no Swift local connector implementation")
        }
        // Repo-relative paths and absolute paths have intentionally different
        // trust resolution. Continue with the spelling that passed the gate;
        // the connector snapshot remains bound to the resolved directory.
        if case .object(var object) = result, case .object(var next)? = object["next"] {
            next["path"] = .string(path)
            object["next"] = .object(next)
            return .object(object)
        }
        return result
    }

    func impl_trusted_write_file(input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        _ = try requireString(input, "content")
        let url = try await resolveTrustedFilePath(path, includeRepoSandbox: false)
        let roots = await trustedWorkspaceRoots()
        var patchedInput = input
        patchedInput["path"] = .string(url.path)
        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        let ctx = ConnectorActionContext(
            repoRoot: "",
            fileAccess: [
                "mode": .string("workspace"),
                "sandbox": .string("workspace"),
            ],
            dataRoot: dataRoot.path,
            extraAllowedRoots: roots.map(\.path),
            personaRoot: PersonaRootResolver.resolve().path,
            workspaceRoot: workspaceRoot.path
        )
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            "write_file",
            input: patchedInput,
            ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: write_file has no Swift local connector implementation"
            )
        }
        return result
    }
}
