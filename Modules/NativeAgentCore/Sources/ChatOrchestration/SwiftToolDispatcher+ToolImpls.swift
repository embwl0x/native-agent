import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Dispatcher

// MARK: - Basic file tools

extension SwiftToolDispatcher {

    static let maxFileBytes: Int = 64 * 1024
    private static let maxListEntries: Int = 200

    func impl_read_file(input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(path)
        // Read at most maxFileBytes + 1 so we can flag truncation. Reading the
        // whole file then trimming would still allocate the full size; we cap
        // via FileHandle to keep blast radius bounded for huge files.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return filePathMissEnvelope(
                tool: "read_file",
                input: input,
                resultObject: [
                    "ok": .bool(false),
                    "status": .string("failed"),
                    "error_code": .string("file_not_found"),
                    "reason": .string("File not found at the requested path."),
                ]
            ) ?? .object([
                "ok": .bool(false),
                "status": .string("failed"),
                "error_code": .string("file_not_found"),
            ])
        }
        defer { try? handle.close() }
        let totalBytes: Int = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                return size.intValue
            }
            return -1
        }()
        let data = (try? handle.read(upToCount: Self.maxFileBytes)) ?? Data()
        var text = String(data: data, encoding: .utf8) ?? ""
        if totalBytes > Self.maxFileBytes {
            text += "\n... [truncated, \(totalBytes) bytes total]"
        }
        return .string(text)
    }

    func impl_list_dir(input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(path)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        } catch {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: cannot list '\(path)': \(error.localizedDescription)"
            )
        }
        let capped = Array(names.prefix(Self.maxListEntries))
        return .array(capped.map { .string($0) })
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
