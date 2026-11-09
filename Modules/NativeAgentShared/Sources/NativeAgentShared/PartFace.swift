import Foundation
// Blueprint: | `PartFace.swift` | Shared page values, documents, typed forms and installed-phone notes; feed keys and catalog |

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

/// A page's shared presentation. `PartFace.bound` binds row references and calls to the page owner's declared keys.
public struct PartFace: Codable, Sendable, Equatable {
    /// How a section reads: a card of rows, a timeline of moments, a flow of pills, label/value rows, a quiet note, or a waiting card.
    public enum Style: String, Codable, Sendable {
        case list, timeline, flow, values, note, waiting
    }

    public enum Tone: String, Codable, Sendable {
        case plain, quiet, attention, failed, done, live
    }

    /// A call's argument, as JSON: the one value shape a door call carries on every device.
    public indirect enum Value: Codable, Sendable, Equatable {
        case string(String), int(Int64), double(Double), bool(Bool), null
        case array([Value]), object([String: Value])

        public var stringValue: String? {
            if case .string(let value) = self { value } else { nil }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int64.self) { self = .int(value) }
            else if let value = try? container.decode(Double.self) { self = .double(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        /// Compact JSON with sorted keys, as a door reads it.
        public var text: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
            return text
        }
    }

    /// What an action does: one door call, `app {action, args}`. The person's tap and the agent's call are the same call through the same
    /// door, judged by the same Trust law; the agent's door reads it on the row.
    public struct Call: Codable, Sendable, Equatable {
        public let action: String
        public let args: [String: Value]
        public init(_ action: String, _ args: [String: Value] = [:]) { self.action = action; self.args = args }
        /// Controls and form adapters bind a setting's submitted value identically.
        public func setting(_ value: Value) -> Self {
            Self(action, args.merging(["value": value]) { _, new in new })
        }
        /// The call as a door reads it: `desk.close {"handle":"d-12"}`.
        public var text: String { args.isEmpty ? action : action + " " + Value.object(args).text }
    }

    /// Something the person can do to a row: a door call (`call`), or a place it opens (`open`, a link like a row's). Exactly one.
    public struct Action: Codable, Sendable, Equatable, Identifiable {
        public enum Role: String, Codable, Sendable {
            case plain, primary, destructive
        }
        public let id: String
        public let label: String
        public let role: Role?
        /// The person's doors it runs from (`mac`, `phone`); absent, every door. Another door neither draws it nor accepts it, and the agent's
        /// door reads it with the doors it runs from.
        public let doors: [String]?
        public let call: Call?
        public let open: String?
        public let unavailable: String?
        public init(id: String, label: String, role: Role? = nil, doors: [String]? = nil, call: Call? = nil, open: String? = nil,
                    unavailable: String? = nil) {
            self.id = id; self.label = label; self.role = role; self.doors = doors; self.call = call; self.open = open
            self.unavailable = unavailable
        }
        public func runs(from door: String) -> Bool {
            guard let doors else { return true }
            return doors.contains(door)
        }
        /// The doors it runs from, as a reader names them ("Mac"), or nil when it runs from every door.
        public var doorWords: String? {
            guard let doors else { return nil }
            return doors.map { door -> String in door.prefix(1).uppercased() + String(door.dropFirst()) }.joined(separator: " or ")
        }
    }

    /// A setting the row is: a switch, one choice among options, or words the person types (a search, a field). Changing it makes `call`
    /// with the new value as its `value` argument: a switch's Boolean, a choice's option id, a field's words (a field sends on return).
    public struct Control: Codable, Sendable, Equatable {
        public struct Number: Codable, Sendable, Equatable {
            public let value: Double
            public let min: Double?
            public let max: Double?
            public let step: Double?
            public init(value: Double, min: Double? = nil, max: Double? = nil, step: Double? = nil) {
                self.value = value; self.min = min; self.max = max; self.step = step
            }
        }
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
        public var call: Call?
        public let number: Number?
        public let date: String?
        public static func toggle(_ on: Bool, confirm: String? = nil, call: Call? = nil) -> Control {
            Control(on: on, options: nil, selected: nil, confirm: confirm, call: call)
        }
        public static func choice(_ options: [Option], selected: String?, confirm: String? = nil, call: Call? = nil) -> Control {
            Control(on: nil, options: options, selected: selected, confirm: confirm, call: call)
        }
        public static func field(_ text: String, placeholder: String? = nil, call: Call? = nil) -> Control {
            Control(on: nil, options: nil, selected: nil, text: text, placeholder: placeholder, call: call)
        }
        public init(on: Bool? = nil, options: [Option]? = nil, selected: String? = nil, confirm: String? = nil,
                    text: String? = nil, placeholder: String? = nil, call: Call? = nil, number: Number? = nil, date: String? = nil) {
            self.on = on; self.options = options; self.selected = selected; self.confirm = confirm
            self.text = text; self.placeholder = placeholder; self.call = call
            self.number = number; self.date = date
        }
        /// The call a change makes: `call` with the person's new value (as the view sends it: "on"/"off", an option id, the field's words)
        /// as its `value`. Nil when the control makes no call or the value is not one it offers.
        public func settingCall(_ value: String) -> Call? {
            guard let call else { return nil }
            let typed: Value
            if on != nil {
                guard value == "on" || value == "off" else { return nil }
                typed = .bool(value == "on")
            } else if let options {
                guard options.contains(where: { $0.id == value }) else { return nil }
                typed = .string(value)
            } else if text != nil {
                typed = .string(value)
            } else if let number {
                guard let amount = Double(value), amount.isFinite,
                      number.min.map({ amount >= $0 }) != false, number.max.map({ amount <= $0 }) != false else { return nil }
                typed = .double(amount)
            } else if date != nil {
                do { _ = try Date.ISO8601FormatStyle().parse(value) }
                catch { return nil }
                typed = .string(value)
            } else { return nil }
            return call.setting(typed)
        }
    }

    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public let title: String
        public var detail: String?
        public let value: String?
        /// When it happened (ISO 8601).
        public let at: String?
        /// An SF Symbols name; a platform without it draws none.
        public let symbol: String?
        public let tone: Tone?
        /// Where the row leads: `chat:<session>`, `page:<page>[/<row>]`, `approval:<id>`, `card:<id>`, `dream:<id>` or `url:<https url>`.
        public let open: String?
        public var actions: [Action]?
        public var control: Control?
        public var rows: [Row]?
        public var expands: Bool?
        public var read: Call?
        public init(id: String, title: String, detail: String? = nil, value: String? = nil, at: String? = nil, symbol: String? = nil,
                    tone: Tone? = nil, open: String? = nil, actions: [Action]? = nil, control: Control? = nil,
                    rows: [Row]? = nil, expands: Bool? = nil, read: Call? = nil) {
            (self.id, self.title, self.detail, self.value, self.at) = (id, title, detail, value, at)
            (self.symbol, self.tone, self.open, self.actions, self.control) = (symbol, tone, open, actions, control)
            self.rows = rows; self.expands = expands; self.read = read
        }
        public var descendants: [Row] { [self] + (rows ?? []).flatMap(\.descendants) }
    }

