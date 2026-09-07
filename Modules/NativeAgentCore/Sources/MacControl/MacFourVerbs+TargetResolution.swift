import Foundation

// Pure name, role, ordinal, motion-identity, and aim-point resolution for the
// already observed targets. Observation and dispatch stay in MacFourVerbs.swift.
extension MacFourVerbs {
    // MARK: - Resolution
    //
    // The ladder, and it NEVER falls back to "just click the first match":
    //
    //   1. exact label, case/whitespace-insensitive
    //   2. unique contains-match, either direction
    //   3. ordinal address — "row 3", "button 2", "text area 1", "3" — the
    //      content or role ordinals the render printed
    //   4. a ROLE HINT in the phrase ("the Send button") narrows a multi-match
    //      at every rung, never widens one
    //
    // Unique, or ask.

    enum Resolution {
        case hit(ActTarget)
        case ambiguous([ActTarget])
        case none(nearest: [String])
    }

    static func resolve(_ target: String, among targets: [ActTarget]) -> Resolution {
        let hint = roleHint(in: target)
        let identityTarget = stripWithinTargetAimQualifier(target)
        let qualifier = trailingRoleQualifier(in: identityTarget)
        let needle = qualifier?.label ?? normalize(stripRoleWords(identityTarget))
        guard !needle.isEmpty || hint != nil else { return .none(nearest: nearest(to: "", among: targets)) }

        func narrow(_ matches: [ActTarget], respectingQualifier: Bool = true) -> Resolution? {
            let candidates = respectingQualifier && qualifier != nil
                ? matches.filter { $0.kind == qualifier?.kind }
                : matches
            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return .hit(candidates[0]) }
            if let hint {
                let byRole = candidates.filter { $0.kind == hint }
                if byRole.count == 1 { return .hit(byRole[0]) }
                if byRole.count > 1 { return .ambiguous(byRole) }
            }
            return .ambiguous(candidates)
        }

        // A region's rendered kind is itself a valid name ("web area",
        // "sidebar", "list"). It need not repeat that kind as its label.
        if let hint, normalize(target) == hint,
           let hit = narrow(targets.filter { $0.kind == hint }) {
            return hit
        }

        // Focus is a temporary but exact semantic address. Keep its aliases on
        // the existing target so "focused field" and "focused control" reach
        // the one element the screen says is focused without minting a second
        // handle or letting fuzzy matching choose another control.
        let normalizedTarget = normalize(identityTarget)
        if let hit = narrow(targets.filter { candidate in
            candidate.aliases.contains { normalize($0) == normalizedTarget }
        }, respectingQualifier: false) {
            return hit
        }

        // A literal label can contain role words without describing its role
        // (a row named "Send button", for example). Preserve that exact
        // address before interpreting a trailing kind as a qualifier.
        if let hit = narrow(targets.filter {
            normalize($0.label ?? "") == normalizedTarget && !normalizedTarget.isEmpty
        }, respectingQualifier: false) { return hit }

        // A copied DO/recovery address includes both its ordinal and label,
        // e.g. `button 4 Remove`. Resolve that complete address before fuzzy
        // name matching can discard the number. The label must still agree:
        // a changed screen must not silently redirect a stale address.
        if let address = labeledOrdinalAddress(in: identityTarget) {
            let matches = targets.filter { candidate in
                let ordinalMatches = address.kind == "row"
                    ? candidate.ordinal == address.ordinal
                    : candidate.kind == address.kind && candidate.roleOrdinal == address.ordinal
                return ordinalMatches && candidate.label.map(normalize) == address.label
            }
            return narrow(matches, respectingQualifier: false)
                ?? .none(nearest: nearest(to: address.label, among: targets))
        }

