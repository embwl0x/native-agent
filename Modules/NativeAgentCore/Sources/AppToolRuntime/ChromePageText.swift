import Foundation
import NativeAgentShared
import NativeAgentCore
import ChatTurnContracts
import AgentWorkspace
import PersistenceCore
import CryptoKit
import Senses
import MacControl
import Privacy
import Research
// Blueprint: | `ChromePageText.swift` | `ChromePageText` enum; one `VisiblePageText` shares rendered text and addressable rows with the mirror and envelope; ordered inline prose with link proofs, section-named continuation headers, `project`, `rows`, page and folded-control `next`; empty image-document reads point to chrome.look; `readDocument` adds a bounded independent HTTP PDF transcript explicitly unverified against Chrome beside its displayed picture; `contentVersion` shared by the envelope and Chrome news without rendering |

/// Chrome's ordered prose and action rows, with the same receipt on raw and
/// sense-served reads. Continuations name positions in the rendered page.
enum ChromePageText {
    struct VisiblePageText {
        let text: String?
        let rows: [ChromePageMirror.Row]
        let hasVisibleRows: Bool
    }

    static func project(_ snapshot: JSONValue) -> VisiblePageText {
        let nodes: [JSONValue] = if case .object(let page) = snapshot, case .array(let nodes)? = page["nodes"] { nodes } else { [] }
        let visible = renderedRows(nodes)
        let rows = rows(nodes, visible: visible)
        return VisiblePageText(text: render(snapshot, visible: visible, rows: rows), rows: rows, hasVisibleRows: !visible.isEmpty)
    }

    /// Chrome's reader waited for the tab to load and its deadline passed first.
    static func loadUnfinished(_ snapshot: JSONValue) -> Bool {
        guard case .object(let page) = snapshot, case .object(let rendering)? = page["rendering"] else { return false }
        return rendering["loaded"] == .bool(false)
    }

    /// An independent HTTP read retains its own coverage; it cannot prove
    /// which PDF Chrome displayed with its cookies and authentication.
    static func readDocument(_ snapshot: JSONValue) async throws -> JSONValue {
        guard case .object(var page) = snapshot, case .object(var document)? = page["document"],
              document["kind"] == .string("pdf") else { return snapshot }
        document["status"] = .string("failed")
        document["text"] = .string("")
        document["source"] = .string("http_pdf")
        document["chrome_document_verified"] = .bool(false)
        do {
            guard let address = page["url"]?.stringValue, let url = URL(string: address),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw SenseFailure(code: "unsupported_document_url", message: "This PDF has no HTTP(S) document address to read.")
            }
            let response = try await URLSessionResearchHTTPClient().getBounded(url: url, timeout: 20,
                maxBytes: MacDocumentRead.maxFileBytes)
            document["read_at"] = .string(NativeTimestampFormat.plainZulu(Date()))
            document["final_url"] = response.finalURL.map { .string($0.absoluteString) } ?? .string(address)
            document["http_status"] = .int(Int64(response.status))
            document["retained_body_bytes"] = .int(Int64(response.body.count))
            document["body_truncated"] = .bool(response.truncated)
            guard (200...299).contains(response.status) else {
                throw SenseFailure(code: "pdf_http_failed", message: "The PDF read returned HTTP \(response.status); no document text was read.")
            }
            let extraction = response.truncated ? .failure(MacDocumentRead.ExtractionFailure.fileTooLarge)
                : MacDocumentRead.extract(data: response.body, kind: .pdf)
            switch extraction {
            case .success(let extracted):
                document["text"] = .string(NativeAppSecretRedactor.redactText(extracted.text))
                document["status"] = .string("unverified")
                document["http_read_status"] = .string(extracted.truncated ? "partial" : "completed")
                document["reason"] = .string("Independent HTTP PDF text; Chrome's displayed document has not been verified. Chrome cookies and authentication were not used.")
                document["pages"] = extracted.pages.map { .int(Int64($0)) } ?? .null
                document["text_truncated"] = .bool(extracted.truncated)
            case .failure(let failure):
                document["error"] = .string(failure.rawValue)
                document["reason"] = .string(MacDocumentRead.words(for: failure, path: url.path))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            document["error"] = .string((error as? SenseFailure)?.code ?? "pdf_read_failed")
            document["reason"] = .string(NativeAppSecretRedactor.redactText(error.localizedDescription))
        }
        page["document"] = .object(document)
        return .object(page)
    }

