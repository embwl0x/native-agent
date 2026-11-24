import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DoorArgs.swift` | Typed door fields, object decoding and argument contracts |

struct DoorFieldDescriptor: Sendable {
    let name: String
    let schema: JSONValue
    let required: Bool
    let secret: Bool
    let subject: Bool

    init(_ name: String, _ schema: JSONValue, required: Bool, secret: Bool = false, subject: Bool = false) {
        self.name = name
        self.schema = schema
        self.required = required
        self.secret = secret
        self.subject = subject
    }

    static func string(_ name: String, _ description: String? = nil, required: Bool = false,
                       secret: Bool = false, subject: Bool = false) -> Self {
        Self(name, ToolSchema.strSchema(description), required: required, secret: secret, subject: subject)
    }

    func nullable() -> Self {
        Self(name, ToolSchema.nullable(schema), required: required, secret: secret, subject: subject)
    }

    static func int(_ name: String, _ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil, required: Bool = false) -> Self {
        Self(name, ToolSchema.intSchema(description, minimum: minimum, maximum: maximum), required: required)
    }

    static func bool(_ name: String, _ description: String? = nil, required: Bool = false) -> Self {
        Self(name, ToolSchema.boolSchema(description), required: required)
    }

    static func number(_ name: String, _ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil, required: Bool = false) -> Self {
        Self(name, ActionDescriptor.numSchema(description, minimum: minimum, maximum: maximum), required: required)
    }

    static func choice(_ name: String, _ values: [String], _ description: String? = nil, required: Bool = false) -> Self {
        Self(name, ToolSchema.enumStringSchema(values, description), required: required)
    }

    static func suggestedString(_ name: String, _ values: [String], _ description: String, required: Bool = false) -> Self {
        Self(name, .object(["description": .string(description), "anyOf": .array([ToolSchema.enumStringSchema(values), ToolSchema.strSchema()])]), required: required)
    }

    static func stringBoolOrNull(_ name: String, _ description: String, booleanFirst: Bool) -> Self {
        let forms = booleanFirst ? [ToolSchema.boolSchema(), ToolSchema.strSchema()] : [ToolSchema.strSchema(), ToolSchema.boolSchema()]
        return Self(name, .object(["description": .string(description), "anyOf": .array(forms + [.object(["type": .string("null")])])]), required: false)
    }

    static func strings(_ name: String, _ description: String? = nil, minItems: Int? = nil, maxItems: Int? = nil,
                        maxItemLength: Int? = nil, required: Bool = false) -> Self {
        Self(name, ActionDescriptor.stringArraySchema(description, minItems: minItems, maxItems: maxItems, maxItemLength: maxItemLength), required: required)
    }

    static func object<T: DoorObjectSchema>(_ name: String, _ type: T.Type, description: String? = nil, declaresRequired: Bool = true, required: Bool = false) -> Self {
        var constraints = T.constraints
        if let description { constraints["description"] = .string(description) }
        let fields = T.doorFields.all
        let requiredNames = declaresRequired ? fields.filter(\.required).map(\.name) : nil
        let contract = DoorArgsContract(fields: fields, constraints: constraints, required: requiredNames, names: [:], references: [:])
        return Self(name, contract.schema, required: required)
    }

    static func objects<T: DoorObjectSchema>(_ name: String, _ type: T.Type, description: String? = nil, maxItems: Int? = nil, required: Bool = false) -> Self {
        var schema: [String: JSONValue] = ["type": .string("array"), "items": object(name, type).schema]
        schema["description"] = description.map(JSONValue.string)
        schema["maxItems"] = maxItems.map { .int(Int64($0)) }
        return Self(name, .object(schema), required: required)
    }

    static func emptyObject(_ name: String, description: String? = nil, declaresRequired: Bool = false) -> Self {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]
        if declaresRequired { schema["required"] = .array([]) }
        schema["description"] = description.map(JSONValue.string)
        return Self(name, .object(schema), required: false)
    }

    enum OpenValues {
        case implicit, any, typed(JSONValue)
    }

    static func openObject(_ name: String, reason: String, description: String? = nil, values: OpenValues) -> Self {
        precondition(!reason.isEmpty)
        var schema: [String: JSONValue] = ["type": .string("object")]
        schema["description"] = description.map(JSONValue.string)
        switch values {
        case .implicit: break
        case .any: schema["additionalProperties"] = .bool(true)
        case .typed(let value): schema["additionalProperties"] = value
        }
        return Self(name, .object(schema), required: false)
    }
}

struct NonEmptyFields: Sendable {
    let first: DoorFieldDescriptor
    let rest: [DoorFieldDescriptor]
    init(_ first: DoorFieldDescriptor, _ rest: DoorFieldDescriptor...) {
        self.first = first
        self.rest = rest
    }
    var all: [DoorFieldDescriptor] { [first] + rest }
}

protocol DoorObjectSchema: Sendable {
    static var doorFields: NonEmptyFields { get }
    static var constraints: [String: JSONValue] { get }
    init(door: inout DoorObjectDecoder) throws(DoorDecodeError)
}

extension DoorObjectSchema {
    static var constraints: [String: JSONValue] { ["additionalProperties": .bool(false)] }
}

protocol DoorArgs: Sendable {
    static var doorFields: [DoorFieldDescriptor] { get }
    static var rootRequired: [String]? { get }
    static func isTransportMetadata(_ key: String) -> Bool
    static var rootSchemaConstraints: [String: JSONValue] { get }
    static var argumentNames: [String: [String]] { get }
    static var argumentReferences: [String: AppAction.ArgumentReference] { get }
    init(door: inout DoorObjectDecoder) throws(DoorDecodeError)
}

extension DoorArgs {
    static var rootRequired: [String]? { doorFields.filter(\.required).map(\.name) }
    static func isTransportMetadata(_ key: String) -> Bool { key.hasPrefix("__") }
    static var rootSchemaConstraints: [String: JSONValue] { [:] }
    static var argumentNames: [String: [String]] { [:] }
    static var argumentReferences: [String: AppAction.ArgumentReference] { [:] }
}

struct DoorDecodeError: Error {
    let path: String
    let accepted: String

    var failure: ToolFailureError {
        ToolFailureError("\(path) must be \(accepted). Nothing ran.", argumentPath: path, accepted: accepted,
                         effects: .none, code: "invalid_arguments")
    }
}

enum DoorAdmissionError: Error {
    case badArguments(JSONValue.SchemaProblem)
    case schemaUnavailable(ToolFailureError)

    var failure: ToolFailureError {
        switch self {
        case .badArguments(let problem):
            ToolFailureError("\(problem.words). Nothing ran.", argumentPath: problem.path, accepted: problem.expected,
                effects: .none, code: "invalid_arguments")
        case .schemaUnavailable(let failure): failure
        }
    }
}

enum DoorDecoder {
    static func admit(_ input: [String: JSONValue], schema: JSONValue, path: String = "$",
                      transportMetadata: Bool = false, declaredKeysOnly: Bool = false) throws(ToolFailureError) {
        do throws(DoorAdmissionError) {
            try check(input, schema: schema, path: path, transportMetadata: transportMetadata, declaredKeysOnly: declaredKeysOnly)
        } catch { throw error.failure }
    }

    static func check(_ input: [String: JSONValue], schema: JSONValue, path: String,
                      transportMetadata: Bool = false, declaredKeysOnly: Bool = false) throws(DoorAdmissionError) {
        guard case .object(var fields) = schema else {
            throw .schemaUnavailable(ToolFailureError("The action's input schema must be an object.", effects: .none,
                owner: "Tool catalog", code: "tool_schema_unavailable",
                instruction: "Repair the registered input schema before calling it again.", recovery: .repair))
        }
        if declaredKeysOnly, fields["additionalProperties"] == nil {
            fields["additionalProperties"] = .bool(false)
        }
        let arguments = transportMetadata ? input.filter { !$0.key.hasPrefix("__") } : input
        if let problem = JSONValue.object(arguments).schemaProblem(schema: .object(fields), path: path) {
            guard problem.keyword == "schema" else { throw .badArguments(problem) }
            throw .schemaUnavailable(ToolFailureError("\(problem.words). Nothing ran.",
                argumentPath: problem.path, accepted: problem.expected, effects: .none,
                owner: "Tool catalog", code: "tool_schema_unavailable"))
        }
    }

    static func object<T: DoorObjectSchema>(_ type: T.Type, from value: JSONValue, path: String = "$") throws(DoorDecodeError) -> T {
        guard case .object(let fields) = value else { throw DoorDecodeError(path: path, accepted: "an object") }
        let schema = DoorArgsContract(fields: T.doorFields.all, constraints: T.constraints).schema
        var decoder = DoorObjectDecoder(fields, schema: schema, path: path)
        let object = try T(door: &decoder)
        try decoder.rejectUnknownKeys()
        return object
    }
}

enum DoorNumberLiteral: Sendable {
    case int(Int64)
    case double(Double)

    var wire: JSONValue {
        switch self {
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        }
    }
}

enum DoorStringOrInteger: Sendable {
    case string(String)
    case integer(DoorNumberLiteral)

    var wire: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): value.wire
        }
    }
}

enum DoorStringOrObject: Sendable {
    case string(String)
    case object([String: JSONValue])

    var wire: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .object(let value): .object(value)
        }
    }
}

enum DoorStringOrBool: Sendable {
    case string(String)
    case bool(Bool)

    var wire: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        }
    }
}

enum DoorStringOrList: Sendable {
    case string(String)
    case list([String])

    var wire: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .list(let value): .array(value.map(JSONValue.string))
        }
    }

    var values: [String] {
        switch self {
        case .string(let text): [text]
        case .list(let words): words
        }
    }
}

struct DoorObjectDecoder {
    private var remaining: [String: JSONValue]
    let path: String

    private let schema: JSONValue

    init(_ fields: [String: JSONValue], schema: JSONValue, path: String = "$") {
        remaining = fields
        self.schema = schema
        self.path = path
    }

    func declaredField(_ name: String) throws(DoorDecodeError) -> DoorFieldDescriptor {
        guard let definition = schema.objectValue?["properties"]?.objectValue?[name] else {
            throw DoorDecodeError(path: path + "." + name, accepted: "a declared field")
        }
        let required = schema.objectValue?["required"]?.arrayValue?.contains(.string(name)) == true
        return DoorFieldDescriptor(name, definition, required: required)
    }

    mutating func omit(where predicate: (String, JSONValue) -> Bool) -> [String] {
        let omitted = remaining.filter { predicate($0.key, $0.value) }.keys.sorted()
        for key in omitted { remaining.removeValue(forKey: key) }
        return omitted
    }

    mutating func takeAdditionalFields() -> [String: JSONValue] {
        defer { remaining.removeAll() }
        return remaining
    }

    mutating func value(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> JSONValue? {
        guard let raw = remaining.removeValue(forKey: field.name) else {
            guard !field.required else { throw error(field, "present") }
            return nil
        }
        if let problem = raw.schemaProblem(schema: field.schema, path: path + "." + field.name) {
            throw DoorDecodeError(path: problem.path, accepted: problem.expected)
        }
        return raw == .null && !field.required ? nil : raw
    }

    private func error(_ field: DoorFieldDescriptor, _ expected: String) -> DoorDecodeError {
        DoorDecodeError(path: path + "." + field.name, accepted: expected)
    }

    private mutating func read<T>(_ field: DoorFieldDescriptor, _ expected: String, _ convert: (JSONValue) -> T?) throws(DoorDecodeError) -> T? {
        guard let raw = try value(field), raw != .null else { return nil }
        guard let typed = convert(raw) else { throw error(field, expected) }
        return typed
    }

    mutating func string(_ field: DoorFieldDescriptor, normalizing: ((String) -> String)? = nil) throws(DoorDecodeError) -> String? {
        if let normalizing, case .string(let text)? = remaining[field.name] {
            remaining[field.name] = .string(normalizing(text))
        }
        return try read(field, "a string", \.stringValue)
    }

    mutating func requiredString(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> String {
        guard let text = try string(field) else { throw error(field, "a string") }
        return text
    }

    mutating func bool(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> Bool? {
        try read(field, "a boolean") { if case .bool(let flag) = $0 { flag } else { nil } }
    }

    mutating func int(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> Int? {
        try read(field, "an integer", \.exactIntegerValue)
    }

    mutating func number(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> Double? {
        try read(field, "a number", \.finiteDoubleValue)
    }

    private static func list(_ raw: JSONValue) -> [String]? {
        guard case .array(let items) = raw else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }

    mutating func strings(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> [String]? {
        try read(field, "a list of strings", Self.list)
    }

    mutating func requiredStringOrInteger(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> DoorStringOrInteger {
        guard let result = try stringOrInteger(field) else { throw error(field, "a string or integer") }
        return result
    }

    mutating func numberLiteral(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> DoorNumberLiteral? {
        try read(field, "a number") { raw in
            switch raw {
            case .int(let value): .int(value)
            case .double(let value): .double(value)
            default: nil
            }
        }
    }

    mutating func stringOrInteger(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> DoorStringOrInteger? {
        try read(field, "a string or integer") { raw in
            switch raw {
            case .string(let value): .string(value)
            case .int(let value): .integer(.int(value))
            case .double(let value) where value.isFinite && value == value.rounded(): .integer(.double(value))
            default: nil
            }
        }
    }

    mutating func stringOrObject(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> DoorStringOrObject? {
        try read(field, "a string or object") { raw in
            switch raw {
            case .string(let value): .string(value)
            case .object(let value): .object(value)
            default: nil
            }
        }
    }

    mutating func stringOrBool(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> DoorStringOrBool? {
        try read(field, "a string or boolean") { raw in
            switch raw {
            case .string(let value): .string(value)
            case .bool(let value): .bool(value)
            default: nil
            }
        }
    }

    mutating func stringOrList(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> DoorStringOrList? {
        try read(field, "a string or list of strings") { raw in
            switch raw {
            case .string(let value): .string(value)
            case .array: Self.list(raw).map(DoorStringOrList.list)
            default: nil
            }
        }
    }

    mutating func objectValue(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> [String: JSONValue]? {
        try read(field, "an object", \.objectValue)
    }

    mutating func objectValues(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> [[String: JSONValue]]? {
        try read(field, "a list of objects") {
            guard let items = $0.arrayValue else { return nil }
            let objects = items.compactMap(\.objectValue)
            return objects.count == items.count ? objects : nil
        }
    }

    mutating func stringMap(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> [String: String]? {
        guard let values = try objectValue(field) else { return nil }
        let strings = values.compactMapValues(\.stringValue)
        guard strings.count == values.count else { throw error(field, "an object of strings") }
        return strings
    }

    mutating func emptyObject(_ field: DoorFieldDescriptor) throws(DoorDecodeError) -> Bool {
        guard let fields = try objectValue(field) else { return false }
        guard fields.isEmpty else { throw error(field, "an empty object") }
        return true
    }

    mutating func object<T: DoorObjectSchema>(_ field: DoorFieldDescriptor, as: T.Type) throws(DoorDecodeError) -> T? {
        guard let fields = try objectValue(field) else { return nil }
        var child = DoorObjectDecoder(fields, schema: field.schema, path: path + "." + field.name)
        let result = try T(door: &child)
        try child.rejectUnknownKeys()
        return result
    }

    mutating func objects<T>(_ field: DoorFieldDescriptor, decode: (inout DoorObjectDecoder) throws(DoorDecodeError) -> T) throws(DoorDecodeError) -> [T]? {
        guard let items = try objectValues(field) else { return nil }
        var results: [T] = []
        for (index, fields) in items.enumerated() {
            var child = DoorObjectDecoder(fields, schema: field.schema.objectValue?["items"] ?? .object([:]), path: "\(path).\(field.name)[\(index)]")
            results.append(try decode(&child))
            try child.rejectUnknownKeys()
        }
        return results
    }

    mutating func objects<T: DoorObjectSchema>(_ field: DoorFieldDescriptor, as type: T.Type) throws(DoorDecodeError) -> [T]? {
        try objects(field, decode: T.init(door:))
    }

    func rejectUnknownKeys() throws(DoorDecodeError) {
        if let key = remaining.keys.min() {
            throw DoorDecodeError(path: path + "." + key, accepted: "a declared argument")
        }
    }
}

struct DoorArgsContract: Sendable {
    let schema: JSONValue
    let bytes: Data

    let secretArgs: [String]
    let subject: [String]
    let names: [String: [String]]
    let references: [String: AppAction.ArgumentReference]

    init(schema: JSONValue, secretArgs: [String] = [], subject: [String] = [],
         names: [String: [String]] = [:], references: [String: AppAction.ArgumentReference] = [:]) {
        self.secretArgs = secretArgs
        self.subject = subject
        self.names = names
        self.references = references
        bytes = try! schema.serializedData(pretty: false)
        self.schema = try! JSONValue.parse(bytes)
    }

    init(fields: [DoorFieldDescriptor], constraints: [String: JSONValue],
         names: [String: [String]] = [:], references: [String: AppAction.ArgumentReference] = [:]) {
        self.init(fields: fields, constraints: constraints, required: fields.filter(\.required).map(\.name), names: names, references: references)
    }

    init(fields: [DoorFieldDescriptor], constraints: [String: JSONValue], required: [String]?,
         names: [String: [String]], references: [String: AppAction.ArgumentReference]) {
        var schema = constraints
        schema["type"] = .string("object")
        schema["properties"] = ToolSchema.obj(fields.map { ($0.name, $0.schema) })
        schema["required"] = required.map { .array($0.map(JSONValue.string)) }
        self.init(schema: .object(schema), secretArgs: fields.filter(\.secret).map(\.name),
                  subject: fields.filter(\.subject).map(\.name), names: names, references: references)
    }

    func admitHost(_ input: [String: JSONValue]) throws(ToolFailureError) {
        try DoorDecoder.admit(input, schema: schema, transportMetadata: true, declaredKeysOnly: true)
    }
}

struct DoorSchemaBuilder<Args: DoorArgs>: Sendable {
    let contract: DoorArgsContract
    private let names: Set<String>

    init(fields: [DoorFieldDescriptor] = Args.doorFields) {
        names = Set(fields.map(\.name))
        contract = DoorArgsContract(fields: fields, constraints: Args.rootSchemaConstraints, required: Args.rootRequired,
                                    names: Args.argumentNames, references: Args.argumentReferences)
    }

    func decode(_ input: [String: JSONValue]) throws -> Args {
        let fields = input.filter { names.contains($0.key) || !($0.key.hasPrefix("__") || Args.isTransportMetadata($0.key)) }
        var decoder = DoorObjectDecoder(fields, schema: contract.schema)
        do throws(DoorDecodeError) {
            let value = try Args(door: &decoder)
            try decoder.rejectUnknownKeys()
            return value
        } catch { throw error.failure }
    }
}

final class DoorActionArguments: Sendable {
    struct Shape: Sendable {
        let spelling: String
        let schema: JSONValue?
        fileprivate init(_ spelling: String, _ schema: JSONValue?) {
            self.spelling = spelling
            self.schema = schema
        }

        static let text = Self("", ToolSchema.strSchema())
        static let boolean = Self("bool", ToolSchema.boolSchema())
        static let integer = Self("int", ToolSchema.intSchema())
        static let number = Self("number", .object(["type": .string("number")]))
        static let list = Self("list", .object(["type": .string("array")]))
        static let array = Self("array", list.schema)
        static let any = Self("any", .object([:]))
        static let secret = Self("secret", ToolSchema.strSchema())
        static let receiptView = Self("receipts", ToolSchema.strSchema())
        static let openObject = Self("object*", DoorFieldDescriptor.openObject("", reason: "Caller-defined fields.", values: .any).schema)
        static let fromOwner = Self("object", nil)

        static func open(reason: String) -> Self {
            Self("object", DoorFieldDescriptor.openObject("", reason: reason, values: .implicit).schema)
        }
        static let numbers = Self("[number]", .object(["type": .string("array"), "items": .object(["type": .string("number")])]))
        static let strings = Self("[string]", .object(["type": .string("array"), "items": ToolSchema.strSchema()]))
        static let shortStrings = Self("[str]", strings.schema)

        static func options(_ first: String, _ rest: String...) -> Self {
            let values = [first] + rest
            return Self(values.joined(separator: "|"), ToolSchema.enumStringSchema(values))
        }

        static func objects<T: DoorObjectSchema>(_ type: T.Type, spelling: String) -> Self {
            Self(spelling, .object(["type": .string("array"), "items": DoorFieldDescriptor.object("", type).schema]))
        }
    }

    struct Field: Sendable {
        let spelling: String
        let names: [String]
        let optional: Bool
        let shape: Shape
        var secret: Bool { shape.spelling == "secret" }

        private init(_ name: String, _ shape: Shape, optional: Bool) {
            self.names = name.split(separator: "|").map(String.init)
            self.optional = optional
            self.shape = shape
            spelling = name + (optional ? "?" : "") + (shape.spelling.isEmpty ? "" : ":" + shape.spelling)
        }

        static func required(_ name: String, _ shape: Shape = .text) -> Self { Self(name, shape, optional: false) }
        static func optional(_ name: String, _ shape: Shape = .text) -> Self { Self(name, shape, optional: true) }

        func renaming(_ transform: (String) -> String) -> Self {
            Self(transform(names.joined(separator: "|")), shape, optional: optional)
        }

        init(admitted spelling: String) {
            self.spelling = spelling
            let parts = spelling.split(separator: ":", maxSplits: 1)
            let head = parts.first.map(String.init) ?? spelling
            names = head.trimmingCharacters(in: CharacterSet(charactersIn: "?")).split(separator: "|").map(String.init)
            optional = head.hasSuffix("?")
            let word = parts.dropFirst().first.map(String.init) ?? ""
            shape = Shape(word, ToolSignature.doorProperty(word))
        }
    }

    struct Projection: Sendable {
        let schema: JSONValue
        let form: Result<String, any Error>
        let example: JSONValue
        let plural: [String]
    }

    let spellings: [String]
    let fields: [Field]
    let secretArgs: [String]
    let subject: [String]
    let names: [String: [String]]
    let references: [String: AppAction.ArgumentReference]
    private let projected = Mutex<Result<Projection, any Error>?>(nil)

    init(_ fields: [Field], subject: [String], names: [String: [String]], references: [String: AppAction.ArgumentReference],
         declaredSecrets: [String]) {
        spellings = fields.map(\.spelling)
        self.fields = fields
        let secrets = Set(declaredSecrets)
        secretArgs = fields.flatMap { field in field.names.filter { field.secret || secrets.contains($0) } }
        self.subject = subject
        self.names = names
        self.references = references
    }

    func projection(_ action: AppAction) throws -> Projection {
        try projected.withLock { result in
            if let result { return try result.get() }
            let built = Result { try AppActions.project(action) }
            result = built
            return try built.get()
        }
    }
}
