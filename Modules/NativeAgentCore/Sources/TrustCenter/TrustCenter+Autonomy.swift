import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry

// MARK: - The permission law (User, 2026-10-17)

/// User's posture, as he set it in Trust.
public enum PermissionPosture: Sendable {
    /// Full Mac: she acts.
    case fullMac
    /// Work mode: she asks before a send or a change to User's world.
    case work
    /// Safe: nothing beyond her own domain changes.
    case readOnly
}

/// Every call is judged by four facts and nothing else: what it is (the class
/// its declaration gives it), User's posture, the integration switch it touches
/// (held before any card, and again at dispatch) and who steered the turn (an
/// untrusted peer meets the floor and the cards). Everything she is — chat,
/// bots, Workshop, swarm workers, every part she writes — gets the same answer:
/// a sub-agent is her hands, not a lesser user.
///
/// One line divides her world from User's. Hers: her data root and Trust's
/// workspace roots (her scratch, her worktrees, her abilities, bots, chats and
/// memory). His: a path beyond those roots, his accounts and integrations, his
/// Mac's apps, browser, settings and permissions, another app's settings, a
/// shared remote. Destructive is what cannot be undone on his side of it, and
/// always asks a person; Safe changes nothing on his side.
public enum PermissionLaw {
    public static func posture(_ policy: [String: JSONValue]) -> PermissionPosture {
        if SwiftNativeSecurityCenter.fullMacActive(policy: policy) { return .fullMac }
        if case .string(let level)? = policy["permissionLevel"], ["strict", "locked_down"].contains(level) { return .readOnly }
        return .work
    }

    /// The one effective answer for a call: the law, then User's saved entries.
    /// Below Full Mac the stricter stands (his entry for the tool, for a
    /// capability the call carries, or for the old tool an app action runs);
    /// under Full Mac only his explicit `blocked`. Both SecurityCenter (with the
    /// facts it already resolved) and Trust's by-name and Workshop answers use it.
    public static func answer(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                              saved: [String: JSONValue], dataRoot: URL) -> (toolClass: ToolClass, law: String, level: String) {
        let roots = SwiftNativeSecurityCenter.trustedWorkspaceRoots(
            policy: policy, filePolicy: SwiftNativeSecurityCenter.object(policy["filePolicy"]), dataRoot: dataRoot)
        let capabilities = input.map { SwiftNativeSecurityCenter.profile(tool: SwiftNativeSecurityCenter.policyToolName(tool),
                                                                         input: $0, dataRoot: dataRoot, trustedWorkspaceRoots: roots).capabilities }
        return answer(tool: tool, input: input, policy: policy, saved: saved, dataRoot: dataRoot, roots: roots, capabilities: capabilities)
    }

