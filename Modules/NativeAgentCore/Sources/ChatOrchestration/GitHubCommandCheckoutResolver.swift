import Foundation

// Trusted repository-checkout resolution for explicit codex_message repository
// selection. The GitHub watcher never invokes this resolver.
//
// The trust anchor is the remote, not the name. A caller names an owner/name
// GitHub repository -- never a filesystem path -- and this resolver only
// accepts a local directory whose own `git remote -v` actually points at that
// repository. A directory that merely has a matching folder name resolves to
// nil, so a model cannot steer execution at an arbitrary root by choosing a
// suggestive repository string.

public enum GitHubCommandCheckoutResolver {
    public static func resolve(
        repository: String,
        headSHA: String?,
        dataRoot: URL,
        searchRoots: [URL]? = nil
    ) -> URL? {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let repoName = parts[1]
        let roots = searchRoots ?? defaultSearchRoots(dataRoot: dataRoot)
        let candidates = checkoutCandidates(repoName: repoName, roots: roots)
        return candidates.compactMap { candidate -> (URL, Int)? in
            guard remoteOutput(candidate).split(separator: "\n").contains(where: {
                normalizedRemote(String($0)).hasSuffix("github.com/\(repository.lowercased())")
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

    private static func normalizedRemote(_ line: String) -> String {
        let field = line.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first { $0.localizedCaseInsensitiveContains("github.com") } ?? ""
        return field.lowercased()
            .replacingOccurrences(of: "git@github.com:", with: "github.com/")
            .replacingOccurrences(of: "ssh://git@github.com/", with: "github.com/")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
    }

    private static func git(_ arguments: [String], at directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        guard process.terminationStatus == 0 else { return "" }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
}
