import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import ChatToolParsing
import ToolRegistry
import TrustCenter
// Blueprint: | `Expansion+Practice.swift` | `Expansion`; `Expectation`; Measured authority-separated practice |

extension Expansion {
    /// Expectation owns standing; these measurements bound costs and resources without deciding admission.
    enum Law {
        static func median(_ values: [Double]) -> Double? {
            let sorted = values.filter(\.isFinite).sorted()
            guard !sorted.isEmpty else { return nil }
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }

        /// Use measured median gaps and runs for benefit and cost; prepared acts save a confirmation round, while token cost stays unknown.
        static func measure(_ record: Record, _ template: Template, among: Int? = nil)
            -> (stands: Bool, lower: Double, bar: Double?, cHit: Double?, cMiss: Double?) {
            let cHit = median(template.gaps)
            let cMiss = median(record.costs.isEmpty ? template.runs : record.costs)
            let standing = Expectation.stands(hits: record.hits, tries: record.tries,
                cHit: cHit, cMiss: cMiss, among: among ?? 1)
            return (standing.stands, standing.lower, standing.bar, cHit, cMiss)
        }

        // Resource caps bound work and storage without deciding standing; examples form the situation's observation window.
        static let leafCap = 2048
        static let pathsPerValue = 8
        static let examplesPerSituation = 8
        static let situationCap = 128
        static let recordCap = 256
        static let practiceCap = 32
        static let threadCap = 64
        static let costCap = 16
        static let callCap = 4096
        static let chain = 3
    }

    enum Nature: String, Codable, Sendable { case read, act }
    enum Outcome: String, Sendable { case hit, miss, unknown }

    struct Plan: Sendable {
        let invocation: UUID
        let signature: String
        let call: [String: JSONValue]
        let nature: Nature
        let why: JSONValue
    }

    struct Template: Sendable {
        let form: String
        let shape: [String: JSONValue]
        let leaves: [Leaf]
        let gaps: [Double]
        let runs: [Double]
    }

    struct Leaf: Sendable {
        let path: String
        let constant: JSONValue?
        let sources: [String]
    }

    struct Try: Sendable {
        let invocation = UUID()
        let signature: String
        let call: [String: JSONValue]
        let nature: Nature?
        let turn: String
        let standing: Bool
        let lower: Double
        let bar: Double?
        let known: Set<String>
        /// Label opening claims with the actual first call, even when its prediction was not shown.
        var firstCall = false
        var planned = false
        var delivered = false
        var withheld = false
        var distinctive: Set<String> = []
        var next: Observation?
    }

    struct Observation: Sendable {
        let tool: String
        let call: [String: JSONValue]
    }

    struct Last: Sendable {
        let situation: String
        let index: [String: [String]]
        let returnedAt: Date
    }

    struct Open: Sendable {
        let situation: String
        let at: Date
    }

    struct CallThread: Sendable {
        let caller: Caller
        var calls = 0
        var last: Last?
        var tries: [Try] = []
        var ended = false
        var observationLost = false
        var open: Open?
        var at: Date

        init(_ caller: Caller, at: Date) {
            self.caller = caller
            self.at = at
        }
    }

    struct Book: Codable, Sendable {
        static let current = 3
        var version = Book.current
        /// Separate practice by mind and authority so principals cannot borrow another scope's standing.
        var practices: [String: Practice] = [:]