    static func answer(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue], saved: [String: JSONValue],
                       dataRoot: URL, roots: [URL], capabilities: Set<String>?) -> (toolClass: ToolClass, law: String, level: String) {
        // Steering caps the posture: a turn an untrusted peer steered is judged as Work at most.
        let posture = CapabilityLifecycle.writeRefusal != nil && posture(policy) == .fullMac ? .work : posture(policy)
        let (toolClass, law) = judge(tool: tool, input: input, posture: posture, dataRoot: dataRoot, roots: roots, capabilities: capabilities)
        let name = SwiftNativeSecurityCenter.policyToolName(tool)
        guard posture != .fullMac else {
            return (toolClass, law, SwiftNativeTrustCenter.hasExplicitBlockOverride(name, overrides: saved) ? "blocked" : law)
        }
        let bundle: [String: JSONValue] = ["autonomyOverrides": .object(saved), "autonomyDefault": .string(law)]
        let level = SwiftNativeTrustCenter.moreRestrictiveAutonomy(
            law, SwiftNativeTrustCenter.autonomyForTool(name, policy: bundle, capabilities: capabilities ?? []))
        // An app door action that runs its old tool's code in process keeps
        // the level saved on that tool: the stricter of the two stands.
        guard name == "app", let input, let action = AppActionBinding.action(input: input) else { return (toolClass, law, level) }
        return (toolClass, law, action.savedTrustKeys.reduce(level) {
            SwiftNativeTrustCenter.moreRestrictiveAutonomy($0, SwiftNativeTrustCenter.autonomyForTool($1, policy: bundle))
        })
    }

    /// The one judgment: the call's class, and the level its class, its reach
    /// and User's posture give (act is `auto`, ask `confirm`, refuse `blocked`).
    /// With no input (a judgment by name) only what its declaration says counts.
    public static func judge(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                             dataRoot: URL) -> (toolClass: ToolClass, level: String) {
        let roots = SwiftNativeSecurityCenter.trustedWorkspaceRoots(
            policy: policy, filePolicy: SwiftNativeSecurityCenter.object(policy["filePolicy"]), dataRoot: dataRoot)
        let capabilities = input.map { SwiftNativeSecurityCenter.profile(tool: SwiftNativeSecurityCenter.policyToolName(tool),
                                                                         input: $0, dataRoot: dataRoot, trustedWorkspaceRoots: roots).capabilities }
        return judge(tool: tool, input: input, posture: posture(policy), dataRoot: dataRoot, roots: roots, capabilities: capabilities)
    }

    /// The same judgment from the facts the caller already resolved for this
    /// call (SecurityCenter's roots and effect profile), each read once.
    static func judge(tool: String, input: [String: JSONValue]?, posture: PermissionPosture, dataRoot: URL,
                      roots: [URL], capabilities: Set<String>?) -> (toolClass: ToolClass, level: String) {
        let toolClass = toolClass(tool, input: input ?? [:])
        let users = toolClass >= .send || reachesUser(tool, input: input, capabilities: capabilities ?? [])
        let level: String = switch (toolClass, posture) {
        case (.read, _): "auto"
        case _ where !users: "auto"
        case (_, .readOnly): "blocked"
        case (.destructive, _): "confirm"
        case (_, .fullMac): "auto"
        case (_, .work): "confirm"
        }
        return (toolClass, level)
    }

    /// What this call is: a read where its binding reads for this input, else
    /// its declaration's class (a registered tool's schema, a door action's
    /// row, a part's reach, a host primitive's effect). A command line's text
    /// is never read: a shell or git call is the write its tool declares.
    static func toolClass(_ tool: String, input: [String: JSONValue]) -> ToolClass {
        let name = ToolNameAliases.canonical(tool)
        if name == "app" {
            let named = ["action", "script"].contains { key in
                if case .string(let text)? = input[key] { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                else if key == "script", case .array(let calls)? = input[key] { !calls.isEmpty }
                else { false }
            }
            // Home, a page read, find and a preview change nothing; a folded
            // action re-enters under its tool's name and is judged there.
            guard named, input["preview"] != .bool(true) else { return .read }
            guard let action = AppActionBinding.action(input: input) else { return .write }
            return action.read || action.folded ? .read : action.toolClass
        }
        if AuthoredToolEffects.primitiveCapabilities[name] != nil || name.hasPrefix("fetch.") {
            return effectClass(AuthoredToolEffects.primitiveEffect(name, arguments: .object(input)).capabilities)
        }
        let action = AppActionBinding.action(tool: name, input: input) ?? AppActionBinding.binding(ToolNameAliases.authoredAction(name))
        if action?.read == true { return .read }
        let declared = AppActionBinding.declaredClass(name) ?? action?.toolClass ?? .write
        // A send's dry run reaches no one.
        return declared == .send && input["dry_run"] == .bool(true) ? .write : declared
    }

    /// Whether a write lands on User's side of the line: a command line (nobody
    /// knows what one reaches), a path beyond her roots (the path policy's own
    /// reading), another app's settings, his Mac's settings, apps or
    /// clipboard, a remote, his accounts (the Mac integration tools; a
    /// notification to him changes nothing of his), or anything whose
    /// declaration does not say where it reaches. Her app's own door actions
    /// are hers, and so are her Chrome extension's tabs; a folded door action
    /// re-enters under its tool's name.
    static func reachesUser(_ tool: String, input: [String: JSONValue]?, capabilities: Set<String>) -> Bool {
        let name = ToolNameAliases.canonical(tool)
        if SwiftNativeSecurityCenter.commandLineTools.contains(name.lowercased()) { return true }
        if input != nil, !capabilities.isDisjoint(with: [
            "outside_app_data_write", "other_app_settings_write", "system_control", "system_permission_reset",
            "ax_injection", "mac_control", "clipboard_write", "remote_effect",
        ]) { return true }
        if name == "app" || SwiftNativeSecurityCenter.notificationToolNames.contains(SwiftNativeSecurityCenter.policyToolName(name)) {
            return false
        }
        // One of her parts reaches what its own manifest declares.
        if let him = AppActionBinding.binding(ToolNameAliases.authoredAction(name))?.reachesHim { return him }
        guard let bucket = AppActionBinding.declaredBucket(name) else { return true }
        return [.macIntegration, .macControl, .system].contains(bucket)
    }

    /// Whether a card is a person's even under Full Mac: the call it carries
    /// cannot be undone on his side (User, 10-17: one card, a human's tap; her
    /// own approve never stands in for his). A chat tool's card carries the
    /// tool as its action and the call's `input`; a Workshop step's carries
    /// the step's `tool` and `args`.
    public static func humanDecides(action: String, payload: JSONValue) -> Bool {
        guard case .object(let payload) = payload else { return false }
        let step = ExecutionEventVocabulary.matches(action, WorkshopStepApprovalAction.canonical)
        var tool = action
        if step, case .string(let name)? = payload["tool"] { tool = name }
        var input: [String: JSONValue] = [:]
        if case .object(let fields)? = payload[step ? "args" : "input"] { input = fields }
        return toolClass(tool, input: input) == .destructive
    }

    /// A part's declared permission, as the primitive it names reaches.
    public static func permissionClass(_ permission: String) -> ToolClass {
        guard AuthoredToolEffects.primitiveCapabilities[permission] != nil || permission.hasPrefix("fetch") else { return .write }
        return effectClass(AuthoredToolEffects.primitiveEffect(permission, arguments: nil).capabilities)
    }

    static func effectClass(_ capabilities: Set<String>) -> ToolClass {
        if !capabilities.isDisjoint(with: ["destructive", "filesystem_delete", "system_permission_reset"]) { return .destructive }
        if capabilities.contains("external_send") { return .send }
        return capabilities.contains("safe_read") ? .read : .write
    }
}

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
    /// The effective answer for a tool by name (catalog, planner).
    public func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        try await autonomyLevel(forTool: toolName, input: nil)
    }

    /// The same, for a call whose input is known: `PermissionLaw.answer`, the
    /// one resolver SecurityCenter uses too.
    public func autonomyLevel(forTool toolName: String, input: [String: JSONValue]?) async throws -> String {
        let authorization = try await loadAuthorizationSnapshotChecked()
        return PermissionLaw.answer(tool: toolName, input: input, policy: authorization.policy,
                                    saved: authorization.userConfiguredAutonomyOverrides, dataRoot: dataRoot).level
    }

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
    public nonisolated static func autonomyForTool(
        _ toolName: String,
        policy: [String: JSONValue],
        capabilities: Set<String> = []
    ) -> String {
        var resolved = Self.autonomyForExactToolName(toolName, policy: policy)
        if case .object(let overrides)? = policy["autonomyOverrides"] {
            for capability in capabilities {
                if let level = Self.explicitAutonomyOverride(capability, overrides: overrides) {
                    resolved = Self.moreRestrictiveAutonomy(resolved, level)
                }
            }
        }
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
    public nonisolated static func moreRestrictiveAutonomy(_ a: String, _ b: String) -> String {
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
