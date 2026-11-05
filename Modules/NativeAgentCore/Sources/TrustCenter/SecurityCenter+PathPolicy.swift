import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
// Blueprint: | `SecurityCenter+PathPolicy.swift` | `capabilityWritesOutsideAppData`, `pathIsInsideRoots`, `pathLikeStrings`; Byte-exact path reach. |

extension SwiftNativeSecurityCenter {
    /// File mutations share execution's resolver; unknown relative bases conservatively count outside app data and workspace roots.
    static func capabilityWritesOutsideAppData(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        turn: Turn?,
        trustedWorkspaceRoots: [URL] = []
    ) throws -> Bool {
        let binding = tool == "app" ? try AppActionBinding.action(input: input, turn: turn) : nil
        let operation = ToolNameAliases.canonical(binding?.tool ?? tool)
        let pathInput = input
        if ["write_file", "copy_file", "move_file", "trash_file"].contains(operation) {
            let arguments = binding?.arguments(object(input["args"])) ?? input
            let keys = ["copy_file", "move_file"].contains(operation) ? ["path", "destination"] : ["path"]
            for key in keys {
                guard case .string(let raw)? = arguments[key], !raw.isEmpty else {
                    throw ToolFailureError("\(operation) requires its declared I/O argument \(key).", argumentPath: key, effects: .none)
                }
                let resolved = NativeAgentWorkspaceRoot.resolveFileMutationPath(raw, dataRoot: dataRoot).path
                if !pathIsInsideRoots(resolved, roots: [dataRoot] + trustedWorkspaceRoots) { return true }
            }
            return false
        }
        return pathLikeStrings(in: .object(pathInput)).contains { raw in
            let expanded = NativeAgentWorkspaceRoot.fileSpelling(raw)
            guard expanded.hasPrefix("/") else { return true }
            let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            return !pathIsInsideRoots(resolved, roots: [dataRoot] + trustedWorkspaceRoots)
        }
    }

    /// Compare the resolved, standardized absolute path the caller will open. Preserve its bytes: whitespace and Unicode spelling are part of a name.
    static func pathIsInsideRoots(_ resolvedPath: String, roots: [URL]) -> Bool {
        guard resolvedPath.hasPrefix("/") else { return false }
        return roots.contains {
            NativeAgentWorkspaceRoot.relativePath(resolvedPath, under: NativeAgentWorkspaceRoot.canonicalFileURL($0).path) != nil
        }
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
