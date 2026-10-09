import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Dispatcher
import Senses

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
                + "Use dedicated runtime tools such as app agent.introspect or memory.recall instead."
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
        let fileInput = patchedInput
        if FileReadSourceMaterial.metadataOnly {
            guard let result = LocalConnectorActions.fileSystemDefault.run("read_file", input: fileInput, ctx: ctx) else {
                throw AutonomyGateError.toolDenied(reason: "read_file has no Swift local connector implementation")
            }
            return result
        }
        let nativeReadSupported = FileReadSourceMaterial.nativeReadSupported(path: url.path)
        let result = try await SenseDoor.read(corner: .fileKind(url.pathExtension.lowercased()), address: url.path, input: input,
            scope: ChatToolSessionContext.verifiedSessionId ?? "",
            nativeReadSupported: nativeReadSupported,
            fileAlreadyReadable: nativeReadSupported,
            raw: {
                guard let result = LocalConnectorActions.fileSystemDefault.run("read_file", input: fileInput, ctx: ctx) else {
                    throw AutonomyGateError.toolDenied(reason: "read_file has no Swift local connector implementation")
                }
                return result
            }, material: { try Self.senseFileMaterial($0) })
        if input["raw"] == .bool(true) || input["wrong"] == .bool(true) || SenseDoor.readingRaw { return result }
        if case .object(let object) = result,
           let pathMiss = await filePathMissEnvelope(tool: "read_file", input: input, resultObject: object) {
            return pathMiss
        }
        return Self.fileReadPresentation(result, callerPath: path)
    }

    /// Keep the range receipt and replay the authorized caller path spelling.
    static func fileReadPresentation(_ result: JSONValue, callerPath: String) -> JSONValue {
        guard case .object(var object) = result, case .string? = object["content"] else { return result }
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

    /// Preview checks through the file reader's own fences and parser. No sense
    /// growth, image delivery, dispatch ledger, provider, command or write runs.
    func fileReadPreviewRefusal(tool: String, input: [String: JSONValue], surface: String) async -> JSONValue? {
        guard ["read_file", "list_dir", "file_excerpt"].contains(tool) else { return nil }
        do {
            let result = try await FileReadSourceMaterial.$metadataOnly.withValue(true) {
                if await self.fullMacToolAccess(surface: surface).fileOpsAllowed || tool == "file_excerpt" {
                    return try await self.impl_local_connector_tool(tool: tool, input: input, surface: surface)
                }
                return tool == "read_file" ? try await self.impl_read_file(input: input) : try await self.impl_list_dir(input: input)
            }
            return ChatToolOutcome.outputLooksSuccessful(result) ? nil : ChatToolOutcome.normalizedFailure(result, tool: tool)
        } catch {
            if let need = fileOpsNeedEnvelope(tool: tool, mode: .read, path: jsonString(input["path"]), error: error) { return need }
            return ChatToolOutcome.failure(error: error, tool: tool)
        }
    }

    func impl_trusted_file_mutation(tool: String, input: [String: JSONValue], attachment: (filename: String, data: Data)? = nil) async throws -> JSONValue {
        let path = try requireString(input, "path")
        if tool == "write_file" { _ = try requireString(input, "content") }
        let url = try await resolveTrustedFilePath(path, includeRepoSandbox: false)
        let roots = await trustedWorkspaceRoots()
        var patchedInput = input
        patchedInput["path"] = .string(url.path)
        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        if ["move_file", "copy_file"].contains(tool) {
            patchedInput["destination"] = .string(try await resolveTrustedFilePath(requireString(input, "destination"), includeRepoSandbox: false).path)
        }
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
        if let attachment { return LocalConnectorActions.saveAttachment(attachment, input: patchedInput, ctx: ctx) }
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            tool,
            input: patchedInput,
            ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: \(tool) has no Swift local connector implementation"
            )
        }
        return result
    }
}
