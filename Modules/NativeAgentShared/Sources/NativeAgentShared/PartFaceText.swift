import Foundation
// Blueprint: | `PartFaceText.swift` | Page prose, committed form values, document openings and demand links for the agent door and Telegram |

/// Where a row leads, read once for every door: one of the agent's own places, or a web page the person opens in their own browser (http or
/// https). Any other scheme would let editable prose open an arbitrary handler. Each door maps these places to its own.
public enum FaceLink: Equatable, Sendable {
    case chat(String)
    case page(String, item: String?)
    case approval(String)
    case card(String)
    case dream(String)
    case url(URL)

    public init?(_ link: String) {
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let target = String(link[link.index(after: colon)...])
        guard !target.isEmpty else { return nil }
        switch link[..<colon] {
        case "chat": self = .chat(target)
        case "approval": self = .approval(target)
        case "card": self = .card(target)
        case "dream": self = .dream(target)
        case "page":
            let parts = target.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let page = parts.first, !page.isEmpty else { return nil }
            self = .page(page, item: parts.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 })
        case "url":
            guard let url = URL(string: target), ["http", "https"].contains(url.scheme), url.host?.isEmpty == false else { return nil }
            self = .url(url)
        default: return nil
        }
    }
}

extension PartFace {
    public static func isLink(_ link: String) -> Bool { FaceLink(link) != nil }

    /// Bounded page prose. The agent's door retains complete row references and action calls.
    public func text(lineLimit: Int? = nil, door: Bool = false, page: String? = nil) -> String {
        // The agent reads a row whole: a reason cut mid-sentence is a reason it cannot act on. A longer line still ends on a word.
        let limit = max(1, lineLimit ?? (door ? 1_200 : 240))
        func bounded(_ line: String) -> String {
            let flat = line.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard flat.count > limit else { return flat }
            let head = flat.prefix(limit - 1)
            let word = head.lastIndex(of: " ").map { head[..<$0] } ?? head
            return String(word.count > limit / 2 ? word : head) + "…"
        }
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append(title) }
        if let line, !line.isEmpty { lines.append(bounded(line)) }
        // The link leads, so a long title never cuts the address.
        if let opened { lines.append(bounded("Open now: " + opened.link + " · " + Self.oneLine(opened.title, limit: 80))) }
        for section in sections {
            if !lines.isEmpty { lines.append("") }
            if let title = section.title, !title.isEmpty { lines.append(title + (section.folded == true ? " (folded)" : "") + ":") }
            if let block = section.block {
                if block.kind == "document" {
                    if let text = block.text {
                        lines.append(bounded(text))
                        lines.append("Document: \(text.utf8.count) UTF-8 bytes")
                    } else { lines.append("Document: read on demand") }
                    if door, let read = block.read { lines.append("Read \(block.key) → " + read.text) }
                    if let page { lines.append("page:" + page + "/" + block.key) }
                } else if block.kind == "form" {
                    if block.protected == true || block.fields?.contains(where: { $0.kind == "secret" }) == true {
                        for field in block.fields ?? [] {
                            if field.kind == "secret" {
                                lines.append("- " + field.label + ": " + (block.secretSet.map { $0 ? "set" : "not set" } ?? "status not read"))
                            } else { lines.append("- " + field.label) }
                        }
                        lines.append("Protected entry opens on the Mac; no secret is carried by a page call.")
                    } else {
                        for field in block.fields ?? [] {
                            let value = field.value.map { value -> String in
                                if case .string(let text) = value { return text.isEmpty ? "(empty)" : bounded(text) }
                                return value.text
                            } ?? "(not supplied)"
                            lines.append("- " + field.label + ": " + value + (field.required == true ? " (required)" : ""))
                        }
                        for submit in block.submit ?? [] {
                            var words = submit.label + (submit.doorWords.map { " (" + $0 + ")" } ?? "")
                            if let reason = submit.unavailable { words += " (unavailable: " + reason + ")" }
                            if door, let call = submit.call { words += " → " + call.text + " with form values" }
                            lines.append("[" + words + "]")
                        }
                    }
                } else if block.kind == "leaf", let alt = block.alt { lines.append(alt) }
                else { lines.append(PartFace.Block.updateNote) }
                if let footer = section.footer { lines.append(bounded(footer)) }
                continue
            }
            // Folding is how a section is drawn for the person. The agent's reading keeps every folded row it could act on (a control or
            // an action) and counts the rest, so a fold never takes a call out of its reach.
            // A row's inline group reads on the row's own line, so its children are not listed again; rows they hold are listed beneath it.
            let listed = section.rows.flatMap(\.lineRows)
            func callable(_ row: Row) -> Bool { row.control != nil || row.actions?.isEmpty == false }
            func reachable(_ row: Row) -> Bool { callable(row) || row.group.contains(where: callable) }
            let rows = section.folded != true ? listed : door ? listed.filter(reachable) : []
            if section.folded == true, door, listed.count > rows.count {
                let quiet = listed.count - rows.count
                lines.append(quiet == 1 ? "1 folded row carries nothing to call and is not listed."
                    : "\(quiet) folded rows carry nothing to call and are not listed.")
            }
            /// A row's words, and its reference on the door (its id, its set call, where it opens, its actions), which is never cut.
            func reading(_ row: Row) -> (parts: [String], reference: String) {
                // A time reads as FaceView shows it: the clock time today, the day otherwise.
                let time = row.at.flatMap(FaceTime.short).map { $0 + " " } ?? ""
                // A meter with no words of its own reads as its amount.
                let value = row.value ?? row.meter.map { Self.amount($0.value) + " of " + Self.amount($0.max) }
                var parts = [time + row.title, row.detail ?? "", value ?? ""].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let control = row.control {
                    if let on = control.on { parts.append(on ? "on" : "off") }
                    if let text = control.text { parts.append(text.isEmpty ? "(empty)" : "\u{201C}" + text + "\u{201D}") }
                    if let number = control.number { parts.append(String(number.value)) }
                    if let date = control.date { parts.append(date) }
                    if let selected = control.selected, let option = control.options?.first(where: { $0.id == selected }) {
                        parts.append(option.label)
                    }
                }
                // An action that runs from some of the person's doors names them ("Reset identity (Mac)").
                let actions = row.actions.map { "[" + $0.map { action in
                    var words = action.label + (action.doorWords.map { " (" + $0 + ")" } ?? "")
                    if let reason = action.unavailable { words += " (unavailable: " + reason + ")" }
                    if door, let call = action.call { words += " → " + call.text }
                    if door, let open = action.open { words += " → opens " + open }
                    return words
                }.joined(separator: " | ") + "]" }
                // On the door the actions ride the reference, which is never cut; Telegram keeps them in the line.
                if !door, let actions, row.actions?.isEmpty == false { parts.append(actions) }
                var reference = ""
                if door, row.actions?.isEmpty == false || row.control != nil || row.open != nil {
                    let set = row.control.map { control in ", set" + (control.call.map { " → " + $0.text + " with value" } ?? "") } ?? ""
                    reference = " (row " + row.id + set + (row.open.map { ", opens " + $0 } ?? "") + ")"
                    if let actions, row.actions?.isEmpty == false { reference += " " + actions }
                }
                return (parts, reference)
            }
            for row in rows {
                let (parts, reference) = reading(row)
                guard !parts.isEmpty else { continue }
                // Each child of an inline group follows on the same line: its word and state, then its own reference.
                let group = row.group.map { child -> String in
                    let (words, reference) = reading(child)
                    return " · " + bounded(words.joined(separator: " ")) + reference
                }.joined()
                lines.append(bounded("- " + parts.joined(separator: " · ")) + reference + group)
                if row.expands == true {
                    if door, let read = row.read { lines.append("Read " + row.id + " → " + read.text) }
                    if let page { lines.append("page:" + page + "/" + row.id) }
                }
            }
            if let more = section.more {
                lines.append("Showing \(section.rows.count)" + (more.total.map { " of \($0)" } ?? "") + "; next cursor: " + more.next)
                if door, let read = more.read { lines.append("Read more → " + read.text + " with cursor " + more.next) }
                if let page { lines.append("page:" + page + "/" + section.id + ", offset:" + more.next) }
            }
            if let footer = section.footer, !footer.isEmpty { lines.append(bounded(footer)) }
        }
        if let detail { lines.append("Read an item from " + detail.of + " through its page link.") }
        return lines.joined(separator: "\n")
    }

    /// Words for one line in a person's message or a page read: every whitespace run (newlines included) one space, cut on a word to `limit`
    /// characters.
    public static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit, limit > 1 else { return flat }
        let head = flat.prefix(limit - 1)
        let word = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return String(word) + "…"
    }

    /// A meter's number as words: a whole number without a decimal point.
    private static func amount(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}

