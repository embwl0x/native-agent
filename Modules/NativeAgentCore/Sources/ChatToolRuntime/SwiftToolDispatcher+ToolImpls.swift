import AgentWorkspace
import ChatToolParsing
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
    func requireNonSensitiveReadPath(turn: Turn, _ url: URL, tool: String) throws {
        guard connectorPathIsSensitiveData(url, dataRoot: dataRoot, turn: turn) else { return }
        throw AutonomyGateError.toolDenied(
            reason: "\(tool): '\(url.path)' is under a sensitive data sub-tree "
                + "(OAuth tokens, pairing secrets, provider credentials, trust policy). "
                + "Use dedicated runtime tools such as app agent.introspect or memory.recall instead."
        )
    }

    func impl_read_file(turn: Turn, invocation: ChatToolInvocation, input: [String: JSONValue], surface: String? = nil) async throws -> JSONValue {
        let fullMac = if let surface { try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed } else { false }
        let path: String, address: String
        let raw: @Sendable (SenseReadOperation) async throws -> JSONValue
        if fullMac, let surface {
            path = input["path"]?.stringValue ?? ""
            address = path
            raw = { operation in
                try await self.impl_local_connector_tool(turn: turn, invocation: invocation.serving(sense: operation),
                    tool: "read_file", input: input, surface: surface)
            }
        } else {
            path = try requireString(input, "path")
            let url = try await resolveTrustedFilePath(turn: turn, path)
            try requireNonSensitiveReadPath(turn: turn, url, tool: "read_file")
            address = url.path
            let fileInput = input.merging(["path": .string(url.path)]) { _, new in new }
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
        let nativeReadSupported = FileReadSourceMaterial.nativeReadSupported(path: address)
        let result = try await SenseDoor.read(corner: .fileKind(URL(fileURLWithPath: address).pathExtension.lowercased()), address: address, input: input,
            scope: turn.verifiedSessionID ?? "",
            nativeReadSupported: nativeReadSupported,
            fileAlreadyReadable: nativeReadSupported,
            operation: invocation.senseOperation(turn: turn),
            raw: raw, material: { result, _ in try Self.senseFileMaterial(result) })
        let reply = ToolResult(result)
        if input["raw"] == .bool(true) || input["wrong"] == .bool(true) || invocation.readingRaw { return result }
        guard case .object(let object) = result else { return result }
        if fullMac {
            // A sense's own failure returns as itself: identity, provenance and repair.
            if object["ok"] == .bool(false), object["sense_provenance"] != nil { return result }
            if case .string? = object["content"] { return Self.fileReadPresentation(result, callerPath: path) }
            if case .string(let code)? = object["error_code"],
               ["file_changed", "bad_input", "window_too_small", "continuation_unavailable", "read_failed", "unsupported_file_type",
                   "invalid_utf8"].contains(code) { return result }
        }
        if let pathMiss = filePathMissEnvelope(tool: "read_file", input: input, resultObject: object) {
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

    func impl_file_metadata(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(turn: turn, path, followFinalLink: tool != "file_info")
        try requireNonSensitiveReadPath(turn: turn, url, tool: tool)
        var patchedInput = input
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
        let input = tool == "list_dir" ? Self.listDirInput(input) : input
        do {
            let invocation = invocation.with(\.metadataOnly, true)
            let read: () async throws -> JSONValue = {
                if tool == "read_file" { return try await self.impl_read_file(turn: turn, invocation: invocation, input: input, surface: surface) }
                if try await self.fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed || tool == "file_excerpt" {
                    return try await self.impl_local_connector_tool(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
                }
                return try await self.impl_file_metadata(turn: turn, invocation: invocation, tool: tool, input: input)
            }
            let result = try await read()
            return ChatToolOutcome.outputLooksSuccessful(result) ? nil : ChatToolOutcome.normalizedFailure(result, tool: tool)
        } catch {
            if let need = fileOpsNeedEnvelope(invocation: invocation, tool: tool, mode: .read, path: input["path"]?.stringValue, error: error) { return need }
            return ChatToolOutcome.failure(error: error, tool: tool)
        }
    }

    func impl_trusted_file_mutation(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue], attachment: (filename: String,
        data: Data)? = nil) async throws -> JSONValue {
        let path = try requireString(input, "path")
        if tool == "write_file" { _ = try requireString(input, "content") }
        let roots = try await trustedWorkspaceRoots()
        let url = try await resolveTrustedFilePath(turn: turn, path, write: true, trustedRoots: roots)
        if ["move_file", "copy_file"].contains(tool) {
            _ = try await resolveTrustedFilePath(turn: turn, requireString(input, "destination"), write: true, trustedRoots: roots)
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
