import Foundation
import PersistenceCore
// Blueprint: | `SecurityCenter+JSONUtilities.swift` | Trust JSON primitives and workspace roots; resolved containment uses NativeAgentWorkspaceRoot's byte-exact component law; transport policy decoding belongs to TransportAllowlist in PersistenceCore |

extension SwiftNativeSecurityCenter {
    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let obj)? = value { return obj }
        return [:]
    }

    static func bool(_ value: JSONValue?, default fallback: Bool) -> Bool {
        if case .double = value { return fallback }
        return ConnectorInputValue.bool(value, default: fallback)
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let array)? = value else { return [] }
        return array.compactMap { $0.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    package static func trustedWorkspaceRoots(
        policy: [String: JSONValue],
        filePolicy: [String: JSONValue],
        dataRoot: URL = defaultDataRoot()
    ) -> [URL] {
        var roots = TrustCenterDefaultWorkspaceRoots.defaultRoots(dataRoot: dataRoot)

        func appendRoots(from obj: [String: JSONValue]) {
            for key in ["workspaceRoots", "workspace_roots", "trustedWorkspaceRoots", "trustedRoots"] {
                guard case .array(let values)? = obj[key] else { continue }
                for value in values {
                    guard case .string(let raw) = value else { continue }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    // Only current-user shorthand expands; relative roots retain URL's process-directory interpretation.
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    var expanded = trimmed
                    if trimmed == "~" { expanded = home.path }
                    else if trimmed.hasPrefix("~/") { expanded = home.appendingPathComponent(String(trimmed.dropFirst(2))).path }
                    roots.append(URL(fileURLWithPath: expanded))
                }
            }
        }

        appendRoots(from: policy)
        appendRoots(from: filePolicy)
        return normalizedUniqueRoots(roots)
    }

    static func normalizedUniqueRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<Data> = []
        var out: [URL] = []
        for root in roots {
            let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(Data(normalized.path.utf8)).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    /// `read_file`'s fence, for a file that reaches the model another way (a
    /// chat attachment the agent names): it must sit in a Trust workspace root.
    public static func isInsideTrustedWorkspace(
        _ file: URL, policy: [String: JSONValue], dataRoot: URL
    ) -> Bool {
        trustedWorkspaceRoots(policy: policy, filePolicy: object(policy["filePolicy"]), dataRoot: dataRoot)
            .contains { isSelfOrAncestor(root: $0, of: file) }
    }

    package static func isSelfOrAncestor(root: URL, of candidate: URL) -> Bool {
        let rootPath = NativeAgentWorkspaceRoot.canonicalFileURL(root).path
        let candidatePath = NativeAgentWorkspaceRoot.canonicalFileURL(candidate).path
        return NativeAgentWorkspaceRoot.relativePath(candidatePath, under: rootPath) != nil
    }

}
