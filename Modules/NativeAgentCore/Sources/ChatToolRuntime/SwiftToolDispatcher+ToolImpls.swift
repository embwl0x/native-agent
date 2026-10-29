import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Dispatcher
import Senses
// Blueprint: | `SwiftToolDispatcher+ToolImpls.swift` | `SwiftToolDispatcher`: `requireNonSensitiveReadPath`, `impl_read_file` (window parsing, ceilings and omitted defaults belong to `FileSystemActions`), `fileReadPresentation`, shared `impl_file_metadata` for list/info, `impl_trusted_file_mutation` (workspace writes and Trash) |

// MARK: - Basic file tools

extension SwiftToolDispatcher {

    /// Basic reads retain the same sensitive-subtree fence as Full Mac reads.
    func requireNonSensitiveReadPath(_ url: URL, tool: String) throws {
        guard connectorPathIsSensitiveData(url, dataRoot: dataRoot) else { return }
        throw AutonomyGateError.toolDenied(
            reason: "\(tool): '\(url.path)' is under a sensitive data sub-tree "
                + "(OAuth tokens, pairing secrets, provider credentials, trust policy). "
                + "Use dedicated runtime tools such as app agent.introspect or memory.recall instead."
        )
    }

    func impl_read_file(input: [String: JSONValue], surface: String? = nil) async throws -> JSONValue {
        let fullMac = if let surface { await fullMacToolAccess(surface: surface).fileOpsAllowed } else { false }
        let path: String, address: String
        let raw: @Sendable () async throws -> JSONValue
        if fullMac, let surface {
            path = input["path"]?.stringValue ?? ""
            address = path
            raw = { try await self.impl_local_connector_tool(tool: "read_file", input: input, surface: surface) }
        } else {
            path = try requireString(input, "path")
            let url = try await resolveTrustedFilePath(path)
            try requireNonSensitiveReadPath(url, tool: "read_file")
            address = url.path
            let fileInput = input.merging(["path": .string(url.path)]) { _, new in new }
            let ctx = ConnectorActionContext(repoRoot: url.deletingLastPathComponent(), dataRoot: dataRoot)
            raw = {
                guard let result = LocalConnectorActions.fileSystemDefault.run("read_file", input: fileInput, ctx: ctx) else {
                    throw AutonomyGateError.toolDenied(reason: "read_file has no Swift local connector implementation")
                }
                return result
            }
        }
        if FileReadSourceMaterial.metadataOnly { return try await raw() }
        let nativeReadSupported = FileReadSourceMaterial.nativeReadSupported(path: address)
        let result = try await SenseDoor.read(corner: .fileKind(URL(fileURLWithPath: address).pathExtension.lowercased()), address: address, input: input,
            scope: ChatToolSessionContext.verifiedSessionId ?? "",
            nativeReadSupported: nativeReadSupported,
            fileAlreadyReadable: nativeReadSupported,
            raw: raw, material: { try Self.senseFileMaterial($0) })
        if input["raw"] == .bool(true) || input["wrong"] == .bool(true) || SenseDoor.readingRaw { return result }
        guard case .object(let object) = result else { return result }
        if fullMac {
            if object["ok"] == .bool(false), object["raw"] != nil, object["sense_provenance"] != nil { return result }
            if case .string? = object["content"] { return Self.fileReadPresentation(result, callerPath: path) }
            if case .string(let code)? = object["error_code"],
               ["file_changed", "bad_input", "window_too_small", "continuation_unavailable", "read_failed", "unsupported_file_type"].contains(code) { return result }
        }
        if let pathMiss = filePathMissEnvelope(tool: "read_file", input: input, resultObject: object) {
            return pathMiss
        }
        if fullMac, case .string(let error)? = object["error"] { throw AutonomyGateError.toolDenied(reason: error) }
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

    /// Missing or empty listing paths mean "."; reads and writes require nonempty paths.
    static func listDirInput(_ input: [String: JSONValue]) -> [String: JSONValue] {
        switch input["path"] {
        case nil, .null?: break
        case .string(let path)? where path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: break
        default: return input
        }
        var input = input
        input["path"] = .string(".")
        return input
    }

    func impl_file_metadata(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(path, followFinalLink: tool != "file_info")
        try requireNonSensitiveReadPath(url, tool: tool)
        var patchedInput = input
        patchedInput["path"] = .string(url.path)
        // The path has already passed the ordinary read-root and sensitive
        // fences. Share the bounded listing implementation without invoking
        // the Full Mac-only connector route or widening the approved roots.
        let ctx = ConnectorActionContext(
            repoRoot: tool == "file_info" ? url.deletingLastPathComponent() : url,
            dataRoot: dataRoot
        )
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            tool, input: patchedInput, ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(reason: "\(tool) has no Swift local connector implementation")
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
        guard ["read_file", "list_dir", "file_info", "file_excerpt"].contains(tool) else { return nil }
        let input = tool == "list_dir" ? Self.listDirInput(input) : input
        do {
            let result = try await FileReadSourceMaterial.$metadataOnly.withValue(true) {
                if tool == "read_file" { return try await self.impl_read_file(input: input, surface: surface) }
                if await self.fullMacToolAccess(surface: surface).fileOpsAllowed || tool == "file_excerpt" {
                    return try await self.impl_local_connector_tool(tool: tool, input: input, surface: surface)
                }
                return try await self.impl_file_metadata(tool: tool, input: input)
            }
            return ChatToolOutcome.outputLooksSuccessful(result) ? nil : ChatToolOutcome.normalizedFailure(result, tool: tool)
        } catch {
            if let need = fileOpsNeedEnvelope(tool: tool, mode: .read, path: input["path"]?.stringValue, error: error) { return need }
            return ChatToolOutcome.failure(error: error, tool: tool)
        }
    }

    func impl_trusted_file_mutation(tool: String, input: [String: JSONValue], attachment: (filename: String, data: Data)? = nil) async throws -> JSONValue {
        let path = try requireString(input, "path")
        if tool == "write_file" { _ = try requireString(input, "content") }
        let roots = await trustedWorkspaceRoots()
        let url = try await resolveTrustedFilePath(path, includeRepoSandbox: false, trustedRoots: roots)
        if ["move_file", "copy_file"].contains(tool) {
            _ = try await resolveTrustedFilePath(requireString(input, "destination"), includeRepoSandbox: false, trustedRoots: roots)
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
            workspaceRoot: NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        )
        if let attachment {
            var attachmentInput = input
            attachmentInput["path"] = .string(url.path)
            return LocalConnectorActions.saveAttachment(attachment, input: attachmentInput, ctx: ctx)
        }
        // I/O keeps the caller's spelling and this operation's admitted roots.
        guard let result = LocalConnectorActions.fileSystemDefault.run(
            tool,
            input: input,
            ctx: ctx
        ) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: \(tool) has no Swift local connector implementation"
            )
        }
        return result
    }
}
