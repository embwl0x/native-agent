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
// Blueprint: | `MacPerceptionCompiler.swift` | `MacPerceptionCompiler`, look frames and handles: graded perception from the existing AX snapshot, redacted readouts and fresh target resolution |
public enum MacPerceptionCompiler {
    /// A glance is one line. 220 characters is roughly what fits on a terminal
    /// row and is ~55 tokens — the whole point of the grade.
    public static let glanceMaxChars = 220
    /// Hard byte cap on the FINAL look payload (inner percept + tool envelope).
    public static let lookByteBudget = 6144
    /// What a glance may print for a text channel: the compiler-redacted clear
    /// text when it was let through, nil when redaction withheld it; with no
    /// compiler verdict (hand-built value) the standalone shape test decides.
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
    /// A readout channel longer than this is the text of the
    /// window, not the values in it.
    public static let maxReadouts = 12
    /// The ranking the affordance list is emitted in, named on the
    /// wire so a caller can tell a ranked list from a document-order one.
    public static let affordanceRankingName = "controls_first"
    /// Non-interactive roles that CARRY a value a human reads.
    /// `AXTextField`/`AXTextArea` are here for the read-only case: when they are
    /// interactive they are already affordances and are skipped.
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
    /// Ancestor roles that make anything inside them a CONTROL for ranking:
    /// a toolbar's contents and a sheet's contents are what she came for.
    public static let controlContainerRoles: Set<String> = [
        "AXToolbar", "AXSheet", "AXMenuBar", "AXMenu",
    ]
    /// Pick `budget` of `members` (indices into `paths`, in ranked order)
    /// spread over the tree: where the paths branch, each branch gets an even
    /// share (a small branch keeps all of its members and its unused share goes
    /// to the others), recursively. Returns a subset of `members`.
    static func fairShare(_ members: [Int], paths: [[Int]], budget: Int, depth: Int) -> [Int] {
        guard members.count > budget else { return members }
        guard budget > 0 else { return [] }
        // Branch on the path component at `depth`; a path that ends here is its own branch.
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
    /// Advertises `AXPress`, or is one of the roles that is interactive whether
    /// or not the app bothered to advertise an action. Same two-family logic as
    /// `MacScreenViewBuilder.isMarkable`, narrowed: this list is what she can
    /// ACT on, so scroll containers are landmarks here rather than affordances.
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
    /// role → landmark kind. A window's structure in the vocabulary a human
    /// would use for it.
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
    /// A display string that is safe for the PROSE grade: nil when the redactor
    /// says the text is itself a secret. The glance has no room for a
    /// count+digest object, so a secret is simply absent from it and the
    /// structured grade carries the audit shape.
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
    /// Fields and popups an app names with a separate label (`MacAXAttributeRead.copyLabel`).
    static let captionedRoles: Set<String> = ["AXTextField", "AXComboBox", "AXPopUpButton"]
    /// "Save As:" → "Save As"; nil when there is no text.
    static func captionText(_ raw: String?) -> String? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(":") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    /// Compile ONE walk into ONE percept. Pure: same snapshot in ⇒ same percept
    /// out, handles included.
    public static func compile(
        snapshot: MacAXTreeSnapshot,
        secretContext: MacScreenViewTextRedaction.NodeSecretContext,
        app: MacAXAppInfo?,
        windowTitle: String?,
        focusPath: [Int]? = nil,
        maxAffordances: Int = MacPerceptionCompiler.maxAffordances,
        /// The act's identity check: the element at a handle's path is judged
        /// against the whole walk, never against which controls a cap kept.
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
        // The identity of a TITLE-LESS container, from the text it
        // contains two levels down (Finder's shape is AXRow > AXCell >
        // AXStaticText). The row's OWN text, all of it: a child control's
        // label ("Delete" in every row) is skipped and the whole text is
        // hashed, so two records sharing a sender, a prefix or a button stay
        // distinct. A recycled row that shows another record is a new handle.
        func contentName(of node: MacAXNode) -> String? {
            let attributes = node.attributes
            guard MacLookHandle.contentIdentityRoles.contains(attributes.role) else { return nil }
            // Rule 2 is untouched for anything with a name of its own, and for
            // any CONTROL whose value IS its label — the popup button reading
            // "Medium" then "Large" must keep one handle.
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
            // Compute content explicitly only for untitled nodes, keeping coalescing at String?.
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
        // 1. Handles for EVERY node, in document order, so the focused element
        //    and an affordance agree on one identity. Ordinals are assigned by
        //    rendered TOKEN, which makes a hash collision between two distinct
        //    fingerprints a disambiguated pair rather than a silent merge.
        //
        //    THIS PASS RUNS BEFORE RANKING and over document order, so the
        //    controls-first ordering below can never change a handle.
        let tokens = ordered.map { node in
            MacLookHandle.token(
                fingerprint: MacLookHandle.fingerprint(
                    role: node.attributes.role,
                    subrole: node.attributes.subrole,
                    // TITLE only — never the value. A field whose contents
                    // change is still the same field.
                    title: cleaned(node.attributes.title),
                    ancestors: ancestors(of: node.path),
                    // Already computed once above; `fingerprint` ignores it for
                    // titled nodes anyway.
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
        // Repeated tokens remain actionable and explicitly report their positional ambiguity.
        // 2. Affordances, landmarks, unlabeled census — one pass.
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
            // Landmark?
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
                        labelJSON: label.map { redacted($0, of: node, under: nil) }
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
                    labelJSON: label.map { redacted($0, of: node, under: nil) }
                ))
            }
            // Modal? The ROOT is never a modal — it is the window itself.
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
            // Collect read-only candidates; dedupe/rank/cap after the affordance list is final.
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
            if let title {
                label = title
                labelSource = "title"
            } else if let value {
                // A popup button / tab publishes its own state as its name.
                // Nearby-text inference is deliberately NOT run here: it needs
                // the capture geometry `mac_view` has and a look does not, and
                // a guessed label that costs a second AX pass is not "trivially
                // available".
                label = value
                labelSource = "value"
            } else {
                // A missing AX name is not a reason to throw a visible,
                // interactive control away. Keep its stable look handle and
                // let the one fused screen/target model publish `button 2`,
                // `text area 1`, and similar role ordinals. The empty label is
                // intentional: it renders as ⟨unlabeled⟩ and never masquerades
                // as an invented name.
                label = ""
                labelSource = "unlabeled"
                unlabeled[attributes.role, default: 0] += 1
            }
            if labelSource != "unlabeled" { labeledCount += 1 }
            // NO CAP HERE: the cap is applied AFTER ranking, so
            // "the 60 rows we kept" are the 60 most useful rows and not the
            // first 60 in document order (Finder's filenames, every time).
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
                // A value-derived label IS a value: redact it as one (under no
                // caption of its own). A title is redacted as a title.
                labelJSON: redacted(label, of: node, under: nil, isValue: labelSource == "value"),
                // The control's own title is the value's caption — the "CVV"
                // box showing `123`, the "API key" field showing the key.
                valueJSON: shownValue.map { redacted($0, of: node, under: title, isValue: true) },
                handleAmbiguity: ambiguityByPath[node.path],
                placeholder: cleaned(attributes.placeholder),
                placeholderJSON: cleaned(attributes.placeholder).map { redacted($0, of: node, under: nil) },
                state: attributes.state
            ))
        }
        // 2b. RANK, THEN CAP. Controls — buttons, menus, popups,
        //     checkboxes, radios, tabs, links, and anything inside a toolbar or
        //     a sheet — come before row CONTENT (the rename-able filename in
        //     every Finder row). Document order is preserved WITHIN a tier, and
        //     handles were minted in the pass above, so nothing here can move a
        //     handle.
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
            // Share the cap across regions in tier order, retaining ranked order among survivors.
            // Never shared out: the focused control, a selected one, and
            // anything in a dialog or sheet. A lone modal button must not lose
            // its slot to a busy branch.
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
        // 3. Focus — only when the source could actually tell us. An absent
        //    focus is reported as absent, never guessed at from "the first text
        //    field", which is how a look starts lying about where the cursor is.
        var focus: MacLookFocus?
        if let focusPath, let node = byPath[focusPath] {
            let title = cleaned(node.attributes.title)
            let label = title ?? cleaned(node.attributes.value)
            focus = MacLookFocus(
                role: node.attributes.role,
                label: label,
                handle: handleByPath[focusPath],
                path: focusPath,
                // A focused field's VALUE is the thing most likely to be the
                // secret (the cursor is in the password box). When the label
                // fell back to the value, the node has no title to caption it,
                // so its secure role and the surrounding context decide.
                labelJSON: label.map { redacted($0, of: node, under: nil, isValue: title == nil) },
                selectionRange: node.attributes.selectionRange
            )
        }
        let rootNode = byPath[[]]
        let title = cleaned(windowTitle)
        // 4. READOUTS — dedupe hard, then rank, then cap.
        //
        //    Without the dedupe this channel becomes a second tree: a button's
        //    own AXStaticText child says exactly what the button says, and a
        //    sheet's message is already the modal's label. A control's text is
        //    the readout inside it or its caption beside it, never the same
        //    words elsewhere: Calculator's display reading "1" is not the "1" key.
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
                // A readout is a VALUE. Same compile-time redactor, same full
                // node context (standalone shape, enclosing secret-naming group,
                // the caption beside/above) as every affordance channel — a
                // readout channel that bypassed this would ship the password
                // the login sheet is displaying.
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
    /// A sheet often has no title of its own; its message is the first static
    /// text inside it. Naming it from there is what makes the MODAL segment of
    /// a glance useful instead of "MODAL: AXSheet". Returns the NODE so the
    /// caller can redact the message under that node's own frame/context.
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