    public struct FormField: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let kind: String
        public let value: Value?
        public let placeholder: String?
        public let required: Bool?
        public let options: [Control.Option]?
        public let min: Double?
        public let max: Double?
        public let step: Double?
        public init(id: String, label: String, kind: String = "line", value: Value? = nil, placeholder: String? = nil,
                    required: Bool? = nil, options: [Control.Option]? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil) {
            self.id = id; self.label = label; self.kind = kind; self.value = value; self.placeholder = placeholder
            self.required = required; self.options = options; self.min = min; self.max = max; self.step = step
        }

        public func issue(for value: Value?) -> String? {
            guard ["line", "lines", "choice", "switch", "number", "date"].contains(kind) else {
                return kind == "secret" ? "\(label) requires its protected entry owner." : "\(label) has no supported \(kind) value."
            }
            guard let value, value != .null else { return required == true ? "\(label) is required." : nil }
            switch (kind, value) {
            case ("line", .string(let text)), ("lines", .string(let text)):
                return required == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(label) is required." : nil
            case ("choice", .string(let selected)):
                return options?.contains(where: { $0.id == selected }) == true ? nil : "Choose an offered \(label.lowercased())."
            case ("switch", .bool): return nil
            case ("number", .int(let value)): return numberIssue(Double(value))
            case ("number", .double(let value)): return numberIssue(value)
            case ("date", .string(let value)):
                do { _ = try Date.ISO8601FormatStyle().parse(value); return nil }
                catch { return "\(label) must be an ISO 8601 date." }
            default: return "\(label) has no supported \(kind) value."
            }
        }

