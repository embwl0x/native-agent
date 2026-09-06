import Foundation
import PersistenceCore

// MARK: - Raw spelling of a canonicalized tool name

/// 2026-09-06: the outermost dispatch wrapper rewrites a dotted alias
/// (`save.skill` → `save_skill`) BEFORE any gate runs, so every gate now judges
/// the name that will actually execute. The cost is that a user's policy entry
/// keyed on the spelling they typed — `"save.skill": "blocked"` — no longer
/// matches anything, because the gates literally/glob-match the name they are
/// handed. The canonicalizer therefore carries the raw spelling alongside the
/// canonical one in this per-dispatch context, and the policy gates evaluate
/// BOTH names and keep the stricter answer.
public struct GatedToolNameAlias: Sendable, Equatable {
    public let raw: String
    public let canonical: String

    public init(raw: String, canonical: String) {
        self.raw = raw
        self.canonical = canonical
    }
}

public enum GatedToolNameContext {
    /// Bound by the canonicalizing dispatcher for the whole downstream chain.
    /// It binds `nil` when it rewrote nothing, so a nested dispatch can never
    /// inherit a stale alias from the call that contains it — the one
    /// exception (2026-09-06) being a second canonicalizer in the same chain,
    /// which re-binds the inherited alias when that alias canonicalizes to
    /// exactly the name it was handed.
    @TaskLocal public static var alias: GatedToolNameAlias?

    /// The spelling the caller supplied for `toolName`, when it differs. Nil
    /// unless the bound alias canonicalizes to exactly this tool — an alias for
    /// some other tool carries no policy authority here.
    public static func rawSpelling(of toolName: String) -> String? {
        let tool = toolName.trimmingCharacters(in: .whitespaces)
        guard let alias else { return nil }
        let canonical = alias.canonical.trimmingCharacters(in: .whitespaces)
        let raw = alias.raw.trimmingCharacters(in: .whitespaces)
        guard canonical == tool, raw != tool, !raw.isEmpty else { return nil }
        return raw
    }
}

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
        let resolved = Self.autonomyForExactToolName(toolName, policy: policy)
        // 2026-09-06: the name reaching this gate may have been canonicalized
        // outside it, which would silently discard a user override keyed on the
        // spelling they actually wrote (`"save.skill": "blocked"`). Evaluate the
        // raw spelling too — but only its EXPLICIT (exact/glob) entry, never the
        // bundle default, or an unlisted alias would drag a canonical "auto"
        // override down to the default level. The stricter answer wins.
        guard let raw = GatedToolNameContext.rawSpelling(of: toolName) else { return resolved }
        var overrides: [String: JSONValue] = [:]
        if case .object(let ov)? = policy["autonomyOverrides"] { overrides = ov }
        guard let rawLevel = Self.explicitAutonomyOverride(raw, overrides: overrides) else {
            return resolved
        }
        return Self.moreRestrictiveAutonomy(resolved, rawLevel)
    }

    /// The literal resolution, for exactly the name it is given.
    nonisolated static func autonomyForExactToolName(
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

        // 1. exact match. 2. glob matches with specificity ranking.
        if let explicit = explicitAutonomyOverride(tool, overrides: overrides) {
            return explicit
        }

        // 3. explicit default key.
        if case .string(let v)? = overrides["default"],
           unifiedPolicyAutonomyLevels.contains(v) {
            return v
        }

        // 4. preset autonomyDefault.
        return fallback
    }

    /// An override entry that NAMES this tool: the exact key, else the most
    /// specific matching glob. Never the `default` key and never the bundle
    /// fallback — those are not statements about this tool.
    nonisolated static func explicitAutonomyOverride(
        _ toolName: String,
        overrides: [String: JSONValue]
    ) -> String? {
        let tool = toolName.trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty else { return nil }
        func level(_ jv: JSONValue?) -> String? {
            guard case .string(let s)? = jv,
                  unifiedPolicyAutonomyLevels.contains(s) else { return nil }
            return s
        }
        if let exact = level(overrides[tool]) { return exact }

        var globs: [(pattern: String, level: String)] = []
        for (pat, value) in overrides {
            if pat == "default" || pat == tool { continue }
            guard let lvl = level(value) else { continue }
            if fnmatch(name: tool, pattern: pat) {
                globs.append((pat, lvl))
            }
        }
        guard !globs.isEmpty else { return nil }
        globs.sort { a, b in
            let aw = wildcardCount(a.pattern)
            let bw = wildcardCount(b.pattern)
            if aw != bw { return aw < bw }
            if a.pattern.count != b.pattern.count {
                return a.pattern.count > b.pattern.count
            }
            return a.pattern < b.pattern
        }
        return globs[0].level
    }

    /// Restrictiveness ranking over `unifiedPolicyAutonomyLevels`. An
    /// unrecognized level ranks as approval-tier, matching `AutonomyGate.map`'s
    /// safe default for one.
    nonisolated static func moreRestrictiveAutonomy(_ a: String, _ b: String) -> String {
        func rank(_ level: String) -> Int {
            switch level {
            case "auto": return 0
            case "draft_auto": return 1
            case "send_approval": return 2
            case "confirm": return 3
            case "destructive_strong": return 4
            case "blocked": return 5
            default: return 3
            }
        }
        return rank(a) >= rank(b) ? a : b
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
        if blockedByName(tool, overrides: overrides) { return true }
        // 2026-09-06: a block the user keyed on the dotted spelling still binds
        // after the outer canonicalizer rewrote the name — see
        // GatedToolNameContext.
        if let raw = GatedToolNameContext.rawSpelling(of: tool),
           blockedByName(raw, overrides: overrides) {
            return true
        }
        return false
    }

    private nonisolated static func blockedByName(
        _ tool: String,
        overrides: [String: JSONValue]
    ) -> Bool {
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