        mutating func fold() throws {
            guard version == 2 else { return }
            var folded: [String: Practice] = [:]
            var histories: [(key: String, signature: String, record: Record)] = []
            for (_, old) in practices.sorted(by: { $0.key < $1.key }) {
                var practice = folded[old.key] ?? Practice(agent: old.agent, steered: old.steered, at: old.lastAt)
                practice.lastAt = max(practice.lastAt, old.lastAt)
                for (key, situation) in old.situations.sorted(by: { $0.key < $1.key }) {
                    // Exclude qualified fields from the wake label so its authored text stays unchanged.
                    let name: String
                    if let fields = key.range(of: " fields:") {
                        let woke = key.range(of: " woke:", range: fields.upperBound..<key.endIndex)
                        name = String(key[..<fields.lowerBound]) + (woke.map { String(key[$0.lowerBound...]) } ?? "")
                    } else { name = key }
                    var place = practice.situations[name] ?? Situation(at: situation.lastAt)
                    place.lastAt = max(place.lastAt, situation.lastAt)
                    place.examples = Array((place.examples + situation.examples).sorted { $0.at < $1.at }.suffix(Law.examplesPerSituation))
                    practice.situations[name] = place
                }
                for (signature, record) in old.records.sorted(by: { $0.key < $1.key }) {
                    histories.append((old.key, signature, record))
                }
                folded[old.key] = practice
            }
            for history in histories.sorted(by: { $0.record.lastAt < $1.record.lastAt }) {
                guard var practice = folded[history.key] else { continue }
                if var held = practice.records[history.signature] {
                    guard held.situation == history.record.situation, held.form == history.record.form else {
                        throw Record.invalid("practices." + history.key + ".records." + history.signature + ".identity")
                    }
                    try held.merge(history.record)
                    practice.records[history.signature] = held
                } else { practice.records[history.signature] = history.record }
                folded[history.key] = practice
            }
            // Field-qualified claims keep their exact historical signatures;
            // a broader situation cannot borrow standing from a narrower one.
            for key in folded.keys.sorted() {
                guard var practice = folded[key] else { continue }
                practice.situations = Dictionary(uniqueKeysWithValues: practice.situations.sorted {
                    $0.value.lastAt == $1.value.lastAt ? $0.key < $1.key : $0.value.lastAt > $1.value.lastAt
                }.prefix(Law.situationCap).map { ($0.key, $0.value) })
                practice.records = Dictionary(uniqueKeysWithValues: practice.records.sorted {
                    $0.value.lastAt == $1.value.lastAt ? $0.key < $1.key : $0.value.lastAt > $1.value.lastAt
                }.prefix(Law.recordCap).map { ($0.key, $0.value) })
                folded[key] = practice
            }
            practices = Dictionary(uniqueKeysWithValues: folded.sorted {
                $0.value.lastAt == $1.value.lastAt ? $0.key < $1.key : $0.value.lastAt > $1.value.lastAt
            }.prefix(Law.practiceCap).map { ($0.key, $0.value) })
            version = Self.current
        }
    }

    struct Practice: Codable, Sendable {
        var agent: String
        /// Preserve every untrusted principal that steered the learned practice; empty means the mind's own authority.
        var steered: [String]
        var situations: [String: Situation] = [:]
        var records: [String: Record] = [:]
        var lastAt: Date

        init(agent: String, steered: [String], at: Date) {
            self.agent = agent
            self.steered = steered
            lastAt = at
        }

        var key: String { [agent, steered.isEmpty ? "own" : "steered:" + steered.joined(separator: ",")].joined(separator: "\u{1}") }
    }

    struct Situation: Codable, Sendable {
        var examples: [Example] = []
        var lastAt: Date

        init(at: Date) { lastAt = at }
    }

    /// Keep exact call values, their observed sources and follow-up costs so predictions remain grounded in actual work.
    struct Example: Codable, Sendable {
        var at: Date
        var call: [String: JSONValue]
        var sources: [String: [String]]
        var gap: Double
        var ran: Double?
    }

    struct Record: Codable, Sendable {
        var situation: String
        var form: String
        /// Earn standing only on trials since the last detected change.
        var tries = 0
        var hits = 0
        var lifetimeTries = 0
        var lifetimeHits = 0
        var unknown = 0
        var misses = 0
        var changes = 0
        var delivered = 0
        var prepared = 0
        var withheld = 0
        var costs: [Double] = []
        var lastAt: Date

        init(situation: String, form: String, at: Date) {
            self.situation = situation
            self.form = form
            lastAt = at
        }

        /// A miss streak resets standing only when even the highest plausible miss rate makes fewer than one such streak likely across its tries.
        static func invalid(_ field: String) -> NSError {
            NSError(domain: "Expansion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or overflowing expansion counter at " + field])
        }

        mutating func increment(_ key: WritableKeyPath<Record, Int>, _ name: String) throws {
            let (next, overflow) = self[keyPath: key].addingReportingOverflow(1)
            guard !overflow, next < Int.max else { throw Self.invalid("\(situation).\(form).\(name)") }
            self[keyPath: key] = next
        }