        private func numberIssue(_ value: Double) -> String? {
            guard value.isFinite, min.map({ value >= $0 }) != false, max.map({ value <= $0 }) != false else {
                return "\(label) must be a finite number within its bounds."
            }
            return nil
        }
    }

    /// Open kinds let an installed door draw the section's note without losing its page.
    public struct Block: Codable, Sendable, Equatable {
        public let kind: String
        public let key: String
        public let text: String?
        public let format: String?
        public let language: String?
        public let copy: Bool?
        public var read: Call?
        /// The native owner's document revision; authored reads carry their identity in the bound call.
        public var revision: String?
        public let leaf: String?
        public let ref: String?
        public let alt: String?
        public let fields: [FormField]?
        public var submit: [Action]?
        public let protected: Bool?
        public let receiver: String?
        public var secretSet: Bool?
        public var secretPage: String?
        public let doors: [String]?
        public init(kind: String = "document", key: String, text: String? = nil, format: String? = nil,
                    language: String? = nil, copy: Bool? = nil, read: Call? = nil, revision: String? = nil,
                    leaf: String? = nil, ref: String? = nil, alt: String? = nil,
                    fields: [FormField]? = nil, submit: [Action]? = nil, protected: Bool? = nil,
                    receiver: String? = nil, doors: [String]? = nil) {
            self.kind = kind; self.key = key; self.text = text; self.format = format
            self.language = language; self.copy = copy; self.read = read; self.revision = revision
            self.leaf = leaf; self.ref = ref; self.alt = alt
            self.fields = fields; self.submit = submit; self.protected = protected; self.doors = doors
            self.receiver = receiver
        }
        public func formIssues(values: [String: Value]) -> [String: String] {
            var issues: [String: String] = [:]
            let fields = fields ?? []
            let ids = Set(fields.map(\.id))
            for key in values.keys where !ids.contains(key) { issues[key] = "This form has no field named \(key)." }
            for field in fields { if let issue = field.issue(for: values[field.id]) { issues[field.id] = issue } }
            return issues
        }
        public static let inlineByteLimit = 16 * 1024
        public static let updateNote = "Update NativeAgent on this iPhone to see this."
    }

    public struct More: Codable, Sendable, Equatable {
        public let next: String
        public let total: Int?
        public let revision: String?
        public var read: Call?
        public init(next: String, total: Int? = nil, revision: String? = nil, read: Call? = nil) {
            self.next = next; self.total = total; self.revision = revision; self.read = read
        }
    }

    public struct Detail: Codable, Sendable, Equatable {
        public let of: String
        public init(of: String) { self.of = of }
    }

    public struct Section: Codable, Sendable, Equatable, Identifiable {
        private static let continuationNote = "More rows are available on your Mac."
        public var allRows: [Row] { rows.flatMap(\.descendants) }
        public var id: String
        public let title: String?
        public let style: Style?
        public var footer: String?
        public var rows: [Row]
        public var block: Block?
        public var more: More?
        public var filter: String?
        public var revision: String?
        /// Drawn as one header row (its title) with a disclosure; its rows show when the reader opens it. Open or closed is each view's own
        /// and is never written back to the face.
        public var folded: Bool?
        public init(id: String, title: String? = nil, style: Style? = nil, footer: String? = nil, rows: [Row], folded: Bool? = nil,
                    block: Block? = nil, more: More? = nil, filter: String? = nil, revision: String? = nil) {
            self.id = id; self.title = title; self.style = style; self.footer = footer; self.rows = rows; self.folded = folded
            self.block = block
            self.more = more; self.filter = filter; self.revision = revision
        }

        private enum CodingKeys: String, CodingKey { case id, title, style, footer, rows, folded, block, more, filter, revision }
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            title = try fields.decodeIfPresent(String.self, forKey: .title)
            style = try fields.decodeIfPresent(Style.self, forKey: .style)
            let wireFooter = try fields.decodeIfPresent(String.self, forKey: .footer)
            folded = try fields.decodeIfPresent(Bool.self, forKey: .folded)
            block = try fields.decodeIfPresent(Block.self, forKey: .block)
            more = try fields.decodeIfPresent(More.self, forKey: .more)
            if more != nil, wireFooter == Self.continuationNote { footer = nil }
            else if more != nil, let wireFooter, wireFooter.hasSuffix("\n" + Self.continuationNote) {
                footer = String(wireFooter.dropLast(Self.continuationNote.count + 1))
            } else { footer = wireFooter }
            filter = try fields.decodeIfPresent(String.self, forKey: .filter)
            revision = try fields.decodeIfPresent(String.self, forKey: .revision)
            if block != nil { rows = [.init(id: "document-note", title: Block.updateNote, tone: .quiet)] }
            else { rows = try fields.decode([Row].self, forKey: .rows) }
        }

        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(id, forKey: .id)
            try fields.encodeIfPresent(title, forKey: .title)
            try fields.encodeIfPresent(style, forKey: .style)
            // Installed phones ignore `more`; its footer keeps the undisplayed collection reachable.
            let wireFooter = more == nil ? footer : footer.map { $0 + "\n" + Self.continuationNote } ?? Self.continuationNote
            try fields.encodeIfPresent(wireFooter, forKey: .footer)
            try fields.encodeIfPresent(folded, forKey: .folded)
            try fields.encodeIfPresent(block, forKey: .block)
            try fields.encodeIfPresent(more, forKey: .more)
            try fields.encodeIfPresent(filter, forKey: .filter)
            try fields.encodeIfPresent(revision, forKey: .revision)
            let wireRows = block == nil ? rows : [.init(id: "document-note", title: Block.updateNote, tone: .quiet)]
            try fields.encode(wireRows, forKey: .rows)
        }

        /// The section as one of the person's doors draws it: each row keeps the actions that run from that door, and a row that was only
        /// actions for other doors (no link, no control) is not drawn there.
        public func drawn(on door: String) -> Section {
            func draw(_ row: Row) -> Row? {
                var drawn = row
                drawn.rows = row.rows.map { $0.compactMap(draw) }
                if let actions = row.actions, actions.contains(where: { !$0.runs(from: door) }) {
                    let kept = actions.filter { $0.runs(from: door) }
                    if kept.isEmpty, row.open == nil, row.control == nil, drawn.rows?.isEmpty != false, row.expands != true { return nil }
                    drawn.actions = kept
                }
                return drawn
            }
            var drawn = self
            drawn.rows = rows.compactMap(draw)
            if var block = block, block.kind == "form" {
                if let doors = block.doors, !doors.contains(door) {
                    drawn.block = Block(kind: "unavailable", key: block.key)
                } else {
                    block.submit = block.submit?.filter { $0.runs(from: door) }
                    drawn.block = block
                }
            }
            return drawn
        }
    }

    /// The page's name and its one sentence.
    public let title: String?
    public let line: String?
    public var sections: [Section]
    public var detail: Detail?
    public var allRows: [Row] { sections.flatMap(\.allRows) }
    public init(title: String? = nil, line: String? = nil, sections: [Section], detail: Detail? = nil) {
        self.title = title; self.line = line; self.sections = sections; self.detail = detail
    }
}

