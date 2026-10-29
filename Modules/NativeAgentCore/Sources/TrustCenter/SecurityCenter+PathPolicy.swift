import Foundation
import PersistenceCore
import ToolRegistry
// Blueprint: | `SecurityCenter+PathPolicy.swift` | Capability effects and Mac Control file admission use NativeAgentWorkspaceRoot's byte-exact path law; supported file mutations share execution's resolver and relative base; unknown relative capability paths count as outside; `capabilityWritesOutsideAppData`, `pathIsInsideRoots`, `pathLikeStrings` |

extension SwiftNativeSecurityCenter {
    /// Her line for the paths a call names: true when one lands beyond her
    /// data root and Trust's workspace roots. File mutations share execution's
    /// resolver; relative paths with no known I/O base still count as beyond.
    static func capabilityWritesOutsideAppData(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> Bool {
        let binding = tool == "app" ? AppActionBinding.action(input: input) : nil
        let operation = ToolNameAliases.canonical(binding?.tool ?? tool)
        var pathInput = input
        if ["write_file", "copy_file", "move_file", "trash_file"].contains(operation) {
            var arguments = binding?.arguments(object(input["args"])) ?? input
            let keys = ["copy_file", "move_file"].contains(operation) ? ["path", "destination"] : ["path"]
            for key in keys {
                if case .string(let raw)? = arguments[key] {
                    arguments[key] = .string(NativeAgentWorkspaceRoot.resolveFileMutationPath(raw, dataRoot: dataRoot).path)
                }
            }
            if binding != nil { pathInput["args"] = .object(arguments) }
            else { pathInput = arguments }
        }
        return pathLikeStrings(in: .object(pathInput)).contains { raw in
            let expanded = NativeAgentWorkspaceRoot.fileSpelling(raw)
            guard expanded.hasPrefix("/") else { return true }
            let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            return !pathIsInsideRoots(resolved, roots: [dataRoot] + trustedWorkspaceRoots)
        }
    }

    /// Compare the resolved, standardized absolute path the caller will open.
    /// Preserve its bytes: whitespace and Unicode spelling are part of a name.
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
