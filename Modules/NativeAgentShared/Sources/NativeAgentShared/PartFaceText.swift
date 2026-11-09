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
    public func text(lineLimit: Int = 240, door: Bool = false, page: String? = nil) -> String {
        func bounded(_ line: String) -> String {
            let flat = line.split(whereSeparator: \.isNewline).joined(separator: " ")
            return flat.count <= lineLimit ? flat : String(flat.prefix(max(1, lineLimit) - 1)) + "…"
        }
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append(title) }
        if let line, !line.isEmpty { lines.append(bounded(line)) }
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
            for row in section.folded == true ? [] : section.allRows {
                // A time reads as FaceView shows it: the clock time today, the day otherwise.
                let time = row.at.flatMap(FaceTime.short).map { $0 + " " } ?? ""
                var parts = [time + row.title, row.detail ?? "", row.value ?? ""].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
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
                guard !parts.isEmpty else { continue }
                var reference = ""
                if door, row.actions?.isEmpty == false || row.control != nil || row.open != nil {
                    let set = row.control.map { control in ", set" + (control.call.map { " → " + $0.text + " with value" } ?? "") } ?? ""
                    reference = " (row " + row.id + set + (row.open.map { ", opens " + $0 } ?? "") + ")"
                    if let actions, row.actions?.isEmpty == false { reference += " " + actions }
                }
                lines.append(bounded("- " + parts.joined(separator: " · ")) + reference)
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
}

extension PartFaceSnapshot {
    /// Native levers remain readable beside the face or its owner's failure.
    public func text(title: String, lineLimit: Int = 240, door: Bool = false, page: String? = nil) -> String {
        var blocks: [String] = []
        let drawn = drawnFace
        if let drawn, let header = PartFace(title: drawn.title, line: drawn.line, sections: []).text(lineLimit: lineLimit, door: door).nonEmpty {
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
