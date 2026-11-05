import Foundation
// Blueprint: | `PartFaceText.swift` | A page's face read as text for the agent's door and Telegram, and the links a row may lead to |

extension PartFace {
    /// The places a row may lead: the agent's own places, or a web page the person opens in their own browser (http or https). Any other scheme
    /// would let editable prose open an arbitrary handler.
    public static func isLink(_ link: String) -> Bool {
        ["chat:", "page:", "approval:", "card:", "dream:"].contains { link.hasPrefix($0) && link.count > $0.count }
            || ["url:https://", "url:http://"].contains { link.hasPrefix($0) && link.count > $0.count }
    }

    /// The same page as words: its title and sentence, then each section as a heading and its rows as "time title · detail · value", a
    /// control's state, and its actions in brackets. Lines are bounded so a long row never floods a door. For the agent's door (`door`), a row the
    /// agent can act on also names its id, where it leads and its action ids, so the agent can answer it through the page's port.
    public func text(lineLimit: Int = 240, door: Bool = false) -> String {
        func bounded(_ line: String) -> String {
            let flat = line.split(whereSeparator: \.isNewline).joined(separator: " ")
            return flat.count <= lineLimit ? flat : String(flat.prefix(lineLimit - 1)) + "…"
        }
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append(title) }
        if let line, !line.isEmpty { lines.append(bounded(line)) }
        for section in sections {
            if !lines.isEmpty { lines.append("") }
            if let title = section.title, !title.isEmpty { lines.append(title + ":") }
            for row in section.rows {
                // A time reads as FaceView shows it: the clock time today, the day otherwise.
                let time = row.at.flatMap(FaceTime.short).map { $0 + " " } ?? ""
                var parts = [time + row.title, row.detail ?? "", row.value ?? ""].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let control = row.control {
                    if let on = control.on { parts.append(on ? "on" : "off") }
                    if let text = control.text { parts.append(text.isEmpty ? "(empty)" : "\u{201C}" + text + "\u{201D}") }
                    if let selected = control.selected, let option = control.options?.first(where: { $0.id == selected }) {
                        parts.append(option.label)
                    }
                }
                let actions = row.actions.map { "[" + $0.map { door ? $0.id + " = " + $0.label : $0.label }.joined(separator: " | ") + "]" }
                // On the door the actions ride the reference, which is never cut; Telegram keeps them in the line.
                if !door, let actions, row.actions?.isEmpty == false { parts.append(actions) }
                guard !parts.isEmpty else { continue }
                // The reference is never cut: a bounded row still names what the agent can do with it.
                var reference = ""
                if door, row.actions?.isEmpty == false || row.control != nil || row.open != nil {
                    reference = " (row " + row.id + (row.control != nil ? ", set" : "") + (row.open.map { ", opens " + $0 } ?? "") + ")"
                    if let actions, row.actions?.isEmpty == false { reference += " " + actions }
                }
                lines.append(bounded("- " + parts.joined(separator: " · ")) + reference)
            }
            if let footer = section.footer, !footer.isEmpty { lines.append(bounded(footer)) }
        }
        return lines.joined(separator: "\n")
    }
}

extension Notification.Name {
    /// A page's face changed (object: the page id). Doors that carry faces elsewhere (the phone) publish on it instead of waiting for an
    /// unrelated pass.
    public static let pageFacePublished = Notification.Name("pageFacePublished")
}
