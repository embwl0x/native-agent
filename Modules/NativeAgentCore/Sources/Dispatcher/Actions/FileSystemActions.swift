import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import MacControl
import PersistenceCore
import TrustCenter
#if canImport(Darwin)
import Darwin
import Darwin
#endif
// Blueprint: | `FileSystemActions.swift` | `FileSystemActions`; `SwiftNativeSecurityCenter.fencedAttachment`; `FileReadSourceMaterial` |
// File access follows allowed roots and the sensitive-path fence; verified descriptors keep reads and mutations bound to the checked paths.
package enum FileSystemActions {
    /// Connector reads retain their repository base and final-entry semantics.
    static func resolvePath(_ raw: String, repoRoot: URL?, workspaceRoot: URL? = nil, followFinalLink: Bool = true) -> URL {
        return NativeAgentWorkspaceRoot.canonicalFileURL(
            NativeAgentWorkspaceRoot.fileCandidate(raw, relativeTo: repoRoot ?? URL(fileURLWithPath: "."), workspaceRoot: workspaceRoot),
            followFinalLink: followFinalLink)
    }
    /// Full access removes the root sandbox at this layer; the sensitive-store fence still applies.
    static func allowedRoots(_ ctx: ConnectorActionContext, write: Bool = false) -> [URL] {
        let mode = (ctx.fileAccess["mode"]?.stringValue ?? "").lowercased()
        let sandbox = (ctx.fileAccess["sandbox"]?.stringValue ?? "").lowercased()
        if mode == "full" || sandbox == "danger-full-access" {
            return []
        }
        var roots: [URL] = []
        func add(_ raw: URL) {
            guard !raw.path.isEmpty else { return }
            let u = raw.standardizedFileURL.resolvingSymlinksInPath()
            if !roots.contains(u) { roots.append(u) }
        }
        if let root = ctx.repoRoot { add(root) }
        if case .array(let arr)? = ctx.fileAccess["writableRoots"] {
            for v in arr { if case .string(let s) = v, !s.isEmpty { add(URL(fileURLWithPath: s)) } }
        }
        if case .array(let arr)? = ctx.fileAccess["addDirs"] {
            for v in arr { if case .string(let s) = v, !s.isEmpty { add(URL(fileURLWithPath: s)) } }
        }
        for r in ctx.extraAllowedRoots { add(r) }
        // Ordinary callers get skills; a part adds only its declared data reach.
        if let dr = ctx.dataRoot {
            add(dr.appendingPathComponent("skills"))
            if let appDataWrite = ctx.appDataWrite, !write || appDataWrite { add(dr) }
        }
        return roots
    }
    static func isWithinRoots(_ path: URL, _ roots: [URL]) -> Bool {
        let target = NativeAgentWorkspaceRoot.canonicalFileURL(path).path
        return roots.contains {
            NativeAgentWorkspaceRoot.relativePath(target, under: NativeAgentWorkspaceRoot.canonicalFileURL($0).path) != nil
        }
    }
    /// Sensitive subtrees stay fenced under explicit and default data roots.
    static func isSensitiveDataPath(_ path: URL, _ ctx: ConnectorActionContext) -> Bool {
        let dataRoot = (ctx.dataRoot ?? PersistenceCore.defaultDataRoot()).standardizedFileURL.resolvingSymlinksInPath()
        let resolved = path.standardizedFileURL.resolvingSymlinksInPath()
        // Fold both sides, including paths that do not exist yet.
        let drPath = dataRoot.path.lowercased()
        let pPath = resolved.path.lowercased()
        guard var relStr = NativeAgentWorkspaceRoot.relativePath(pPath, under: drPath) else { return false }
        // Backup payloads copy the data root, so they inherit its sensitive-store fence.
        if let payload = relStr.range(of: "^backups/[^/]+/data/", options: .regularExpression) { relStr.removeSubrange(payload) }
        if ctx.appDataWrite != nil,
           connectorPartPrivateDataSubpaths.contains(where: { NativeAgentWorkspaceRoot.relativePath(relStr, under: $0) != nil }) { return true }
        if connectorSensitiveDataSubpaths.contains(where: { NativeAgentWorkspaceRoot.relativePath(relStr, under: $0) != nil }) { return true }
        // Stored MCP launch commands may contain credentials.
        if relStr == "mcp/servers.json" { return true }
        let parts = relStr.split(separator: "/").map(String.init)
        // Fence credentials by their writer-owned location; ordinary config elsewhere remains readable.
        if parts.count >= 2, parts[0] == "connectors",
           ["auth.json", "credential.json", "credentials.json"].contains(parts[parts.count - 1]) {
            return true
        }
        if parts.count == 2, parts[0] == "jev", parts[1] == "credential.json" { return true }
        if parts.count >= 2 {
            if parts[0] == "agents", ["peers.json", "peer-claims"].contains(parts[1]) { return true }
            if parts[0] == "workflows", parts[1] == "approvals" { return true }
            if parts[0] == "tools", parts[1].hasPrefix(".manifest_signing_key") { return true }
            if parts[0] == "catalog", parts[1].hasPrefix(".pack_signing_key") { return true }
            if parts[0] == "memory", parts[1] == "vault" { return true }
        }
        if parts.count >= 2 && parts[0] == "nextgen" && parts[1] == "remote" { return true }
        // Root-level .bin files hold pairing secrets.
        if parts.count == 1 && resolved.pathExtension.lowercased() == "bin" { return true }
        return false
    }
    static func sensitiveReadRefusal(_ resolved: URL) -> String {
        "Path '\(resolved.path)' is under a sensitive data sub-tree (OAuth tokens, "
            + "pairing secrets, provider credentials, trust policy). "
            + "Use the app's own actions such as app agent.introspect or memory.recall instead."
    }
    static func truncate(_ text: String, maxChars: Int = connectorResultMaxChars) -> String {
        if text.count <= maxChars { return text }
        let remaining = text.count - maxChars
        let head = String(text.prefix(maxChars))
        return head + "\n...(truncated, \(remaining) more bytes)"
    }
    static func shouldUseCompactReadDefault(path: URL, actualBytes: Int) -> Bool {
        guard actualBytes > connectorResultMaxChars else { return false }
        guard path.pathExtension.lowercased() == "md" else { return false }
        return path.deletingPathExtension().lastPathComponent.lowercased().contains("handoff")
    }
    /// Only absent or empty values use the default; malformed values remain bad_input.
    static func safeInt(_ value: JSONValue?, default def: Int) -> Int? {
        switch value ?? .null {
        case .null: return def
        case .int(let i): return Int(i)
        // Preserve numeric truncation toward zero but refuse unrepresentable values before they can trap.
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
        case .string(let s):
            if s.isEmpty { return def }
            if let i = Int(s) { return i }
            return nil
        default: return nil
        }
    }
    static func errResult(_ message: String, code: String? = nil, folder: String? = nil, path: URL? = nil, pathKind: String? = nil) -> JSONValue {
        var obj: [String: JSONValue] = ["ok": .bool(false), "error": .string(message)]
        if let code { obj["error_code"] = .string(code) }
        if let folder { obj["folder"] = .string(folder) }
        if let path {
            obj["path"] = .string(path.path)
            let kind = code == "file_not_found" ? "missing" : pathKind
            if let kind { obj["path_kind"] = .string(kind) }
            if kind == "missing" {
                obj.merge(VerifiedPath.missingReadEvidence(path)) { _, value in value }
            }
        }
        return .object(obj)
    }
}
func isNull(_ v: JSONValue) -> Bool { if case .null = v { return true }; return false }
func jsonToStr(_ v: JSONValue) throws -> String {
    switch v {
    case .string(let s): return s
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .null: return "None"
    default: return try v.serialize(pretty: false)
    }
}
func jsonRepr(_ v: JSONValue?) -> String {
    guard let v else { return "None" }
    switch v {
    case .null: return "None"
    case .string(let s): return "'\(s)'"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    default:
        do { return try v.serialize(pretty: false) }
        catch { return "[JSON serialization unavailable: \(error.localizedDescription)]" }
    }
}
func rootsRepr(_ roots: [URL]) -> String {
    "[" + roots.map { "'\($0.path)'" }.joined(separator: ", ") + "]"
}