/// Native owners supply status, owed state and the person's levers beside the authored face.
public struct PartFaceSnapshot: FaceValue {
    public enum Status: String, Codable, Sendable { case ready, unavailable, failed }
    public let part: String
    public let version: String?
    public let sourceEpoch: UInt64
    public let status: Status
    public let face: PartFace?
    public let error: PartCallError?
    public let owed: Bool
    public let levers: [PartFace.Section]?
    public let keyLevers: [PartFace.Section]?
    public init(part: String, version: String?, sourceEpoch: UInt64, status: Status, face: PartFace?, error: PartCallError?, owed: Bool,
                levers: [PartFace.Section]? = nil, keyLevers: [PartFace.Section]? = nil) {
        self.part = part; self.version = version; self.sourceEpoch = sourceEpoch
        self.status = status; self.face = face; self.error = error; self.owed = owed; self.levers = levers; self.keyLevers = keyLevers
    }

    /// Authored copy carries its preparation failure wherever its words are drawn.
    public func copyWords(readyOnly: Bool = false) -> String? {
        if status == .ready { return face?.sections.first?.rows.first?.title }
        if readyOnly { return nil }
        return "Readout " + status.rawValue + ": " + (error?.message ?? status.rawValue)
    }

    /// Key levers retain their native subject and remain reachable when the authored face omits their row.
    public var drawnFace: PartFace? {
        guard status == .ready, let face else { return nil }
        let stemRows = (keyLevers ?? []).flatMap(\.allRows)
        guard !stemRows.isEmpty else { return face }
        let riding = Dictionary(stemRows.map { ($0.id, $0.actions ?? []) }, uniquingKeysWith: +)
        let subjects = Dictionary(stemRows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let drawn = Set(face.allRows.map(\.id))
        func ridingRow(_ row: PartFace.Row) -> PartFace.Row {
            var result = row
            result.rows = row.rows.map { $0.map(ridingRow) }
            guard let levers = riding[row.id], !levers.isEmpty else { return result }
            let named = subjects[row.id].flatMap { $0 == row.title ? nil : $0 }
            result.actions = (row.actions ?? []) + levers.map { lever in
                named.map { PartFace.Action(id: lever.id, label: lever.label + " \u{201C}" + $0 + "\u{201D}", role: lever.role,
                    doors: lever.doors, call: lever.call, open: lever.open, unavailable: lever.unavailable) } ?? lever
            }
            return result
        }
        var sections = face.sections.map { section in
            var drawn = section
            drawn.rows = section.rows.map(ridingRow)
            return drawn
        }
        sections += (keyLevers ?? []).compactMap { section in
            func missingRows(_ rows: [PartFace.Row]) -> [PartFace.Row] {
                rows.flatMap { row in
                    if !drawn.contains(row.id) { return [row] }
                    return missingRows(row.rows ?? [])
                }
            }
            let missing = missingRows(section.rows)
            guard !missing.isEmpty else { return nil }
            var drawn = section
            drawn.id = "stem:" + section.id
            drawn.rows = missing
            drawn.folded = true
            drawn.footer = nil
            return drawn
        }
        var drawnFace = face
        drawnFace.sections = sections
        return drawnFace
    }
}

/// Projection keys contain slashes, which authored page ids cannot contain.
public enum PageFaceKey {
    public static func item(_ page: String, _ item: String) -> FaceKey { .page(page + "/" + item) }
    public static let catalog = FaceKey.page("catalog/own-pages")
    public static func phone(_ page: String) -> FaceKey { .page("phone/" + page) }
    public static func copy(_ key: String) -> FaceKey { .page("copy/" + key) }
    public static func makeTitle(file: URL, revision: Int) -> FaceKey { .page("make-title/\(revision)/" + file.path) }
}

/// A completed inventory retains known claims beside an inventory failure; no value means discovery is still pending.
public struct PartFaceCatalog: FaceValue {
    public enum Claim: Sendable, Equatable, Codable {
        case success(String)
        case failure(PartCallError)
    }
    public let claims: [String: Claim]
    public let failure: PartCallError?
    public init(claims: [String: Claim], failure: PartCallError? = nil) { self.claims = claims; self.failure = failure }
}
