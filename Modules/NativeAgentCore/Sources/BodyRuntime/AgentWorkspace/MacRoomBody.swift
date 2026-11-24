import Foundation

// Blueprint: | `MacRoomBody.swift` | Turn-free body readings for Home and the Mac room, and the window observed by a Mac verb |

package struct MacRoom: Equatable, Sendable {
    package let front: String?
    package let readable: Bool
    package let onConsole: Bool
    package let locked: Bool
    package let running: [String]

    package init(front: String?, readable: Bool, onConsole: Bool, locked: Bool, running: [String]) {
        self.front = front
        self.readable = readable
        self.onConsole = onConsole
        self.locked = locked
        self.running = running
    }
}

package struct MacRoomWindow: Codable, Equatable, Sendable {
    package let app: String
    package let kind: String?
    package let readout: String?
    package let at: Double
    func isRecent(at now: Date) -> Bool { at + 4 * 3600 > now.timeIntervalSince1970 }

    package init(app: String, kind: String?, readouts: [String], before: [String]) {
        self.app = AgentScreen.clip(app, 40)
        self.kind = kind.map { $0.contains("AXSheet") ? "sheet" : $0.contains("Dialog") ? "dialog" : $0.contains("Floating") ? "panel" : "window" }
        func value(_ raw: String) -> String? {
            let text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count <= 24 && text.range(of: #"^[\d\s.,:+\-−×÷=%$€£()/]*\d[\d\s.,:+\-−×÷=%$€£()/]*[a-zA-Z%°]{0,3}$"#,
                                                  options: .regularExpression) != nil ? text : nil
        }
        let values = readouts.compactMap(value), earlier = Set(before.compactMap(value))
        func result(_ text: String) -> Bool { text.dropFirst().range(of: #"[+\-−×÷=/]"#, options: .regularExpression) == nil }
        let changed = values.filter { !earlier.contains($0) }
        readout = changed.first(where: result) ?? changed.first ?? values.first(where: result) ?? values.first
        at = Date().timeIntervalSince1970
    }
}

extension BodyField {
    static func require(_ body: BodyField?) throws -> BodyField {
        guard let body else { throw AgentScreen.NameFailure("The Mac body field is closed.") }
        return body
    }
}
