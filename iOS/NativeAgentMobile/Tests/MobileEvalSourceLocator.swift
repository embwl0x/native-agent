import Foundation
import XCTest

/// Shared checkout locator for the `ios.screens` coverage evals.
///
/// The iOS unit-test bundle runs on the HOST filesystem, so the checkout that
/// produced the binary is readable from the test. `UIIntegrityContractTests`
/// already relies on this (2026-05); this type generalises the walk-up so the
/// hand-mirrored-constant contracts (iOS catalog vs Mac source of truth) can be
/// asserted against the real Mac sources instead of a second copy of the table
/// living in the test — which would only test the test.
enum MobileEvalSources {

    enum LocatorError: Error, CustomStringConvertible {
        case checkoutNotFound(from: String)
        case missing(String)

        var description: String {
            switch self {
            case .checkoutNotFound(let from):
                return "Could not locate the NativeAgent checkout walking up from \(from)"
            case .missing(let path):
                return "Expected repo file is missing: \(path)"
            }
        }
    }

    /// Repo root: the first ancestor that carries BOTH the iOS project spec and
    /// the Core module tree. Requiring both means a stray `Modules/` directory
    /// somewhere above the worktree cannot be mistaken for the checkout.
    static func repoRoot(from file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<10 {
            let iosSpec = directory.appendingPathComponent("iOS/NativeAgentMobile/project.yml")
            let coreSources = directory.appendingPathComponent("Modules/NativeAgentCore/Sources")
            if fm.fileExists(atPath: iosSpec.path), fm.fileExists(atPath: coreSources.path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw LocatorError.checkoutNotFound(from: "\(file)")
    }

    /// Text of a repo-relative file. Throws (never returns "") so a moved or
    /// renamed file fails the eval LOUDLY instead of turning every
    /// `XCTAssertFalse(text.contains(...))` in the caller into a vacuous pass.
    static func repoFile(_ relativePath: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocatorError.missing(relativePath)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.isEmpty else { throw LocatorError.missing("\(relativePath) (empty)") }
        return text
    }

    /// Text of one `iOS/NativeAgentMobile/Sources/<name>`.
    static func mobileSource(_ name: String) throws -> String {
        try repoFile("iOS/NativeAgentMobile/Sources/\(name)")
    }

    // MARK: - Tiny scanning helpers (shared by the mirror evals)

    /// All capture-group-1 matches of `pattern` in `text`, in source order.
    static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// The body of the first `<keyword> <name> ... { ... }` block,
    /// brace-balanced. Used to scope a regex to one enum/struct instead of a
    /// whole file. Tolerates a conformance list between the name and the brace.
    static func blockBody(named name: String, keyword: String, in text: String) -> String? {
        guard let declRange = text.range(of: "\(keyword) \(name)") else { return nil }
        var depth = 0
        var started = false
        var body = ""
        for character in text[declRange.lowerBound...] {
            if character == "{" {
                depth += 1
                if !started { started = true; continue }
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            if started { body.append(character) }
        }
        return nil
    }
}
