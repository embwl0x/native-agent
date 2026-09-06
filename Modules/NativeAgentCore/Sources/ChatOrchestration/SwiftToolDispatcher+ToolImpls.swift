import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Dispatcher

// MARK: - Basic file tools

extension SwiftToolDispatcher {

    static let maxFileBytes: Int = 64 * 1024
    private static let maxListEntries: Int = 200

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
        if let image = LocalToolImage.readAuthorizedFile(url) { return image }
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
        // User, 2026-09-06: the schema ADVERTISES max_bytes on this tool and the
        // basic impl ignored it, always reading the 64 KiB ceiling — a caller
        // asking for a 200-byte peek at a big file paid for the whole window.
        // A window LARGER than the ceiling is still capped there (this lane's
        // bound is not the model's to raise); the truncation note says so.
        let window: Int
        switch Self.readFileMaxBytes(input["max_bytes"]) {
        case .omitted: window = Self.maxFileBytes
        case .bytes(let n): window = min(max(0, n), Self.maxFileBytes)
        case .invalid:
            return .object([
                "ok": .bool(false),
                "status": .string("failed"),
                "error_code": .string("bad_input"),
                "reason": .string("max_bytes must be an integer."),
            ])
        }
        let data: Data
        do {
            data = try handle.read(upToCount: window) ?? Data()
        } catch {
            // A read that THREW used to become an empty string with no error
            // bit, so an unreadable file read to the model as an empty one.
            return .object([
                "ok": .bool(false),
                "status": .string("failed"),
                "error_code": .string("read_failed"),
                "reason": .string("Could not read the file: \(error.localizedDescription)"),
            ])
        }
        // A window that lands mid-character used to fail whole-buffer UTF-8
        // decoding and return "" — the entire read silently discarded. Drop
        // only the split tail; decode the rest, replacing any genuinely
        // invalid bytes rather than throwing the content away.
        let decodable = Self.trimmingSplitUTF8Tail(data)
        var text = String(decoding: decodable, as: UTF8.self)
        if totalBytes > data.count {
            text += "\n... [truncated, \(totalBytes) bytes total]"
        }
        return .string(text)
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

    /// The trailing bytes of a byte window that begin a UTF-8 sequence the
    /// window cut in half, removed. Everything before them is intact text.
    static func trimmingSplitUTF8Tail(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }
        var idx = bytes.count - 1
        var continuations = 0
        while idx >= 0, bytes[idx] & 0xC0 == 0x80, continuations < 3 {
            continuations += 1
            idx -= 1
        }
        guard idx >= 0 else { return data }
        let needed: Int
        switch bytes[idx] {
        case 0x00...0x7F: needed = 1
        case 0xC2...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF4: needed = 4
        default: return data
        }
        guard continuations + 1 < needed else { return data }
        return Data(bytes[0..<idx])
    }

    func impl_list_dir(input: [String: JSONValue]) async throws -> JSONValue {
        let path = try requireString(input, "path")
        let url = try await resolveTrustedFilePath(path)
        try requireNonSensitiveReadPath(url, tool: "list_dir")
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
