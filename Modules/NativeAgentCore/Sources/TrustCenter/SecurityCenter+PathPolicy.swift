import Foundation
import PersistenceCore

extension SwiftNativeSecurityCenter {
    static func capabilityWritesOutsideAppData(
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> Bool {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        for path in pathLikeStrings(in: .object(input)) {
            let expanded = expandTildePath(path.trimmingCharacters(in: .whitespacesAndNewlines))
            guard expanded.hasPrefix("/") else { continue }
            let normalized = URL(fileURLWithPath: expanded)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if isSelfOrAncestor(root: root, of: normalized) { continue }
            if trustedWorkspaceRoots.contains(where: { isSelfOrAncestor(root: $0, of: normalized) }) { continue }
            return true
        }
        return false
    }

    static func pathLikeStrings(in value: JSONValue) -> [String] {
        var out: [String] = []
        func walk(_ v: JSONValue, keyPath: String) {
            switch v {
            case .string(let s):
                let key = keyPath.lowercased()
                if key.contains("path") || key.contains("file") || key.contains("dir")
                    || s.hasPrefix("/") || s.hasPrefix("~/") {
                    out.append(s)
                }
            case .array(let arr):
                for (idx, item) in arr.enumerated() { walk(item, keyPath: "\(keyPath)[\(idx)]") }
            case .object(let obj):
                for (k, item) in obj { walk(item, keyPath: keyPath.isEmpty ? k : "\(keyPath).\(k)") }
            default:
                break
            }
        }
        walk(value, keyPath: "")
        return out
    }
}
