import Foundation
import ChatOrchestration
import PersistenceCore

/// Her-screen Phase 3 (2026-09-23): a Chrome page as the model reads it. One
/// title/url line, where the view sits, then one row per node:
/// `n  role name  [state]`, where n is the node id's number (row 12 is node
/// `n12`; tools accept either, or the row's label). 09-24: lean — plain text
/// rows carry no role word, text a parent or the row before already says is
/// left out, short text runs share one line, and the snapshot id stays off
/// the page (acts default to the page last read). The extension's full JSON nodes and its
/// `summary.text` (a second copy of the node text) never reach the model on a
/// direct call; the workspace keeps the structured snapshot it projects from.
enum ChromePageText {
    /// Well under the 48 KB provider cap, so a page never needs paging.
    static let maxBytes = 40_000

    static func render(_ snapshot: JSONValue) -> String? {
        guard case .object(let page) = snapshot, text(page["snapshotId"]) != nil,
              case .array(let nodes)? = page["nodes"] else { return nil }
        // Page-controlled text: one line each, tool markup made inert (the
        // same defuse the home screen uses), on every lane.
        let title = safe(text(page["title"]) ?? "")
        let url = safe(text(page["url"]) ?? "")
        var head = [(title.isEmpty ? "" : title + " — ") + url]
        var where_: [String] = []
        if case .object(let view)? = page["viewport"], let y = number(view["scrollY"]),
           let height = number(view["height"]), let total = number(view["documentHeight"]), total > height {
            // The exact call that reaches the next rows: a screen less a strip of overlap.
            let step = Int(min(total - y - height, max(200, height - 120)))
            var below = y + height < total - 1 ? "\(Int(total - y - height))px more below: browser.chrome_scroll{delta_y: \(step)}" : nil
            // 09-24 (fam-web: 3 scrolls to a footer): in main content, "below"
            // counts only when a main row runs past the bottom edge. Bounds
            // are viewport-relative; rows from inner frames are skipped.
            // A cut read's last row is not the content's end.
            let cutShort: Bool = if case .object(let summary)? = page["summary"] { summary["truncated"] == .bool(true) } else { false }
            if below != nil, mainContent(page), !nodes.isEmpty, !cutShort {
                let bottoms = nodes.compactMap { value -> Double? in
                    guard case .object(let node) = value, (number(node["frameId"]) ?? 0) == 0,
                          case .object(let box)? = node["bounds"], let top = number(box["y"]), let tall = number(box["height"]) else { return nil }
                    return top + tall
                }
                if let last = bottoms.max(), last <= height + 1 { below = "the main content ends in view; the rest below is outside it" }
            }
            let more = [y > 1 ? "more above" : nil, below].compactMap { $0 }
            where_.append("showing \(Int(y))–\(Int(y + height)) of \(Int(total))px"
                + (more.isEmpty ? "" : " (" + more.joined(separator: "; ") + ")"))
        }
        if mainContent(page) { where_.append("main content (scope page adds the site's nav)") }
        head.append(where_.joined(separator: " · "))

        var rows: [String] = []
        var bytes = head.joined(separator: "\n").utf8.count
        var cut = 0
        for line in lines(nodes) {
            if bytes + line.utf8.count + 1 > maxBytes { cut += 1; continue }
            bytes += line.utf8.count + 1
            rows.append(line)
        }
        var foot: [String] = []
        if rows.isEmpty, case .object(let summary)? = page["summary"], let prose = text(summary["text"]) {
            rows.append(String(safe(prose).prefix(4_000)))
        }
        if case .object(let summary)? = page["summary"], summary["truncated"] == .bool(true) {
            let reasons = strings(summary["truncationReasons"]).joined(separator: ", ")
            foot.append("Page cut (\(reasons.isEmpty ? "limit" : reasons)): browser.chrome_scroll{delta_y} for the rest.")
        }
        if cut > 0 { foot.append("\(cut) more rows left out to stay small: browser.chrome_scroll{delta_y} for the rest.") }
        if case .array(let frames)? = page["frames"] {
            let closed = frames.filter { if case .object(let f) = $0 { return f["accessible"] == .bool(false) }; return false }.count
            if closed > 0 { foot.append("\(closed) embedded frame(s) could not be read.") }
        }
        foot.append("Act by row number or label: chrome_click · chrome_fill{fields, submit} · chrome_select · chrome_scroll{delta_y}; each returns the page.")
        return (head + [""] + rows + [""] + foot).joined(separator: "\n")
    }

    /// The page's rows as the mirror keeps them, so a row can be named by its label.
    static func rows(_ snapshot: JSONValue) -> [ChromePageMirror.Row] {
        guard case .object(let page) = snapshot, case .array(let nodes)? = page["nodes"] else { return [] }
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
            return .init(node: id, role: role, label: label, acts: Set(strings(node["actions"])), options: options)
        }
    }

    private static func roleAndLabel(_ node: [String: JSONValue]) -> (String, String) {
        var role = safe(text(node["role"]) ?? text(node["kind"]) ?? "")
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
        let cap = role == "text" ? 1_200 : 300
        if label.count > cap { label = String(label.prefix(cap)) + "…" }
        return (role, label)
    }

    private struct Line { var number: String; var id: String; var role: String; var label: String; var state: [String]; var acts: Bool }

    /// The rows as lines. Dropped: a read-only row with no word in it, or
    /// whose text is exactly its parent's (four levels up) or the row just
    /// kept ("York" under "New York" stays). Consecutive short text rows join
    /// one line under the first number.
    private static func lines(_ nodes: [JSONValue]) -> [String] {
        var labels: [String: String] = [:], parents: [String: String] = [:], items: [Line] = []
        for case .object(let node) in nodes {
            guard let id = text(node["nodeId"]) else { continue }
            let (role, label) = roleAndLabel(node)
            labels[id] = label
            if let parent = text(node["parentNodeId"]) { parents[id] = parent }
            let acts = !Set(strings(node["actions"])).isDisjoint(with: ["click", "fill", "type", "select", "set_checked", "keypress"])
            let state = rowState(node)
            if label.isEmpty, state.isEmpty, !acts { continue }
            items.append(.init(number: id.hasPrefix("n") ? String(id.dropFirst()) : id, id: id, role: role, label: label, state: state, acts: acts))
        }
        var kept: [Line] = []
        for item in items {
            if item.acts || !item.state.isEmpty { kept.append(item); continue }
            guard item.label.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            var parent = parents[item.id], depth = 0, repeated = kept.last?.label == item.label
            while !repeated, let id = parent, depth < 4 {
                repeated = labels[id] == item.label
                parent = parents[id]; depth += 1
            }
            if repeated { continue }
            kept.append(item)
        }
        var joined: [Line] = [], open = false
        for item in kept {
            let plain = item.role == "text" && !item.acts && item.state.isEmpty && item.label.count < 120
            if plain, open, joined[joined.count - 1].label.count < 240 { joined[joined.count - 1].label += " · " + item.label; continue }
            joined.append(item); open = plain
        }
        return joined.map { line in
            String(repeating: " ", count: max(0, 3 - line.number.count)) + line.number + "  "
                + (line.role == "text" ? "" : line.role + " ") + line.label
                + (line.state.isEmpty ? "" : "  [" + line.state.joined(separator: "; ") + "]")
        }
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
            state.append("options: " + labels.prefix(30).joined(separator: " | ")
                + (labels.count > 30 ? " | +\(labels.count - 30)" : ""))
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