    private static func render(_ snapshot: JSONValue, visible: [Line], rows mirrorRows: [ChromePageMirror.Row]) -> String? {
        guard case .object(let page) = snapshot else { return nil }
        if case .object(let document)? = page["document"], document["kind"] == .string("pdf") {
            let content = document["text"]?.stringValue ?? ""
            let status = content.isEmpty ? "failed" : document["status"]?.stringValue ?? "partial"
            return safe(page["url"]?.stringValue ?? "") + "\nPDF read: " + status + "\n\n"
                + safe(document["reason"]?.stringValue ?? "The PDF document text was not read.")
                + (content.isEmpty ? "" : "\n\n" + UntrustedText.neutralized(content))
        }
        guard page["snapshotId"]?.stringValue != nil, case .array(let nodes)? = page["nodes"] else { return nil }
        // Prose uses the home's markup defuse. Code is quoted behind a fence
        // longer than any delimiter in its source, preserving its syntax.
        let title = safe(page["title"]?.stringValue ?? "")
        let url = safe(page["url"]?.stringValue ?? "")
        let fromViewport: Bool = if case .object(let reading)? = page["reading"] { reading["fromViewport"] == .bool(true) } else { false }
        let byNode = Dictionary(mirrorRows.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        var head = [(title.isEmpty ? "" : title + " — ") + url]
        var where_: [String] = []
        if case .object(let reading)? = page["reading"], case .array(let sections)? = reading["sections"] {
            let headings = visible.filter(\.heading)
            let topLevel = headings.map(\.level).filter { $0 > 1 }.min() ?? 1
            let visibleHeadings = Set(headings.filter { $0.level <= topLevel }.map { safe($0.original) })
            let capturedHeadings = Set(nodes.compactMap { value -> String? in
                guard case .object(let node) = value, node["role"]?.stringValue == "heading" else { return nil }
                return safe(node["name"]?.stringValue ?? node["text"]?.stringValue ?? "")
            })
            let names = sections.compactMap { $0.stringValue.map(safe) }
                .filter { visibleHeadings.contains($0) || !capturedHeadings.contains($0) }.prefix(8)
            if !names.isEmpty { where_.append("Reading: " + names.joined(separator: " · ")) }
        }
        if fromViewport { where_.append("reading from the current viewport outward") }
        if mainContent(page) {
            where_.append(Self.mainContentFound(page) ? "main content (scope page adds the site's nav)"
                : "no main region declared: reading the page without its navigation (scope page adds it)")
        }
        head.append(where_.joined(separator: " · "))
        if loadUnfinished(snapshot) {
            head.append("Still loading: Chrome had not finished loading this page when the read's deadline passed, so this read may be partial. Read it again for the rest.")
        }
        if case .object(let reading)? = page["reading"], reading["pageMoved"] == .bool(true) {
            head.append("The page moved while reading; this is what was read.")
        }

        var rows = lines(visible)
        var foot: [String] = []
        if rows.isEmpty, case .object(let summary)? = page["summary"], let prose = summary["text"]?.stringValue {
            rows.append(safe(prose))
        }
        if rows.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            rows = ["No readable content in this window."]
        }
        if case .object(let summary)? = page["summary"], summary["truncated"] == .bool(true) {
            foot.append("Read limited: " + strings(summary["truncationReasons"]).map(safe).joined(separator: ", "))
        }
        if case .object(let cursor)? = page["readMore"], let next = next(page) {
            foot.append("Folded: " + safe(cursor["name"]?.stringValue ?? "Remaining page"))
            if let address = next["more"]?.stringValue {
                foot.append("More: " + address + " · app {page: \"site:\(URL(string: url)?.host ?? "")\", item: \"" + address + "\"}")
            }
        } else if page["readMore"] != nil, page["readMore"] != .null {
            foot.append("Folded page is unavailable: Chrome's reader supplied no readable continuation place. raw view · Chrome continuation metadata is incomplete.")
        }
        for case .object(let node) in nodes {
            guard let cursor = node["more"], cursor != .null else { continue }
            guard let args = next(page, cursor: cursor), let address = args["more"]?.stringValue else {
                foot.append("Folded control is unavailable: Chrome's reader supplied no readable continuation place. raw view · Chrome continuation metadata is incomplete.")
                continue
            }
            let id = node["nodeId"]?.stringValue ?? ""
            let row = byNode[id]?.number ?? safe(node["name"]?.stringValue ?? "control")
            foot.append("Folded: remaining content of row " + row)
            foot.append("More for row " + row + ": " + address + " · app {page: \"site:\(URL(string: url)?.host ?? "")\", item: \"" + address + "\"}")
        }
        if case .array(let frames)? = page["frames"] {
            let closed = frames.filter { if case .object(let f) = $0 { return f["accessible"] == .bool(false) }; return false }.count
            if closed > 0 { foot.append("\(closed) embedded frame(s) could not be read.") }
        }
        foot.append("Act with node_id: a row number as a string or its label, e.g. chrome.click{node_id: \"73\"}. chrome.fill{fields, submit} · chrome.select{node_id, values} · chrome.scroll{delta_y}; each returns the page.")
        return (head + [""] + rows + [""] + foot).joined(separator: "\n")
    }

