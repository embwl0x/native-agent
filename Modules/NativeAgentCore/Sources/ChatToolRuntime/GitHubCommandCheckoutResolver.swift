import Foundation
import Dispatcher

// Trusted repository-checkout resolution for explicit codex_message repository
// selection. The GitHub watcher never invokes this resolver.
//
// The trust anchor is the remote, not the name. A caller names an owner/name
// GitHub repository -- never a filesystem path -- and this resolver only
// accepts a local directory whose own `git remote -v` actually points at that
// repository. A directory that merely has a matching folder name resolves to
// nil, so a model cannot steer execution at an arbitrary root by choosing a
// suggestive repository string.

enum GitHubCommandCheckoutResolver {
    static func resolve(
        repository: String,
        headSHA: String?,
        dataRoot: URL,
        searchRoots: [URL]? = nil
    ) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }) else { return nil }
        let repoName = parts[1]
        let roots = searchRoots ?? defaultSearchRoots(dataRoot: dataRoot)
        let candidates = checkoutCandidates(repoName: repoName, roots: roots)
        return candidates.compactMap { candidate -> (URL, Int)? in
            guard remoteOutput(candidate).split(separator: "\n").contains(where: {
                remoteRepository(String($0)) == repository.lowercased()
            }) else { return nil }
            var score = 0
            let name = candidate.lastPathComponent.lowercased()
            if name == repoName.lowercased() { score += 20 }
            if name.contains("contrib") { score += 10 }
            if let headSHA, git(["rev-parse", "HEAD"], at: candidate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(headSHA) == .orderedSame {
                score += 100
            }
            return (candidate, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.path < rhs.0.path
        }
        .first?.0
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

    private static func checkoutCandidates(repoName: String, roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        for root in unique(roots) {
            candidates.append(root)
            candidates.append(root.appendingPathComponent(repoName, isDirectory: true))
            candidates.append(root.appendingPathComponent("\(repoName)-contrib", isDirectory: true))
            if let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) {
                candidates.append(contentsOf: children.filter {
                    $0.lastPathComponent.localizedCaseInsensitiveContains(repoName)
                })
            }
        }
        return unique(candidates).filter { candidate in
            (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fileManager.fileExists(
                    atPath: candidate.appendingPathComponent(".git").path
                )
        }
    }

    private static func remoteOutput(_ directory: URL) -> String {
        git(["remote", "-v"], at: directory)
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

    private static func git(_ arguments: [String], at directory: URL) -> String {
        let result = runProcess(
            "/usr/bin/git", ["-C", directory.path] + arguments, timeout: 5
        )
        guard result.launched, !result.timedOut, !result.captureReadFailed,
              result.status == 0 else { return "" }
        return result.stdout
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
}
