import Foundation
import ChatOrchestration
import PersistenceCore
import CryptoKit
import Senses
import MacControl
import Privacy
import Research

/// Chrome's ordered prose and action rows, with the same receipt on raw and
/// sense-served reads. Continuations name structural elements on this URL.
enum ChromePageText {
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
            guard let address = text(page["url"]), let url = URL(string: address),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw SenseFailure(code: "unsupported_document_url", message: "This PDF has no HTTP(S) document address to read.")
            }
            let response = try await URLSessionResearchHTTPClient().getBounded(url: url, timeout: 20,
                maxBytes: MacDocumentRead.maxFileBytes)
            document["read_at"] = .string(ISO8601DateFormatter().string(from: Date()))
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

    static func render(_ snapshot: JSONValue) -> String? {
        guard case .object(let page) = snapshot, text(page["snapshotId"]) != nil,
              case .array(let nodes)? = page["nodes"] else { return nil }
        if case .object(let document)? = page["document"], document["kind"] == .string("pdf") {
            let content = text(document["text"]) ?? ""
            let status = content.isEmpty ? "failed" : text(document["status"]) ?? "partial"
            return safe(text(page["url"]) ?? "") + "\nPDF read: " + status + "\n\n"
                + safe(text(document["reason"]) ?? "The PDF document text was not read.")
                + (content.isEmpty ? "" : "\n\n" + UntrustedText.neutralized(content))
        }
        // Prose uses the home's markup defuse. Code is quoted behind a fence
        // longer than any delimiter in its source, preserving its syntax.
        let title = safe(text(page["title"]) ?? "")
        let url = safe(text(page["url"]) ?? "")
        let fromViewport: Bool = if case .object(let reading)? = page["reading"] { reading["fromViewport"] == .bool(true) } else { false }
        var head = [(title.isEmpty ? "" : title + " — ") + url]
        var where_: [String] = []
        if case .object(let reading)? = page["reading"], case .array(let sections)? = reading["sections"] {
            let headings = renderedRows(nodes).filter(\.heading)
            let topLevel = headings.map(\.level).filter { $0 > 1 }.min() ?? 1
            let visibleHeadings = Set(headings.filter { $0.level <= topLevel }.map { safe($0.original) })
            let capturedHeadings = Set(nodes.compactMap { value -> String? in
                guard case .object(let node) = value, text(node["role"]) == "heading" else { return nil }
                return safe(text(node["name"]) ?? text(node["text"]) ?? "")
            })
            let names = sections.compactMap { text($0).map(safe) }
                .filter { visibleHeadings.contains($0) || !capturedHeadings.contains($0) }.prefix(8)
            if !names.isEmpty { where_.append("Reading: " + names.joined(separator: " · ")) }
        }
        if fromViewport { where_.append("sections in the scrolled view") }
        if mainContent(page) {
            where_.append(Self.mainContentFound(page) ? "main content (scope page adds the site's nav)"
                : "no main or article region on this page: read it with scope page to see its content")
        }
        head.append(where_.joined(separator: " · "))

        var rows: [String] = []
        for line in lines(nodes) {
            rows.append(line)
        }
        var foot: [String] = []
        if rows.isEmpty, case .object(let summary)? = page["summary"], let prose = text(summary["text"]) {
            rows.append(safe(prose))
        }
        if rows.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            rows = ["No readable content in this window."]
        }
        if case .object(let summary)? = page["summary"], summary["truncated"] == .bool(true) {
            foot.append("Read limited: " + strings(summary["truncationReasons"]).map(safe).joined(separator: ", "))
        }
        if case .object(let cursor)? = page["readMore"], let next = next(page) {
            foot.append("Folded: " + safe(text(cursor["name"]) ?? "Remaining page"))
            if let address = text(next["more"]) {
                foot.append("More: " + address + " · app {page: \"site:\(URL(string: url)?.host ?? "")\", item: \"" + address + "\"}")
            }
        } else if page["readMore"] != nil, page["readMore"] != .null {
            foot.append("Folded page is unavailable: Chrome's reader supplied no readable continuation place. raw view · Chrome continuation metadata is incomplete.")
        }
        for case .object(let node) in nodes {
            guard let cursor = node["more"], cursor != .null else { continue }
            guard let args = next(page, cursor: cursor), let address = text(args["more"]) else {
                foot.append("Folded control is unavailable: Chrome's reader supplied no readable continuation place. raw view · Chrome continuation metadata is incomplete.")
                continue
            }
            let id = text(node["nodeId"]) ?? ""
            let row = Self.rows(.object(page)).first { $0.node == id }?.number ?? safe(text(node["name"]) ?? "control")
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

    static func envelope(_ snapshot: JSONValue, rendered: String) throws -> JSONValue {
        guard case .object(let page) = snapshot else { return .string(rendered) }
        let elementMore: [JSONValue] = if case .array(let nodes)? = page["nodes"] { nodes.compactMap { value in
            guard case .object(let node) = value, let cursor = node["more"],
                  let args = next(page, cursor: cursor) else { return nil }
            let row = rows(snapshot).first { $0.node == text(node["nodeId"]) }
            return .object(["node_id": row?.number.map(JSONValue.string) ?? row.map { .string($0.label) } ?? .null, "next": .object(args)])
        } } else { [] }
        var fields: [String: JSONValue] = ["ok": .bool(true), "text": .string(rendered),
            "url": page["url"] ?? .null, "title": page["title"] ?? .null,
            "snapshot_id": page["snapshotId"] ?? .null, "captured_at": page["capturedAt"] ?? .null,
            "bytes": .int(Int64(rendered.utf8.count)), "has_more": .bool(next(page) != nil || !elementMore.isEmpty)]
        if case .object(let document)? = page["document"] {
            let hasText = !(text(document["text"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            fields["ok"] = .bool(hasText && document["chrome_document_verified"] == .bool(true))
            fields["status"] = .string(hasText ? text(document["status"]) ?? "partial" : "failed")
            fields["chrome_context"] = .object(["snapshot_id": page["snapshotId"] ?? .null,
                "captured_at": page["capturedAt"] ?? .null, "url": page["url"] ?? .null])
            fields["snapshot_id"] = .null
            fields["captured_at"] = document["read_at"] ?? .null
            fields["url"] = document["final_url"] ?? .null
            fields["document"] = .object(document.filter { $0.key != "text" })
        } else if case .array(let nodes)? = page["nodes"] {
            let summary: [String: JSONValue] = if case .object(let summary)? = page["summary"] { summary } else { [:] }
            let hasContent = !lines(nodes).isEmpty || !(text(summary["text"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            fields["ok"] = .bool(hasContent)
            fields["status"] = .string(hasContent ? (summary["truncated"] == .bool(true) ? "partial" : "completed")
                : (next(page) != nil ? "partial" : "failed"))
            if !hasContent { fields["reason"] = .string("read_window_empty") }
            fields["truncated"] = summary["truncated"] ?? .bool(false)
            fields["truncation_reasons"] = summary["truncationReasons"] ?? .array([])
        }
        if !elementMore.isEmpty { fields["element_more"] = .array(elementMore) }
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
        fields["version"] = .string(SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined())
        if let next = next(page) { fields["next"] = .object(next) }
        return .object(fields)
    }

    /// The page's rows as the mirror keeps them, so a row can be named by its label.
    static func rows(_ snapshot: JSONValue) -> [ChromePageMirror.Row] {
        guard case .object(let page) = snapshot, case .array(let nodes)? = page["nodes"] else { return [] }
        let visible = renderedRows(nodes)
        let numbers = Set(visible.map(\.number) + visible.flatMap { $0.references })
        return nodes.compactMap { value -> ChromePageMirror.Row? in
            guard case .object(let node) = value, let id = text(node["nodeId"]) else { return nil }
            var options: [ChromePageMirror.Option] = []
            if case .object(let select)? = node["select"], case .array(let list)? = select["options"] {
                options = list.compactMap { item in
                    guard case .object(let option) = item, let raw = text(option["value"]) else { return nil }
                    return .init(label: text(option["label"]) ?? raw, value: raw)
                }
            }
            let (role, label) = roleAndLabel(node)
            let number = id.hasPrefix("n") ? String(id.dropFirst()) : id
            return .init(node: id, role: role, label: safe(label), acts: Set(strings(node["actions"])), options: options,
                         number: numbers.contains(number) ? number : nil)
        }
    }

    private static func roleAndLabel(_ node: [String: JSONValue]) -> (String, String) {
        if node["preformatted"] == .bool(true) { return ("code", text(node["text"]) ?? "") }
        if node["time"] == .bool(true) { return ("text", safe(text(node["text"]) ?? "")) }
        var role = safe(text(node["role"]) ?? text(node["kind"]) ?? "")
        if text(node["kind"]) == "image" { role = "image" }
        if role == "other" || role.isEmpty { role = "text" }
        if role == "heading", let level = number(node["level"]) { role = "h\(Int(level))" }
        let name = safe(text(node["name"]) ?? "")
        let body = safe(text(node["text"]) ?? "")
        var label = name.isEmpty ? body : name
        if !body.isEmpty, body != label, !label.contains(body) {
            label = body.contains(label) ? body : label + " — " + body
        }
        if label.isEmpty, role == "link", let url = text(node["url"]) { label = safe(url) }
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
    private static func lines(_ nodes: [JSONValue]) -> [String] {
        renderedRows(nodes).map { line in
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
        for case .object(let node) in nodes {
            guard let id = text(node["nodeId"]) else { continue }
            byID[id] = node
            if let path = text(node["elementPath"]) { pathIDs[path] = id }
            if let parent = text(node["parentNodeId"]) { parents[id] = parent }
        }
        // A card's link belongs on its heading. Only fold the parent link
        // when the retained child blocks account for its entire visible text.
        var contentLinks: [String: String] = [:]
        for case .object(let link) in nodes where link["childTextName"] == .bool(true) {
            guard let id = text(link["nodeId"]), let path = text(link["elementPath"]) else { continue }
            let children = nodes.compactMap { value -> [String: JSONValue]? in
                guard case .object(let child) = value, text(child["contentLinkPath"]) == path,
                      child["inline"] != .bool(true) || text(child["role"]) == "heading",
                      !safe(text(child["text"]) ?? "").isEmpty else { return nil }
                return child
            }
            let childIDs = Set(children.compactMap { text($0["nodeId"]) })
            let blocks = children.filter { child in
                var parent = text(child["parentNodeId"])
                while let key = parent, key != id {
                    if childIDs.contains(key) { return false }
                    parent = parents[key]
                }
                return true
            }
            guard !blocks.isEmpty, safe(blocks.compactMap { text($0["text"]) }.joined(separator: " ")) == safe(text(link["text"]) ?? ""),
                  let target = (blocks.first { text($0["role"]) == "heading" } ?? blocks.first).flatMap({ text($0["nodeId"]) }) else { continue }
            contentLinks[id] = target
        }
        // Structure every article shares: a heading prints once. A named
        // region repeating a heading, and a box wrapping a heading (its text
        // is the heading plus controls like "[edit]"), are the same heading.
        var headingNames = Set<String>(), headingChild: [String: String] = [:], linkPaths = Set<String>()
        for case .object(let node) in nodes where text(node["role"]) == "link" { if let path = text(node["elementPath"]) { linkPaths.insert(path) } }
        for case .object(let node) in nodes where text(node["role"]) == "heading" {
            let name = safe(text(node["name"]) ?? text(node["text"]) ?? "")
            guard !name.isEmpty else { continue }
            headingNames.insert(name)
            if let parent = text(node["parentNodeId"]) { headingChild[parent] = name }
        }
        var section = 0
        for case .object(let node) in nodes {
            guard let id = text(node["nodeId"]) else { continue }
            let (role, original) = roleAndLabel(node)
            let heading = text(node["role"]) == "heading"
            if heading { section += 1 }
            if contentLinks[id] != nil { continue }
            let ownActs = !Set(strings(node["actions"])).isDisjoint(with: ["click", "fill", "type", "select", "set_checked", "keypress"])
            if role == "landmark", !ownActs, headingNames.contains(safe(text(node["name"]) ?? "")) {
                // Only a region that holds nothing but its name repeats the heading.
                let whole = safe(text(node["text"]) ?? "")
                if whole.isEmpty || whole == safe(text(node["name"]) ?? "") { continue }
            }
            if !role.hasPrefix("h"), !ownActs, let heading = headingChild[id],
               case .array(let parts)? = node["inlineText"], !parts.isEmpty {
                // A box whose only words besides its heading are links ("[edit]").
                let prose = parts.compactMap { value -> String? in
                    guard case .object(let part) = value, !linkPaths.contains(text(part["elementPath"]) ?? "") else { return nil }
                    return text(part["text"])
                }.joined()
                let bare = safe(prose).trimmingCharacters(in: CharacterSet(charactersIn: " []()|·"))
                if bare == heading { continue }
            }
            var label = original
            var references = Set<String>()
            if node["preformatted"] != .bool(true), case .array(let parts)? = node["inlineText"], !parts.isEmpty {
                let plain = parts.compactMap { value -> String? in
                    guard case .object(let part) = value else { return nil }; return text(part["text"])
                }.joined()
                if safe(plain) == safe(text(node["text"]) ?? "") {
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
            if let parent = text(node["parentNodeId"]) { parents[id] = parent }
            let acts = !Set(strings(node["actions"])).isDisjoint(with: ["click", "fill", "type", "select", "set_checked", "keypress"])
            var state = rowState(node)
            for (link, target) in contentLinks where target == id {
                for flag in rowState(byID[link] ?? [:]) where !state.contains(flag) { state.append(flag) }
            }
            if !acts, state.isEmpty, let ownerPath = text(node["textOwnerPath"]),
               let owner = pathIDs[ownerPath], let ownerNode = byID[owner] {
                if ownerNode["preformatted"] == .bool(true) || ownerNode["time"] == .bool(true)
                    || safe(text(ownerNode["text"]) ?? "").contains(safe(text(node["text"]) ?? "")) { continue }
            }
            if label.isEmpty, state.isEmpty, !acts, text(node["kind"]) != "cell" { continue }
            if node["inline"] == .bool(true), !acts, state.isEmpty,
               let parent = text(node["parentNodeId"]), let parentLabel = labels[parent], parentLabel.contains(original) { continue }
            items.append(.init(number: id.hasPrefix("n") ? String(id.dropFirst()) : id, id: id, role: role, label: label, state: state, acts: acts, references: references,
                original: original, heading: heading, level: Int(number(node["level"]) ?? 1), section: section,
                rowPath: text(node["tableRowPath"]), cellPath: text(node["tableCellPath"])))
        }
        // Remove a standalone link only after a retained row carries it.
        // A discarded heading wrapper cannot swallow the section's controls.
        var represented = Set(items.flatMap { $0.references.subtracting([$0.number]) })
        for item in items {
            guard case .array(let parts)? = byID[item.id]?["inlineText"], item.role != "code" else { continue }
            for case .object(let part) in parts where isFootnote(text(part["text"]) ?? "") {
                if let path = text(part["elementPath"]), let target = pathIDs[path] {
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
                    && byID[$0.id].flatMap { text($0["sectionControlHeadingPath"]) } == nil
            }
        }.map(\.element)
        // Section actions keep their exact node number when folded.
        let headingIDs = Set(kept.filter(\.heading).map(\.id))
        var folded = Set<String>()
        for index in kept.indices where kept[index].heading {
            let headingID = kept[index].id
            for control in kept where byID[control.id].flatMap({ text($0["sectionControlHeadingPath"]) }).flatMap({ pathIDs[$0] }) == headingID {
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
               let previousPath = text(byID[item.id]?["adjacentLinkPath"]), pathIDs[previousPath] == previous.id {
                links[links.count - 1].label += (text(byID[item.id]?["adjacentLinkGap"]) ?? "") + item.label
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
            let raw = text(part["text"]) ?? ""
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
            let part = parts[index], raw = text(part["text"]) ?? ""
            guard !isFootnote(raw), let path = text(part["elementPath"]), let target = pathIDs[path], target != ownID else {
                label += prose(part); index += 1; continue
            }
            let first = target.hasPrefix("n") ? String(target.dropFirst()) : target
            references.insert(first)
            var words = prose(part), end = index + 1
            if let href = text(part["href"]) {
                while end < parts.count {
                    var next = end, gap = ""
                    while next < parts.count, text(parts[next]["elementPath"]) == nil,
                          (text(parts[next]["text"]) ?? "").allSatisfy(\.isWhitespace) {
                        gap += text(parts[next]["text"]) ?? ""; next += 1
                    }
                    guard next < parts.count, text(parts[next]["href"]) == href,
                          !isFootnote(text(parts[next]["text"]) ?? ""),
                          let nextPath = text(parts[next]["elementPath"]), let nextID = pathIDs[nextPath] else { break }
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
                    let ownText = safe(text(byID[pathIDs[path] ?? ""]?["text"]) ?? "")
                    let childText = safe(text(byID[item.id]?["text"]) ?? "")
                    if !item.acts && item.state.isEmpty && !childText.isEmpty && ownText.contains(childText) { continue }
                    cells[cell] += (cells[cell].isEmpty ? "" : " · ") + label + state
                } else {
                    paths[path] = cells.count
                    var spans: [String] = []
                    if let value = number(byID[item.id]?["columnSpan"]), value > 1 { spans.append("colspan=\(Int(value))") }
                    if let value = number(byID[item.id]?["rowSpan"]), value > 1 { spans.append("rowspan=\(Int(value))") }
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
                guard case .object(let option) = value, let raw = text(option["value"]) else { return nil }
                let optionValue = safe(raw)
                let shown = safe(text(option["label"]) ?? raw)
                let mark = option["selected"] == .bool(true) ? "*" : ""
                return mark + (shown == optionValue ? optionValue : shown + "=" + optionValue)
            }
            // Folded controls expose every option in this window. Ordinary
            // controls retain the existing compact presentation.
            let shown = select["optionOffset"] == nil ? 30 : labels.count
            state.append("options: " + labels.prefix(shown).joined(separator: " | ")
                + (labels.count > shown ? " | +\(labels.count - shown)" : ""))
        } else if let value = text(node["value"]), !value.isEmpty,
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

    private static func text(_ value: JSONValue?) -> String? {
        if case .string(let raw)? = value { return raw }
        return nil
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let n)?: return Double(n)
        case .double(let n)?: return n
        default: return nil
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { text($0) }
    }

    /// One line, tool markup inert: `UntrustedText`, as home uses it.
    static func safe(_ raw: String) -> String {
        UntrustedText.neutralized(raw.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