        func validate(at path: String) throws {
            for (name, value) in [("tries", tries), ("hits", hits), ("lifetimeTries", lifetimeTries), ("lifetimeHits", lifetimeHits),
                                  ("unknown", unknown), ("misses", misses), ("changes", changes), ("delivered", delivered),
                                  ("prepared", prepared), ("withheld", withheld)] {
                guard value >= 0, value < Int.max else { throw Self.invalid(path + "." + name) }
            }
            guard hits <= tries, tries <= lifetimeTries, hits <= lifetimeHits, lifetimeHits <= lifetimeTries,
                  misses <= tries, hits <= tries - misses else { throw Self.invalid(path + ".hits/tries/misses") }
            guard costs.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw Self.invalid(path + ".costs") }
        }

        /// Only identical signatures may pool trials. Streak order across
        /// models is not recorded: retain the newest record's trailing streak.
        mutating func merge(_ other: Record) throws {
            for key in [\Record.tries, \.hits, \.lifetimeTries, \.lifetimeHits, \.unknown,
                        \.changes, \.delivered, \.prepared, \.withheld] {
                let (sum, overflow) = self[keyPath: key].addingReportingOverflow(other[keyPath: key])
                guard !overflow, sum < Int.max else { throw Self.invalid(situation + "." + form + ".fold") }
                self[keyPath: key] = sum
            }
            if other.lastAt >= lastAt {
                misses = other.misses
                costs = Array((costs + other.costs).suffix(Law.costCap))
            } else {
                costs = Array((other.costs + costs).suffix(Law.costCap))
            }
            lastAt = max(lastAt, other.lastAt)
            try validate(at: situation + "." + form)
        }

        mutating func note(_ outcome: Outcome, z: Double) throws {
            switch outcome {
            case .unknown:
                try increment(\.unknown, "unknown")
            case .hit:
                try increment(\.tries, "tries"); try increment(\.hits, "hits")
                try increment(\.lifetimeTries, "lifetimeTries"); try increment(\.lifetimeHits, "lifetimeHits")
                misses = 0
            case .miss:
                try increment(\.tries, "tries"); try increment(\.lifetimeTries, "lifetimeTries")
                try increment(\.misses, "misses")
                let before = tries - misses
                guard before > 0 else { return }
                let missing = 1 - Expectation.lowerBound(hits: hits, tries: before, z: z)
                if pow(missing, Double(misses)) < 1 / Double(tries) {
                    tries = misses
                    hits = 0
                    try increment(\.changes, "changes")
                }
            }
        }
    }

    /// Judge prediction by subsequent calls, never prose. An unshown exact next call hits; a delivered read hits only through later use.
    /// Repeated reads miss; absent evidence remains unknown. Prepared acts hit only when the mind performs them.
    static func outcome(_ attempt: Try, tool: String?, next: [String: JSONValue]?) -> Outcome {
        let again: Bool
        if tool == "app", let next {
            guard let matched = same(stripped(next), attempt.call) else { return .unknown }
            again = matched
        } else { again = false }
        guard !attempt.firstCall, attempt.delivered, attempt.nature != .act else { return again ? .hit : .miss }
        if again { return .miss }
        guard let next else { return .unknown }
        var flat: [(path: String, value: JSONValue)] = []
        guard JSONValue.object(next).leaves(into: &flat, limit: Law.leafCap, depthLimit: 128) else { return .unknown }
        let used = flat.contains { leaf in
            guard case .string = leaf.value, let token = sourceToken(leaf.value) else { return false }
            return attempt.distinctive.contains(token)
        }
        return used ? .hit : .unknown
    }

    /// A call carrying a key or token (`:secret` args) is never kept.
    static func carriesSecret(_ call: [String: JSONValue], turn: Turn?) throws -> Bool {
        if NativeAgentSecretRedactor.secretPath(.object(call), at: "call") != nil { return true }
        guard let binding = try AppActionBinding.action(input: call, turn: turn), !binding.secretArgs.isEmpty else { return false }
        guard case .object(let args)? = call["args"] else { return false }
        return binding.secretArgs.contains { args[$0] != nil }
    }

    /// Predict repeated forms only when every argument has a shared exact source or structural constant.
    static func templateEvidence(_ examples: [Example], turn: Turn?) throws -> (templates: [Template], rejected: [String: Int]) {
        var rejected: [String: Int] = [:]
        var groups: [String: [(example: Example, values: [String: JSONValue], paths: [String])]] = [:]
        var order: [String] = []
        for example in examples {
            var flat: [(path: String, value: JSONValue)] = []
            guard JSONValue.object(example.call).leaves(into: &flat, limit: Law.leafCap, depthLimit: 128) else {
                rejected["incomplete_traversal", default: 0] += 1; continue
            }
            let paths = flat.map { $0.path }
            guard let key = try? JSONValue.array([.string(verb(tool: "app", input: example.call)), structure(.object(example.call))]).serialize(
                pretty: false) else {
                rejected["unserializable_shape", default: 0] += 1; continue
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((example: example,
                                             values: Dictionary(flat.map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first }),
                                             paths: paths))
        }
        var templates: [Template] = []
        for key in order {
            guard let members = groups[key], members.count >= 2, let latest = members.last else {
                rejected["insufficient_examples", default: 0] += 1; continue
            }
            var slots: [Leaf] = []
            var judged = false
            let binding = try AppActionBinding.action(input: latest.example.call, turn: turn)
            let properties: [String: JSONValue]? = {
                guard let descriptor = binding?.descriptor,
                      let parsed = try? JSONValue.parse(descriptor.schema.parametersJSON),
                      case .object(let root) = parsed,
                      case .object(let props)? = root["properties"] else { return nil }
                return props
            }()
            for path in latest.paths {
                let tokens = members.map { member in member.values[path].flatMap { token($0) } }
                let repeated: JSONValue? = Set(tokens.compactMap { $0 }).count == 1 && !tokens.contains(nil)
                    ? latest.values[path] : nil
                let constant = repeated.flatMap { structural($0, at: path, properties: properties, rename: binding?.rename ?? [:]) ? $0 : nil }
                var sources = Set(members[0].example.sources[path] ?? [])
                for member in members.dropFirst() { sources.formIntersection(member.example.sources[path] ?? []) }
                guard constant != nil || !sources.isEmpty else {
                    let reason = members.allSatisfy { !($0.example.sources[path] ?? []).isEmpty }
                        ? "no_shared_source" : "judgment_without_source"
                    rejected[reason, default: 0] += 1
                    judged = true; break
                }
                slots.append(Leaf(path: path, constant: constant, sources: sources.sorted()))
            }
            guard !judged else { continue }
            // Identity binds the whole mechanic, not just its destinations.
            let mapping: JSONValue = .object([
                "verb": .string(verb(tool: "app", input: latest.example.call)),
                "shape": structure(.object(latest.example.call)),
                "slots": .array(slots.map { slot in .object([
                    "path": .string(slot.path), "constant": slot.constant ?? .null,
                    "sources": .array(slot.sources.map(JSONValue.string)),
                ]) }),
            ])
            guard let form = try? mapping.serialize(pretty: false) else {
                rejected["unserializable_mapping", default: 0] += 1; continue
            }
            templates.append(Template(form: form, shape: latest.example.call, leaves: slots,
                                      gaps: members.map { $0.example.gap }, runs: members.compactMap { $0.example.ran }))
        }
        return (templates, rejected)
    }

    /// Only booleans, null, the call's verb or schema-declared enum members may be constants; all other values require an observed source.
    static func structural(_ value: JSONValue, at path: String, properties: [String: JSONValue]?, rename: [String: String]) -> Bool {
        switch value {
        case .bool, .null: return true
        case .object(let fields): return fields.isEmpty
        case .array(let values): return values.isEmpty
        case .string, .int, .double: break
        default: return false
        }
        let parts = JSONValue.pointerComponents(path)
        if parts == ["action"] { return true }
        if parts == ["page"], case .string(let page) = value {
            let place = AppDoorNames.place(page: page, item: "")
            return place.item.isEmpty && (place.page == "home" || AppDoorNames.partPages.contains(place.page))
        }
        guard parts.count == 2, parts[0] == "args",
              case .object(let argument)? = properties?[rename[parts[1]] ?? parts[1]] else { return false }
        let variants: [JSONValue] = if case .array(let options)? = argument["anyOf"] { options } else { [] }
        return ([JSONValue.object(argument)] + variants).contains { option in
            guard case .object(let fields) = option, case .array(let members)? = fields["enum"] else { return false }
            return members.contains { token($0) == token(value) }
        }
    }

    /// Missing or conflicting sources make the prediction unavailable rather than guessing an argument.
    static func fill(_ template: Template, from values: [String: JSONValue]) -> [String: JSONValue]? {
        var call = JSONValue.object(template.shape)
        for leaf in template.leaves {
            var chosen = leaf.constant
            for source in leaf.sources {
                guard let value = values[source] else { continue }
                if let held = chosen, token(held) != token(value) { return nil }
                chosen = value
            }
            guard let chosen, let replaced = call.replacing(at: JSONValue.pointerComponents(leaf.path)[...], with: chosen) else { return nil }
            call = replaced
        }
        guard case .object(let fields) = call else { return nil }
        return fields
    }

    // MARK: - Shapes

    /// Use the door's own grammar so action, page, find, batch, script and named-tool calls retain distinct identities.
    static func verb(tool: String, input: [String: JSONValue]) -> String {
        guard tool == "app" else { return "tool:" + tool }
        func text(_ key: String) -> String {
            if case .string(let value)? = input[key] { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } else { "" }
        }
        if !text("action").isEmpty { return "action:" + text("action") }
        if input["script"] != nil { return "script" }
        if input["actions"] != nil { return "actions" }
        if input["find"] != nil { return "find" }
        let item = input["item"] != nil
        if !text("page").isEmpty { return "page:" + text("page") + (item ? "+item" : "") }
        return item ? "item" : "home"
    }

    /// Include verb, argument names, result status and opening wake so practice matches the actual situation.
    static func situation(tool: String, input: [String: JSONValue], result: JSONValue, woke: String?) -> String {
        let reply = ToolResult(result)
        var parts = [verb(tool: tool, input: input)]
        if case .object(let args)? = input["args"] { parts.append("args:" + args.keys.sorted().joined(separator: ",")) }
        parts.append("status:" + ChatToolOutcome.statusWord(reply.payload, verdict: reply.outcome))
        if let woke { parts.append("woke:" + woke) }
        return parts.joined(separator: " ")
    }

    /// Opening perception neither acts nor prepares an act's preview.
    static func openingRead(_ call: [String: JSONValue], turn: Turn?) throws -> Bool {
        try call["preview"] != .bool(true) && nature(call, turn: turn) == .read
    }

    /// Reads run, acts preview; batches, scripts and home items cannot be predictions.
    static func nature(_ call: [String: JSONValue], turn: Turn?) throws -> Nature? {
        if call["actions"] != nil || call["script"] != nil { return nil }
        if case .string(let id)? = call["action"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let binding = try AppActionBinding.action(input: call, turn: turn) else { return nil }
            // A preview runs nothing: the door's posture, and Trust's reading of it.
            if call["preview"] == .bool(true) { return .read }
            return try enforcedRead(call, binding, turn: turn) ? .read : .act
        }
        func text(_ key: String) -> String { if case .string(let value)? = call[key] { value } else { "" } }
        let place = AppDoorNames.place(page: text("page"), item: text("item"))
        if !place.item.isEmpty, place.page.isEmpty || place.page == "home" { return nil }
        return .read
    }

    /// A read needs both Trust’s argument-sensitive class and an enforced read-only declaration.
    static func enforcedRead(_ call: [String: JSONValue], _ binding: AppActionBinding, turn: Turn?) throws -> Bool {
        guard binding.read, binding.capabilities.isSubset(of: readCapabilities) else { return false }
        let ran = ToolNameAliases.ranCall("app", input: call)
        guard try PermissionLaw.toolClass(ran.tool, input: ran.input, turn: turn) == .read else { return false }
        return binding.toolClass == .read || (!binding.readWhen.isEmpty && AppActionBinding.builtInToolName(binding.tool))
    }

    static let readCapabilities: Set<String> = ["safe_read", "tool_call", "app_data_read"]

    static func stripped(_ input: [String: JSONValue], preview: Bool = false) -> [String: JSONValue] {
        input.filter { !$0.key.hasPrefix("__") && !(preview && $0.key == "preview") }
    }

    static func same(_ left: [String: JSONValue], _ right: [String: JSONValue]) -> Bool? {
        var one: [(path: String, value: JSONValue)] = [], two: [(path: String, value: JSONValue)] = []
        guard JSONValue.object(left).leaves(into: &one, limit: Law.leafCap, depthLimit: 128),
              JSONValue.object(right).leaves(into: &two, limit: Law.leafCap, depthLimit: 128) else { return nil }
        guard structure(.object(left)) == structure(.object(right)) else { return false }
        return one.count == two.count && zip(one, two).allSatisfy { $0.path == $1.path && token($0.value) == token($1.value) }
    }

    /// Container kinds and presence are part of a call, even with no leaves.
    static func structure(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields): return .object(fields.mapValues(structure))
        case .array(let values): return .array(values.map(structure))
        default: return .null
        }
    }

    /// Compare numeric scalars by value rather than spelling.
    static func token(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return "s:" + text
        case .int(let whole): return "n:" + String(whole)
        case .double(let real):
            if real.isFinite, real.rounded() == real, abs(real) < 9e15 { return "n:" + String(Int64(real)) }
            return "n:" + String(real)
        case .bool(let flag): return flag ? "b:1" : "b:0"
        case .null: return "z"
        case .object(let fields) where fields.isEmpty: return "{}"
        case .array(let values) where values.isEmpty: return "[]"
        default: return nil
        }
    }

    /// Only text and numbers flow from results; booleans and null are constants, since matching them would invent sources.
    static func sourceToken(_ value: JSONValue) -> String? {
        switch value {
        case .string, .int, .double: return token(value)
        default: return nil
        }
    }

    static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    public func summary(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> String {
        let root = dataRoot.standardizedFileURL.path
        load(root)
        if let reason = unavailable[root] { return "Expansion record unavailable: " + reason }
        var lines = ["""
            A prediction reaches the opening thought or rides inside the result before it while the lower bound of its hit rate (Wilson, one-sided, z \
            = √(2 ln(m/0.05)) for the m predictions this mind's record is testing) beats c_miss / (c_miss + c_hit): c_hit is the median time this \
            mind took to make the call after the turn started or the result came back, c_miss the median time that call takes to run. Only reads run \
            at turn start; follow-up acts are only previewed.
            """]
        if savePending(root) { lines.append("Practice has changes awaiting a durable save.") }
        let practices = (books[root]?.practices.values.map { $0 } ?? []).sorted { $0.lastAt > $1.lastAt }
        if practices.isEmpty { lines.append("No mind has made a call through the door yet.") }
        for practice in practices {
            let among = max(1, practice.records.values.filter { $0.lifetimeTries > 0 }.count)
            lines.append("")
            var head = practice.agent
            if !practice.steered.isEmpty { head += ", in turns steered by " + practice.steered.joined(separator: ", ") }
            lines.append(head + ": \(practice.situations.count) situations, \(practice.records.count) predictions")
            let evidence: [String: (templates: [Template], rejected: [String: Int])]
            do { evidence = try practice.situations.mapValues { try Self.templateEvidence($0.examples, turn: nil) } }
            catch { return "Expansion action catalog unavailable: " + error.localizedDescription + ". Repair the catalog before reading predictions." }
            let rejected = evidence.values.reduce(into: [String: Int]()) { counts, item in
                for (reason, count) in item.rejected { counts[reason, default: 0] += count }
            }
            lines.append("Template rejections in the retained window (forms; incomplete traversal/unserializable shape count examples): "
                + (rejected.isEmpty ? "none" : rejected.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
            let records = practice.records.values.sorted {
                $0.lifetimeTries != $1.lifetimeTries ? $0.lifetimeTries > $1.lifetimeTries : $0.lastAt > $1.lastAt
            }.prefix(40)
            for record in records {
                let template = evidence[record.situation]?.templates.first { $0.form == record.form }
                let measure = template.map { Law.measure(record, $0, among: among) }
                var parts = [(record.situation.hasPrefix("start woke:") ? "at " : "after ") + record.situation + " -> " + record.form,
                             """
                                 \(record.hits)/\(record.tries) since its last change (\(record.lifetimeHits)/\(record.lifetimeTries) in all, \
                                 \(record.unknown) unknown, \(record.changes) changes)
                                 """]
                if let measure {
                    parts.append(String(format: "lower %.2f", measure.lower)
                                 + (measure.bar.map { String(format: " vs bar %.2f", $0) } ?? " (cost not measured yet)")
                                 + (measure.stands ? ": stands" : ": watching"))
                } else {
                    parts.append("no longer predicted by its examples")
                }
                parts.append("ran \(record.delivered), prepared \(record.prepared), withheld \(record.withheld)")
                lines.append(parts.joined(separator: "; "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