extension PartFaceSnapshot {
    /// Native levers remain readable beside the face or its owner's failure.
    public func text(title: String, lineLimit: Int? = nil, door: Bool = false, page: String? = nil) -> String {
        var blocks: [String] = []
        let drawn = drawnFace
        if let drawn, let header = PartFace(title: drawn.title, line: drawn.line, sections: [], opened: drawn.opened)
            .text(lineLimit: lineLimit, door: door).nonEmpty {
            blocks.append(header)
        }
        if let levers, let words = PartFace(sections: levers).text(lineLimit: lineLimit, door: door).nonEmpty { blocks.append(words) }
        if let drawn {
            if let words = PartFace(sections: drawn.sections, detail: drawn.detail).text(lineLimit: lineLimit, door: door, page: page).nonEmpty {
                blocks.append(words)
            }
        } else {
            blocks.append(error?.message ?? title + " is " + status.rawValue + ".")
            if let keyLevers, let words = PartFace(sections: keyLevers).text(lineLimit: lineLimit, door: door).nonEmpty { blocks.append(words) }
        }
        return blocks.joined(separator: "\n\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Notification.Name {
    /// Engine-side discovery invalidation; a completed inventory settles pending action-index reads.
    public static let pageCatalogPublished = Notification.Name("pageCatalogPublished")

    /// A page's face changed (object: the page id). Doors that carry faces elsewhere (the phone) publish on it instead of waiting for an
    /// unrelated pass.
    public static let pageFacePublished = Notification.Name("pageFacePublished")
}
