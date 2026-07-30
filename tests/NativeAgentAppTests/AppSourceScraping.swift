import Foundation

/// Shared source-scraping helpers for the app-wiring guard tests. Several tests
/// assert structural wiring by reading `NativeAgentApp` source directly; the
/// repo-root walk, file readers, and balanced-brace slicers were copy-pasted
/// across four files (FluidContextSurfaceWiring / NoAutomaticChatGreeting /
/// ConnectorWizardRouting / OperationalSettingsPresentation) before this.
enum AppSourceScraping {

    struct ScrapeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Walk up from `filePath` (default: the CALLER's source file) to the repo
    /// root — the directory holding `Package.swift` and `Sources/NativeAgentApp`.
    static func repositoryRoot(startingFrom filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let package = directory.appendingPathComponent("Package.swift")
            let sources = directory.appendingPathComponent("Sources/NativeAgentApp", isDirectory: true)
            if FileManager.default.fileExists(atPath: package.path),
               FileManager.default.fileExists(atPath: sources.path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw ScrapeError("Could not locate the NativeAgent repository from \(filePath)")
    }

    /// The `Sources/NativeAgentApp` directory.
    static func appSourcesRoot(startingFrom filePath: String = #filePath) throws -> URL {
        try repositoryRoot(startingFrom: filePath)
            .appendingPathComponent("Sources/NativeAgentApp", isDirectory: true)
    }

    /// Read a single app source file by (relative) name.
    static func appSource(_ name: String, startingFrom filePath: String = #filePath) throws -> String {
        let url = try appSourcesRoot(startingFrom: filePath).appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.swift` file URL under `root`.
    static func swiftSourceURLs(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ScrapeError("Could not enumerate app sources at \(root.path)")
        }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    /// Every `.swift` file under `root` as `(fileName, contents)` pairs.
    static func swiftSourceContents(under root: URL) throws -> [(file: String, source: String)] {
        var results: [(file: String, source: String)] = []
        for url in try swiftSourceURLs(under: root) {
            results.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return results
    }

    /// Balanced `{...}` body of `func <name>` (braces included). Throws if the
    /// function or a balanced body isn't found.
    static func functionBody(named name: String, in source: String) throws -> String {
        guard let nameRange = source.range(of: "func \(name)") else {
            throw ScrapeError("Could not find function \(name)")
        }
        guard let openBrace = source[nameRange.upperBound...].firstIndex(of: "{") else {
            throw ScrapeError("Could not find body for function \(name)")
        }
        guard let closeBrace = balancedEnd(
            in: source, startingAt: openBrace, opening: "{", closing: "}"
        ) else {
            throw ScrapeError("Unbalanced body for function \(name)")
        }
        return String(source[openBrace...closeBrace])
    }

    /// Best-effort body slice from `func <name>(` to the next member decl (or
    /// EOF). Non-throwing; returns nil if not found. Coarser than
    /// `functionBody`, but enough to scope a gate assertion.
    static func looseFunctionBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let tail = source[start.upperBound...]
        let terminators = ["\n    func ", "\n    private func ", "\n    var ", "\n    private var "]
        let end = terminators
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min() ?? tail.endIndex
        return String(tail[..<end])
    }

    /// Every `name(...)` call expression (balanced parens), skipping
    /// commented-out lines.
    static func executableCalls(named name: String, in source: String) -> [String] {
        let needle = "\(name)("
        var searchStart = source.startIndex
        var calls: [String] = []
        while searchStart < source.endIndex,
              let match = source.range(of: needle, range: searchStart..<source.endIndex) {
            defer { searchStart = match.upperBound }
            let lineStart = source[..<match.lowerBound].lastIndex(of: "\n")
                .map { source.index(after: $0) } ?? source.startIndex
            let prefix = source[lineStart..<match.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard !prefix.hasPrefix("//") else { continue }
            let openParen = source.index(before: match.upperBound)
            guard let closeParen = balancedEnd(
                in: source, startingAt: openParen, opening: "(", closing: ")"
            ) else { continue }
            calls.append(String(source[match.lowerBound...closeParen]))
        }
        return calls
    }

    /// Index of the balanced closing delimiter for the `opening` at `start`.
    static func balancedEnd(
        in source: String,
        startingAt start: String.Index,
        opening: Character,
        closing: Character
    ) -> String.Index? {
        var depth = 0
        var index = start
        while index < source.endIndex {
            switch source[index] {
            case opening:
                depth += 1
            case closing:
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Count of non-overlapping `needle` occurrences in `source`.
    static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
