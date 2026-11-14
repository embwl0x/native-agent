import Foundation
@_exported import NativeAgentShared
import PersistenceCore
// Blueprint: | `PartCall.swift` | Strict document, form and collection vocabulary bound to packet-owned calls and reads |

extension PartFace {
    /// Validate before decode so editable prose cannot forge native status and ids stay unambiguous across UIs.
    public static func decode(_ value: JSONValue, documentRead: Bool = false) throws -> PartFace {
        func object(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
            guard case .object(let fields) = value, Set(fields.keys).isSubset(of: keys) else {
                throw PartCallError(code: "bad_face", message: "A face holds title, line, detail, opened and sections; a section id, title, style, "
                    + "footer, rows, folded, beside, more and filter; a section may hold a document, form or leaf block instead of rows; "
                    + "a row id, title, detail, value, at, symbol, tone, open, actions, control, rows, expands and meter; a meter value, max and start; "
                    + "an action id, label, role and unavailable.")
            }
            return fields
        }
        func finite(_ value: JSONValue?, _ what: String) throws -> Double? {
            guard let value else { return nil }
            let result: Double
            switch value {
            case .int(let value): result = Double(value)
            case .double(let value): result = value
            default: throw PartCallError(code: "bad_face", message: "\(what) is a finite number.")
            }
            guard result.isFinite else { throw PartCallError(code: "bad_face", message: "\(what) is a finite number.") }
            return result
        }
        func list(_ value: JSONValue?, at most: Int, _ what: String) throws -> [JSONValue] {
            guard let value else { return [] }
            guard case .array(let items) = value, items.count <= most else {
                throw PartCallError(code: "bad_face", message: "A face's \(what) is a list of at most \(most).")
            }
            return items
        }
        func rows(_ value: JSONValue?, depth: Int, count: inout Int, ids: inout Set<String>) throws {
            let items = try list(value, at: 256, "section rows")
            guard items.isEmpty || depth <= 4 else {
                throw PartCallError(code: "bad_face", message: "Inline rows nest to depth 4; declare an expanding row's read for deeper evidence.")
            }
            for row in items {
                count += 1
                guard count <= 256 else {
                    throw PartCallError(code: "bad_face", message: "A section holds at most 256 rows including nested rows; use more for a continuation.")
                }
                let fields = try object(row, keys: ["id", "title", "detail", "value", "at", "symbol", "tone", "open", "actions", "control",
                                                    "rows", "inline", "expands", "meter"])
                guard case .string(let id)? = fields["id"], !id.isEmpty, ids.insert(id).inserted else {
                    throw PartCallError(code: "bad_face", message: "Row ids are nonempty and unique within their section, including nested rows.")
                }
                if case .string(let link)? = fields["open"], !Self.isLink(link) {
                    throw PartCallError(code: "bad_face", message: "A row opens chat:, page:, approval:, card:, dream:, url:https:// or url:http:// only.")
                }
                if let expands = fields["expands"], expands != .bool(true), expands != .bool(false) {
                    throw PartCallError(code: "bad_face", message: "A row's expands is a Boolean.")
                }
                if let inline = fields["inline"], inline != .bool(true), inline != .bool(false) {
                    throw PartCallError(code: "bad_face", message: "A row's inline is a Boolean: true draws its rows as named controls on its own line.")
                }
                for action in try list(fields["actions"], at: 4, "row actions") {
                    let fields = try object(action, keys: ["id", "label", "role", "unavailable"])
                    if let unavailable = fields["unavailable"] {
                        guard case .string(let reason) = unavailable, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw PartCallError(code: "bad_face", message: "An action's unavailable names its reason.")
                        }
                    }
                }
                if let control = fields["control"] {
                    let fields = try object(control, keys: ["on", "options", "selected", "confirm", "text", "placeholder", "number", "date"])
                    for option in try list(fields["options"], at: 32, "control options") { _ = try object(option, keys: ["id", "label"]) }
                    if let number = fields["number"] {
                        let bounds = try object(number, keys: ["value", "min", "max", "step"])
                        func numeric(_ key: String) throws -> Double? { try finite(bounds[key], "A number control's \(key)") }
                        guard let value = try numeric("value") else {
                            throw PartCallError(code: "bad_face", message: "A number control has a value.")
                        }
                        let min = try numeric("min"), max = try numeric("max"), step = try numeric("step")
                        guard min.map({ value >= $0 }) != false, max.map({ value <= $0 }) != false,
                              step.map({ $0 > 0 }) != false else {
                            throw PartCallError(code: "bad_face", message: "A number's value lies within its bounds and its step is positive.")
                        }
                    }
                    if let date = fields["date"] {
                        guard case .string(let date) = date, UserDisplayFormatters.parseISOTimestamp(date) != nil else {
                            throw PartCallError(code: "bad_face", message: "A date control holds an ISO 8601 date.")
                        }
                    }
                    let variants = ["on", "options", "text", "number", "date"].filter { fields[$0] != nil }
                    guard variants.count == 1 else {
                        throw PartCallError(code: "bad_face", message: "A control holds exactly one switch, choice, text, number or date value.")
                    }
                }
                // A meter is drawn as value out of max, from start (PartFace.Row.Meter); its words stay in the row's value.
                if let meter = fields["meter"] {
                    let bar = try object(meter, keys: ["value", "max", "start"])
                    guard let value = try finite(bar["value"], "A meter's value"), let whole = try finite(bar["max"], "A meter's max") else {
                        throw PartCallError(code: "bad_face", message: "A meter has a value and a max.")
                    }
                    let start = try finite(bar["start"], "A meter's start") ?? 0
                    guard whole > 0, value >= 0, value <= whole, start >= 0, start <= whole else {
                        throw PartCallError(code: "bad_face", message: "A meter's max is above 0, and its value and start lie between 0 and its max.")
                    }
                }
                try rows(fields["rows"], depth: depth + 1, count: &count, ids: &ids)
            }
        }
        let fields = try object(value, keys: ["title", "line", "sections", "detail", "opened"])
        if let opened = fields["opened"] {
            guard case .object(let held) = opened, Set(held.keys) == ["link", "title"],
                  case .string(let link)? = held["link"], case .page? = FaceLink(link),
                  case .string(let title)? = held["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !title.contains(where: \.isNewline) else {
                throw PartCallError(code: "bad_face", message: "A face's opened says what the page has open now: exactly a page link (such as "
                    + "page:desk/<item>) and a one-line nonempty title in the person's words.")
            }
        }
        if let detail = fields["detail"] {
            let fields = try object(detail, keys: ["of"])
            guard case .string(let id)? = fields["of"], !id.isEmpty else {
                throw PartCallError(code: "bad_face", message: "A face's detail names its selection section with of.")
            }
        }
        guard fields["sections"] != nil else { throw PartCallError(code: "bad_face", message: "A face has sections.") }
        for section in try list(fields["sections"], at: 64, "sections") {
            let fields = try object(section, keys: ["id", "title", "style", "footer", "rows", "folded", "block", "more", "filter", "revision",
                                                    "beside"])
            if let block = fields["block"] {
                guard fields["rows"] == nil else {
                    throw PartCallError(code: "bad_face", message: "A section holds rows or a block, never both.")
                }
                let block = try object(block, keys: ["kind", "key", "text", "format", "language", "copy", "leaf", "ref", "alt",
                                                      "fields", "submit", "revision", "protected", "receiver", "doors"])
                guard case .string(let kind)? = block["kind"], !kind.isEmpty,
                      case .string(let key)? = block["key"], !key.isEmpty else {
                    throw PartCallError(code: "bad_face", message: "A block has nonempty kind and key strings.")
                }
                if let text = block["text"] {
                    guard case .string(let text) = text, documentRead || text.utf8.count <= Block.inlineByteLimit else {
                        throw PartCallError(code: "bad_face", message: "Inline document text is at most 16 KiB; declare its key's read for a longer body.")
                    }
                }
                if let format = block["format"], !["plain", "markdown", "code"].contains(where: { format.stringValue == $0 }) {
                    throw PartCallError(code: "bad_face", message: "A document's format is plain, markdown or code.")
                }
                if let language = block["language"], language.stringValue == nil {
                    throw PartCallError(code: "bad_face", message: "A document's language is a string.")
                }
                if let copy = block["copy"], copy != .bool(true), copy != .bool(false) {
                    throw PartCallError(code: "bad_face", message: "A document's copy is a Boolean.")
                }
                if let revision = block["revision"], revision.stringValue == nil {
                    throw PartCallError(code: "bad_face", message: "A block's revision is a string.")
                }
                if kind == "leaf" {
                    guard case .string(let leaf)? = block["leaf"], !leaf.isEmpty,
                          case .string(let ref)? = block["ref"], !ref.isEmpty, case .string(_)? = block["alt"] else {
                        throw PartCallError(code: "bad_face", message: "A leaf names its leaf kind, owner ref and alt words.")
                    }
                }
                if kind == "form" {
                    let protected = block["protected"] == .bool(true)
                    if protected {
                        guard let receiver = block["receiver"]?.stringValue, receiver.hasPrefix("keyring:"),
                              Keyring.validName(String(receiver.dropFirst("keyring:".count))),
                              block["doors"] == .array([.string("mac")]) else {
                            throw PartCallError(code: "bad_face", message: "A protected authored form names receiver keyring:<name> and doors:[mac].")
                        }
                    } else if block["receiver"] != nil || (block["protected"] != nil && block["protected"] != .bool(false)) {
                        throw PartCallError(code: "bad_face", message: "A secret receiver belongs to a protected form.")
                    }
                    guard block["fields"] != nil, block["submit"] != nil else {
                        throw PartCallError(code: "bad_face", message: "A form declares fields and submit actions.")
                    }
                    var ids: Set<String> = []
                    for field in try list(block["fields"], at: 64, "form fields") {
                        let field = try object(field, keys: ["id", "label", "kind", "value", "placeholder", "required", "options", "min", "max", "step"])
                        guard case .string(let id)? = field["id"], !id.isEmpty, ids.insert(id).inserted,
                              case .string(let label)? = field["label"], !label.isEmpty,
                              case .string(let kind)? = field["kind"], !kind.isEmpty else {
                            throw PartCallError(code: "bad_face", message: "Form fields have unique nonempty ids, labels and kinds.")
                        }
                        guard kind != "secret" || (protected && field["value"] == nil) else {
                            throw PartCallError(code: "bad_face", message: "A secret has no value and belongs to a protected form.")
                        }
                        if protected, kind != "secret" {
                            throw PartCallError(code: "bad_face", message: "A keyring form holds exactly one secret field.")
                        }
                        for option in try list(field["options"], at: 64, "form options") {
                            _ = try object(option, keys: ["id", "label"])
                        }
                        if let required = field["required"], required != .bool(true), required != .bool(false) {
                            throw PartCallError(code: "bad_face", message: "A form field's required is a Boolean.")
                        }
                        for key in ["min", "max", "step"] {
                            if let bound = field[key] {
                                let number: Double
                                switch bound {
                                case .int(let value): number = Double(value)
                                case .double(let value): number = value
                                default: throw PartCallError(code: "bad_face", message: "A form field's bounds are finite numbers.")
                                }
                                guard number.isFinite, key != "step" || number > 0 else {
                                    throw PartCallError(code: "bad_face", message: "Form bounds are finite and a step is positive.")
                                }
                            }
                        }
                    }
                    if protected, ids.count != 1 {
                        throw PartCallError(code: "bad_face", message: "A keyring form holds exactly one secret field.")
                    }
                    var submits: Set<String> = []
                    for submit in try list(block["submit"], at: 4, "form submit actions") {
                        let submit = try object(submit, keys: ["id", "label", "role", "unavailable"])
                        guard case .string(let id)? = submit["id"], !id.isEmpty, submits.insert(id).inserted else {
                            throw PartCallError(code: "bad_face", message: "Form submit ids are nonempty and unique.")
                        }
                    }
                    if let doors = block["doors"] {
                        let values = try list(doors, at: 8, "form doors")
                        guard !values.isEmpty, values.allSatisfy({ $0.stringValue?.isEmpty == false }) else {
                            throw PartCallError(code: "bad_face", message: "A form's doors are nonempty door names.")
                        }
                    }
                }
            }
            guard fields["folded"] == nil || fields["folded"] == .bool(true) || fields["folded"] == .bool(false) else {
                throw PartCallError(code: "bad_face", message: "A section's folded is a Boolean.")
            }
            if let beside = fields["beside"], beside.stringValue?.isEmpty != false {
                throw PartCallError(code: "bad_face", message: "A section's beside is a nonempty string its column neighbours share.")
            }
            var count = 0
            var ids: Set<String> = []
            try rows(fields["rows"], depth: 1, count: &count, ids: &ids)
            if let more = fields["more"] {
                let fields = try object(more, keys: ["next", "total", "revision"])
                guard case .string(let next)? = fields["next"], !next.isEmpty else {
                    throw PartCallError(code: "bad_face", message: "A collection's more.next is a nonempty cursor.")
                }
                if let total = fields["total"] {
                    guard case .int(let value) = total, value >= 0 else {
                        throw PartCallError(code: "bad_face", message: "A collection's total is a nonnegative integer.")
                    }
                }
                if let revision = fields["revision"], revision.stringValue == nil {
                    throw PartCallError(code: "bad_face", message: "A collection's revision is a string.")
                }
            }
            if let filter = fields["filter"], filter.stringValue == nil {
                throw PartCallError(code: "bad_face", message: "A collection's filter is its search field's label.")
            }
            if let revision = fields["revision"], revision.stringValue == nil {
                throw PartCallError(code: "bad_face", message: "A collection's revision is a string.")
            }
        }
        let face = try JSONDecoder().decode(PartFace.self, from: value.serializedData(pretty: false))
        let blocks = face.sections.compactMap(\.block).map(\.key)
        guard Set(blocks).count == blocks.count else {
            throw PartCallError(code: "bad_face", message: "Block keys are unique within a face.")
        }
        guard Set(face.sections.map(\.id)).count == face.sections.count,
              face.sections.allSatisfy({ !$0.id.isEmpty && Set($0.rows.map(\.id)).count == $0.rows.count && $0.rows.allSatisfy({ !$0.id.isEmpty }) }) else {
            throw PartCallError(code: "bad_face", message: "Face section ids and each section's row ids must be nonempty and unique.")
        }
        if let detail = face.detail, !face.sections.contains(where: { $0.id == detail.of }) {
            throw PartCallError(code: "bad_face", message: "A face's detail.of names one of its sections.")
        }
        return face
    }

    /// What a page's packet lets its rows do: for each key a row may carry, the one place it leads, the actions it may hold (each with its
    /// role, the person's doors it runs from, and what it does: a door call or a place it opens), its control's call and its document read.
    /// The packet's keys hold {open?, actions?: [{id, role?, doors?, call?, open?, unavailable?}], set?, read?, submit?: {id:call}};
    /// calls hold {action, args?};
    /// each action has exactly one of call and open); a packet without `keys` lets no row lead or act. What a row does is the packet owner's
    /// alone: the face names an action by its id and labels it, never says what it calls.
    public struct Keys: Sendable, Equatable {
        public struct KeyAction: Sendable, Equatable {
            public let role: Action.Role
            public let doors: [String]?
            public let call: Call?
            public let open: String?
            public let unavailable: String?
        }
        public struct Key: Sendable, Equatable {
            public let open: String?
            public let actions: [String: KeyAction]
            /// The call the row's control makes with its new value; nil when the row holds no control.
            public let set: Call?
            public let read: Call?
            public let submit: [String: Call]
        }
        public let rows: [String: Key]

        public init(packet: JSONValue) throws {
            func bad(_ detail: String) -> PartCallError {
                PartCallError(code: "bad_packet", message: "A page packet's keys map each row key to {open?, actions?: [{id, role?, doors?, "
                    + "call?: {action, args?}, open?, unavailable?}], set?: {action, args?}, read?: {action, args?}, submit?: {id:{action,args?}}}: " + detail)
            }
            func call(_ value: JSONValue, _ what: String) throws -> Call {
                guard case .object(let fields) = value, Set(fields.keys).isSubset(of: ["action", "args"]),
                      case .string(let action)? = fields["action"], !action.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw bad("\(what) is not {action, args?}.")
                }
                guard let args = fields["args"] else { return Call(action) }
                guard case .object(let named) = args else { throw bad("\(what).args is not an object.") }
                return Call(action, named.mapValues(PartFace.Value.init))
            }
            guard case .object(let fields) = packet else { throw bad("the packet is not an object.") }
            guard let declared = fields["keys"] else { rows = [:]; return }
            guard case .object(let keys) = declared else { throw bad("keys is not an object.") }
            var rows: [String: Key] = [:]
            for (key, value) in keys {
                guard !key.isEmpty, case .object(let entry) = value, Set(entry.keys).isSubset(of: ["open", "actions", "set", "read", "submit"]) else {
                    throw bad("\(key) is not one.")
                }
                var open: String?
                if let link = entry["open"] {
                    guard case .string(let text) = link, PartFace.isLink(text) else { throw bad("\(key).open is not a link a row may hold.") }
                    open = text
                }
                var actions: [String: KeyAction] = [:]
                if let list = entry["actions"] {
                    guard case .array(let items) = list else { throw bad("\(key).actions is not a list.") }
                    for item in items {
                        guard case .object(let action) = item, Set(action.keys).isSubset(of: ["id", "role", "doors", "call", "open", "unavailable"]),
                              case .string(let id)? = action["id"], !id.isEmpty else {
                            throw bad("\(key).actions holds {id, role?, doors?, call?, open?, unavailable?} only.")
                        }
                        var doors: [String]?
                        if let named = action["doors"] {
                            let list = named.arrayValue ?? []
                            let names = list.compactMap(\.stringValue)
                            guard !names.isEmpty, names.count == list.count else {
                                throw bad("\(key).\(id).doors is a nonempty list of door names.")
                            }
                            doors = names
                        }
                        let made = try action["call"].map { try call($0, "\(key).\(id).call") }
                        var place: String?
                        if let link = action["open"] {
                            guard case .string(let text) = link, PartFace.isLink(text) else { throw bad("\(key).\(id).open is not a link.") }
                            place = text
                        }
                        guard (made == nil) != (place == nil) else { throw bad("\(key).\(id) has exactly one of call and open.") }
                        actions[id] = KeyAction(role: action["role"]?.stringValue.flatMap(Action.Role.init(rawValue:)) ?? .plain,
                            doors: doors, call: made, open: place, unavailable: try action["unavailable"].map { value in
                                guard case .string(let reason) = value, !reason.isEmpty else { throw bad("\(key).\(id).unavailable needs a reason.") }
                                return reason
                            })
                    }
                }
                let set = try entry["set"].map { try call($0, "\(key).set") }
                var submit: [String: Call] = [:]
                if let declared = entry["submit"] {
                    guard case .object(let calls) = declared else { throw bad("\(key).submit is not an object.") }
                    for (id, value) in calls {
                        guard !id.isEmpty else { throw bad("\(key).submit has an empty id.") }
                        submit[id] = try call(value, "\(key).submit.\(id)")
                    }
                }
                rows[key] = Key(open: open, actions: actions, set: set, read: try entry["read"].map { try call($0, "\(key).read") }, submit: submit)
            }
            self.rows = rows
        }
    }

    /// A face drawn from a packet is bound to its keys: a row that leads somewhere, acts or holds a control carries one of the packet's keys
    /// as its id, leads only where that key leads, holds only that key's actions (a destructive one stays destructive) and a control only
    /// when the key is set. The person's levers are the stem's alone: no row of the face takes a page lever's id, no key is one, and no key
    /// or row offers an action its key lever holds (the stem draws that action on the row itself).
    public func bound(to keys: Keys, levers: [Section], keyLevers: [Section] = []) throws -> PartFace {
        let leverRows = Set(levers.flatMap(\.allRows).map(\.id) + levers.compactMap(\.block).map(\.key))
        let keyedRows = keyLevers.flatMap(\.allRows).map { ($0.id, Set(($0.actions ?? []).map(\.id))) }
        let keyedForms = keyLevers.compactMap(\.block).map { ($0.key, Set(($0.submit ?? []).map(\.id))) }
        let keyed = Dictionary(keyedRows + keyedForms, uniquingKeysWith: { $0.union($1) })
        if let key = keys.rows.keys.sorted().first(where: { leverRows.contains($0) }) {
            throw PartCallError(code: "bad_packet", message: "The packet declares \(key), a lever's key; levers are drawn by the stem only.")
        }
        for (key, entry) in keys.rows.sorted(by: { $0.key < $1.key }) {
            let held = (keyed[key] ?? []).intersection(Set(entry.actions.keys))
            guard held.isEmpty else {
                throw PartCallError(code: "bad_packet", message: "The packet declares \(key)'s " + held.sorted().joined(separator: ", ")
                    + ", which its key lever holds; the stem draws it.")
            }
        }
        for row in allRows {
            guard !leverRows.contains(row.id) else {
                throw PartCallError(code: "bad_face", message: "Row \(row.id) takes a lever's id; the stem draws that lever itself.")
            }
            guard row.open != nil || row.actions?.isEmpty == false || row.control != nil || row.expands == true else { continue }
            guard let key = keys.rows[row.id] else {
                throw PartCallError(code: "bad_face", message: "Row \(row.id) leads or acts, but its page's packet declares no key \(row.id).")
            }
            if let open = row.open, open != key.open {
                throw PartCallError(code: "bad_face", message: "Row \(row.id) leads to \(open); its key leads to \(key.open ?? "nothing").")
            }
            for action in row.actions ?? [] {
                guard keyed[row.id]?.contains(action.id) != true else {
                    throw PartCallError(code: "bad_face", message: "Row \(row.id) offers \(action.id), the person's lever on that key; the stem draws it.")
                }
                guard let declared = key.actions[action.id] else {
                    throw PartCallError(code: "bad_face", message: "Row \(row.id) offers \(action.id), which its key does not declare.")
                }
                guard declared.role != .destructive || action.role == .destructive else {
                    throw PartCallError(code: "bad_face", message: "Row \(row.id) offers \(action.id) without the destructive role its key declares.")
                }
            }
            guard row.control == nil || key.set != nil else {
                throw PartCallError(code: "bad_face", message: "Row \(row.id) holds a control its key does not declare (set).")
            }
            guard row.expands != true || key.read != nil else {
                throw PartCallError(code: "bad_face", message: "Expanding row \(row.id) has no packet-owned read.")
            }
        }
        for section in sections where section.more != nil {
            guard !leverRows.contains(section.id), keys.rows[section.id]?.read != nil else {
                throw PartCallError(code: "bad_face", message: "Collection \(section.id) has no packet-owned read outside the person's levers.")
            }
        }
        for block in sections.compactMap(\.block) {
            guard !leverRows.contains(block.key) else {
                throw PartCallError(code: "bad_face", message: "Document \(block.key) takes a lever's key.")
            }
            if block.kind == "document", block.text == nil, keys.rows[block.key]?.read == nil {
                throw PartCallError(code: "bad_face", message: "Document \(block.key) has no inline text and its packet declares no read.")
            }
            if block.kind == "form" {
                for submit in block.submit ?? [] {
                    guard keys.rows[block.key]?.submit[submit.id] != nil, keyed[block.key]?.contains(submit.id) != true else {
                        throw PartCallError(code: "bad_face",
                            message: "Form \(block.key)'s submit \(submit.id) has no packet-owned call outside the person's levers.")
                    }
                    if block.protected == true {
                        guard let call = keys.rows[block.key]?.submit[submit.id], call.action == block.receiver, call.args.isEmpty else {
                            throw PartCallError(code: "bad_face", message: "A keyring submit calls its exact keyring:<name> receiver without arguments.")
                        }
                    }
                }
            }
        }
        // What each action and control does is the key's: the face only names and labels it.
        var bound = self
        bound.sections = sections.map { section in
            var bound = section
            if let block = section.block {
                var held = block
                held.read = keys.rows[block.key]?.read
                if block.kind == "form" {
                    held.submit = block.submit?.map { submit in
                        Action(id: submit.id, label: submit.label, role: submit.role, doors: block.doors,
                               call: keys.rows[block.key]?.submit[submit.id], unavailable: submit.unavailable)
                    }
                }
                bound.block = held
            }
            if var more = section.more {
                more.read = keys.rows[section.id]?.read
                bound.more = more
            }
            func bind(_ row: Row) -> Row {
                var bound = row
                bound.rows = row.rows?.map(bind)
                guard let key = keys.rows[row.id] else { return bound }
                let actions = row.actions?.map { action -> Action in
                    let declared = key.actions[action.id]
                    return Action(id: action.id, label: action.label, role: action.role, doors: declared?.doors, call: declared?.call,
                        open: declared?.open, unavailable: declared?.unavailable ?? action.unavailable)
                }
                let control = row.control.map { control in
                    var bound = control
                    bound.call = key.set
                    return bound
                }
                bound.actions = actions
                bound.control = control
                bound.read = key.read
                return bound
            }
            bound.rows = section.rows.map(bind)
            return bound
        }
        return bound
    }
}

extension PartFace.Value {
    /// The same value as the face's wire carries it.
    public init(_ json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map(PartFace.Value.init))
        case .object(let fields): self = .object(fields.mapValues(PartFace.Value.init))
        }
    }
}

extension JSONValue {
    /// A face's call argument as the door reads it.
    public init(_ value: PartFace.Value) {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map(JSONValue.init))
        case .object(let fields): self = .object(fields.mapValues(JSONValue.init))
        }
    }
}

extension PartFace.Call {
    /// The call as the door takes it: `app {action, args}`.
    public var input: [String: JSONValue] {
        ["action": .string(action), "args": .object(args.mapValues(JSONValue.init))]
    }
}
