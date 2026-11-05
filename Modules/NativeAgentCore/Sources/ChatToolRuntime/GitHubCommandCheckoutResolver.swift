import Foundation
import Dispatcher
import NativeAgentCore
// Blueprint: | `GitHubCommandCheckoutResolver.swift` | Match exact repository remotes; refuse ambiguity and read failures. |

// Match the repository remote, never its directory name: an owner/name selector must not steer execution to an arbitrary filesystem root.

enum GitHubCommandCheckoutResolver {
    static func resolve(
        repository: String,
        dataRoot: URL
    ) throws -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }) else { return nil }
        let repoName = parts[1]
        let roots = defaultSearchRoots(dataRoot: dataRoot)
        let candidates = try checkoutCandidates(repoName: repoName, roots: roots)
        let matches = try candidates.filter { candidate in
            try remoteOutput(candidate).split(separator: "\n").contains(where: {
                remoteRepository(String($0)) == repository.lowercased()
            })
        }
        guard matches.count <= 1 else {
            throw ToolFailureError("""
                More than one checkout matches \(repository). Select working_directory explicitly: \
                \(matches.map(\.path).sorted().joined(separator: ", ")). No checkout was selected and no work started.
                """,
                argumentPath: "$.repository", effects: .none, code: "repository_checkout_ambiguous",
                instruction: "Pass the exact intended checkout as working_directory.")
        }
        return matches.first
    }

    private static func defaultSearchRoots(dataRoot: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectParent = dataRoot.deletingLastPathComponent().deletingLastPathComponent()
        return unique([
            projectParent,
            home.appendingPathComponent("Projects", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true),
            home.appendingPathComponent(".hermes", isDirectory: true),
        ])
    }

    private static func checkoutCandidates(repoName: String, roots: [URL]) throws -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        for root in unique(roots) {
            candidates.append(root)
            candidates.append(root.appendingPathComponent(repoName, isDirectory: true))
            candidates.append(root.appendingPathComponent("\(repoName)-contrib", isDirectory: true))
            let children: [URL]
            do { children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) } catch CocoaError.fileReadNoSuchFile { continue }
            catch { throw unavailable(root, cause: error.localizedDescription) }
            candidates.append(contentsOf: children.filter {
                $0.lastPathComponent.localizedCaseInsensitiveContains(repoName)
            })
        }
        return try unique(candidates).filter { candidate in
            do {
                guard try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return false }
                _ = try candidate.appendingPathComponent(".git").resourceValues(forKeys: [.isDirectoryKey])
                return true
            } catch CocoaError.fileReadNoSuchFile { return false }
            catch { throw unavailable(candidate, cause: error.localizedDescription) }
        }
    }

    private static func remoteOutput(_ directory: URL) throws -> String {
        try git(["remote", "-v"], at: directory)
    }

    private static func remoteRepository(_ line: String) -> String? {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 3 else { return nil }
        let address = String(fields[1])
        let path: String
        if address.contains("://") {
            guard let remote = URLComponents(string: address),
                  ["https", "http", "ssh", "git"].contains(remote.scheme?.lowercased() ?? ""),
                  remote.host?.lowercased() == "github.com",
                  remote.query == nil, remote.fragment == nil,
                  remote.path.hasPrefix("/") else { return nil }
            path = String(remote.path.dropFirst())
        } else {
            let parts = address.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let authority = parts[0].split(separator: "@", omittingEmptySubsequences: false)
            guard authority.count <= 2, authority.last?.lowercased() == "github.com" else { return nil }
            path = String(parts[1])
        }
        // Only the suffix: "o/o.github.io.git" is o/o.github.io.
        let normalized = path.lowercased()
        return normalized.hasSuffix(".git") ? String(normalized.dropLast(4)) : normalized
    }

    private static func git(_ arguments: [String], at directory: URL) throws -> String {
        let result = runProcess(
            "/usr/bin/git", ["-C", directory.path] + arguments, timeout: 5
        )
        guard result.launched, !result.timedOut, !result.captureReadFailed,
              result.status == 0 else {
            throw unavailable(directory, cause: """
                git remote -v: launched=\(result.launched), timedOut=\(result.timedOut), captureReadFailed=\(result.captureReadFailed), \
                exit=\(result.status)
                """)
        }
        return result.stdout
    }

    private static func unavailable(_ path: URL, cause: String) -> ToolFailureError {
        ToolFailureError("Repository checkout discovery is unavailable at \(path.path): \(cause). No checkout was selected and no work started.",
            effects: .none, owner: path.path, code: "repository_discovery_unavailable",
            instruction: "Repair the reported directory or git remote read failure, then request the repository again.", recovery: .repair)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
    }
}
