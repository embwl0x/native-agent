import Foundation
// Blueprint: | `MacFourVerbs+TargetResolution.swift` | `MacFourVerbs`: Exact names, ordinals and visible main-content scroll targets |

extension MacFourVerbs {
    // MARK: - Resolution
    // Literal addresses precede containment; each resolution requires uniqueness, and role hints only narrow matches.

    enum Resolution {
        case hit(ActTarget)
        case ambiguous([ActTarget])
        case none(nearest: [String])
    }

    /// Actionable controls outrank same-named containers for every verb except scroll.
    static func resolve(_ target: String, among targets: [ActTarget], actionable: Bool = true, pressing: Bool = false) -> Resolution {
        // Use a symbol's word alias only when no AX control carries the literal symbol.
        if let words = symbolAliasWords(target) {
            let raw = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !targets.contains(where: { !$0.isSupplemental && ($0.label ?? "").lowercased() == raw }) {
                let aliased = targets.filter { !$0.isSupplemental && words.contains(normalize($0.label ?? "")) }
                if aliased.count == 1 { return .hit(aliased[0]) }
                if aliased.count > 1 { return .ambiguous(aliased) }
            }
        }
        let asHandle = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byHandle = targets.first(where: { $0.handle == asHandle }) { return .hit(byHandle) }
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
                if byRole.count > 1 { return tiebreak(byRole).map { .hit($0) } ?? .ambiguous(byRole) }
            }
            return tiebreak(candidates).map { .hit($0) } ?? .ambiguous(candidates)
        }

        // Prefer the strictly longest name match, then a lone control over plain text or containers sharing its name.
        func tiebreak(_ candidates: [ActTarget]) -> ActTarget? {
            let spans = candidates.map { candidate -> Int in
                let label = normalize(candidate.label ?? "")
                guard !label.isEmpty, !needle.isEmpty else { return 0 }
                if label.contains(needle) { return needle.count }
                return needle.contains(label) ? label.count : 0
            }
            if let best = spans.max(), best > 0, spans.filter({ $0 == best }).count == 1,
               let index = spans.firstIndex(of: best) {
                return candidates[index]
            }
            let controls: Set<String> = ["button", "link", "radio", "tab", "checkbox", "menu item"]
            let plain: Set<String> = ["text", "group", "window", "web area", "sheet"]
            let presses = candidates.filter { $0.actions.contains("AXPress") }
            if pressing, presses.count == 1, candidates.allSatisfy({
                $0 == presses[0] || plain.contains($0.kind) || $0.regionOnly
                    || ($0.kind == presses[0].kind && $0.actions.isEmpty && $0.frame == nil)
            }) { return presses[0] }
            let picked = candidates.filter { controls.contains($0.kind) }
            // A lone window wins when only its descendants repeat its title.
            let windows = candidates.filter { $0.kind == "window" }
            if picked.isEmpty, windows.count == 1 {
                let window = windows[0]
                let title = normalize(window.label ?? "")
                let repeats = candidates.allSatisfy { candidate in
                    guard candidate != window else { return true }
                    guard normalize(candidate.label ?? "") == title else { return false }
                    guard let root = window.sourceAXPath, let path = candidate.sourceAXPath else { return true }
                    return path.count > root.count && Array(path.prefix(root.count)) == root
                }
                if !title.isEmpty, repeats { return window }
            }
            // Two actionable controls tying is still a question, never a pick.
            guard picked.count == 1,
                  candidates.allSatisfy({
                      controls.contains($0.kind) || plain.contains($0.kind) || (actionable && $0.regionOnly)
                  }) else { return nil }
            return picked[0]
        }

        // A non-row AX control literally named by the number wins, then its rendered row. Pixel/OCR labels enter only later exact matching; a row's label
        // cannot override its number.
        if hint == nil, qualifier == nil, let number = Int(needle) {
            if let hit = narrow(targets.filter {
                !$0.isSupplemental && $0.ordinal == nil && normalize($0.label ?? "") == needle
            }) {
                return hit
            }
            if let hit = narrow(targets.filter { $0.ordinal == number }) { return hit }
        }

        // Visible row numbers precede role ordinals; `item N` uses list-item ordinals only when no row has that number.
        func ordinalHit() -> Resolution? {
            guard let ordinal = ordinalAddress(in: target) else { return nil }
            if hint == nil || hint == "row" || hint == "item",
               let hit = narrow(targets.filter { $0.ordinal == ordinal }) {
                return hit
            }
            if let hint, let hit = narrow(targets.filter { $0.kind == hint && $0.roleOrdinal == ordinal }) {
                return hit
            }
            return nil
        }
        // Resolve numbered rows before labels so a row labeled "Row 1" cannot steal row 1’s address.
        let words = needle.split(separator: " ")
        if words.count == 2, ordinalNouns.contains(String(words[0])), Int(words[1]) != nil,
           let hit = ordinalHit() {
            return hit
        }

        // A rendered region kind is an address even when the region has no label.
        if let hint, normalize(target) == hint,
           let hit = narrow(targets.filter { $0.kind == hint }) {
            return hit
        }

        // Focus aliases stay on the existing target so they cannot mint another handle or fuzzy-match another control.
        let normalizedTarget = normalize(identityTarget)
        if let hit = narrow(targets.filter {
            let label = exactName($0.label ?? "")
            return !label.isEmpty && label == exactName(target)
        }, respectingQualifier: false) { return hit }
        if let hit = narrow(targets.filter { candidate in
            candidate.aliases.contains { normalize($0) == normalizedTarget }
        }, respectingQualifier: false) {
            return hit
        }

        // Resolve copied ordinals and labels together; a changed label must not redirect a stale address.
        if let address = labeledOrdinalAddress(in: identityTarget) {
            let matches = targets.filter { candidate in
                let ordinalMatches = address.kind == "row"
                    ? candidate.ordinal == address.ordinal
                    : candidate.kind == address.kind && candidate.roleOrdinal == address.ordinal
                // Accept a copied label prefix only with a value suffix; `Delete` must never resolve to `Delete All`.
                let label = candidate.label.map(normalize) ?? ""
                let raw = (candidate.label ?? "").lowercased()
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let suffix = raw.hasPrefix(address.label) ? raw.dropFirst(address.label.count) : ""
                let valueSuffix = [" - ", " (", ":"].contains { suffix.hasPrefix($0) }
                    || suffix.first?.isNumber == true
                return ordinalMatches && (label == address.label || valueSuffix)
            }
            return narrow(matches, respectingQualifier: false)
                ?? .none(nearest: nearest(to: address.label, among: targets))
        }

        if let hit = narrow(targets.filter { normalize($0.label ?? "") == needle && !needle.isEmpty && answers(target, $0) }) {
            return hit
        }
        // A field's placeholder answers only after every exact label on the screen.
        if let hit = narrow(targets.filter { !needle.isEmpty && $0.placeholder.map(normalize) == needle && answers(target, $0) }) {
            return hit
        }
        // Short and numeric names never enter fuzzy matching; numeric rows resolved above.
        if isExactOnlyName(needle) {
            return .none(nearest: nearest(to: needle, among: targets))
        }
        if let hit = ordinalHit() { return hit }
        let name = askedName(target)
        if let hit = narrow(targets.filter { containsName(name, $0) }) { return hit }
        return .none(nearest: nearest(to: needle, among: targets))
    }

    /// Named commits require an explicit address or exact alias, kind or label; fuzzy and copied-prefix matches grant no authority.
    static func answers(_ target: String, _ candidate: ActTarget, exact: Bool = false) -> Bool {
        if candidate.handle == target.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        if let words = symbolAliasWords(target), words.contains(normalize(candidate.label ?? "")) { return true }
        let identity = stripWithinTargetAimQualifier(target)
        if let address = labeledOrdinalAddress(in: identity) {
            return !exact || normalize(candidate.label ?? "") == address.label
        }
        let asked = trailingRoleQualifier(in: identity)?.label ?? normalize(stripRoleWords(identity))
        if !isExactOnlyName(asked), ordinalAddress(in: identity) != nil { return true }
        if let number = Int(asked), candidate.ordinal == number { return true }
        let whole = normalize(identity)
        if candidate.aliases.contains(where: { normalize($0) == whole }) || candidate.kind == whole { return true }
        let label = exactName(candidate.label ?? "")
        if asked.isEmpty { return roleHint(in: identity) == candidate.kind }
        let literal = exactName(target)
        if !label.isEmpty, label == literal { return true }
        let name = askedName(target)
        return !name.isEmpty && (label == name || candidate.placeholder.map(exactName) == name
            || (!exact && !isExactOnlyName(asked) && containsName(name, candidate)))
    }

    /// Containment is one-way: the label must hold the whole request so a shorter label cannot steal a qualified name.
    static func containsName(_ name: String, _ candidate: ActTarget) -> Bool {
        let label = exactName(candidate.label ?? "")
        return name.count >= 3 && label != name && label.contains(name)
    }

    static func askedName(_ target: String) -> String {
        var name = exactName(withinTargetAimQualifier(target)?.target ?? target)
        for role in trailingRolePhrases {
            let suffix = name.hasSuffix(" (\(role))") ? " (\(role))" : " \(role)"
            guard name.hasSuffix(suffix) else { continue }
            name = String(name.dropLast(suffix.count))
            for article in ["the ", "a ", "an "] where name.hasPrefix(article) {
                name = String(name.dropFirst(article.count))
            }
            break
        }
        return name
    }

    static func exactName(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Disclose numeric control/row collisions so the caller can address the other target.
    static func bareNumberNote(_ target: String, chose candidate: ActTarget, among targets: [ActTarget]) -> String? {
        let asked = normalize(target)
        guard let number = Int(asked), candidate.ordinal != number,
              let row = targets.first(where: { $0.ordinal == number && $0 != candidate }) else { return nil }
        return """
            (\"\(asked)\" is the control named \(asked); row \(number) is \((row.label ?? "").isEmpty ? "unlabeled" : name(row)) — say \"row \(number)\" for \
            that.)
            """
    }

    /// Committing on a name requires an exact match.
    static let committingVerbs: Set<MacActVerb> = [.click, .select, .toggle]

    static let symbolAliases: [String: Set<String>] = [
        "=": ["equals", "equal"],
        "×": ["multiply", "times"], "*": ["multiply", "times"], "x": ["multiply", "times"],
        "÷": ["divide"], "/": ["divide"],
        "+": ["add", "plus"],
        "−": ["subtract", "minus"], "-": ["subtract", "minus"],
        "%": ["percent"],
        "±": ["negate", "change sign"], "+/-": ["negate", "change sign"], "+/−": ["negate", "change sign"],
        ".": ["decimal", "point", "decimal point"],
    ]

    static func symbolAliasWords(_ target: String) -> Set<String>? {
        symbolAliases[target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// Common button names stay controls; explicit `key` or chord syntax disambiguates keyboard input.
    static func pressMeansKey(_ target: String) -> Bool {
        if keySpec(target) != nil { return true }
        // `press +` / `press =` mean the button; `key +` still reaches the key.
        if symbolAliasWords(target) != nil { return false }
        let tokens = target.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        guard !tokens.isEmpty, (try? MacKeySyntax.parseChords(target)) != nil else { return false }
        let buttonNames: Set<String> = ["delete", "backspace", "del", "help", "home", "end"]
        return tokens.allSatisfy { $0.contains("+") || (MacKeySyntax.namedKeys[$0] != nil && !buttonNames.contains($0)) }
    }

    /// Short and numeric labels require exact matches to avoid ambiguous partial hits.
    static func isExactOnlyName(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return needle.count <= 2 || needle.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " }
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

    /// The identity probe earns another observation, never an action target; the motion-qualified name must still resolve.
    static func canConfirmTemporalTurn(_ target: String, previous: [ActTarget], current: [ActTarget]) -> Bool {
        guard hasTemporalQualifier(target) else { return false }
        let appearance = normalize(target).split(separator: " ")
            .filter { $0 != "moving" && $0 != "stationary" }.joined(separator: " ")
        func identity(_ targets: [ActTarget]) -> String? {
            guard case .hit(let candidate) = resolve(appearance, among: targets),
                  candidate.physicalOnly, candidate.motionUncertain, candidate.enabled == true,
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

    /// A bare field role uses focus or uniqueness; multiple unfocused candidates must remain ambiguous.
    static let bareFieldPhrases: Set<String> = [
        "field", "text field", "textfield", "search field", "search box", "search bar", "search",
        "path field", "text box", "input", "input field", "entry field", "box",
    ]

    static func bareField(_ target: String, in seen: Sighting) -> (hit: ActTarget?, candidates: [ActTarget])? {
        guard bareFieldPhrases.contains(normalize(target)) else { return nil }
        var handles = Set<String>()
        let fields = seen.targets.filter { candidate in
            // A field phrase never names a password field.
            !candidate.isSupplemental && candidate.enabled == true && candidate.kind != "secure text"
                && seen.editableHandles.contains(candidate.handle)
                && handles.insert(candidate.handle).inserted
        }
        if let focused = fields.first(where: {
            $0.aliases.contains("focused field") || (seen.focusPath != nil && $0.sourceAXPath == seen.focusPath)
        }) {
            return (focused, fields)
        }
        return (fields.count == 1 ? fields[0] : nil, fields)
    }

    /// Canvas editors may expose only keyboard focus; type there only when focus is known and not secure.
    static func typesAtFocus(_ target: String, in seen: Sighting) -> Bool {
        guard let bare = bareField(target, in: seen), bare.candidates.isEmpty else { return false }
        return seen.focusPath != nil && !seen.focusSecure
    }

    static func focusedEditableAliases(kind: String) -> [String] {
        var aliases = ["focused control", "focused field", "focused text", "focused editable control"]
        aliases.append("focused \(kind)")
        return Array(Set(aliases)).sorted()
    }

    /// Region kind disambiguates scroll destinations when a window, radio and web area share a title.
    static func resolveScrollTarget(_ target: String, among targets: [ActTarget], viewport: MacAXFrame? = nil) -> Resolution {
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Main-content scrolling excludes sidebar, toolbar and scrollbar furniture.
            let contents = targets.filter {
                $0.enabled == true && $0.kind != "scroll bar" && physicalScrollKinds.contains($0.kind)
                    && visiblePortion(of: $0.frame, within: viewport) != nil
            }.sorted {
                func area(_ target: ActTarget) -> Double {
                    guard let frame = visiblePortion(of: target.frame, within: viewport) else { return 0 }
                    return frame.w * frame.h
                }
                return area($0) > area($1)
            }
            if let main = contents.first { return .hit(main) }
            // Canvas scrolling may use the observed window, never a guessed off-window point.
            if let viewport {
                return .hit(ActTarget(handle: "", label: "main content", kind: "window", ordinal: nil,
                    enabled: true, frame: viewport, regionOnly: true))
            }
            return .none(nearest: [])
        }
        let phrase = normalize(target)
        for kind in physicalScrollKinds.sorted(by: { $0.count > $1.count })
        where phrase.contains(normalize(kind)) {
            let matches = targets.filter { $0.kind == kind }
            if matches.count == 1, let match = matches.first { return .hit(match) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return resolve(target, among: targets, actionable: false)
    }

    public static func isScrollVerb(_ raw: String) -> Bool { parseVerb(raw).0 == "scroll" }

    /// Misses offer observed labels only; unnamed controls cannot supply a useful name.
    static func nearest(to needle: String, among targets: [ActTarget], limit: Int = 8) -> [String] {
        let wantsScrollBar = needle.contains("scroll")
        let named = targets.compactMap { candidate -> (String, Int)? in
            guard let label = candidate.label, !label.isEmpty else { return nil }
            if !wantsScrollBar, isScrollBarPart(candidate) { return nil }
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

    /// Scrollbar position values are not useful target names.
    static func isScrollBarPart(_ candidate: ActTarget) -> Bool {
        if ["scroll bar", "valueindicator"].contains(candidate.kind) { return true }
        guard let label = candidate.label?.trimmingCharacters(in: .whitespaces),
              let value = Double(label), (0...1).contains(value),
              let dot = label.firstIndex(of: ".") else { return false }
        return label[label.index(after: dot)...].count >= 4
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
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'…"))
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        for article in ["the ", "a ", "an "] where value.hasPrefix(article) {
            value = String(value.dropFirst(article.count))
        }
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Role hints use the renderer’s vocabulary so they cannot promise an unrendered role.
    static let roleWords: [String: String] = {
        var out: [String: String] = [:]
        for name in Set(MacScreenRender.kindNames.values) { out[name] = name }
        // Regions share target ambiguity rules; a bare landmark kind must identify exactly one visible region.
        for name in Set(MacPerceptionCompiler.landmarkKinds.values) { out[name] = name }
        out["field"] = "text"
        out["textfield"] = "text"
        out["icon"] = "button"
        out["window"] = "window"
        return out
    }()

    private static let trailingRolePhrases = roleWords.keys.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    /// Only trailing role words constrain resolution; embedded words remain part of the literal name.
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

    /// Strip trailing role words so "the send button" can name "send".
    static func stripRoleWords(_ phrase: String) -> String {
        var words = normalize(phrase).split(separator: " ").map(String.init)
        while let last = words.last, roleWords[last] != nil, words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Aim prefixes select a point within an object, not its identity; preserve the original phrase for `aimPoint`.
    static func stripWithinTargetAimQualifier(_ phrase: String) -> String {
        withinTargetAimQualifier(phrase)?.target ?? normalize(phrase)
    }

    /// Only bounded spatial prefixes qualify; hyphens inside object names remain literal.
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

    /// Quarter-points keep side aims away from resize edges.
    static func safeAimPoint(for target: ActTarget, in frame: MacAXFrame,
                            describedBy phrase: String) -> MacPointerPosition? {
        // A whole exact alias names the object, including any directional words.
        let identity = normalize(phrase)
        let phrase = target.aliases.contains { normalize($0) == identity } ? "" : phrase
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

    /// AX documents can exceed the viewport; aim the wheel inside their visible portion.
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
