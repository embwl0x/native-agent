import Foundation
// Blueprint: | `PartFace.swift` | Shared part results and faces; native owners supply availability and repair evidence |

/// A decision, never authority to commit it. Shared by native and JS callers.
public enum PartCallResult<Value: Codable & Sendable>: Codable, Sendable {
    case success(Value)
    case failure(PartCallError)
    private enum CodingKeys: String, CodingKey { case ok, value, error }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if try fields.decode(Bool.self, forKey: .ok) {
            self = .success(try fields.decode(Value.self, forKey: .value))
        } else { self = .failure(try fields.decode(PartCallError.self, forKey: .error)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let value):
            try fields.encode(true, forKey: .ok); try fields.encode(value, forKey: .value)
        case .failure(let error):
            try fields.encode(false, forKey: .ok); try fields.encode(error, forKey: .error)
        }
    }
}

public struct PartCallError: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// A page: the agent's reading of one part of its life, in one vocabulary every door draws the same way (`FaceView` on the Mac and the iPhone,
/// `text` for the agent's door and Telegram). What a row does goes back to the page's owner (`PartFaces.act`). Everything beyond sections of
/// titled rows is optional, so every face written before it stays valid; a value a newer build wrote that this one cannot read reads plain.
public struct PartFace: Codable, Sendable, Equatable {
    /// How a section reads: a card of rows, a timeline of moments, a flow of pills, label/value rows, a quiet note, or a waiting card.
    public enum Style: String, Codable, Sendable {
        case list, timeline, flow, values, note, waiting
        public init(from decoder: Decoder) throws {
            self = Style(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .list
        }
    }

    public enum Tone: String, Codable, Sendable {
        case plain, quiet, attention, failed, done, live
        public init(from decoder: Decoder) throws {
            self = Tone(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .plain
        }
    }

    /// Something the person can do to a row; its owner answers it.
    public struct Action: Codable, Sendable, Equatable, Identifiable {
        public enum Role: String, Codable, Sendable {
            case plain, primary, destructive
            public init(from decoder: Decoder) throws {
                self = Role(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .plain
            }
        }
        public let id: String
        public let label: String
        public let role: Role?
        public init(id: String, label: String, role: Role? = nil) { self.id = id; self.label = label; self.role = role }
    }

    /// A setting the row is: a switch, one choice among options, or words the person types (a search, a field). Changing it is the action "set"
    /// with the new value (a field sends on return).
    public struct Control: Codable, Sendable, Equatable {
        public struct Option: Codable, Sendable, Equatable, Identifiable {
            public let id: String
            public let label: String
            public init(id: String, label: String) { self.id = id; self.label = label }
        }
        public let on: Bool?
        public let options: [Option]?
        public let selected: String?
        /// Asked before the change is sent (a raise of what the agent may do); the owner still decides.
        public let confirm: String?
        /// A field's current words and the hint it shows when empty.
        public let text: String?
        public let placeholder: String?
        public static func toggle(_ on: Bool, confirm: String? = nil) -> Control {
            Control(on: on, options: nil, selected: nil, confirm: confirm)
        }
        public static func choice(_ options: [Option], selected: String?, confirm: String? = nil) -> Control {
            Control(on: nil, options: options, selected: selected, confirm: confirm)
        }
        public static func field(_ text: String, placeholder: String? = nil) -> Control {
            Control(on: nil, options: nil, selected: nil, text: text, placeholder: placeholder)
        }
        public init(on: Bool?, options: [Option]?, selected: String?, confirm: String? = nil, text: String? = nil, placeholder: String? = nil) {
            self.on = on; self.options = options; self.selected = selected; self.confirm = confirm
            self.text = text; self.placeholder = placeholder
        }
    }

    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String?
        public let value: String?
        /// When it happened (ISO 8601).
        public let at: String?
        /// An SF Symbols name; a platform without it draws none.
        public let symbol: String?
        public let tone: Tone?
        /// Where the row leads: `chat:<session>`, `page:<page>[/<row>]`, `approval:<id>`, `card:<id>`, `dream:<id>` or `url:<https url>`.
        public let open: String?
        public let actions: [Action]?
        public let control: Control?
        public init(id: String, title: String, detail: String? = nil, value: String? = nil, at: String? = nil, symbol: String? = nil,
                    tone: Tone? = nil, open: String? = nil, actions: [Action]? = nil, control: Control? = nil) {
            (self.id, self.title, self.detail, self.value, self.at) = (id, title, detail, value, at)
            (self.symbol, self.tone, self.open, self.actions, self.control) = (symbol, tone, open, actions, control)
        }
    }

    public struct Section: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String?
        public let style: Style?
        public let footer: String?
        public let rows: [Row]
        public init(id: String, title: String? = nil, style: Style? = nil, footer: String? = nil, rows: [Row]) {
            self.id = id; self.title = title; self.style = style; self.footer = footer; self.rows = rows
        }
    }

    /// The page's name and its one sentence.
    public let title: String?
    public let line: String?
    public let sections: [Section]
    public init(title: String? = nil, line: String? = nil, sections: [Section]) { self.title = title; self.line = line; self.sections = sections }
}

/// Only native source/obligation owners supply status and owed. Both platforms render these beside, rather than from within, the part's editable prose.
public struct PartFaceSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ready, unavailable, failed }
    public let part: String
    public let version: String?
    public let sourceEpoch: UInt64
    public let status: Status
    public let face: PartFace?
    public let error: PartCallError?
    public let owed: Bool
    public init(part: String, version: String?, sourceEpoch: UInt64, status: Status,
                face: PartFace?, error: PartCallError?, owed: Bool) {
        self.part = part; self.version = version; self.sourceEpoch = sourceEpoch
        self.status = status; self.face = face; self.error = error; self.owed = owed
    }
}
