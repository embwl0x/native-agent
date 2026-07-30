import Foundation
import PersistenceCore

extension SwiftNativeSecurityCenter {
    static func maxDecision(_ lhs: SecurityToolDecision, _ rhs: SecurityToolDecision) -> SecurityToolDecision {
        func rank(_ d: SecurityToolDecision) -> Int {
            switch d {
            case .allow: return 0
            case .ask: return 1
            case .block: return 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let obj)? = value { return obj }
        return [:]
    }

    static func object(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let obj) = value { return obj }
        return [:]
    }

    static func string(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func string(_ value: JSONValue) -> String? {
        string(Optional(value))
    }

    static func deduped(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }

    static func bool(_ value: JSONValue?, default fallback: Bool) -> Bool {
        switch value {
        case .bool(let b): return b
        case .string(let s):
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "on"].contains(v) { return true }
            if ["false", "0", "no", "off"].contains(v) { return false }
            return fallback
        case .int(let i): return i != 0
        default: return fallback
        }
    }

    static func stringSet(_ value: JSONValue?) -> Set<String> {
        guard case .array(let array)? = value else { return [] }
        return Set(array.compactMap { string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let array)? = value else { return [] }
        return array.compactMap { string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func telegramChatId(fromSessionId sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("telegram:") else { return nil }
        return String(trimmed.dropFirst("telegram:".count))
    }

    static func trustedWorkspaceRoots(
        policy: [String: JSONValue],
        filePolicy: [String: JSONValue],
        dataRoot: URL = defaultDataRoot()
    ) -> [URL] {
        var roots = TrustCenterDefaultWorkspaceRoots.defaultRoots(dataRoot: dataRoot)

        func appendRoots(from obj: [String: JSONValue]) {
            for key in ["workspaceRoots", "workspace_roots", "trustedWorkspaceRoots", "trustedRoots"] {
                for raw in stringArray(obj[key]) {
                    let expanded = expandTildePath(raw)
                    guard expanded.hasPrefix("/") else { continue }
                    roots.append(URL(fileURLWithPath: expanded))
                }
            }
        }

        appendRoots(from: policy)
        appendRoots(from: filePolicy)
        return normalizedUniqueRoots(roots)
    }

    static func expandTildePath(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(suffix)
                .path
        }
        return path
    }

    static func normalizedUniqueRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for root in roots {
            let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(normalized.path).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    static func isSelfOrAncestor(root: URL, of candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

}