        // 1. exact
        if let hit = narrow(targets.filter { normalize($0.label ?? "") == needle && !needle.isEmpty }) {
            return hit
        }
        // 2. contains
        let contains = targets.filter { candidate in
            guard !needle.isEmpty else { return false }
            let labelMatches: Bool = {
                guard let label = candidate.label else { return false }
                let normalized = normalize(label)
                return !normalized.isEmpty
                    && (normalized.contains(needle) || needle.contains(normalized))
            }()
            let aliasMatches = candidate.aliases.contains { alias in
                let normalized = normalize(alias)
                // An alias may refine a short request ("yellow" -> "yellow
                // object"), but a longer request may not silently discard
                // qualifiers such as moving, above, or left-of.
                return !normalized.isEmpty && normalized.contains(needle)
            }
            return labelMatches || aliasMatches
        }
        if let hit = narrow(contains) { return hit }
        // 3. ordinal. A bare ordinal and `row N` mean the visible content-row
        // number. Every other role uses its own visible ordinal, so repeated
        // unlabeled buttons, tabs, text areas, and landmarks have an honest
        // natural address.
        if let ordinal = ordinalAddress(in: target) {
            if hint == "row",
               let hit = narrow(targets.filter { $0.ordinal == ordinal }) {
                return hit
            }
            if let hint,
               let hit = narrow(targets.filter {
                   $0.kind == hint && $0.roleOrdinal == ordinal
               }) {
                return hit
            }
            if hint == nil,
               let hit = narrow(targets.filter { $0.ordinal == ordinal }) {
                return hit
            }
        }
        return .none(nearest: nearest(to: needle, among: targets))
    }

    static func isPotentialDynamicVisualReference(_ target: String) -> Bool {
        let words = normalize(target).split(separator: " ")
        let exactRegion = words.count == 3
            && words[0] == "visual"
            && words[1] == "region"
            && Int(words[2]) != nil
        let compactObjectPhrase = (2...7).contains(words.count)
            && (words.contains("object") || words.contains("square") || words.contains("circle"))
        return exactRegion || compactObjectPhrase
    }

    /// This identity probe only earns one more observation. It NEVER supplies
    /// an action target: the original motion-qualified name must still resolve.
    static func canConfirmTemporalTurn(_ target: String, previous: [ActTarget], current: [ActTarget]) -> Bool {
        guard hasTemporalQualifier(target) else { return false }
        let appearance = normalize(target).split(separator: " ")
            .filter { $0 != "moving" && $0 != "stationary" }.joined(separator: " ")
        func identity(_ targets: [ActTarget]) -> String? {
            guard case .hit(let candidate) = resolve(appearance, among: targets),
                  candidate.physicalOnly, candidate.motionUncertain, candidate.enabled,
                  candidate.observedFrame != nil, let label = candidate.label, !label.isEmpty else { return nil }
            return candidate.handle + "|" + label
        }
        guard let previousID = identity(previous), let currentID = identity(current) else { return false }
        return previousID == currentID
    }

    static func hasTemporalQualifier(_ target: String) -> Bool {
        let words = normalize(target).split(separator: " ")
        return words.contains("moving") || words.contains("stationary")
    }

    static let editableKinds: Set<String> = ["text", "text area", "secure text"]

    static func focusedEditableAliases(kind: String) -> [String] {
        var aliases = ["focused control", "focused field", "focused text", "focused editable control"]
        aliases.append("focused \(kind)")
        return Array(Set(aliases)).sorted()
    }

    /// Scroll names commonly combine a page title with the region kind. Kind
    /// is the decisive part: a browser can expose the same title on a radio,
    /// window, and web area, but only the web area is a scroll destination.
    static func resolveScrollTarget(_ target: String, among targets: [ActTarget]) -> Resolution {
        let phrase = normalize(target)
        for kind in physicalScrollKinds.sorted(by: { $0.count > $1.count })
        where phrase.contains(normalize(kind)) {
            let matches = targets.filter { $0.kind == kind }
            if matches.count == 1, let match = matches.first { return .hit(match) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return resolve(target, among: targets)
    }

    /// What she DID see, so a miss is a fact she can act on rather than a dead
    /// end. Labels only — an unnamed control is not a suggestion.
    static func nearest(to needle: String, among targets: [ActTarget], limit: Int = 8) -> [String] {
        let named = targets.compactMap { candidate -> (String, Int)? in
            guard let label = candidate.label, !label.isEmpty else { return nil }
            let normalized = normalize(label)
            var score = 0
            if !needle.isEmpty {
                let shared = Set(needle.split(separator: " ")).intersection(normalized.split(separator: " "))
                score = shared.count * 10
                if let first = needle.first, normalized.hasPrefix(String(first)) { score += 1 }
            }
            return (recoveryName(candidate), score)
        }
        let ranked = named.enumerated()
            .sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            .map(\.element.0)
        var seen: Set<String> = []
        return ranked.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    static func matches(_ needle: String, _ label: String?, kind: String?) -> Bool {
        if let kind, normalize(kind) == needle { return true }
        guard let label else { return false }
        let normalized = normalize(label)
        guard !normalized.isEmpty, !needle.isEmpty else { return false }
        return normalized.contains(needle) || needle.contains(normalized)
    }

    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'"))
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        for article in ["the ", "a ", "an "] where value.hasPrefix(article) {
            value = String(value.dropFirst(article.count))
        }
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The kind words the renderer's own vocabulary publishes, so a hint can
    /// never name a role the render does not print.
    static let roleWords: [String: String] = {
        var out: [String: String] = [:]
        for name in Set(MacScreenRender.kindNames.values) { out[name] = name }
        // Regions use the same target model as controls. Their vocabulary is
        // published by the perception compiler, so a bare `sidebar` can
        // resolve only when exactly one such visible landmark exists.
        for name in Set(MacPerceptionCompiler.landmarkKinds.values) { out[name] = name }
        // Two synonyms a person actually says, mapped onto the same vocabulary.
        out["field"] = "text"
        out["textfield"] = "text"
        return out
    }()

    private static let trailingRolePhrases = roleWords.keys.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    /// Only a trailing role phrase qualifies the remaining fuzzy/exact-name
    /// rungs. Embedded words in a literal name are not role restrictions.
    static func trailingRoleQualifier(in phrase: String) -> (label: String, kind: String)? {
        let normalized = normalize(phrase)
        for role in trailingRolePhrases where normalized.hasSuffix(" " + role) {
            guard let kind = roleWords[role] else { continue }
            return (normalize(String(normalized.dropLast(role.count))), kind)
        }
        return nil
    }

    static func roleHint(in phrase: String) -> String? {
        let words = normalize(phrase).split(separator: " ").map(String.init)
        // Longest match first, so "menu item" beats "menu".
        if words.count >= 2 {
            for index in 0..<(words.count - 1) {
                if let hit = roleWords[words[index] + " " + words[index + 1]] { return hit }
            }
        }
        for word in words.reversed() {
            if let hit = roleWords[word] { return hit }
        }
        return nil
    }

    /// The phrase with its trailing role word removed — "the send button" is a
    /// request for something NAMED "send", not for something named "send button".
    static func stripRoleWords(_ phrase: String) -> String {
        var words = normalize(phrase).split(separator: " ").map(String.init)
        while let last = words.last, roleWords[last] != nil, words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// These prefixes specify an aim point *within* an already named object;
    /// unlike motion, coarse position, and relations, they are not part of its
    /// identity. Strip them for resolution while preserving the original
    /// phrase for `aimPoint`.
    static func stripWithinTargetAimQualifier(_ phrase: String) -> String {
        withinTargetAimQualifier(phrase)?.target ?? normalize(phrase)
    }

    /// Interpret only a bounded spatial prefix. Hyphens in the object's own
    /// name (for example "upper-left-icon") remain part of its identity.
    private static func withinTargetAimQualifier(_ phrase: String) -> (target: String, words: Set<String>)? {
        let normalized = normalize(phrase)
        guard let separator = normalized.range(of: " of ") else { return nil }
        let qualifier = String(normalized[..<separator.lowerBound])
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let singles: Set<String> = ["left side", "right side", "top", "upper part",
                                    "bottom", "lower part", "center", "centre", "middle"]
        let diagonal = qualifier.count >= 2 && qualifier.count <= 3
            && ["top", "upper", "bottom", "lower"].contains(qualifier[0])
            && ["left", "right"].contains(qualifier[1])
            && (qualifier.count == 2 || ["corner", "part", "side"].contains(qualifier[2]))
        guard diagonal || singles.contains(qualifier.joined(separator: " ")) else { return nil }
        let target = normalize(String(normalized[separator.upperBound...]))
        guard !target.isEmpty else { return nil }
        return (target, Set(qualifier))
    }

    private static func aimWords(in phrase: String) -> Set<String> {
        withinTargetAimQualifier(phrase)?.words
            ?? Set(normalize(phrase).split(separator: " ").map(String.init))
    }

    static let ordinalNouns: Set<String> = ["row", "item", "cell", "line", "no", "number", "#"]

    static func labeledOrdinalAddress(in phrase: String) -> (kind: String, ordinal: Int, label: String)? {
        let normalized = normalize(phrase)
        for role in trailingRolePhrases where normalized.hasPrefix(role + " ") {
            let remainder = normalized.dropFirst(role.count + 1)
            let parts = remainder.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let ordinal = Int(parts[0]),
                  let kind = roleWords[role] else { continue }
            let label = normalize(String(parts[1]))
            guard !label.isEmpty else { continue }
            return (kind, ordinal, label)
        }
        return nil
    }

    static func ordinalAddress(in phrase: String) -> Int? {
        let words = normalize(phrase)
            .replacingOccurrences(of: "#", with: "# ")
            .split(separator: " ").map(String.init)
        if words.count == 1, let only = Int(words[0]) { return only }
        if words.count > 1,
           let last = words.last,
           let value = Int(last),
           roleHint(in: words.dropLast().joined(separator: " ")) != nil {
            return value
        }
        for (index, word) in words.enumerated() where ordinalNouns.contains(word) {
            if index + 1 < words.count, let value = Int(words[index + 1]) { return value }
        }
        return nil
    }

    static func nextRoleOrdinal(for kind: String, among targets: [ActTarget]) -> Int {
        (targets.compactMap { target in
            target.kind == kind ? target.roleOrdinal : nil
        }.max() ?? 0) + 1
    }

    static func name(_ candidate: ActTarget) -> String {
        if let label = candidate.label, !label.isEmpty { return "\"\(label)\"" }
        if let ordinal = candidate.ordinal { return "row \(ordinal)" }
        return "that \(candidate.kind)"
    }

    static func recoveryName(_ candidate: ActTarget) -> String {
        let address = candidate.ordinal.map { "row \($0)" }
            ?? candidate.roleOrdinal.map { "\(candidate.kind) \($0)" }
        guard let address else { return name(candidate) }
        if let label = candidate.label, !label.isEmpty { return "\(address) \"\(label)\"" }
        return address
    }

    static func spokenName(_ candidate: ActTarget, requestedAs target: String) -> String {
        let requested = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = normalize(stripWithinTargetAimQualifier(requested))
        if !requested.isEmpty,
           candidate.aliases.contains(where: { normalize($0) == identity }) {
            return "\"\(requested)\""
        }
        return name(candidate)
    }

    /// Natural spatial qualifiers turn one visible region into useful aim
    /// points without exposing coordinates. Quarter-points leave a margin so
    /// "right side" does not accidentally target a resize edge.
    static func safeAimPoint(for target: ActTarget, in frame: MacAXFrame,
                            describedBy phrase: String) -> MacPointerPosition? {
        let aim = aimPoint(in: frame, describedBy: phrase)
        guard let preferred = MacPointerPosition(x: aim.x, y: aim.y) else { return nil }
        let words = aimWords(in: phrase)
        let spatialWords: Set<String> = ["left", "right", "top", "upper", "bottom", "lower", "center", "centre", "middle"]
        return MacRegionAim.point(in: frame, preferred: preferred, excluding: target.excludedFrames,
                                  allowAlternate: target.regionOnly && words.isDisjoint(with: spatialWords))
    }

    static func aimPoint(in frame: MacAXFrame, describedBy phrase: String) -> (x: Double, y: Double) {
        let words = aimWords(in: phrase)
        let xRatio = words.contains("left") ? 0.25 : words.contains("right") ? 0.75 : 0.5
        let yRatio = words.contains("top") || words.contains("upper")
            ? 0.25
            : (words.contains("bottom") || words.contains("lower") ? 0.75 : 0.5)
        return (frame.x + frame.w * xRatio, frame.y + frame.h * yRatio)
    }

    /// AX can describe a web document with its full many-screen height. A
    /// wheel event must be aimed inside the portion a person can currently
    /// see, not at the mathematical centre of the off-screen document.
    static func visiblePortion(of frame: MacAXFrame?, within viewport: MacAXFrame?) -> MacAXFrame? {
        guard let frame else { return nil }
        guard let viewport else { return frame }
        let x = max(frame.x, viewport.x)
        let y = max(frame.y, viewport.y)
        let right = min(frame.x + frame.w, viewport.x + viewport.w)
        let bottom = min(frame.y + frame.h, viewport.y + viewport.h)
        guard right > x, bottom > y else { return nil }
        return MacAXFrame(x: x, y: y, w: right - x, h: bottom - y)
    }

}
