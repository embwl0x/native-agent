import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import DeskCore
import MindCore
// Blueprint: | `ActionDescriptor.swift` | Native execution, input contracts and offered schemas |

struct ActionContext: Sendable {
    let client: SwiftToolDispatcher
    var runtime: ActionRuntime { client.runtime }
    let turn: Turn
    let invocation: ChatToolInvocation
    let tool: String
    let surface: String
    let deskState: DeskState?
    let transportMetadata: [String: JSONValue]
}

struct ActionDescriptor: Sendable {
    enum Availability { case always, files, system, accessibility, activity }

    struct Bound: ToolInvocationPart, Sendable {
        static let unset: Self? = nil
        let name: String
        let input: [String: JSONValue]
        let arguments: @Sendable () throws -> any DoorArgs
        let preflight: (@Sendable (ActionContext) async throws -> JSONValue?)?
        let approvalReason: (@Sendable (URL, Bool) async throws -> String?)?
        let run: @Sendable (ActionContext) async throws -> JSONValue
    }

    let args: DoorArgsContract
    let schema: LLMToolSchema
    let courier: DesktopConversationTools.Operation?
    let availability: Availability
    typealias Bind = @Sendable ([String: JSONValue]) -> Bound
    let bind: Bind
    var toolDescriptor: ToolDescriptor { ToolDescriptor(schema: schema, bucket: SwiftToolDispatcher.nativeBucket(schema)) }

    init<Args: DoorArgs>(_ type: Args.Type, name: String, fields: [DoorFieldDescriptor] = Args.doorFields,
        availability: Availability = .always, courier: DesktopConversationTools.Operation? = nil,
        preflight: (@Sendable (ActionContext, Args) async -> JSONValue?)? = nil,
        approvalReason: (@Sendable (URL, Bool, Args) async -> String?)? = nil,
        run: @escaping @Sendable (ActionContext, Args) async throws -> JSONValue, toolClass: ToolClass,
        reach: ToolReach = .agent, capabilities: CapabilitySet? = nil,
        effectInputPolicy: ToolEffectInputPolicy = .fixed, macIntegration: MacIntegrationAccess? = nil,
        makes: String? = nil, removes: String? = nil, description: String) {
        let builder = DoorSchemaBuilder<Args>(fields: fields)
        args = builder.contract
        self.availability = availability
        self.courier = courier
        schema = LLMToolSchema(name: name, toolClass: toolClass, reach: reach, capabilities: capabilities,
            effectInputPolicy: effectInputPolicy, macIntegration: macIntegration, makes: makes, removes: removes,
            description: description, parametersJSON: args.bytes)
        bind = { input in
            let cached = Mutex<Result<Args, any Error>?>(nil)
            let arguments: @Sendable () throws -> Args = {
                try cached.withLock { result in
                    if let result { return try result.get() }
                    let decoded = Result { try builder.decode(input) }
                    result = decoded
                    return try decoded.get()
                }
            }
            return Bound(name: name, input: input, arguments: { try arguments() },
                preflight: preflight.map { check in { @Sendable context in try await check(context, arguments()) } },
                approvalReason: approvalReason.map { reason in { @Sendable root, canonical in try await reason(root, canonical, arguments()) } },
                run: { context in try await run(context, arguments()) })
        }
    }

    func bound(_ input: [String: JSONValue], invocation: ChatToolInvocation) -> Bound {
        if let held = invocation[Bound.self], held.name == schema.name, held.input == input { return held }
        return bind(input)
    }

    static func numSchema(
        _ desc: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("number"))]
        if let minimum { props.append(("minimum", .double(minimum))) }
        if let maximum { props.append(("maximum", .double(maximum))) }
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    static func stringArraySchema(
        _ desc: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        maxItemLength: Int? = nil
    ) -> JSONValue {
        var itemProps: [(String, JSONValue)] = [("type", .string("string"))]
        if let maxItemLength { itemProps.append(("maxLength", .int(Int64(maxItemLength)))) }
        var props: [(String, JSONValue)] = [
            ("type", .string("array")),
            ("items", ToolSchema.obj(itemProps)),
        ]
        // A bound the validator enforces must also be a bound the schema STATES, or the model only discovers it by being refused.
        if let minItems { props.append(("minItems", .int(Int64(minItems)))) }
        if let maxItems { props.append(("maxItems", .int(Int64(maxItems)))) }
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    static func stringOrStringArraySchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("string"))]),
                ToolSchema.obj([
                    ("type", .string("array")),
                    ("items", ToolSchema.obj([("type", .string("string"))])),
                ]),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    static func stringOrIntSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("string"))]),
                ToolSchema.obj([("type", .string("integer"))]),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    static func looseObjectSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("object")),
            ("additionalProperties", .bool(true)),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    static func stringOrLooseObjectSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([ToolSchema.strSchema(), looseObjectSchema(), ToolSchema.obj([("type", .string("null"))])])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    static func looseObjectArraySchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("array")),
            ("items", ToolSchema.obj([
                ("type", .string("object")),
                ("additionalProperties", .bool(true)),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }

    static func nonEmptyStringSchema(_ description: String) -> JSONValue {
        ToolSchema.obj([
            ("type", .string("string")),
            ("minLength", .int(1)),
            ("description", .string(description)),
        ])
    }

}
