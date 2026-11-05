import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import os
#endif
// Blueprint: | `MacPerceptionCompiler.swift` | `MacPerceptionCompiler`: One AX snapshot supplies graded, redacted perception and stable target handles |
public enum MacPerceptionCompiler {
    /// 220 characters fit roughly one terminal row and cost about 55 tokens.
    public static let glanceMaxChars = 220
    /// Cap the complete delivered payload, including the tool envelope.
    public static let lookByteBudget = 6144
    /// Prose uses approved clear text only; without a compiler verdict, the standalone shape check decides.
    static func displayText(_ raw: String?, json: JSONValue?) -> String? {
        guard let raw else { return nil }
        guard let json else { return safeDisplay(raw) }
        if case .string(let clear) = json { return clear }
        return nil
    }
    /// Same ceiling as the fused view's legend, for the same reason.
    public static let maxAffordances = MacScreenViewBuilder.hardMaxMarks
    /// A landmark list longer than this is a tree, not a map.
    public static let maxLandmarks = 12
    public static let maxLandmarkDepth = 6
    /// An affordance's VALUE is a hint, not a document.
    public static let affordanceValueChars = 40
    /// Bound readouts so values cannot become a full window transcript.
    public static let maxReadouts = 12
    /// Publish ranking on the wire so callers do not mistake it for document order.
    public static let affordanceRankingName = "controls_first"
    /// Read-only text fields remain readouts; interactive ones are already affordances.
    public static let readoutRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXValueIndicator", "AXLevelIndicator",
        "AXProgressIndicator", "AXTextField", "AXTextArea",
    ]
    /// Controls rank ahead of editable row content under the count and byte caps.
    public static let controlRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTab", "AXLink", "AXMenuItem", "AXComboBox",
        "AXSlider", "AXDisclosureTriangle", "AXIncrementor",
    ]
    /// Toolbar and sheet descendants rank as controls because they contain the immediate actions.
    public static let controlContainerRoles: Set<String> = [
        "AXToolbar", "AXSheet", "AXMenuBar", "AXMenu",
    ]
    /// Share budget recursively across branches so one large subtree cannot crowd out smaller regions.
    static func fairShare(_ members: [Int], paths: [[Int]], budget: Int, depth: Int) -> [Int] {
        guard members.count > budget else { return members }
        guard budget > 0 else { return [] }
        // An ended path forms its own branch so it does not disappear from the budget.
        var order: [Int] = []
        var branches: [Int: [Int]] = [:]
        for member in members {
            let path = paths[member]
            let key = depth < path.count ? path[depth] : -1 - member
            if branches[key] == nil { order.append(key) }
            branches[key, default: []].append(member)
        }
        if order.count == 1 {
            return fairShare(members, paths: paths, budget: budget, depth: depth + 1)
        }
        var left = budget
        var shares: [Int: Int] = [:]
        let bySize = order.sorted { (branches[$0]?.count ?? 0) < (branches[$1]?.count ?? 0) }
        for (index, key) in bySize.enumerated() {
            let share = min(branches[key]?.count ?? 0, left / (bySize.count - index))
            shares[key] = share
            left -= share
        }
        return order.flatMap { key in
            fairShare(branches[key] ?? [], paths: paths, budget: shares[key] ?? 0, depth: depth + 1)
        }
    }
    /// Interactive roles remain actionable without advertised AXPress; scroll containers remain landmarks rather than controls.
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXSwitch", "AXSearchField",
        "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXPopUpButton",
        "AXComboBox", "AXSlider", "AXRadioButton", "AXMenuButton", "AXTab",
        "AXMenuItem",
        // Secure text fields remain addressable without AXPress; their values stay count+digest.
        "AXSecureTextField",
    ]
    public static func isInteractive(_ attributes: MacAXAttributes) -> Bool {
        if attributes.actions.contains("AXPress") { return true }
        return interactiveRoles.contains(attributes.role)
    }
    public static let landmarkKinds: [String: String] = [
        "AXToolbar": "toolbar",
        "AXOutline": "sidebar",
        "AXTable": "table",
        "AXList": "list",
        "AXScrollArea": "scrollarea",
        "AXWebArea": "webarea",
        "AXSheet": "sheet",
        "AXTabGroup": "tabgroup",
    ]
    public static let modalSubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXSheet",
    ]
    /// Glances omit secret text because prose cannot safely carry a structured count/digest verdict.
    static func safeDisplay(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard MacScreenViewTextRedaction.standaloneSecretReason(trimmed) == nil else { return nil }
        return MacAccessibilityReader.truncate(trimmed, to: 40)
    }
    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    static let captionedRoles: Set<String> = ["AXTextField", "AXComboBox", "AXPopUpButton"]
    static func captionText(_ raw: String?) -> String? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(":") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    /// One snapshot deterministically produces one percept, including handles.
    public static func compile(
        snapshot: MacAXTreeSnapshot,
        secretContext: MacScreenViewTextRedaction.NodeSecretContext,
        app: MacAXAppInfo?,
        windowTitle: String?,
        focusPath: [Int]? = nil,
        maxAffordances: Int = MacPerceptionCompiler.maxAffordances,
        /// Identity checks need the whole walk, not the subset retained by presentation caps.
        uncapped: Bool = false
    ) -> MacLookPercept {
        let cap = uncapped ? Int.max : max(1, min(maxAffordances, MacPerceptionCompiler.maxAffordances))
        var byPath: [[Int]: MacAXNode] = [:]
        for node in snapshot.nodes { byPath[node.path] = node }
        // Every hint uses the whole snapshot's caption context before any cap.
        func redacted(_ text: String, of node: MacAXNode, under caption: String?, isValue: Bool = false) -> JSONValue {
            if isValue, MacScreenViewBuilder.isSecretField(
                role: node.attributes.role,
                subrole: node.attributes.subrole,
                label: node.attributes.title
            ) {
                return MacInjectionResultRedaction.redactedSecret(text)
            }
            return MacScreenViewTextRedaction.redactedNodeString(
                text,
                valueChars: uncapped ? max(1, text.count) : affordanceValueChars,
                frame: node.attributes.frame,
                under: caption,
                enclosing: MacScreenViewTextRedaction.enclosingKinds(
                    forNodeAt: node.attributes.frame,
                    path: node.path,
                    among: secretContext.enclosingCaptions
                ),
                context: secretContext
            )
        }
        let ordered = snapshot.nodes.sorted { pathIsBefore($0.path, $1.path) }
        var childrenByParent: [[Int]: [MacAXNode]] = [:]
        for node in ordered where !node.path.isEmpty {
            childrenByParent[Array(node.path.dropLast()), default: []].append(node)
        }
        // Hash the untitled row’s own complete text, excluding child controls, so shared prefixes and buttons cannot merge records.
        func contentName(of node: MacAXNode) -> String? {
            let attributes = node.attributes
            guard MacLookHandle.contentIdentityRoles.contains(attributes.role) else { return nil }
            // Named controls keep identity across value changes such as a popup switching from Medium to Large.
            guard cleaned(attributes.title) == nil else { return nil }
            guard !(isInteractive(attributes) && cleaned(attributes.value) != nil) else { return nil }
            var texts: [String] = []
            func scan(_ path: [Int], depth: Int) {
                guard depth < 2 else { return }
                for child in childrenByParent[path] ?? [] where !controlRoles.contains(child.attributes.role) {
                    if let text = cleaned(child.attributes.title) ?? cleaned(child.attributes.value) {
                        texts.append(text)
                    } else { scan(child.path, depth: depth + 1) }
                }
            }
            scan(node.path, depth: 0)
            guard !texts.isEmpty else { return nil }
            return MacLookHandle.token(fingerprint: texts.joined(separator: "\n").lowercased())
        }
        // Ancestor titles or content names distinguish descendants; absent labels are absent keys.
        var ancestorLabelByPath: [[Int]: String] = [:]
        var contentNameByPath: [[Int]: String] = [:]
        for node in ordered {
            let title = cleaned(node.attributes.title)
            let content = title == nil ? contentName(of: node) : nil
            let label: String? = title ?? content
            if let label { ancestorLabelByPath[node.path] = label }
            if let content { contentNameByPath[node.path] = content }
        }
        func ancestors(of path: [Int]) -> [(role: String, title: String?)] {
            var chain: [(role: String, title: String?)] = []
            guard !path.isEmpty else { return chain }
            for depth in 0..<path.count {
                let prefix = Array(path.prefix(depth))
                guard let node = byPath[prefix] else { continue }
                // The root contributes its role only, so a window retitle preserves control handles.
                let label = prefix.isEmpty ? nil : ancestorLabelByPath[prefix]
                chain.append((node.attributes.role, label))
            }
            return chain
        }
        // Mint handles before ranking in document order so presentation cannot move identity. Disambiguate rendered-token collisions as ordinals rather than
        // silently merging distinct fingerprints.
        let tokens = ordered.map { node in
            MacLookHandle.token(
                fingerprint: MacLookHandle.fingerprint(
                    role: node.attributes.role,
                    subrole: node.attributes.subrole,
                    // Changing a field’s value must not change its handle.
                    title: cleaned(node.attributes.title),
                    ancestors: ancestors(of: node.path),
                    contentName: contentNameByPath[node.path]
                )
            )
        }
        var handleByPath: [[Int]: String] = [:]
        var ambiguityByPath: [[Int]: String] = [:]
        for (node, minted) in zip(ordered, MacLookHandle.mint(tokens: tokens)) {
            handleByPath[node.path] = minted.handle
            ambiguityByPath[node.path] = minted.ambiguity
        }
        // Repeated tokens stay actionable with explicit positional ambiguity.
        var affordances: [MacLookAffordance] = []
        var landmarks: [MacLookLandmark] = []
        var unlabeled: [String: Int] = [:]
        var interactiveCount = 0
        var labeledCount = 0
        var omitted = 0
        var modal: MacLookModal?
        var readoutCandidates: [(node: MacAXNode, text: String, source: String)] = []
        for node in ordered {
            let attributes = node.attributes
            let depth = node.path.count + 1
            if let kind = landmarkKinds[attributes.role], depth <= maxLandmarkDepth {
                if landmarks.count < maxLandmarks {
                    let label = cleaned(attributes.title)
                    landmarks.append(MacLookLandmark(
                        kind: kind,
                        role: attributes.role,
                        label: label,
                        depth: depth,
                        path: node.path,
                        frame: attributes.frame,
                        labelJSON: label.map { redacted($0, of: node, under: nil) },
                        enabled: attributes.enabled
                    ))
                }
            } else if let subrole = attributes.subrole,
                      subrole == "AXDialog" || subrole == "AXSystemDialog",
                      depth <= maxLandmarkDepth,
                      landmarks.count < maxLandmarks {
                let label = cleaned(attributes.title)
                landmarks.append(MacLookLandmark(
                    kind: "dialog",
                    role: attributes.role,
                    label: label,
                    depth: depth,
                    path: node.path,
                    frame: attributes.frame,
                    labelJSON: label.map { redacted($0, of: node, under: nil) },
                    enabled: attributes.enabled
                ))
            }
            // The root window is not its own modal.
            if modal == nil, !node.path.isEmpty {
                let isSheet = attributes.role == "AXSheet" || attributes.subrole == "AXSheet"
                let isDialog = attributes.subrole == "AXDialog" || attributes.subrole == "AXSystemDialog"
                if isSheet || isDialog {
                    let titled = cleaned(attributes.title)
                    let messageNode = titled == nil ? firstStaticText(under: node.path, in: ordered) : nil
                    let label = titled ?? messageNode.flatMap { cleaned($0.attributes.title) ?? cleaned($0.attributes.value) }
                    modal = MacLookModal(
                        role: attributes.role,
                        subrole: attributes.subrole,
                        label: label,
                        path: node.path,
                        labelJSON: label.map { redacted($0, of: messageNode ?? node, under: nil) }
                    )
                }
            }
            // Defer readout deduplication, ranking and capping until affordances are final.
            if !isInteractive(attributes) {
                let value = cleaned(attributes.value)
                let isReadoutRole = readoutRoles.contains(attributes.role)
                // A container's own value is a readout even when its role is also a landmark.
                let containerValue = (landmarkKinds[attributes.role] != nil || attributes.role == "AXGroup")
                    ? value
                    : nil
                if isReadoutRole || containerValue != nil {
                    let text = value ?? (isReadoutRole ? cleaned(attributes.title) : nil)
                    if let text {
                        readoutCandidates.append((node, text, value != nil ? "value" : "title"))
                    }
                }
            }
            guard isInteractive(attributes) else { continue }
            interactiveCount += 1
            let title = attributes.title == attributes.role ? nil : cleaned(attributes.title)
            let value = cleaned(attributes.value)
            let label: String
            let labelSource: String
            if attributes.labelUnreadable {
                label = ""
                labelSource = "unreadable"
            } else if let title {
                label = title
                labelSource = "title"
            } else if let value {
                // Popups and tabs publish their own state; nearby-label inference needs capture geometry and must not add a second AX pass.
                label = value
                labelSource = "value"
            } else {
                // Unlabeled controls keep stable handles and role ordinals; absence of a name cannot justify dropping or inventing one.
                label = ""
                labelSource = "unlabeled"
                unlabeled[attributes.role, default: 0] += 1
            }
            if labelSource != "unlabeled", labelSource != "unreadable" { labeledCount += 1 }
            // Rank before capping so useful controls survive instead of merely the first document-order rows.
            let shownValue = labelSource == "value" ? nil : value
            affordances.append(MacLookAffordance(
                handle: handleByPath[node.path] ?? "",
                role: attributes.role,
                subrole: attributes.subrole,
                label: label,
                labelSource: labelSource,
                value: shownValue,
                secret: MacScreenViewBuilder.isSecretField(
                    role: attributes.role,
                    subrole: attributes.subrole,
                    label: title
                ),
                enabled: attributes.enabled,
                selected: attributes.selected,
                frame: attributes.frame,
                path: node.path,
                // A value-derived label requires value redaction, not title redaction.
                labelJSON: redacted(label, of: node, under: nil, isValue: labelSource == "value"),
                // A control’s title captions its value, protecting fields such as CVV and API key.
                valueJSON: shownValue.map { redacted($0, of: node, under: title, isValue: true) },
                handleAmbiguity: ambiguityByPath[node.path],
                placeholder: cleaned(attributes.placeholder),
                placeholderJSON: cleaned(attributes.placeholder).map { redacted($0, of: node, under: nil) },
                state: attributes.state
            ))
        }
        // Controls outrank row content, preserving document order within tiers and the handles already minted.
        func rankTier(_ affordance: MacLookAffordance) -> Int {
            if controlRoles.contains(affordance.role) { return 0 }
            for depth in 0..<affordance.path.count {
                let ancestor = byPath[Array(affordance.path.prefix(depth))]
                if let role = ancestor?.attributes.role, controlContainerRoles.contains(role) {
                    return 0
                }
                if let subrole = ancestor?.attributes.subrole, modalSubroles.contains(subrole) {
                    return 0
                }
            }
            return 1
        }
        let ranked = Dictionary(grouping: affordances, by: rankTier)
        let controlCount = ranked[0]?.count ?? 0
        affordances = (ranked[0] ?? []) + (ranked[1] ?? [])
        if affordances.count > cap {
            omitted = affordances.count - cap
            // Share regional caps in tier order, but reserve focused, selected and modal controls so busy branches cannot crowd them out.
            func protected(_ affordance: MacLookAffordance) -> Bool {
                if affordance.path == focusPath || affordance.selected == true { return true }
                return (0..<affordance.path.count).contains { depth in
                    guard let ancestor = byPath[Array(affordance.path.prefix(depth))]?.attributes else { return false }
                    return ancestor.role == "AXSheet"
                        || ["AXDialog", "AXSystemDialog", "AXSheet"].contains(ancestor.subrole ?? "")
                }
            }
            var kept = Set(affordances.indices.filter { protected(affordances[$0]) }.prefix(cap))
            var remaining = cap - kept.count
            for tier in [0..<controlCount, controlCount..<affordances.count] where remaining > 0 {
                let members = tier.filter { !kept.contains($0) }
                let chosen = members.count <= remaining
                    ? members
                    : Self.fairShare(members, paths: affordances.map(\.path), budget: remaining, depth: 0)
                kept.formUnion(chosen)
                remaining -= chosen.count
            }
            affordances = affordances.indices.filter { kept.contains($0) }.map { affordances[$0] }
        }
        // Absent focus remains unknown; guessing the first field would fabricate cursor location.
        var focus: MacLookFocus?
        if let focusPath, let node = byPath[focusPath] {
            let title = cleaned(node.attributes.title)
            let label = title ?? cleaned(node.attributes.value)
            focus = MacLookFocus(
                role: node.attributes.role,
                label: label,
                handle: handleByPath[focusPath],
                path: focusPath,
                // Value-derived labels have no title caption; secure role and surrounding context must protect focused secrets.
                labelJSON: label.map { redacted($0, of: node, under: nil, isValue: title == nil) },
                selectionRange: node.attributes.selectionRange,
                enabled: node.attributes.enabled
            )
        }
        let rootNode = byPath[[]]
        let title = cleaned(windowTitle)
        // Deduplicate readouts against their own control or nearby caption, never equal words elsewhere on screen.
        func normalizedText(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let controlText = Dictionary(grouping: affordances, by: \.path)
            .mapValues { Set($0.map { normalizedText($0.label) }) }
        let siblingCaptions = Dictionary(grouping: affordances, by: { Array($0.path.dropLast()) })
            .mapValues { Set($0.map { normalizedText($0.label) }) }
        func repeatsControl(_ path: [Int], _ text: String) -> Bool {
            siblingCaptions[Array(path.dropLast())]?.contains(text) == true
                || (0..<path.count).contains { controlText[Array(path.prefix($0))]?.contains(text) == true }
        }
        var readoutSeen = Set<String>()
        if let title { readoutSeen.insert(normalizedText(title)) }
        if let label = modal?.label { readoutSeen.insert(normalizedText(label)) }
        func readoutTier(_ path: [Int]) -> Int {
            if let modalPath = modal?.path,
               path.count > modalPath.count,
               Array(path.prefix(modalPath.count)) == modalPath { return 0 }
            if let focusPath {
                if path.count > focusPath.count, Array(path.prefix(focusPath.count)) == focusPath { return 1 }
                if path.count == focusPath.count, path.dropLast() == focusPath.dropLast() { return 1 }
            }
            for depth in 0..<path.count {
                let ancestor = byPath[Array(path.prefix(depth))]
                if let role = ancestor?.attributes.role,
                   let kind = landmarkKinds[role],
                   kind == "scrollarea" || kind == "webarea" || kind == "table" { return 2 }
            }
            return 3
        }
        var readoutBuckets = Array(repeating: [MacLookReadout](), count: 4)
        for candidate in readoutCandidates {
            let normalized = normalizedText(candidate.text)
            guard !normalized.isEmpty, !readoutSeen.contains(normalized),
                  !repeatsControl(candidate.node.path, normalized) else { continue }
            readoutSeen.insert(normalized)
            let tier = readoutTier(candidate.node.path)
            readoutBuckets[tier].append(MacLookReadout(
                handle: handleByPath[candidate.node.path],
                role: candidate.node.attributes.role,
                text: candidate.text,
                source: candidate.source,
                path: candidate.node.path,
                nearFocus: tier == 1,
                inModal: tier == 0,
                // Readouts are values and need the same full-context redaction as affordances to avoid leaking displayed secrets.
                textJSON: redacted(
                    candidate.text,
                    of: candidate.node,
                    under: candidate.source == "value" ? candidate.node.attributes.title : nil,
                    isValue: candidate.source == "value"
                ),
                handleAmbiguity: ambiguityByPath[candidate.node.path]
            ))
        }
        var readouts = readoutBuckets.flatMap { $0 }
        var readoutsOmitted = 0
        if !uncapped, readouts.count > maxReadouts {
            readoutsOmitted = readouts.count - maxReadouts
            readouts = Array(readouts.prefix(maxReadouts))
        }
        return MacLookPercept(
            app: app,
            windowTitle: title,
            focus: focus,
            modal: modal,
            landmarks: landmarks,
            affordances: affordances,
            unlabeledByRole: unlabeled,
            affordancesOmitted: omitted,
            interactiveCount: interactiveCount,
            labeledCount: labeledCount,
            truncated: snapshot.truncated,
            truncationReasons: snapshot.truncationReasons,
            skippedAtLeast: snapshot.skippedAtLeast,
            readFailures: snapshot.readFailures,
            windowTitleJSON: title.map { text in
                rootNode.map { redacted(text, of: $0, under: nil) }
                    ?? MacScreenViewTextRedaction.redactedLegendString(text, valueChars: affordanceValueChars)
            },
            readouts: readouts,
            readoutsOmitted: readoutsOmitted,
            ambiguousHandles: affordances.filter(\.handleAmbiguous).count
                + readouts.filter(\.handleAmbiguous).count
        )
    }
    /// Untitled sheets use their first static message; return its node so redaction retains the message’s own context.
    private static func firstStaticText(under path: [Int], in ordered: [MacAXNode]) -> MacAXNode? {
        for node in ordered where node.path.count > path.count && Array(node.path.prefix(path.count)) == path {
            guard node.attributes.role == "AXStaticText" else { continue }
            if cleaned(node.attributes.title) ?? cleaned(node.attributes.value) != nil {
                return node
            }
        }
        return nil
    }
    static func pathIsBefore(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return lhs.count < rhs.count
    }
}
