import Foundation
import PersistenceCore

extension SwiftNativeTrustCenter {
    /// Resolve the autonomy level for a tool under a unified policy bundle:
    /// `autonomyOverrides` plus `autonomyDefault`.
    ///
    /// Resolution order:
    ///   1. exact tool-name match in overrides (must be a valid level).
    ///   2. fnmatch glob matches, sorted by specificity
    ///      (fewer wildcards beat more, then longer pattern beats shorter,
    ///      then alphabetical).
    ///   3. explicit "default" key in overrides.
    ///   4. bundle's `autonomyDefault`.
    public nonisolated func autonomyForTool(
        _ toolName: String,
        policy: [String: JSONValue]
    ) -> String {
        let tool = toolName.trimmingCharacters(in: .whitespaces)
        let fallback: String = {
            if case .string(let s)? = policy["autonomyDefault"] { return s }
            // A1.4 (prerelease-upgrade-campaign): fail CLOSED. A policy bundle
            // with no `autonomyDefault` used to resolve every unlisted tool to
            // "auto" — a missing/rewritten/partial policy file silently bought
            // unattended tool fire. "send_approval" is the safe literal: the
            // tool still runs, but only behind an approval card.
            return "send_approval"
        }()
        if tool.isEmpty { return fallback }
        var overrides: [String: JSONValue] = [:]
        if case .object(let ov)? = policy["autonomyOverrides"] { overrides = ov }

        func isValid(_ jv: JSONValue?) -> Bool {
            if case .string(let s)? = jv {
                return Self.unifiedPolicyAutonomyLevels.contains(s)
            }
            return false
        }
        func asString(_ jv: JSONValue?) -> String {
            if case .string(let s)? = jv { return s }
            return ""
        }

        // 1. exact match.
        if let v = overrides[tool], isValid(v) {
            return asString(v)
        }

        // 2. glob matches with specificity ranking.
        var globs: [(pattern: String, level: String)] = []
        for (pat, level) in overrides {
            if pat == "default" || pat == tool { continue }
            if !isValid(level) { continue }
            if Self.fnmatch(name: tool, pattern: pat) {
                globs.append((pat, asString(level)))
            }
        }
        if !globs.isEmpty {
            globs.sort { a, b in
                let aw = Self.wildcardCount(a.pattern)
                let bw = Self.wildcardCount(b.pattern)
                if aw != bw { return aw < bw }
                if a.pattern.count != b.pattern.count {
                    return a.pattern.count > b.pattern.count
                }
                return a.pattern < b.pattern
            }
            return globs[0].level
        }

        // 3. explicit default key.
        if let v = overrides["default"], isValid(v) {
            return asString(v)
        }

        // 4. preset autonomyDefault.
        return fallback
    }

    /// 2026-07-21 audit: does an explicit (exact or glob) "blocked" entry
    /// name this tool in the USER's policy file? A deliberate user-set
    /// "blocked" ("never fire") is the ONE override that outranks the yolo /
    /// full-Mac broad posture — a yolo window flattening "never fire" is the
    /// actual hole. confirm/send_approval entries remain flattened by yolo
    /// (pinned: COMPOSED_*_yoloInstall_dispatchesNoApproval). Consult the RAW
    /// user file via userConfiguredAutonomyOverrides() — merged code defaults
    /// would masquerade as explicit entries.
    public nonisolated static func hasExplicitBlockOverride(
        _ toolName: String,
        overrides: [String: JSONValue]
    ) -> Bool {
        let tool = toolName.trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty else { return false }
        func isBlocked(_ jv: JSONValue?) -> Bool {
            if case .string(let s)? = jv { return s == "blocked" }
            return false
        }
        if isBlocked(overrides[tool]) { return true }
        for (pat, level) in overrides where pat != "default" && pat != tool {
            if isBlocked(level), Self.fnmatch(name: tool, pattern: pat) { return true }
        }
        return false
    }

    private nonisolated static func wildcardCount(_ pat: String) -> Int {
        var n = 0
        for c in pat where c == "*" || c == "?" || c == "[" { n += 1 }
        return n
    }

    /// Case-sensitive glob matching for autonomy overrides. Supports `*`, `?`, and `[seq]` / `[!seq]` character classes,
    /// anchored full-string matches.
    nonisolated static func fnmatch(name: String, pattern: String) -> Bool {
        let regex = translateFnmatch(pattern)
        // Use \A/\z anchors and DOTALL so `*` and `?` match newlines consistently.
        guard let re = try? NSRegularExpression(
            pattern: "\\A" + regex + "\\z",
            options: [.dotMatchesLineSeparators]
        ) else {
            return false
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return re.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Converts an autonomy glob to a regex, including `[seq]`, `[!seq]`, and literal `]` handling.
    nonisolated static func translateFnmatch(_ pat: String) -> String {
        var i = pat.startIndex
        var out = ""
        while i < pat.endIndex {
            let c = pat[i]
            i = pat.index(after: i)
            switch c {
            case "*":
                out += ".*"
            case "?":
                out += "."
            case "[":
                // Find the matching ']'. If there is no closing bracket, treat
                // '[' as literal.
                var j = i
                if j < pat.endIndex, pat[j] == "!" {
                    j = pat.index(after: j)
                }
                if j < pat.endIndex, pat[j] == "]" {
                    j = pat.index(after: j)
                }
                while j < pat.endIndex, pat[j] != "]" {
                    j = pat.index(after: j)
                }
                if j >= pat.endIndex {
                    out += NSRegularExpression.escapedPattern(for: "[")
                } else {
                    var stuff = String(pat[i..<j])
                    i = pat.index(after: j)
                    // Escape backslashes inside character classes.
                    stuff = stuff.replacingOccurrences(of: "\\", with: "\\\\")
                    if stuff.first == "!" {
                        stuff = "^" + stuff.dropFirst()
                    } else if stuff.first == "^" {
                        stuff = "\\" + stuff
                    }
                    out += "[" + stuff + "]"
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return out
    }

    /// Format a Date with the shared TrustCenter timestamp helper.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        SwiftNativeManifestSigner.isoTimestamp(date)
    }
}