    static func next(_ page: [String: JSONValue], cursor: JSONValue? = nil) -> [String: JSONValue]? {
        let value = cursor ?? page["readMore"]
        guard let value, let address = SenseNativePages.chromeContinuation(page, cursor: value,
            scope: ChatToolSessionContext.verifiedSessionId ?? "") else { return nil }
        var next: [String: JSONValue] = ["more": .string(address)]
        next["tab_id"] = page["tabId"]
        if case .object(let reading)? = page["reading"] { next["scope"] = reading["scope"] }
        return next
    }

    static func envelope(_ snapshot: JSONValue, rendered: String, projection: VisiblePageText) throws -> JSONValue {
        guard case .object(let page) = snapshot else { return .string(rendered) }
        let nodes: [JSONValue] = if case .array(let nodes)? = page["nodes"] { nodes } else { [] }
        let byNode = Dictionary(projection.rows.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        let elementMore: [JSONValue] = nodes.compactMap { value in
            guard case .object(let node) = value, let cursor = node["more"],
                  let args = next(page, cursor: cursor) else { return nil }
            let row = node["nodeId"]?.stringValue.flatMap { byNode[$0] }
            return .object(["node_id": row?.number.map(JSONValue.string) ?? row.map { .string($0.label) } ?? .null, "next": .object(args)])
        }
        var fields: [String: JSONValue] = ["ok": .bool(true), "text": .string(rendered),
            "url": page["url"] ?? .null, "title": page["title"] ?? .null,
            "snapshot_id": page["snapshotId"] ?? .null, "captured_at": page["capturedAt"] ?? .null,
            "bytes": .int(Int64(rendered.utf8.count)), "has_more": .bool(next(page) != nil || !elementMore.isEmpty)]
        if case .array? = page["nodes"] {
            let summary: [String: JSONValue] = if case .object(let summary)? = page["summary"] { summary } else { [:] }
            let hasContent = projection.hasVisibleRows || !(summary["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            fields["ok"] = .bool(hasContent)
            fields["status"] = .string(hasContent ? (summary["truncated"] == .bool(true) || loadUnfinished(snapshot) ? "partial" : "completed")
                : (next(page) != nil ? "partial" : "failed"))
            if !hasContent {
                fields["reason"] = .string("read_window_empty")
                if case .object(let document)? = page["document"], document["kind"] == .string("image") {
                    fields["next"] = .string("This tab is a picture: chrome.look shows it.")
                }
            }
            fields["truncated"] = summary["truncated"] ?? .bool(false)
            fields["truncation_reasons"] = summary["truncationReasons"] ?? .array([])
            if case .object(let reading)? = page["reading"] {
                fields["page_moved"] = reading["pageMoved"] ?? .bool(false)
            }
        }
        if !elementMore.isEmpty { fields["element_more"] = .array(elementMore) }
        fields["version"] = .string(try contentVersion(page))
        if fields["next"] == nil, let next = next(page) { fields["next"] = .object(next) }
        return .object(fields)
    }

    static func contentVersion(_ page: [String: JSONValue]) throws -> String {
        // The version describes captured content, not a newly minted receipt.
        let contentNodes: JSONValue
        if case .array(let nodes)? = page["nodes"] {
            contentNodes = .array(nodes.map { value in
                guard case .object(let node) = value else { return value }
                return .object(node.filter { !["elementIdentity", "bounds"].contains($0.key) })
            })
        } else { contentNodes = .null }
        let encoded = try JSONValue.object(["url": page["url"] ?? .null, "title": page["title"] ?? .null,
            "nodes": contentNodes, "readMore": page["readMore"] ?? .null,
            "document": page["document"] ?? .null]).serialize(pretty: false)
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The page's rows as the mirror keeps them, so a row can be named by its label.
    static func rows(_ snapshot: JSONValue) -> [ChromePageMirror.Row] {
        guard case .object(let page) = snapshot, case .array(let nodes)? = page["nodes"] else { return [] }
        return rows(nodes, visible: renderedRows(nodes))
    }

    private static func rows(_ nodes: [JSONValue], visible: [Line]) -> [ChromePageMirror.Row] {
        let numbers = Set(visible.map(\.number) + visible.flatMap { $0.references })
        return nodes.compactMap { value -> ChromePageMirror.Row? in
            guard case .object(let node) = value, let id = node["nodeId"]?.stringValue else { return nil }
            var options: [ChromePageMirror.Option] = []
            if case .object(let select)? = node["select"], case .array(let list)? = select["options"] {
                options = list.compactMap { item in
                    guard case .object(let option) = item, let raw = option["value"]?.stringValue else { return nil }
                    return .init(label: option["label"]?.stringValue ?? raw, value: raw)
                }
            }
            let (role, label) = roleAndLabel(node)
            let number = id.hasPrefix("n") ? String(id.dropFirst()) : id
            return .init(node: id, role: role, label: safe(label), acts: Set(strings(node["actions"])), options: options,
                         number: numbers.contains(number) ? number : nil)
        }
    }

    private static func roleAndLabel(_ node: [String: JSONValue]) -> (String, String) {
        if node["preformatted"] == .bool(true) { return ("code", node["text"]?.stringValue ?? "") }
        if node["time"] == .bool(true) { return ("text", safe(node["text"]?.stringValue ?? "")) }
        var role = safe(node["role"]?.stringValue ?? node["kind"]?.stringValue ?? "")
        if node["kind"]?.stringValue == "image" { role = "image" }
        if role == "other" || role.isEmpty { role = "text" }
        if role == "heading", let level = node["level"]?.numberValue(coercingStrings: false, finiteOnly: false) { role = "h\(Int(level))" }
        let name = safe(node["name"]?.stringValue ?? "")
        let body = safe(node["text"]?.stringValue ?? "")
        var label = name.isEmpty ? body : name
        if !body.isEmpty, body != label, !label.contains(body) {
            label = body.contains(label) ? body : label + " — " + body
        }
        if label.isEmpty, role == "link", let url = node["url"]?.stringValue { label = safe(url) }
        // Prose keeps a paragraph; a control's name stays short.
        return (role, label)
    }

    private struct Line {
        var number: String; var id: String; var role: String; var label: String
        var state: [String]; var acts: Bool; var references: Set<String>
        var original: String; var heading: Bool; var level: Int; var section: Int
        var rowPath: String?; var cellPath: String?
    }

    /// The rows as lines. Dropped: a read-only row with no word in it, or
    /// whose text is exactly its parent's (four levels up) or the row just
    /// kept ("York" under "New York" stays). Consecutive short text rows join
    /// one line under the first number.
    private static func lines(_ visible: [Line]) -> [String] {
        visible.map { line in
            if line.role == "code" {
                let fence = codeFence(line.label)
                return line.number + "  code\n" + fence + "\n" + line.label
                    + (line.label.hasSuffix("\n") ? "" : "\n") + fence
                    + (line.state.isEmpty ? "" : "  [" + line.state.joined(separator: "; ") + "]")
            }
            return String(repeating: " ", count: max(0, 3 - line.number.count)) + line.number + "  "
                + (line.role == "text" ? "" : line.role + " ") + line.label
                + (line.state.isEmpty ? "" : "  [" + line.state.joined(separator: "; ") + "]")
        }
    }

    private static func renderedRows(_ nodes: [JSONValue]) -> [Line] {
        var labels: [String: String] = [:], parents: [String: String] = [:], items: [Line] = []
        var pathIDs: [String: String] = [:]
        var byID: [String: [String: JSONValue]] = [:]
        var linkChildren: [String: [[String: JSONValue]]] = [:]
        for case .object(let node) in nodes {
            if let path = node["contentLinkPath"]?.stringValue,
               node["inline"] != .bool(true) || node["role"]?.stringValue == "heading",
               !safe(node["text"]?.stringValue ?? "").isEmpty {
                linkChildren[path, default: []].append(node)
            }
            guard let id = node["nodeId"]?.stringValue else { continue }
            byID[id] = node
            if let path = node["elementPath"]?.stringValue { pathIDs[path] = id }
            if let parent = node["parentNodeId"]?.stringValue { parents[id] = parent }
        }
        // A card's link belongs on its heading. Only fold the parent link
        // when the retained child blocks account for its entire visible text.
        var contentLinks: [String: String] = [:]
        for case .object(let link) in nodes where link["childTextName"] == .bool(true) {
            guard let id = link["nodeId"]?.stringValue, let path = link["elementPath"]?.stringValue else { continue }
            let children = linkChildren[path] ?? []
            let childIDs = Set(children.compactMap { $0["nodeId"]?.stringValue })
            let blocks = children.filter { child in
                var parent = child["parentNodeId"]?.stringValue
                while let key = parent, key != id {
                    if childIDs.contains(key) { return false }
                    parent = parents[key]
                }
                return true
            }
            guard !blocks.isEmpty, safe(blocks.compactMap { $0["text"]?.stringValue }.joined(separator: " ")) == safe(link["text"]?.stringValue ?? ""),
                  let target = (blocks.first { $0["role"]?.stringValue == "heading" } ?? blocks.first).flatMap({ $0["nodeId"]?.stringValue }) else { continue }
            contentLinks[id] = target
        }
        // Structure every article shares: a heading prints once. A named
        // region repeating a heading, and a box wrapping a heading (its text
        // is the heading plus controls like "[edit]"), are the same heading.
        var headingNames = Set<String>(), headingChild: [String: String] = [:], linkPaths = Set<String>()
        for case .object(let node) in nodes where node["role"]?.stringValue == "link" { if let path = node["elementPath"]?.stringValue { linkPaths.insert(path) } }
        for case .object(let node) in nodes where node["role"]?.stringValue == "heading" {
            let name = safe(node["name"]?.stringValue ?? node["text"]?.stringValue ?? "")
            guard !name.isEmpty else { continue }
            headingNames.insert(name)
            if let parent = node["parentNodeId"]?.stringValue { headingChild[parent] = name }
        }
        var section = 0
        for case .object(let node) in nodes {
            guard let id = node["nodeId"]?.stringValue else { continue }
            let (role, original) = roleAndLabel(node)
            let heading = node["role"]?.stringValue == "heading"
            if heading { section += 1 }
            if contentLinks[id] != nil { continue }
            let ownActs = !Set(strings(node["actions"])).isDisjoint(with: ["click", "fill", "type", "select", "set_checked", "keypress"])
            if role == "landmark", !ownActs, headingNames.contains(safe(node["name"]?.stringValue ?? "")) {
                // Only a region that holds nothing but its name repeats the heading.
                let whole = safe(node["text"]?.stringValue ?? "")
                if whole.isEmpty || whole == safe(node["name"]?.stringValue ?? "") { continue }
            }
            if !role.hasPrefix("h"), !ownActs, let heading = headingChild[id],
               case .array(let parts)? = node["inlineText"], !parts.isEmpty {
                // A box whose only words besides its heading are links ("[edit]").
                let prose = parts.compactMap { value -> String? in
                    guard case .object(let part) = value, !linkPaths.contains(part["elementPath"]?.stringValue ?? "") else { return nil }
                    return part["text"]?.stringValue
                }.joined()
                let bare = safe(prose).trimmingCharacters(in: CharacterSet(charactersIn: " []()|·"))
                if bare == heading { continue }
            }
            var label = original
            var references = Set<String>()
            if node["preformatted"] != .bool(true), case .array(let parts)? = node["inlineText"], !parts.isEmpty {
                let plain = parts.compactMap { value -> String? in
                    guard case .object(let part) = value else { return nil }; return part["text"]?.stringValue
                }.joined()
                if safe(plain) == safe(node["text"]?.stringValue ?? "") {
                    let marked = inlineRendering(parts, pathIDs: pathIDs, ownID: id)
                    label = parts.contains { if case .object(let p) = $0 { return p["code"] == .bool(true) }; return false }
                        ? marked.label : safe(marked.label)
                    references = marked.references
                }
            }
            for (link, target) in contentLinks where target == id {
                let number = link.hasPrefix("n") ? String(link.dropFirst()) : link
                label = "[\(label)](\(number))"; references.insert(number)
            }
            labels[id] = original
            if let parent = node["parentNodeId"]?.stringValue { parents[id] = parent }
            let acts = !Set(strings(node["actions"])).isDisjoint(with: ["click", "fill", "type", "select", "set_checked", "keypress"])
            var state = rowState(node)
            for (link, target) in contentLinks where target == id {
                for flag in rowState(byID[link] ?? [:]) where !state.contains(flag) { state.append(flag) }
            }
            if !acts, state.isEmpty, let ownerPath = node["textOwnerPath"]?.stringValue,
               let owner = pathIDs[ownerPath], let ownerNode = byID[owner] {
                if ownerNode["preformatted"] == .bool(true) || ownerNode["time"] == .bool(true)
                    || safe(ownerNode["text"]?.stringValue ?? "").contains(safe(node["text"]?.stringValue ?? "")) { continue }
            }
            if label.isEmpty, state.isEmpty, !acts, node["kind"]?.stringValue != "cell" { continue }
            if node["inline"] == .bool(true), !acts, state.isEmpty,
               let parent = node["parentNodeId"]?.stringValue, let parentLabel = labels[parent], parentLabel.contains(original) { continue }
            items.append(.init(number: id.hasPrefix("n") ? String(id.dropFirst()) : id, id: id, role: role, label: label, state: state, acts: acts, references: references,
                original: original, heading: heading, level: Int(node["level"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 1), section: section,
                rowPath: node["tableRowPath"]?.stringValue, cellPath: node["tableCellPath"]?.stringValue))
        }
        // Remove a standalone link only after a retained row carries it.
        // A discarded heading wrapper cannot swallow the section's controls.
        var represented = Set(items.flatMap { $0.references.subtracting([$0.number]) })
        for item in items {
            guard case .array(let parts)? = byID[item.id]?["inlineText"], item.role != "code" else { continue }
            for case .object(let part) in parts where isFootnote(part["text"]?.stringValue ?? "") {
                if let path = part["elementPath"]?.stringValue, let target = pathIDs[path] {
                    represented.insert(target.hasPrefix("n") ? String(target.dropFirst()) : target)
                }
            }
        }
        items.removeAll { $0.role == "link" && represented.contains($0.number) }
        var kept: [Line] = []
        for item in items {
            if item.acts || !item.state.isEmpty { kept.append(item); continue }
            guard item.role == "code" || item.cellPath != nil || item.label.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            var parent = parents[item.id], depth = 0, repeated = kept.last?.original == item.original && kept.last?.section == item.section
            while !repeated, let id = parent, depth < 4 {
                repeated = labels[id] == item.original
                parent = parents[id]; depth += 1
            }
            if repeated && !item.heading && item.cellPath == nil && item.role != "code" { continue }
            kept.append(item)
        }
        // Headings without a body disappear, but their controls remain.
        // A nested heading's body also belongs to the enclosing section.
        kept = kept.enumerated().filter { index, item in
            guard item.heading, !item.acts, item.references.isEmpty else { return true }
            return kept.dropFirst(index + 1).prefix { !$0.heading || $0.level > item.level }.contains {
                (!$0.heading || !$0.references.isEmpty) && !$0.label.isEmpty
                    && byID[$0.id].flatMap { $0["sectionControlHeadingPath"]?.stringValue } == nil
            }
        }.map(\.element)
        // Section actions keep their exact node number when folded.
        let headingIDs = Set(kept.filter(\.heading).map(\.id))
        var folded = Set<String>()
        for index in kept.indices where kept[index].heading {
            let headingID = kept[index].id
            for control in kept where byID[control.id].flatMap({ $0["sectionControlHeadingPath"]?.stringValue }).flatMap({ pathIDs[$0] }) == headingID {
                guard !control.heading else { continue }
                let label = control.acts ? "[\(control.label)](\(control.number))" : control.label
                kept[index].label += " · " + label + (control.state.isEmpty ? "" : " [" + control.state.joined(separator: "; ") + "]")
                kept[index].references.formUnion(control.references)
                if control.acts { kept[index].references.insert(control.number) }
                folded.insert(control.id)
            }
        }
        kept.removeAll { folded.contains($0.id) && !headingIDs.contains($0.id) }
        var links: [Line] = []
        for item in kept {
            if let previous = links.last, item.role == "link", previous.role == "link", item.state == previous.state,
               item.section == previous.section, item.cellPath == previous.cellPath,
               let previousPath = byID[item.id]?["adjacentLinkPath"]?.stringValue, pathIDs[previousPath] == previous.id {
                links[links.count - 1].label += (byID[item.id]?["adjacentLinkGap"]?.stringValue ?? "") + item.label
                links[links.count - 1].references.formUnion(item.references)
                links[links.count - 1].references.insert(item.number)
                // Retain the tail identity for a third adjacent link.
                links[links.count - 1].id = item.id
            } else { links.append(item) }
        }
        kept = tableRows(links, byID: byID, pathIDs: pathIDs)
        var joined: [Line] = [], open = false
        for item in kept {
            let plain = item.role == "text" && !item.heading && item.rowPath == nil && !item.acts && item.state.isEmpty && item.label.count < 120
            if plain, open, joined[joined.count - 1].section == item.section, joined[joined.count - 1].label.count < 240 {
                joined[joined.count - 1].label += " · " + item.label
                joined[joined.count - 1].references.formUnion(item.references)
                continue
            }
            joined.append(item); open = plain
        }
        return joined
    }

    private static func codeFence(_ text: String, minimum: Int = 3) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(minimum, longest + 1))
    }

    /// Formatting consumers compare/fold the complete row, including code
    /// lines that can themselves look like numbered actions.
    static func rowRanges(_ lines: [String]) -> [Range<Int>] {
        var result: [Range<Int>] = [], start: Int?, fence: String?, multiline = false
        for (index, line) in lines.enumerated() {
            if let delimiter = fence {
                if line == delimiter || line.hasPrefix(delimiter + "  [") {
                    fence = nil
                    if let current = start, lines[current].hasSuffix("  code") {
                        result.append(current..<(index + 1)); start = nil; multiline = false
                    }
                }
                continue
            }
            if start != nil, line.range(of: #"^`{3,}$"#, options: .regularExpression) != nil {
                fence = line; multiline = true; continue
            }
            if line.range(of: #"^\s*\d+  "#, options: .regularExpression) != nil {
                if let start { result.append(start..<index) }
                start = index; multiline = false
            } else if let current = start, line.isEmpty || !multiline {
                result.append(current..<index); start = nil; multiline = false
            }
        }
        if let start { result.append(start..<lines.count) }
        return result
    }

    private static func inlineRendering(_ values: [JSONValue], pathIDs: [String: String], ownID: String) -> (label: String, references: Set<String>) {
        let parts = values.compactMap { value -> [String: JSONValue]? in
            if case .object(let part) = value { return part }; return nil
        }
        var label = "", references = Set<String>(), index = 0
        func prose(_ part: [String: JSONValue]) -> String {
            let raw = part["text"]?.stringValue ?? ""
            if part["code"] == .bool(true) {
                if raw.contains("\n") {
                    let fence = codeFence(raw)
                    return "\n" + fence + "\n" + raw + (raw.hasSuffix("\n") ? "" : "\n") + fence + "\n"
                }
                let fence = codeFence(raw, minimum: 1)
                let padded = raw.hasPrefix("`") || raw.hasSuffix("`")
                    || (raw.hasPrefix(" ") && raw.hasSuffix(" ") && !raw.allSatisfy(\.isWhitespace))
                let pad = padded ? " " : ""
                return fence + pad + raw + pad + fence
            }
            return UntrustedText.neutralized(raw)
        }
        while index < parts.count {
            let part = parts[index], raw = part["text"]?.stringValue ?? ""
            guard !isFootnote(raw), let path = part["elementPath"]?.stringValue, let target = pathIDs[path], target != ownID else {
                label += prose(part); index += 1; continue
            }
            let first = target.hasPrefix("n") ? String(target.dropFirst()) : target
            references.insert(first)
            var words = prose(part), end = index + 1
            if let href = part["href"]?.stringValue {
                while end < parts.count {
                    var next = end, gap = ""
                    while next < parts.count, parts[next]["elementPath"]?.stringValue == nil,
                          (parts[next]["text"]?.stringValue ?? "").allSatisfy(\.isWhitespace) {
                        gap += parts[next]["text"]?.stringValue ?? ""; next += 1
                    }
                    guard next < parts.count, parts[next]["href"]?.stringValue == href,
                          !isFootnote(parts[next]["text"]?.stringValue ?? ""),
                          let nextPath = parts[next]["elementPath"]?.stringValue, let nextID = pathIDs[nextPath] else { break }
                    words += gap + prose(parts[next])
                    references.insert(nextID.hasPrefix("n") ? String(nextID.dropFirst()) : nextID)
                    end = next + 1
                }
            }
            label += "[\(words)](\(first))"; index = end
        }
        return (label, references)
    }

    private static func tableRows(_ items: [Line], byID: [String: [String: JSONValue]], pathIDs: [String: String]) -> [Line] {
        var result: [Line] = [], index = 0
        while index < items.count {
            guard let row = items[index].rowPath else { result.append(items[index]); index += 1; continue }
            var end = index + 1
            while end < items.count, items[end].rowPath == row { end += 1 }
            var line = items[index], cells: [String] = [], paths: [String: Int] = [:]
            line.role = "row"; line.label = ""; line.state = []; line.references = []
            for item in items[index..<end] {
                line.references.formUnion(item.references)
                if item.acts { line.references.insert(item.number) }
                let path = item.cellPath ?? item.id
                let code = item.role == "code" ? "\n" + codeFence(item.label) + "\n" + item.label
                    + (item.label.hasSuffix("\n") ? "" : "\n") + codeFence(item.label) + "\n" : item.label
                let label = item.acts ? "[\(code)](\(item.number))" : code
                let state = item.state.isEmpty ? "" : " [" + item.state.joined(separator: "; ") + "]"
                if let cell = paths[path] {
                    let ownText = safe(byID[pathIDs[path] ?? ""]?["text"]?.stringValue ?? "")
                    let childText = safe(byID[item.id]?["text"]?.stringValue ?? "")
                    if !item.acts && item.state.isEmpty && !childText.isEmpty && ownText.contains(childText) { continue }
                    cells[cell] += (cells[cell].isEmpty ? "" : " · ") + label + state
                } else {
                    paths[path] = cells.count
                    var spans: [String] = []
                    if let value = span(byID[item.id]?["columnSpan"], maximum: 1000) { spans.append("colspan=\(value)") }
                    if let value = span(byID[item.id]?["rowSpan"], maximum: 65534) { spans.append("rowspan=\(value)") }
                    cells.append(label + state + (spans.isEmpty ? "" : " [" + spans.joined(separator: "; ") + "]"))
                }
            }
            line.label = cells.joined(separator: " | ")
            result.append(line); index = end
        }
        return result
    }

    static func isFootnote(_ prose: String) -> Bool {
        prose.trimmingCharacters(in: .whitespaces).range(of: #"^\[(\d{1,4}|[a-z]{1,2})\]$"#, options: .regularExpression) != nil
    }

    private static func rowState(_ node: [String: JSONValue]) -> [String] {
        var state: [String] = []
        if case .object(let select)? = node["select"], case .array(let options)? = select["options"] {
            let labels = options.compactMap { value -> String? in
                guard case .object(let option) = value, let raw = option["value"]?.stringValue else { return nil }
                let optionValue = safe(raw)
                let shown = safe(option["label"]?.stringValue ?? raw)
                let mark = option["selected"] == .bool(true) ? "*" : ""
                return mark + (shown == optionValue ? optionValue : shown + "=" + optionValue)
            }
            // Folded controls expose every option in this window. Ordinary
            // controls retain the existing compact presentation.
            let shown = select["optionOffset"] == nil ? 30 : labels.count
            state.append("options: " + labels.prefix(shown).joined(separator: " | ")
                + (labels.count > shown ? " | +\(labels.count - shown)" : ""))
        } else if let value = node["value"]?.stringValue, !value.isEmpty,
                  value != "0" || (node["states"].flatMap { if case .object(let f) = $0 { f["editable"] } else { nil } } == .bool(true)) {
            state.append("=\"" + String(safe(value).prefix(120)) + "\"")
        }
        if case .object(let flags)? = node["states"] {
            if flags["editable"] == .bool(true) { state.append("editable") }
            if flags["disabled"] == .bool(true) { state.append("disabled") }
            if flags["checked"] == .bool(true) { state.append("checked") }
            if flags["selected"] == .bool(true) { state.append("selected") }
            if flags["expanded"] == .bool(true) { state.append("expanded") }
            if flags["expanded"] == .bool(false) { state.append("collapsed") }
            if flags["blockedByModal"] == .bool(true) { state.append("behind dialog") }
        }
        if case .object(let form)? = node["formState"] {
            if form["required"] == .bool(true) { state.append("required") }
            let failures = strings(form["failures"]).map(safe)
            if !failures.isEmpty { state.append("invalid: " + failures.joined(separator: ",")) }
        }
        return state
    }

    private static func mainContentFound(_ page: [String: JSONValue]) -> Bool {
        if case .object(let reading)? = page["reading"] { return reading["mainContentAvailable"] == .bool(true) }
        return false
    }

    private static func mainContent(_ page: [String: JSONValue]) -> Bool {
        if case .object(let reading)? = page["reading"] { return reading["scope"] == .string("main_content") }
        return false
    }

    private static func span(_ value: JSONValue?, maximum: Int) -> Int? {
        guard let number = value?.numberValue(coercingStrings: false, finiteOnly: false), number.isFinite,
              let count = Int(exactly: number), (2...maximum).contains(count) else { return nil }
        return count
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { $0.stringValue }
    }

    /// One line, tool markup inert: `UntrustedText`, as home uses it.
    static func safe(_ raw: String) -> String {
        UntrustedText.neutralized(raw.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
