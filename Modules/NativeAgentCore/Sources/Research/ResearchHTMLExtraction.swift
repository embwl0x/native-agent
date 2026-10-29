import Foundation

// Blueprint: | `ResearchHTMLExtraction.swift` | `ResearchHTMLExtraction`: fetched HTML block, list and table text with inline resolved links; HN story rows and comment paragraphs; chrome exclusion and cancellable parsing without a DOM node cutoff |

/// Joins inline text into paragraphs, list items and table rows, resolving links
/// against the final URL or first valid head base; each URL label appears once.
/// HN layout tables become story/points/comments rows or author/comment blocks.
/// Scripts, navigation, footers, hidden content and recognized cookie banners
/// are omitted. Extraction has no DOM node cutoff; excessive nesting is refused.
/// Parsing and rendering check cancellation; Chrome snapshots own their separate
/// node-limited readMore cursor, independent of this bounded-response extraction.
enum ResearchHTMLExtraction {
    struct Evidence {
        let text: String
        let scriptCharacters: Int
        let scripts: Int
        let canvases: Int
        let bodyCharacters: Int
    }

    private final class Node {
        let tag: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ tag: String, _ attributes: [String: String] = [:]) {
            self.tag = tag; self.attributes = attributes
        }
        func hasClass(_ name: String) -> Bool {
            (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).contains(Substring(name))
        }
    }

    static func extract(_ html: String, base: URL, decode: (String) throws -> String) throws -> Evidence {
        let chars = Array(html), n = chars.count
        let root = Node("document")
        var stack = [root], i = 0
        var scripts = 0, scriptCharacters = 0, canvases = 0
        var linkBase = base, sawBase = false
        let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let rawTags: Set<String> = ["script", "style", "noscript"]

        func tagEnd(_ start: Int) throws -> Int? {
            var quote: Character?
            for index in start..<n {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                let c = chars[index]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ">" { return index }
            }
            return nil
        }
        func attributes(_ start: Int, _ end: Int) throws -> [String: String] {
            var p = start, result: [String: String] = [:]
            while p < end {
                try Task.checkCancellation()
                while p < end && (chars[p].isWhitespace || chars[p] == "/") { p += 1 }
                let keyStart = p
                while p < end && !chars[p].isWhitespace && chars[p] != "=" && chars[p] != "/" { p += 1 }
                guard p > keyStart else { p += 1; continue }
                let key = String(chars[keyStart..<p]).lowercased()
                while p < end && chars[p].isWhitespace { p += 1 }
                var value = ""
                if p < end && chars[p] == "=" {
                    p += 1
                    while p < end && chars[p].isWhitespace { p += 1 }
                    if p < end && (chars[p] == "\"" || chars[p] == "'") {
                        let quote = chars[p]; p += 1
                        let valueStart = p
                        while p < end && chars[p] != quote { p += 1 }
                        value = String(chars[valueStart..<p]); if p < end { p += 1 }
                    } else {
                        let valueStart = p
                        while p < end && !chars[p].isWhitespace { p += 1 }
                        value = String(chars[valueStart..<p])
                    }
                }
                if result[key] == nil { result[key] = try decode(value) }
            }
            return result
        }
        // HTML permits omitted p/li/tr/td closing tags. Close only within
        // their containing scope, so a nested table never closes its outer row.
        func closeOpen(_ names: Set<String>, within boundaries: Set<String>) {
            for index in stack.indices.reversed() {
                if names.contains(stack[index].tag) { stack.removeSubrange(index...); return }
                if boundaries.contains(stack[index].tag) { return }
            }
        }
        while i < n {
            try Task.checkCancellation()
            if chars[i] != "<" {
                let start = i
                while i < n && chars[i] != "<" {
                    if i.isMultiple(of: 1_024) { try Task.checkCancellation() }
                    i += 1
                }
                let node = Node("text")
                let decoded = try decode(String(chars[start..<i]))
                // Source wrapping is whitespace, not a paragraph boundary.
                // Keep boundary spaces so adjacent inline elements join naturally.
                node.text = stack.contains(where: { $0.tag == "pre" }) ? decoded
                    : decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                stack.last!.children.append(node)
                continue
            }
            if chars[i...].starts(with: ["<", "!", "-", "-"]) {
                i += 4
                while i + 2 < n && !chars[i...].starts(with: ["-", "-", ">"]) {
                    if i.isMultiple(of: 1_024) { try Task.checkCancellation() }; i += 1
                }
                i = min(n, i + 3); continue
            }
            guard let end = try tagEnd(i + 1) else { break } // incomplete markup in a bounded response
            var p = i + 1
            let closing = p < end && chars[p] == "/"
            if closing { p += 1 }
            let start = p
            while p < end && (chars[p].isLetter || chars[p].isNumber || chars[p] == "-") { p += 1 }
            let tag = String(chars[start..<p]).lowercased()
            i = end + 1
            if tag.isEmpty { continue }
            if closing {
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 { stack.removeSubrange(index...) }
                continue
            }
            if tag == "body", let head = stack.lastIndex(where: { $0.tag == "head" }) {
                stack.removeSubrange(head...)
            }
            if tag == "script" { scripts += 1 }
            if tag == "canvas" { canvases += 1 }
            if rawTags.contains(tag) {
                if chars[end - 1] == "/" { continue }
                let contentStart = i, needle = Array("</" + tag)
                while i < n {
                    if i.isMultiple(of: 1_024) { try Task.checkCancellation() }
                    if chars[i] == "<", i + needle.count <= n,
                       String(chars[i..<(i + needle.count)]).lowercased() == String(needle),
                       i + needle.count == n || chars[i + needle.count].isWhitespace || chars[i + needle.count] == ">" {
                        break
                    }
                    i += 1
                }
                if tag == "script" { scriptCharacters += i - contentStart }
                if i < n { i = try tagEnd(i + needle.count).map { $0 + 1 } ?? n }
                continue
            }
            let attrs = try attributes(p, end)
            if tag == "base", !sawBase, stack.contains(where: { $0.tag == "head" }),
               let href = attrs["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                linkBase = url; sawBase = true
            }
            if tag == "li" { closeOpen(["li"], within: ["ul", "ol"]) }
            if tag == "tr" { closeOpen(["tr"], within: ["table"]) }
            if tag == "td" || tag == "th" { closeOpen(["td", "th"], within: ["tr", "table"]) }
            if ["p", "div", "section", "article", "ul", "ol", "table", "h1", "h2", "h3", "blockquote"].contains(tag) {
                closeOpen(["p"], within: ["td", "th", "div", "section", "article", "body"])
            }
            let node = Node(tag, attrs)
            stack.last!.children.append(node)
            if !voids.contains(tag) && chars[end - 1] != "/" {
                // Refuse pathological nesting explicitly, never return a cut page.
                guard stack.count < 512 else {
                    throw NSError(domain: "ResearchHTMLExtraction", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "HTML nesting exceeds 512 levels; no complete page was extracted."])
                }
                stack.append(node)
            }
        }

        func compact(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func excluded(_ node: Node) -> Bool {
            if ["head", "nav", "footer", "svg", "template", "script", "style", "noscript"].contains(node.tag) { return true }
            let attrs = node.attributes
            if attrs["hidden"] != nil || attrs["aria-hidden"]?.lowercased() == "true" { return true }
            if ["navigation", "contentinfo"].contains(attrs["role"]?.lowercased() ?? "") { return true }
            let style = (attrs["style"] ?? "").lowercased().filter { !$0.isWhitespace }
            if style.contains("display:none") || style.contains("visibility:hidden") { return true }
            let tokens = ((attrs["id"] ?? "") + " " + (attrs["class"] ?? "")).lowercased().split(whereSeparator: \.isWhitespace)
            return tokens.contains { ["cookie-banner", "cookie-consent", "cookie-notice", "consent-banner", "onetrust-banner-sdk", "onetrust-consent-sdk", "pagetop", "yclinks"].contains(String($0)) }
        }
        func descendants(_ node: Node, matching predicate: (Node) -> Bool) throws -> [Node] {
            try Task.checkCancellation()
            if excluded(node) { return [] }
            if predicate(node) { return [node] }
            return try node.children.flatMap { try descendants($0, matching: predicate) }
        }
        func containsFooter(_ node: Node) throws -> Bool {
            var pending = [node]
            while let next = pending.popLast() {
                try Task.checkCancellation()
                if next.hasClass("yclinks") { return true }
                pending.append(contentsOf: next.children)
            }
            return false
        }
        func link(_ node: Node, _ label: String) -> String {
            guard !label.isEmpty, let href = node.attributes["href"] else { return label }
            let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != "#",
                  let url = URL(string: raw, relativeTo: linkBase)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return label }
            let target = url.absoluteString
            if label == target || (label == raw && ["http", "https"].contains(URL(string: label)?.scheme?.lowercased() ?? "")) { return target }
            return label + " → " + target
        }
        let blocks: Set<String> = ["address", "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt", "fieldset", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "ol", "p", "pre", "section", "summary", "table", "tbody", "thead", "tfoot", "tr", "ul"]
        let hackerNews = base.host?.lowercased() == "news.ycombinator.com"
        func render(_ node: Node, links: Bool = true) throws -> String {
            try Task.checkCancellation()
            if excluded(node) { return "" }
            if node.tag == "text" { return node.text }
            if node.tag == "br" { return "\n" }
            if node.tag == "img" { return node.attributes["alt"] ?? "" }
            if hackerNews && node.tag == "form" { return "" }
            if hackerNews && (node.hasClass("votelinks") || node.hasClass("sitebit") || node.hasClass("reply")) { return "" }
            if hackerNews && node.hasClass("comhead") {
                let byline = try descendants(node, matching: { $0.hasClass("hnuser") || $0.hasClass("age") })
                return "\n" + (try byline.map { compact(try render($0, links: false)) }.joined(separator: " · ")) + "\n"
            }
            if hackerNews && node.hasClass("comment") {
                return "\n" + (try node.children.map { try render($0, links: links) }.joined()) + "\n"
            }
            // HN uses a story row followed by its subtext row in a layout table.
            // Emit that pair as one readable item, without vote/profile/hide URLs.
            if hackerNews && ["table", "tbody"].contains(node.tag) {
                var out = "", index = 0
                while index < node.children.count {
                    let child = node.children[index]
                    if child.tag == "tr", try containsFooter(child) { index += 1; continue }
                    if child.tag == "tr", child.hasClass("athing"),
                       let title = try descendants(child, matching: { $0.hasClass("titleline") }).first {
                        let rank = try descendants(child, matching: { $0.hasClass("rank") }).first
                        out += "\n" + (try rank.map { compact(try render($0, links: false)) + " " } ?? "")
                        out += compact(try render(title, links: links))
                        var next = index + 1
                        while next < node.children.count && node.children[next].tag == "text" { next += 1 }
                        if next < node.children.count, node.children[next].tag == "tr",
                           let subtext = try descendants(node.children[next], matching: { $0.hasClass("subtext") }).first {
                            let scores = try descendants(subtext, matching: { $0.hasClass("score") })
                            let comments = try descendants(subtext, matching: { $0.tag == "a" }).filter {
                                let label = compact(try render($0, links: false))
                                return label.contains("comment") || label == "discuss"
                            }
                            let details = try scores.map { compact(try render($0, links: false)) }
                                + comments.map { compact(try render($0, links: links)) }
                            if !details.isEmpty { out += " (" + details.joined(separator: ", ") + ")" }
                            index = next
                        }
                        out += "\n"
                    } else { out += try render(child, links: links) }
                    index += 1
                }
                return out
            }
            if node.tag == "tr" {
                let nestedTables = try descendants(node, matching: { $0.tag == "table" })
                if hackerNews || !nestedTables.isEmpty {
                    return "\n" + (try node.children.map { try render($0, links: links) }.joined()) + "\n"
                }
                var cells: [String] = []
                for child in node.children where child.tag == "td" || child.tag == "th" {
                    let value = compact(try render(child, links: links))
                    cells.append(value)
                }
                return "\n" + cells.joined(separator: " | ") + "\n"
            }
            let body = try node.children.map { try render($0, links: links) }.joined()
            if node.tag == "a" { return links ? link(node, compact(body)) : body }
            if blocks.contains(node.tag) { return "\n" + body + "\n" }
            return body
        }
        let text = try render(root).split(separator: "\n").map { compact(String($0)) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let bodyCharacters = compact(try render(root, links: false)).count
        return Evidence(text: text, scriptCharacters: scriptCharacters, scripts: scripts,
                        canvases: canvases, bodyCharacters: bodyCharacters)
    }
}
