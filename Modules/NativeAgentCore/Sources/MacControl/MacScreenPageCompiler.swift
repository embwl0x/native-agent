import Foundation
import PersistenceCore
import Senses
// Blueprint: | `MacScreenPageCompiler.swift` | Structural AX reading order, scoped alias folding, whole sentences, secret redaction and exact related actions |

/// The walk and look frame own identity; this compiler owns reading order and representation, never input.
public enum MacScreenPageCompiler {
    static func ownName(_ attributes: MacAXAttributes, text: String?) -> String? {
        guard let text, !text.allSatisfy({ $0.isWhitespace || "•◦‣⁃".contains($0) }),
              text != attributes.role, text != MacScreenRender.kindName(role: attributes.role) else { return nil }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func sectionName(_ attributes: MacAXAttributes, name: String?) -> String? {
        switch attributes.subrole ?? attributes.role {
        case "AXLandmarkNavigation": return name ?? "Navigation"
        case "AXLandmarkMain": return name ?? "Main content"
        case "AXLandmarkComplementary", "AXOutline": return name ?? "Sidebar"
        default: return nil
        }
    }

    public struct Compilation: Sendable {
        public let page: NativePage
        /// Source paths support native zoom without another rendered text channel.
        public let blocks: JSONValue
    }

    public static func compile(snapshot: MacAXTreeSnapshot, redactedNodes: [JSONValue], percept: MacLookPercept,
                               frameID: String, isFront: Bool, menuReading: MacMenuBar.Reading?,
                               settableAttributes: (MacAXNode) -> [String]) throws -> Compilation {
        let bundle = percept.app?.bundleIdentifier ?? "*"
        let corner = SenseCorner.app(bundleID: bundle)
        let ordered = snapshot.nodes.sorted { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }
        var words: [[Int]: (title: String?, value: String?)] = [:]
        for (node, json) in zip(snapshot.nodes, redactedNodes) {
            guard case .object(let fields) = json else { continue }
            // Do not guess away words.
            words[node.path] = (display(fields["title"]), display(fields["value"]))
        }
        let byPath = Dictionary(ordered.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let indexByPath = Dictionary(ordered.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var subtreeEnds = Array(repeating: ordered.count, count: ordered.count)
        var open: [Int] = []
        for (index, node) in ordered.enumerated() {
            while let previous = open.last, !node.path.starts(with: ordered[previous].path) {
                subtreeEnds[previous] = index
                open.removeLast()
            }
            open.append(index)
        }
        func descendants(_ node: MacAXNode) -> ArraySlice<MacAXNode> {
            guard let index = indexByPath[node.path] else { return [] }
            return ordered[(index + 1)..<subtreeEnds[index]]
        }
        var controls = Dictionary(percept.affordances.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let webAreas = ordered.filter { $0.attributes.role == "AXWebArea" }
        let webPaths = webAreas.map(\.path)
        func inPage(_ node: MacAXNode) -> Bool { webPaths.contains { node.path.starts(with: $0) } }
        // Renderer documents own their reading order and budget; shell controls must not crowd out the first paragraph.
        let readingOrder = webAreas.isEmpty ? ordered : ordered.filter(inPage) + ordered.filter { !inPage($0) }
        var consumed: Set<[Int]> = []
        var things: [NativeThing] = []
        var lines: [String] = []
        var blocks: [JSONValue] = []
        var headingLines: Set<Int> = []
        func append(_ text: String, at path: [Int], heading: Bool = false) {
            if heading { headingLines.insert(lines.count) }
            lines.append(text)
            blocks.append(.object(["text": .string(text), "path": .array(path.map { .int(Int64($0)) })]))
        }
        let appName = percept.app?.name ?? "App"
        let windowTitle = percept.windowTitleJSON.flatMap { display($0) }
        append(appName + (windowTitle.map { " · " + $0 } ?? "") + (isFront ? " · FRONT" : " · not front"), at: [])
        // Retain menu titles so paths need no extra read.
        if let menuReading {
            if let unavailable = menuReading.unavailable {
                append("Menus unavailable: " + unavailable, at: [])
            } else {
                let titles = MacMenuBar.topLevelNames(menuReading.items)
                if !titles.isEmpty {
                    append("Menus: " + titles.joined(separator: " · ") + " — act target \"File > Save\" presses an item; mac.menu lists them whole.", at: [])
                }
                if menuReading.truncated { append("Menu coverage is partial; submenus or capped items were not read.", at: []) }
            }
        } else {
            append("Menus unavailable: no confirmed app owner.", at: [])
        }
        append(SenseScreenThings.accessibilityReadLine, at: [])
        var shellStarted = false
        var pageNumber = 0

        func ancestors(_ path: [Int]) -> [MacAXNode] {
            (0..<path.count).reversed().compactMap { byPath[Array(path.prefix($0))] }
        }
        func same(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs else { return false }
            return lhs.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                == rhs.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func names(_ text: String, owner: String) -> Bool {
            let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let owner = owner.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !owner.isEmpty else { return false }
            var start = text.startIndex
            while let range = text.range(of: owner, range: start..<text.endIndex) {
                let left = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let right = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                if !(left?.isLetter == true || left?.isNumber == true),
                   !(right?.isLetter == true || right?.isNumber == true) { return true }
                start = range.upperBound
            }
            return false
        }
        func representedByControl(_ text: String, path: [Int]) -> Bool {
            ancestors(path).contains { ancestor in
                guard let control = controls[ancestor.path] else { return false }
                return same(text, controlLabel(ancestor)) || same(text, display(control.valueJSON))
            }
        }

        func inline(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func readable(_ text: String) -> Bool {
            !inline(text).isEmpty && !text.allSatisfy { $0.isWhitespace || "•◦‣⁃".contains($0) }
        }
        func ownName(_ node: MacAXNode) -> String? {
            Self.ownName(node.attributes, text: words[node.path]?.title ?? words[node.path]?.value)
        }
        func staticRuns(_ node: MacAXNode) -> [MacAXNode] {
            let leaves = descendants(node).filter { child in
                child.attributes.role == "AXStaticText"
                    && !descendants(child).contains { $0.attributes.role == "AXStaticText" }
                    && !ancestors(child.path).prefix(while: { $0.path != node.path }).contains {
                        $0.attributes.role == "AXWebArea" || $0.attributes.role == "AXImage"
                            || (controls[$0.path] != nil && !["AXGroup", "AXStaticText"].contains($0.attributes.role))
                    }
            }
            return distinctTextNodes(leaves)
        }
        func distinctTextNodes(_ nodes: [MacAXNode]) -> [MacAXNode] {
            // Equal words at different positions stay distinct; fold only duplicate nodes or coincident representations.
            var paths = Set<[Int]>()
            var names: [MacAXFrame: Set<String?>] = [:]
            return nodes.filter { leaf in
                guard !paths.contains(leaf.path) else { return false }
                if let frame = leaf.attributes.frame, frame.w > 0, frame.h > 0,
                   !names[frame, default: []].insert(ownName(leaf)).inserted { return false }
                paths.insert(leaf.path)
                return true
            }
        }
        func runText(_ nodes: [MacAXNode]) -> String? {
            let parts = nodes.compactMap { ownName($0) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        var captions: [[Int]: String] = [:]
        var captionPaths: [[Int]: Set<[Int]>] = [:]
        func controlLabel(_ node: MacAXNode) -> String? {
            guard !node.attributes.labelUnreadable else { return nil }
            guard let control = controls[node.path] else { return nil }
            if let caption = captions[node.path] { return caption }
            let kind = MacScreenRender.kindName(role: node.attributes.role)
            let displayedLabel = node.attributes.titleIsHelp ? words[node.path]?.title : display(control.labelJSON)
            if let label = displayedLabel, readable(label),
               label != node.attributes.role, label != kind {
                let runs = staticRuns(node)
                let parts = runs.compactMap(ownName)
                if parts.count > 1, same(label, parts.first), let text = runText(runs) { return text }
                return inline(label)
            }
            // Use authoritative AX meanings only for unnamed window buttons; preserve observed labels.
            if let subrole = node.attributes.subrole,
               ["AXCloseButton", "AXMinimizeButton", "AXZoomButton"].contains(subrole) {
                return MacScreenRender.kindName(role: String(subrole.dropLast("Button".count)))
            }
            // Chromium composite names come from descendant text, not wrapper roles or status images.
            return runText(staticRuns(node))
        }
        // Fold presentation descendants only when role, containment, name and actions agree; independently named controls remain distinct.
        let activationActions: Set<String> = ["AXPress", "AXOpen", "AXShowMenu"]
        let labelOwners = MacPerceptionCompiler.controlRoles.union(["AXSwitch"])
        let checkableRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch"]
        // Use the smallest label container with exactly one checkable input; larger containers may caption several controls.
        for node in ordered where checkableRoles.contains(node.attributes.role) && controls[node.path] != nil {
            for scope in ancestors(node.path) where ["AXGroup", "AXListItem", "AXParagraph"].contains(scope.attributes.role) {
                let children = descendants(scope)
                guard children.filter({ checkableRoles.contains($0.attributes.role) }).count == 1 else { break }
                if let label = controlLabel(node) {
                    let matches = staticRuns(scope).filter { same(ownName($0), label) }
                    if !matches.isEmpty {
                        captionPaths[node.path] = Set(matches.map(\.path))
                        break
                    }
                }
                guard
                      !children.contains(where: {
                          $0.path != node.path && labelOwners.contains($0.attributes.role)
                              && !["AXGroup", "AXStaticText", "AXImage"].contains($0.attributes.role)
                      }),
                      !children.contains(where: { ["AXHeading", "AXWebArea"].contains($0.attributes.role) }),
                      children.filter({ $0.attributes.role == "AXParagraph" }).count <= 1 else { break }
                let runs = staticRuns(scope).filter { !consumed.contains($0.path) }
                guard let text = runText(runs) else { continue }
                if controlLabel(node) == nil { captions[node.path] = text }
                if same(text, controlLabel(node)) {
                    captionPaths[node.path] = Set(runs.map(\.path))
                    break
                }
            }
        }
        // Toolbar captions may precede inputs; match locally rather than deduplicating equal text across the page.
        for node in ordered where checkableRoles.contains(node.attributes.role) {
            guard let label = controlLabel(node) else { continue }
            let parent = Array(node.path.dropLast())
            for sibling in ordered where Array(sibling.path.dropLast()) == parent
                && sibling.attributes.role == "AXStaticText" && same(ownName(sibling), label) {
                captionPaths[node.path, default: []].insert(sibling.path)
                captionPaths[node.path, default: []].formUnion(descendants(sibling).map(\.path))
            }
        }
        // Structured editor children retain headings, lists and controls; publishing their aggregate value too would duplicate the body.
        var structuredDocuments: Set<[Int]> = []
        var aggregateDocuments: Set<[Int]> = []
        for node in ordered where ["AXTextArea", "AXDocument"].contains(node.attributes.role) {
            let children = descendants(node)
            if children.contains(where: { ["AXHeading", "AXParagraph", "AXList", "AXListItem"].contains($0.attributes.role) }),
               children.contains(where: { $0.attributes.role == "AXStaticText" && ownName($0) != nil }) {
                // Compare redacted content rather than AX state; partial children cannot erase the complete editor value.
                let textNodes = children.filter { child in
                    ["AXStaticText", "AXHeading", "AXLink", "AXCheckBox"].contains(child.attributes.role)
                        && !descendants(child).contains(where: { $0.attributes.role == "AXStaticText" })
                        && (child.attributes.role != "AXHeading" || words[child.path]?.title != nil)
                }
                let parts = distinctTextNodes(textNodes).compactMap(ownName)
                let value = words[node.path]?.value
                let complete = value.map {
                    $0 != "⟨redacted⟩" && (same($0, parts.joined(separator: " ")) || same($0, parts.joined()))
                } ?? true
                if complete {
                    structuredDocuments.insert(node.path)
                    controls.removeValue(forKey: node.path)
                } else {
                    aggregateDocuments.insert(node.path)
                }
            }
        }
        for node in ordered where controls[node.path] != nil {
            let a = node.attributes
            let actions = Set(a.actions).intersection(activationActions)
            if ["AXSeparator", "AXSplitter"].contains(a.role) {
                controls.removeValue(forKey: node.path)
                continue
            }
            if ["AXGroup", "AXMenu"].contains(a.role), ownName(node) == nil {
                controls.removeValue(forKey: node.path)
                continue
            }
            if ["AXGroup", "AXMenu", "AXStaticText", "AXImage"].contains(a.role), actions.isEmpty {
                controls.removeValue(forKey: node.path)
                continue
            }
            if a.role == "AXImage", ancestors(node.path).contains(where: { owner in
                guard owner.attributes.role == "AXGroup",
                      actions.isSubset(of: Set(owner.attributes.actions).intersection(activationActions)) else { return false }
                let children = descendants(owner)
                return children.filter({ $0.attributes.role == "AXHeading" }).count == 1
                    && children.filter({ checkableRoles.contains($0.attributes.role) }).count == 1
            }) {
                // A card badge repeats its owner’s activation rather than adding an independent action.
                controls.removeValue(forKey: node.path)
                continue
            }
            guard ["AXGroup", "AXStaticText", "AXImage"].contains(a.role),
                  let owner = ancestors(node.path).first(where: {
                      controls[$0.path] != nil && labelOwners.contains($0.attributes.role)
                  }), actions.isSubset(of: Set(owner.attributes.actions)),
                  ownName(node) == nil || ownName(node).map({ name in
                      controlLabel(owner).map { names($0, owner: name) } == true
                  }) == true || a.role == "AXImage"
            else { continue }
            controls.removeValue(forKey: node.path)
        }
        // Unnamed wrappers remain structure even when they repeat child press actions.
        for node in ordered.reversed() where node.attributes.role == "AXGroup" && controls[node.path] != nil {
            let actions = descendants(node).filter {
                controls[$0.path] != nil && (["AXButton", "AXLink"].contains($0.attributes.role) || checkableRoles.contains($0.attributes.role))
            }
            if actions.contains(where: {
                (ownName(node) == nil || same(ownName(node), controlLabel($0)))
                    && Set(node.attributes.actions).intersection(activationActions).isSubset(of: Set($0.attributes.actions))
            }) { controls.removeValue(forKey: node.path) }
        }
        func headingText(_ node: MacAXNode) -> String? {
            // AXHeading numeric values are levels; use static children for names and exclude control-owned captions.
            let parts = staticRuns(node).compactMap(ownName)
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
            // Levels and aggregate titles containing child controls are not heading names.
            guard !descendants(node).contains(where: { controls[$0.path] != nil }),
                  let title = words[node.path]?.title, readable(title) else { return nil }
            return inline(title)
        }
        // Fold sibling checkbox captions only within a one-control label subtree; equal text elsewhere stays independent.
        for group in ordered.reversed() where ["AXGroup", "AXListItem"].contains(group.attributes.role) {
            let children = descendants(group)
            let actions = children.filter { controls[$0.path] != nil && labelOwners.contains($0.attributes.role) }
            guard actions.count == 1, let owner = actions.first, labelOwners.contains(owner.attributes.role),
                  let label = controlLabel(owner),
                  !children.contains(where: { ["AXHeading", "AXWebArea", "AXParagraph"].contains($0.attributes.role) }) else { continue }
            for child in children where ["AXStaticText", "AXGroup"].contains(child.attributes.role)
                && same(ownName(child), label) {
                if Set(child.attributes.actions).isSubset(of: Set(owner.attributes.actions)) {
                    controls.removeValue(forKey: child.path)
                }
                consumed.insert(child.path)
            }
        }
        // Containment and AX names establish rows without app-specific guesses; unnamed inputs and enabled icon buttons remain usable.
        func unnamedName(_ node: MacAXNode) -> String? {
            if let kind = unnamedInputKind(node.attributes.role) { return kind }
            guard labelOwners.contains(node.attributes.role), controls[node.path]?.enabled == true,
                  node.attributes.actions.contains("AXPress") else { return nil }
            return "(unnamed \(MacScreenRender.kindName(role: node.attributes.role)))"
        }
        for node in ordered where controls[node.path] != nil && controlLabel(node) == nil && unnamedName(node) == nil {
            controls.removeValue(forKey: node.path)
        }
        var compositeRows: [[Int]: MacAXNode] = [:]
        var rowIdentities: [[Int]: String] = [:]
        var namedStates: [[Int]: String] = [:]
        var rowRelatedNames: [[Int]: [String]] = [:]
        for group in ordered.reversed() where group.attributes.role == "AXGroup" {
            // An actionable group owns its own address, not just its children.
            if controls[group.path] != nil { continue }
            let children = descendants(group)
            if children.contains(where: { compositeRows[$0.path] != nil }) { continue }
            let actions = children.filter { child in
                controls[child.path] != nil && ["AXButton", "AXLink", "AXPopUpButton", "AXMenuButton"].contains(child.attributes.role)
                    && !ancestors(child.path).prefix(while: { $0.path != group.path }).contains {
                        controls[$0.path] != nil && labelOwners.contains($0.attributes.role)
                    }
            }
            let owners = actions.filter { candidate in
                guard ["AXButton", "AXLink"].contains(candidate.attributes.role),
                      let label = controlLabel(candidate) else { return false }
                // Row status must not become session identity; use AX labels rather than a status vocabulary.
                var statuses = descendants(candidate).filter {
                    ["AXGroup", "AXImage"].contains($0.attributes.role) && controls[$0.path] == nil
                }.compactMap(ownName)
                if let value = display(controls[candidate.path]?.valueJSON) { statuses.append(value) }
                var name = label
                for status in statuses {
                    if let prefix = name.range(of: status + " ", options: [.anchored, .caseInsensitive]) {
                        name.removeSubrange(prefix)
                    }
                }
                let runName = runText(staticRuns(candidate))
                let identities = [name, runName].compactMap { $0 }.filter { !$0.isEmpty }
                return identities.contains { identity in
                    actions.allSatisfy { $0.path == candidate.path || controlLabel($0).map { names($0, owner: identity) && !same($0, identity) } == true }
                }
            }
            guard actions.count > 1, owners.count == 1, let primary = owners.first,
                  children.filter({ controls[$0.path] != nil && $0.path != primary.path && $0.attributes.role != "AXImage" })
                      .allSatisfy({ actions.contains($0) }),
                  Set(actions.compactMap(controlLabel)).count == actions.count,
                  actions.allSatisfy({ $0.attributes.actions.contains("AXPress") || $0.attributes.actions.contains("AXOpen") }),
                  !children.contains(where: { child in
                      child.attributes.role == "AXStaticText" && !ancestors(child.path).prefix(while: { $0.path != group.path })
                          .contains { controls[$0.path] != nil }
                  }) else { continue }
            compositeRows[group.path] = primary
            rowRelatedNames[primary.path] = actions.filter { $0.path != primary.path }.compactMap(controlLabel)
            if let label = controlLabel(primary), let visibleName = runText(staticRuns(primary)),
               !same(label, visibleName), let range = label.range(of: visibleName),
               range.upperBound == label.endIndex,
               actions.filter({ $0.path != primary.path }).allSatisfy({
                   controlLabel($0).map { names($0, owner: visibleName) } == true
               }) {
                // Accessible-name status belongs in detail even when no separate status image or value exists.
                let state = String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !state.isEmpty {
                    rowIdentities[primary.path] = visibleName
                    namedStates[primary.path] = state
                }
            }
            for image in children where image.attributes.role == "AXImage"
                && Set(image.attributes.actions).intersection(activationActions).isSubset(of: Set(primary.attributes.actions)) {
                controls.removeValue(forKey: image.path)
            }
        }
        var controlNames: [[Int]: String] = [:]
        for node in ordered where controls[node.path] != nil {
            if let label = controlLabel(node) { controlNames[node.path] = label }
            else if let name = unnamedName(node) { controlNames[node.path] = name }
            else { controls.removeValue(forKey: node.path) }
        }
        // Contained activations of one label are aliases; equal independent sibling controls remain distinct.
        for node in ordered where controls[node.path] != nil && labelOwners.contains(node.attributes.role) {
            guard let owner = ancestors(node.path).first(where: {
                controls[$0.path] != nil && labelOwners.contains($0.attributes.role)
            }), same(controlLabel(node), controlLabel(owner)),
                  !Set(node.attributes.actions).intersection(activationActions).isEmpty,
                  Set(node.attributes.actions).isSubset(of: Set(owner.attributes.actions)),
                  descendants(node).allSatisfy({ ["AXGroup", "AXStaticText", "AXImage"].contains($0.attributes.role) }) else { continue }
            controls.removeValue(forKey: node.path)
        }
        func documentName(_ area: MacAXNode) -> String {
            func sectionText(_ text: String?) -> String? {
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !text.allSatisfy({ $0.isNumber || $0.isWhitespace }) else { return nil }
                return text
            }
            // Preserve useful document names; derive unnamed sections structurally rather than from numeric frame ids or lexical guesses.
            let editors = descendants(area).filter {
                $0.attributes.role == "AXDocument" || structuredDocuments.contains($0.path) || aggregateDocuments.contains($0.path)
            }
            let titleNamesEditor = editors.contains { same(words[area.path]?.title, words[$0.path]?.title) }
            if let title = sectionText(words[area.path]?.title), !same(title, windowTitle), !titleNamesEditor {
                let components = title.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if components.count < 2 || Set(components).count > 1 { return title }
            }
            let ownDocument = descendants(area).filter { child in
                child.attributes.role != "AXWebArea"
                    && ancestors(child.path).first(where: { $0.attributes.role == "AXWebArea" })?.path == area.path
            }
            let contentTitle = ownDocument.first(where: { $0.attributes.role == "AXHeading" }).flatMap(headingText)
                ?? editors.compactMap { words[$0.path]?.value?.components(separatedBy: .newlines).first(where: readable) }.first
            if titleNamesEditor, let title = sectionText(words[area.path]?.title),
               contentTitle.map({ names(title, owner: $0) }) == true {
                // A title that names its document heading is already meaningful.
                return title
            }
            if let contentTitle {
                // Find a full title through its document heading in the nearest pane, never through app or generic-title word lists.
                for scope in ancestors(area.path) {
                    let candidates = descendants(scope).filter {
                        ["AXWebArea", "AXDocument", "AXButton", "AXPopUpButton"].contains($0.attributes.role)
                            && !($0.path.starts(with: area.path))
                    }.compactMap { candidate -> String? in
                        guard let title = words[candidate.path]?.title, !title.contains("\n"),
                              let range = title.range(of: contentTitle) else { return nil }
                        let prefix = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                        guard prefix.isEmpty || prefix.last.map({ ",|·:".contains($0) }) == true else { return nil }
                        return String(title[range.lowerBound...])
                    }
                    let distinct = Set(candidates)
                    if distinct.count == 1, let title = distinct.first { return title }
                    if !distinct.isEmpty { break }
                }
            }
            if titleNamesEditor, let enclosing = ancestors(area.path).first(where: {
                $0.attributes.role == "AXWebArea" && sectionText(words[$0.path]?.title) != nil
                    && !same(words[$0.path]?.title, words[area.path]?.title)
            }), let title = sectionText(words[enclosing.path]?.title) { return title }
            for heading in ownDocument where heading.attributes.role == "AXHeading" {
                if let text = sectionText(headingText(heading)) {
                    return text
                }
            }
            if let landmark = ownDocument.first(where: {
                MacPerceptionCompiler.landmarkKinds[$0.attributes.role] != nil && sectionText(words[$0.path]?.title) != nil
            }), let title = words[landmark.path]?.title { return title }
            if let text = ownDocument.first(where: {
                $0.attributes.role == "AXStaticText" && sectionText(words[$0.path]?.value ?? words[$0.path]?.title) != nil
                    && !ancestors($0.path).prefix(while: { $0.path != area.path }).contains { controls[$0.path] != nil }
            })
                .flatMap({ words[$0.path]?.value ?? words[$0.path]?.title }) {
                return text.components(separatedBy: .newlines).first { !$0.isEmpty } ?? text
            }
            if let landmark = ownDocument.first(where: { MacPerceptionCompiler.landmarkKinds[$0.attributes.role] != nil }),
               let kind = MacPerceptionCompiler.landmarkKinds[landmark.attributes.role] { return kind.capitalized }
            return "Page \(pageNumber)"
        }
        let documentTitles = Dictionary(webAreas.map { ($0.path, documentName($0)) }, uniquingKeysWith: { first, _ in first })
        for editor in ordered where editor.attributes.role == "AXDocument"
            || structuredDocuments.contains(editor.path) || aggregateDocuments.contains(editor.path) {
            if let area = ancestors(editor.path).first(where: { $0.attributes.role == "AXWebArea" }),
               let title = documentTitles[area.path] {
                captions[editor.path] = title
                if controls[editor.path] != nil { controlNames[editor.path] = title }
            } else if let heading = ancestors(editor.path).compactMap({ scope in
                descendants(scope).first(where: { $0.attributes.role == "AXHeading" }).flatMap(headingText)
            }).first {
                captions[editor.path] = heading
                if controls[editor.path] != nil { controlNames[editor.path] = heading }
            }
        }
        func rowStates(_ node: MacAXNode) -> [String] {
            guard ["AXButton", "AXLink"].contains(node.attributes.role) else { return [] }
            let label = controlLabel(node)
            var states = descendants(node).filter { child in
                guard ["AXImage", "AXGroup"].contains(child.attributes.role), controls[child.path] == nil else { return false }
                if child.attributes.role == "AXImage" || staticRuns(child).isEmpty { return true }
                // Related actions distinguish a group’s visible status from the item’s identity.
                guard let related = rowRelatedNames[node.path], let state = ownName(child),
                      label.map({ names($0, owner: state) }) == true else { return false }
                return related.allSatisfy { !names($0, owner: state) }
            }.compactMap(ownName).filter { !same($0, label) }
            if let state = namedStates[node.path] { states.append(state) }
            if let state = controls[node.path]?.state { states.append(state) }
            if !node.attributes.valueIsHelp, let value = display(controls[node.path]?.valueJSON), !same(value, label) { states.append(value) }
            return states
        }
        func identity(_ node: MacAXNode) -> String {
            if let name = rowIdentities[node.path] { return name }
            var name = controlNames[node.path] ?? MacScreenRender.kindName(role: node.attributes.role)
            let states = rowStates(node)
            if node.attributes.role == "AXLink" { name = name.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            guard !states.isEmpty else { return name }
            for state in states {
                // Strip only AX-published statuses at word boundaries, including multiple leading or trailing states.
                let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: state) + "(?![\\p{L}\\p{N}])"
                name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            let nameParts = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·,:;–—-()[]"))
            return nameParts.isEmpty ? controlNames[node.path] ?? name : nameParts
        }
        func controlRow(_ node: MacAXNode, inlineName: String? = nil, extraDetails: [String] = [], related: [MacAXNode] = [],
            includeValue: Bool = true) throws -> String {
            guard let control = controls[node.path] else { return "" }
            let a = node.attributes
            let kind = MacScreenRender.kindName(role: a.role)
            let label = controlLabel(node)
            let name = identity(node)
            var details = extraDetails + rowStates(node)
            if includeValue, !a.valueIsHelp, let value = display(control.valueJSON), !same(value, label) { details.append(value) }
            if let state = control.state { details.append(state) }
            if control.enabled == false { details.append("disabled") }
            if control.enabled == nil { details.append("enabled state unavailable") }
            if control.selected == true { details.append("selected") }
            if percept.focus?.path == node.path { details.append("focused") }
            if control.secret { details.append("secure") }
            var target: [String: JSONValue] = ["app": .string(bundle), "frame_id": .string(frameID),
                "handle": .string(control.handle)]
            var verbs = control.enabled == true ? SenseScreenThings.verbs(role: a.role, actions: a.actions,
                settable: SenseScreenThings.editableRoles.contains(a.role) ? settableAttributes(node) : []) : []
            if control.enabled == true, a.actions.contains("AXOpen") {
                verbs.insert("open", at: a.actions.contains("AXPress") ? 1 : 0)
            }
            verbs = MacFourVerbs.offeredVerbs(verbs)
            var activations: [String: JSONValue] = [:]
            // Print each related action’s own handle so acts address exactly what the page shows.
            var printedVerbs = verbs
            for child in related {
                guard let action = controls[child.path], let label = controlLabel(child) else { continue }
                if action.enabled != true {
                    details.append(label + (action.enabled == false ? ": disabled" : ": enabled state unavailable"))
                    continue
                }
                // AX supplies verb words; execution retains exact frame and handle binding rather than looking text up again.
                let verb = inline(label)
                let activation = child.attributes.actions.contains("AXPress") ? "press"
                    : child.attributes.actions.contains("AXOpen") ? "open" : nil
                guard let activation, !verbs.contains(verb), activations[verb] == nil else { continue }
                activations[verb] = .object(["handle": .string(action.handle), "verb": .string(activation)])
                verbs.append(verb)
                printedVerbs.append(verb + (activation == "open" ? " (open)" : "") + " [\(action.handle)]")
            }
            if !activations.isEmpty { target["__sense_screen_activations"] = .object(activations) }
            let address = try JSONValue.object(target).serialize(pretty: false)
            var seenDetails: Set<String> = []
            details = details.filter { seenDetails.insert(inline($0).lowercased()).inserted }
            let detail = details.isEmpty ? nil : details.joined(separator: "; ")
            things.append(NativeThing(name: name, kind: kind, address: address, detail: detail, verbs: verbs))
            let printedName = inlineName ?? (name + (label == nil ? "" : " (\(kind))"))
            return (printedName.isEmpty ? "" : printedName + " ") + "[\(SenseScreenThings.printed(address))]"
                + (detail.map { ": " + $0 } ?? "")
                + (printedVerbs.isEmpty ? "" : " · " + printedVerbs.joined(separator: ", "))
        }

        var statusGroups: Set<String> = []
        let rowParents = Dictionary(grouping: compositeRows.keys) { Array($0.dropLast()) }
        let itemSections = Set(rowParents.filter { $0.value.count > 1 }.map(\.key))
        func sectionName(_ node: MacAXNode) -> String? {
            Self.sectionName(node.attributes, name: ownName(node))
                ?? (itemSections.contains(node.path) ? ownName(node) ?? "Items" : nil)
        }
        // A card’s one-heading container owns preceding badges too, despite AX order.
        var cardHeadings: [[Int]: MacAXNode] = [:]
        for image in ordered where image.attributes.role == "AXImage" {
            for scope in ancestors(image.path) where scope.attributes.role == "AXGroup" {
                let children = descendants(scope)
                let headings = children.filter { $0.attributes.role == "AXHeading" }
                if headings.count > 1 { break }
                guard let heading = headings.first, headingText(heading) != nil,
                      children.contains(where: { checkableRoles.contains($0.attributes.role) }),
                      MacPerceptionCompiler.pathIsBefore(image.path, heading.path) else { continue }
                cardHeadings[scope.path] = heading
                break
            }
        }
        for node in readingOrder {
            guard !node.path.isEmpty, !consumed.contains(node.path) else { continue }
            let a = node.attributes
            let own = words[node.path]
            // Live regions are text; drop only empty or duplicate wrappers while preserving visible descendants.
            if a.liveRegion {
                if let text = own?.value ?? own?.title, readable(text) {
                    let leaves = descendants(node).filter { child in
                        controls[child.path] == nil && ownName(child) != nil
                            && !descendants(child).contains { ownName($0) != nil }
                    }.compactMap(ownName)
                    if !leaves.contains(where: { same(text, $0) }),
                       !same(text, leaves.joined(separator: " ")), !same(text, leaves.joined()) {
                        append(text, at: node.path)
                    }
                }
                continue
            }
            if let heading = cardHeadings[node.path], let text = headingText(heading) {
                append("\n### " + text, at: node.path, heading: true)
                consumed.insert(heading.path)
                consumed.formUnion(staticRuns(heading).map(\.path))
            }
            if structuredDocuments.contains(node.path) { continue }
            if aggregateDocuments.contains(node.path) {
                // Partial or different child readings cannot replace the complete aggregate without a visible boundary.
                if controls[node.path] != nil {
                    append(try controlRow(node, includeValue: false), at: node.path)
                }
                let body = own?.value ?? ""
                var cursor = body.startIndex
                var searchCursor = cursor
                var inlineLinks: [(node: MacAXNode, range: Range<String.Index>)] = []
                var unplaced: [MacAXNode] = []
                func appendAggregate(until end: String.Index) throws {
                    // Without inline links, preserve the aggregate reading; link handles belong at line ends.
                    if inlineLinks.isEmpty {
                        let text = String(body[cursor..<end]).trimmingCharacters(in: .newlines)
                        if !text.isEmpty { append(text, at: node.path) }
                    } else {
                        var lineStart = cursor
                        var renderedLines: [String] = []
                        while lineStart < end {
                            var lineEnd = body.range(of: "\n", range: lineStart..<end)?.lowerBound ?? end
                            // Wrapped AX captions remain one link caption.
                            while let crossing = inlineLinks.first(where: {
                                $0.range.lowerBound < lineEnd && $0.range.upperBound > lineEnd
                            }) {
                                lineEnd = body.range(of: "\n", range: crossing.range.upperBound..<end)?.lowerBound ?? end
                            }
                            let links = inlineLinks.filter {
                                $0.range.lowerBound >= lineStart && $0.range.upperBound <= lineEnd
                            }
                            var text = ""
                            var position = lineStart
                            var handles: [String] = []
                            for link in links {
                                let last = body.index(before: link.range.upperBound)
                                if body[last] == "," {
                                    text += body[position..<last] + " (link),"
                                } else {
                                    text += body[position..<link.range.upperBound] + " (link)"
                                }
                                position = link.range.upperBound
                                handles.append(try controlRow(link.node, inlineName: ""))
                            }
                            text += body[position..<lineEnd]
                            if !handles.isEmpty { text += " " + handles.joined(separator: " · ") }
                            renderedLines.append(text)
                            lineStart = lineEnd < end ? body.index(after: lineEnd) : end
                        }
                        let text = renderedLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                        if !text.isEmpty { append(text, at: node.path) }
                    }
                    inlineLinks.removeAll()
                    cursor = end
                }
                // Replace owned captions with their control rows; links instead stay inline so sentences remain whole.
                for child in descendants(node) where controls[child.path] != nil {
                    guard let label = controlLabel(child) else { unplaced.append(child); continue }
                    let pattern = label.split(whereSeparator: \.isWhitespace)
                        .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
                    guard !pattern.isEmpty, let range = body.range(of: pattern, options: .regularExpression, range: searchCursor..<body.endIndex) else {
                        unplaced.append(child)
                        continue
                    }
                    searchCursor = range.upperBound
                    if child.attributes.role == "AXLink" {
                        inlineLinks.append((child, range))
                        continue
                    }
                    try appendAggregate(until: range.lowerBound)
                    append(try controlRow(child), at: child.path)
                    cursor = range.upperBound
                }
                try appendAggregate(until: body.endIndex)
                for child in unplaced { append(try controlRow(child), at: child.path) }
                append("raw view · accessibility · The editor value was served once; its structured children do not expose the same complete text.",
                    at: node.path)
                consumed.formUnion(descendants(node).map(\.path))
                continue
            }
            if !webAreas.isEmpty, !inPage(node), !shellStarted {
                append("\n## Window controls", at: [], heading: true)
                shellStarted = true
            }
            if a.role == "AXWebArea" {
                pageNumber += 1
                append("\n## " + (documentTitles[node.path] ?? documentName(node)), at: node.path, heading: true)
                continue
            }
            if let summary = a.listSummary { append(summary, at: node.path) }
            if let section = sectionName(node), controls[node.path] == nil {
                append("\n## " + section, at: node.path, heading: true)
                continue
            }
            if let primary = compositeRows[node.path] {
                let states = descendants(node).filter { $0.attributes.role == "AXImage" && controls[$0.path] == nil }
                    .compactMap(ownName).map { $0.lowercased() }
                let related = descendants(node).filter { controls[$0.path] != nil && $0.path != primary.path }
                let row = try controlRow(primary, extraDetails: Array(NSOrderedSet(array: states).array.compactMap { $0 as? String }), related: related)
                consumed.formUnion(descendants(node).map(\.path))
                append(row, at: node.path)
                continue
            }
            // Keep exact link addresses inside their paragraphs; layout groups need line geometry or boundary whitespace to join runs.
            let subtree = descendants(node)
            if ["AXGroup", "AXParagraph", "AXStaticText"].contains(a.role), controls[node.path] == nil,
               !subtree.contains(where: { !["AXGroup", "AXStaticText", "AXLink"].contains($0.attributes.role) }),
               !subtree.contains(where: { controls[$0.path] != nil && !["AXLink", "AXStaticText"].contains($0.attributes.role) }) {
                let units = subtree.filter { child in
                    if child.attributes.role == "AXLink" { return controls[child.path] != nil }
                    return child.attributes.role == "AXStaticText" && ownName(child) != nil
                        && !descendants(child).contains(where: { $0.attributes.role == "AXStaticText" || $0.attributes.role == "AXLink" })
                        && !ancestors(child.path).prefix(while: { $0.path != node.path }).contains(where: { $0.attributes.role == "AXLink" })
                }
                let frames = units.compactMap { $0.attributes.frame }
                let oneLine = frames.count == units.count && frames.first.map { first in
                    frames.allSatisfy { $0.w > 0 && $0.h > 0 && $0.y < first.y + first.h && $0.y + $0.h > first.y }
                } == true
                let hasRunBoundaries = units.indices.dropLast().allSatisfy { index in
                    let left = words[units[index].path]?.value ?? words[units[index].path]?.title ?? ""
                    let right = words[units[index + 1].path]?.value ?? words[units[index + 1].path]?.title ?? ""
                    return left.last?.isWhitespace == true || right.first?.isWhitespace == true
                }
                if units.count > 1, units.contains(where: { $0.attributes.role == "AXLink" }),
                   a.role == "AXParagraph" || oneLine || hasRunBoundaries {
                    var parts: [String] = []
                    var handles: [String] = []
                    for unit in units {
                        if unit.attributes.role == "AXLink" {
                            let name = identity(unit)
                            let comma = controlLabel(unit)?.hasSuffix(",") == true ? "," : ""
                            parts.append(name + " (link)" + comma)
                            handles.append(try controlRow(unit, inlineName: ""))
                        }
                        else if let text = ownName(unit), !representedByControl(text, path: unit.path) { parts.append(text) }
                    }
                    append(parts.joined(separator: " ") + " " + handles.joined(separator: " · "), at: node.path)
                    consumed.formUnion(subtree.map(\.path))
                    continue
                }
            }
            if controls[node.path] != nil {
                consumed.formUnion(captionPaths[node.path] ?? [])
                // Fold repeated composite names into one row while retaining independently named child actions and their original handles.
                let composite = labelOwners.contains(a.role)
                let children = composite ? descendants(node).filter {
                    controls[$0.path] != nil && !ancestors($0.path).prefix(while: { $0.path != node.path })
                        .contains { $0.attributes.role == "AXWebArea" }
                } : []
                let states = composite ? descendants(node).filter {
                    $0.attributes.role == "AXImage" && controls[$0.path] == nil
                }.compactMap(ownName).map { $0.lowercased() } : []
                var row = try controlRow(node, extraDetails: Array(NSOrderedSet(array: states).array.compactMap { $0 as? String }))
                for child in children {
                    consumed.insert(child.path)
                    // Print the item identity once while retaining every underlying action in the row and native index.
                    let repeatsOwner = same(controlLabel(child), controlLabel(node))
                    let inlineName = repeatsOwner ? "" : nil
                    row += " · " + (try controlRow(child, inlineName: inlineName))
                }
                for child in descendants(node) where !ancestors(child.path).prefix(while: { $0.path != node.path })
                    .contains(where: { $0.attributes.role == "AXWebArea" }) {
                    if controls[child.path] == nil,
                       let text = words[child.path]?.value ?? words[child.path]?.title,
                       same(text, controlLabel(node)) || children.contains(where: { same(text, controlLabel($0)) })
                        || staticRuns(node).contains(where: { $0.path == child.path }) || child.attributes.role == "AXImage" {
                        consumed.insert(child.path)
                    }
                }
                append(row, at: node.path)
                continue
            }
            // Use styled runs or shared-line geometry to join labels without merging unrelated paragraphs or columns.
            let runs = staticRuns(node)
            let runFrames = runs.compactMap { $0.attributes.frame }
            let oneLine = runFrames.count == runs.count && runFrames.first.map { first in
                runFrames.allSatisfy { $0.w > 0 && $0.h > 0 && $0.y < first.y + first.h && $0.y + $0.h > first.y }
            } == true
            if ["AXGroup", "AXStaticText"].contains(a.role), runs.count > 1,
               (a.role == "AXStaticText" || oneLine),
               !descendants(node).contains(where: { controls[$0.path] != nil || ["AXHeading", "AXWebArea"].contains($0.attributes.role) }),
               let text = runText(runs) {
                append(text, at: node.path)
                consumed.formUnion(descendants(node).map(\.path))
                continue
            }
            if a.role == "AXHeading" {
                let descendants = descendants(node).filter { child in
                    child.attributes.role == "AXStaticText"
                        && !ancestors(child.path).contains { controls[$0.path] != nil }
                        && !ancestors(child.path).prefix(while: { $0.path != node.path })
                            .contains { $0.attributes.role == "AXWebArea" }
                }
                let parts = descendants.compactMap { words[$0.path]?.value ?? words[$0.path]?.title }
                if let heading = headingText(node) {
                    let section = ancestors(node.path).compactMap { ancestor in
                        sectionName(ancestor) ?? documentTitles[ancestor.path]
                    }.first
                    if !same(heading, section) { append("\n### " + heading, at: node.path, heading: true) }
                    for child in descendants {
                        if let text = words[child.path]?.value ?? words[child.path]?.title,
                           same(text, heading) || same(parts.joined(separator: " "), heading) { consumed.insert(child.path) }
                    }
                    // Headings own every run used to name them, including aggregate aliases.
                    consumed.formUnion(staticRuns(node).map(\.path))
                }
                continue
            }
            // Fold only status-shaped wrappers, never repeated prose or independently actionable equal captions.
            if a.role == "AXGroup", let name = ownName(node), staticRuns(node).count <= 1,
               !descendants(node).contains(where: { controls[$0.path] != nil || !["AXGroup", "AXImage", "AXStaticText"].contains($0.attributes.role) }),
               descendants(node).compactMap(ownName).allSatisfy({ same($0, name) }) {
                let scope = ancestors(node.path).first { $0.attributes.role == "AXWebArea" || sectionName($0) != nil }?.path ?? []
                let identity: String
                if let frame = node.attributes.frame, frame.w > 0, frame.h > 0 {
                    identity = [frame.x, frame.y, frame.w, frame.h].map { String($0) }.joined(separator: ",")
                } else { identity = "path:" + node.path.map(String.init).joined(separator: ".") }
                let key = "\(scope):\(name):\(identity)"
                if statusGroups.insert(key).inserted { append(name, at: node.path) }
                consumed.formUnion(descendants(node).map(\.path))
                continue
            }
            // Repeated landmark labels do not make layout wrappers into rows; their content remains readable below.
            if a.role == "AXGroup", controls[node.path] == nil, own?.value == nil { continue }
            guard !["AXListMarker", "AXSeparator", "AXSplitter"].contains(a.role),
                  !a.liveRegion, let text = own?.value ?? own?.title, readable(text), text != a.role else { continue }
            if captionPaths.values.contains(where: { $0.contains(node.path) }) { continue }
            if same(text, windowTitle) || representedByControl(text, path: node.path) { continue }
            // Aggregate and leaf text within one subtree are one reading; equal sentences in separate paragraphs remain distinct.
            let leaves = subtree.filter { child in
                guard (words[child.path]?.value ?? words[child.path]?.title) != nil else { return false }
                return !descendants(child).contains { (words[$0.path]?.value ?? words[$0.path]?.title) != nil }
            }
            let descendantWords = leaves.compactMap { words[$0.path]?.value ?? words[$0.path]?.title }
            // A duplicate of one leaf cannot own its unmatched siblings.
            if descendantWords.contains(where: { same(text, $0) }) { continue }
            let aggregate = !descendantWords.isEmpty
                && (same(text, descendantWords.joined(separator: " ")) || same(text, descendantWords.joined()))
            if aggregate {
                if subtree.contains(where: { controls[$0.path] != nil || $0.attributes.role == "AXWebArea" }) { continue }
                // Keep complete paragraphs and styled runs together rather than repeating a leaf-text dump.
                consumed.formUnion(subtree.map(\.path))
            }
            let listItem = a.role == "AXListItem" || ancestors(node.path).contains { $0.attributes.role == "AXListItem" }
            append((listItem ? "- " : "") + text, at: node.path)
        }
        // State frame ownership once so every handle has an unambiguous source.
        lines[0] += "\n" + actLine(frameID: frameID)
        blocks[0] = .object(["text": .string(lines[0]), "path": .array([])])
        if snapshot.truncated {
            append("raw view · accessibility · The source tree is incomplete: " + snapshot.truncationReasons.joined(separator: ", "), at: [])
        }
        // Drop only empty generated sections; preserve specific headings and all app-authored document headings.
        func generated(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0.isWhitespace })
            return trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ")
        }
        let retained = lines.indices.filter { index in
            guard headingLines.contains(index), generated(lines[index]) else { return true }
            guard let next = lines.indices.dropFirst(index + 1).first(where: {
                !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { return false }
            return !(headingLines.contains(next) && generated(lines[next]))
        }
        return Compilation(page: NativePage(corner: corner,
            address: try JSONValue.object(["app": .string(bundle), "__sense_screen_frame": .string(frameID)]).serialize(pretty: false),
            title: appName, text: retained.map { lines[$0] }.joined(separator: "\n"), things: things),
            blocks: .array(retained.map { blocks[$0] }))
    }

    /// Instruction and provenance lines are scaffolding; exclude both when wait reads content.
    static func actLine(frameID: String) -> String {
        "Act: act {frame_id: \"\(frameID)\", handle: \"<an item's [handle]>\", verb: \"<one of its verbs>\"}."
            + " A verb printed with its own [handle] acts through that handle: press, or the verb in parentheses."
    }

    /// Unlabeled fields still need a usable natural address.
    private static func unnamedInputKind(_ role: String) -> String? {
        switch role {
        case "AXTextField", "AXTextArea": "text field"
        case "AXSearchField": "search field"
        case "AXSecureTextField": "secure field"
        case "AXComboBox": "combo box"
        case "AXCheckBox": "checkbox"
        case "AXRadioButton": "radio button"
        case "AXSlider": "slider"
        case "AXIncrementor": "stepper"
        case "AXPopUpButton": "pop-up menu"
        case "AXDateField": "date field"
        default: nil
        }
    }

    private static func display(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text.isEmpty ? nil : text }
        if case .object(let fields)? = value, fields["redacted"] == .bool(true) { return "⟨redacted⟩" }
        return nil
    }
}
