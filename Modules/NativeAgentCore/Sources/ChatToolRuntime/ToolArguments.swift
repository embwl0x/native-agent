import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import ChatTurnContracts
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import Desk
import MacControl
import SwarmRuns
import MacIntegration
import ToolExecution
import Studio
import Senses
import Research
import TurnTrace
import Context
import NativeAgentShared
// Blueprint: | `ToolArguments.swift` | Checked admission; lossless normalization; explicit tool operation and app-door dependencies |
// Normalize optional nulls from the native schema before gates; preserve required nulls and false.
public enum ToolArguments {

    /// Both doors judge the normalized call against its owner's current schema. Only the native transport carries private metadata beside public arguments.
    public static func admit(_ input: [String: JSONValue], schema: JSONValue, path: String = "$",
                             transportMetadata: Bool = false, declaredKeysOnly: Bool = false) throws {
        guard case .object(var fields) = schema else {
            throw ToolFailureError("The action's input schema must be an object.", effects: .none,
                owner: "Tool catalog", code: "tool_schema_unavailable",
                instruction: "Repair the registered input schema before calling it again.", recovery: .repair)
        }
        if declaredKeysOnly, fields["additionalProperties"] == nil {
            fields["additionalProperties"] = .bool(false)
        }
        let arguments = transportMetadata ? input.filter { !$0.key.hasPrefix("__") } : input
        if let problem = JSONValue.object(arguments).schemaProblem(schema: .object(fields), path: path) {
            throw ToolFailureError("\(problem.words). Nothing ran.",
                argumentPath: problem.path, accepted: problem.expected, effects: .none,
                owner: problem.keyword == "schema" ? "Tool catalog" : nil,
                code: problem.keyword == "schema" ? "tool_schema_unavailable" : "invalid_arguments")
        }
    }

    /// Owners with a fixed current input vocabulary reject undeclared names; transport-owned metadata is not part of their public arguments.
    static func requireDeclaredKeys(_ input: [String: JSONValue], descriptor: LLMToolSchema?) throws {
        guard let descriptor else {
            throw ToolFailureError("The action's input contract is unavailable.", effects: .none,
                owner: "Tool catalog", instruction: "Repair its registered schema before calling it again.")
        }
        try admit(input, schema: descriptor.checkedParameters(), transportMetadata: true, declaredKeysOnly: true)
    }

    /// One host contract for execution and preview alike, so a preview cannot pass what execution refuses. `schema` is the catalog's current contract,
    /// nil when it has none; a preview records no shims, since nothing ran.
    public static func admitted(_ input: [String: JSONValue], tool canonical: String, schema: LLMToolSchema?, wake: JSONValue?,
                                recordShims: Bool = true) throws -> [String: JSONValue] {
        // Contacts owns its raw contract: nulls and numeric entries must not disappear or become strings before the owner can reject them.
        try MacContactsExecutor.validateArguments(tool: canonical, input: input)
        let input = ToolNameAliases.hostArgs(canonical, ToolNameAliases.doorArgs(canonical, input, reportShim: recordShims), reportShim: recordShims)
        try SwiftToolDispatcher.validateDeskMutationArguments(canonical, input: input)
        let authoring = canonical == "sense_make" || (canonical == "ability_manage" && input["verb"] == .string("save"))
        // No executor runs without the current catalog contract.
        let normalized: [String: JSONValue]
        if let schema {
            let parameters: JSONValue
            do { parameters = try JSONValue.parse(schema.parametersJSON) }
            catch {
                throw ToolFailureError("""
                    The catalog's input schema for \(canonical) could not be read: \(error.localizedDescription). Repair its registered schema \
                    before calling it again.
                    """,
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(canonical).", recovery: .repair)
            }
            guard case .object = parameters else {
                throw ToolFailureError("The catalog's input schema for \(canonical) must be an object. Repair its registered schema before calling it again.",
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(canonical).", recovery: .repair)
            }
            normalized = MacContactsExecutor.parameters(for: canonical) != nil ? input
                : ToolArguments.normalized(input, schema: parameters, preserving: authoring ? ["learned", "choices"] : [], recordShims: recordShims)
            // A wake supplies input.wake, not the authored call's parameters. Native actions reached during that wake still admit their own args.
            let native = SwiftToolDispatcher.nativeCanonicalToolNames.contains(canonical)
                || AppActionBinding.declaredSchema(canonical) != nil
            if native || wake == nil {
                try admit(normalized, schema: parameters, transportMetadata: true, declaredKeysOnly: native)
            }
        } else if AuthoredToolEffects.isPrimitiveEffect(canonical) {
            // A primitive effect (fetch, apps.call, …) has no catalog row: Trust admits it by its effect identity and its broker checks its arguments.
            normalized = input
        } else {
            throw ToolFailureError("No current input schema is available for \(canonical). Nothing ran.",
                effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                instruction: "Use app find to select an available current action, or repair its registered schema.", recovery: .repair)
        }
        if canonical == "desk_close" { try SwiftToolDispatcher.validateDeskClose(normalized) }
        return normalized
    }

    public static func normalized(_ input: [String: JSONValue], schema: JSONValue, preserving: Set<String> = [],
        recordShims: Bool = true) -> [String: JSONValue] {
        guard case .object(let schema) = schema,
              case .object(let properties)? = schema["properties"] else { return input }
        let required: [JSONValue]
        if case .array(let values)? = schema["required"] { required = values } else { required = [] }
        var result = input
        for (key, value) in input {
            guard let field = properties[key] else { continue }
            if preserving.contains(key), case .object(let shape) = field, shape["type"] == nil { continue }
            let normalized = normalizedValue(value, schema: field, recordShims: recordShims)
            if !required.contains(.string(key)), value == .null {
                result.removeValue(forKey: key)
                if recordShims { TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T01"), "site": .string(
                    "SwiftToolDispatcher+Dispatch.swift:normalized")]), turn: nil) }
            } else {
                result[key] = normalized
            }
        }
        // Reapply declared clear_fields as empty strings on every pass so repeated normalization cannot erase a clear.
        if case .object(let clear)? = properties["clear_fields"], case .object(let items)? = clear["items"],
           case .array(let allowed)? = items["enum"], case .array(let names)? = result["clear_fields"] {
            for case .string(let name) in names where allowed.contains(.string(name)) && properties[name] != nil
                && !required.contains(.string(name)) && result[name] == nil {
                result[name] = .string("")
            }
        }
        return result
    }
    // Exact protocol forms carry no normalization receipt.
    private static func normalizedValue(_ value: JSONValue, schema: JSONValue, recordShims: Bool = true) -> JSONValue {
        guard case .object(let field) = schema else { return value }
        for key in ["anyOf", "oneOf"] {
            if case .array(let variants)? = field[key] {
                // Preserve an already accepted form. Otherwise only one declared form may accept the normalized value; never choose a union arm.
                if let accepted = variants.first(where: { value.schemaProblem(schema: $0) == nil }) {
                    return normalizedValue(value, schema: accepted, recordShims: recordShims)
                }
                let forms = variants.map { ($0, normalizedValue(value, schema: $0, recordShims: recordShims)) }
                    .filter { $0.1.schemaProblem(schema: $0.0) == nil }
                return forms.count == 1 ? forms[0].1 : value
            }
        }
        if case .object(let object) = value { return .object(normalized(object, schema: schema, recordShims: recordShims)) }
        if case .array(let values) = value, let items = field["items"] {
            return .array(values.map { normalizedValue($0, schema: items, recordShims: recordShims) })
        }
        let types: [JSONValue] = if case .array(let types)? = field["type"] { types }
            else { field["type"].map { [$0] } ?? [] }
        let declared = types.filter { $0 != .string("null") }
        guard declared.count == 1, let type = declared.first else { return value }
        if type == .string("array"), let items = field["items"], case .object(let item) = items {
            let scalar: [JSONValue] = [.string("string"), .string("number"), .string("integer"), .string("boolean")]
            let itemTypes = if case .array(let types)? = item["type"] { types.filter { $0 != .string("null") } }
                else { item["type"].map { [$0] } ?? [] }
            if itemTypes.count == 1, itemTypes.allSatisfy(scalar.contains),
               value != .null {
                let element = normalizedValue(value, schema: items, recordShims: recordShims)
                if element.schemaProblem(schema: items) == nil { return .array([element]) }
            }
        }
        if case .double(let number) = value, type == .string("integer"), let integer = Int64(exactly: number) {
            return .int(integer)
        }
        if type == .string("string") {
            if case .int(let number) = value { return .string(String(number)) }
            if case .double(let number) = value, number.isFinite { return .string(String(number)) }
        }
        if case .string(let text) = value {
            if type == .string("boolean"), text == "true" || text == "false" { return .bool(text == "true") }
            if type == .string("integer") || type == .string("number"),
               let parsed = try? JSONValue.parse(Data(text.utf8)) {
                if case .int(let integer) = parsed,
                   let original = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                   original == Decimal(integer) { return parsed }
                if case .double(let number) = parsed, number.isFinite,
                   // Reject numeric spellings that lose significant digits.
                   let original = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                   let represented = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")),
                   original == represented {
                    if type == .string("number") { return parsed }
                    if let integer = Int64(exactly: number) { return .int(integer) }
                }
            }
        }
        return value
    }
}

private enum AdmittedArgumentsInvocationPart: ToolInvocationPart { static let unset: (tool: String, input: [String: JSONValue])? = nil }
private enum AppDoorInvocationPart: ToolInvocationPart { static let unset: AppDoorReentry? = nil }
private enum SurfacedNosInvocationPart: ToolInvocationPart { static let unset: ChatToolDispatchTracer.SurfacedNos? = nil }
private enum PreparedContextInvocationPart: ToolInvocationPart { static let unset: ContextPreparedTurn? = nil }
private enum InternalReadInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum InsideWorkspaceInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum DryRunInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum LiveTargetInvocationPart: ToolInvocationPart { static let unset: AgentConversationLiveTarget? = nil }
private enum HelperDoorInvocationPart: ToolInvocationPart { static let unset: HelperContact.Door? = nil }
private enum ReturnsHistoryInvocationPart: ToolInvocationPart { static let unset: Bool = true }
private enum HandsBackInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum WroteInvocationPart: ToolInvocationPart { static let unset: (@Sendable (URL) -> Void)? = nil }
private enum ImageSinkInvocationPart: ToolInvocationPart { static let unset: LocalToolImage.Sink? = nil }
private enum MetadataOnlyInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum WaitDeadlineInvocationPart: ToolInvocationPart { static let unset: ContinuousClock.Instant? = nil }
private enum ObservationModeInvocationPart: ToolInvocationPart { static let unset: MacObservationMode = .interactive }
private enum FrameSourceInvocationPart: ToolInvocationPart { static let unset: String = "direct" }
private enum ReadingRawInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum PassiveObservationInvocationPart: ToolInvocationPart { static let unset: Bool = false }
private enum ReadCaptureInvocationPart: ToolInvocationPart { static let unset: SenseAppReadCapture? = nil }
private enum ReadContentInvocationPart: ToolInvocationPart { static let unset: OwnedProgramRunner.ReadContent? = nil }
private enum WakeInvocationPart: ToolInvocationPart { static let unset: JSONValue? = nil }
private enum ProgramHostInvocationPart: ToolInvocationPart { static let unset: (any OwnedProgramToolHost)? = nil }
private enum ValueCallInvocationPart: ToolInvocationPart { static let unset: (id: String, version: String)? = nil }
private enum BotAncestryInvocationPart: ToolInvocationPart { static let unset: Set<UUID> = [] }
private enum DeskContinuationInvocationPart: ToolInvocationPart { static let unset: DeskContinuationTurn? = nil }
private enum AuthoredCallInvocationPart: ToolInvocationPart {
    static let unset: (tool: String, perform: @Sendable () async throws -> JSONValue)? = nil
}
private enum MacOperationInvocationPart: ToolInvocationPart { static let unset: MacOperationContext? = nil }
private enum SenseReadInvocationPart: ToolInvocationPart { static let unset: SenseReadOperation? = nil }
private enum SenseReadsInvocationPart: ToolInvocationPart { static let unset: SenseTurnReads? = nil }
private enum DeadlinesInvocationPart: ToolInvocationPart { static let unset: OperationDeadlines = OperationDeadlines() }

/// Chat tools own these operation parts; profiles carry them without importing their dependencies.
extension ChatToolInvocation {
    package var admittedArguments: (tool: String, input: [String: JSONValue])? {
        get { self[AdmittedArgumentsInvocationPart.self] }
        set { self[AdmittedArgumentsInvocationPart.self] = newValue }
    }
    package var appDoor: AppDoorReentry? {
        get { self[AppDoorInvocationPart.self] }
        set { self[AppDoorInvocationPart.self] = newValue }
    }
    var surfacedNos: ChatToolDispatchTracer.SurfacedNos? {
        get { self[SurfacedNosInvocationPart.self] }
        set { self[SurfacedNosInvocationPart.self] = newValue }
    }
    package var preparedContext: ContextPreparedTurn? {
        get { self[PreparedContextInvocationPart.self] }
        set { self[PreparedContextInvocationPart.self] = newValue }
    }
    package var internalRead: Bool {
        get { self[InternalReadInvocationPart.self] }
        set { self[InternalReadInvocationPart.self] = newValue }
    }
    package var insideWorkspace: Bool {
        get { self[InsideWorkspaceInvocationPart.self] }
        set { self[InsideWorkspaceInvocationPart.self] = newValue }
    }
    package var dryRun: Bool {
        get { self[DryRunInvocationPart.self] }
        set { self[DryRunInvocationPart.self] = newValue }
    }
    package var liveTarget: AgentConversationLiveTarget? {
        get { self[LiveTargetInvocationPart.self] }
        set { self[LiveTargetInvocationPart.self] = newValue }
    }
    package var helperDoor: HelperContact.Door? {
        get { self[HelperDoorInvocationPart.self] }
        set { self[HelperDoorInvocationPart.self] = newValue }
    }
    package var returnsHistory: Bool {
        get { self[ReturnsHistoryInvocationPart.self] }
        set { self[ReturnsHistoryInvocationPart.self] = newValue }
    }
    package var handsBack: Bool {
        get { self[HandsBackInvocationPart.self] }
        set { self[HandsBackInvocationPart.self] = newValue }
    }
    package var wrote: (@Sendable (URL) -> Void)? {
        get { self[WroteInvocationPart.self] }
        set { self[WroteInvocationPart.self] = newValue }
    }
    package var imageSink: LocalToolImage.Sink? {
        get { self[ImageSinkInvocationPart.self] }
        set { self[ImageSinkInvocationPart.self] = newValue }
    }
    package var metadataOnly: Bool {
        get { self[MetadataOnlyInvocationPart.self] }
        set { self[MetadataOnlyInvocationPart.self] = newValue }
    }
    package var waitDeadline: ContinuousClock.Instant? {
        get { self[WaitDeadlineInvocationPart.self] }
        set { self[WaitDeadlineInvocationPart.self] = newValue }
    }
    package var observationMode: MacObservationMode {
        get { self[ObservationModeInvocationPart.self] }
        set { self[ObservationModeInvocationPart.self] = newValue }
    }
    package var frameSource: String {
        get { self[FrameSourceInvocationPart.self] }
        set { self[FrameSourceInvocationPart.self] = newValue }
    }
    package var readingRaw: Bool {
        get { self[ReadingRawInvocationPart.self] }
        set { self[ReadingRawInvocationPart.self] = newValue }
    }
    package var passiveObservation: Bool {
        get { self[PassiveObservationInvocationPart.self] }
        set { self[PassiveObservationInvocationPart.self] = newValue }
    }
    package var readCapture: SenseAppReadCapture? {
        get { self[ReadCaptureInvocationPart.self] }
        set { self[ReadCaptureInvocationPart.self] = newValue }
    }
    package var readContent: OwnedProgramRunner.ReadContent? {
        get { self[ReadContentInvocationPart.self] }
        set { self[ReadContentInvocationPart.self] = newValue }
    }
    package var wake: JSONValue? {
        get { self[WakeInvocationPart.self] }
        set { self[WakeInvocationPart.self] = newValue }
    }
    package var programHost: (any OwnedProgramToolHost)? {
        get { self[ProgramHostInvocationPart.self] }
        set { self[ProgramHostInvocationPart.self] = newValue }
    }
    package var valueCall: (id: String, version: String)? {
        get { self[ValueCallInvocationPart.self] }
        set { self[ValueCallInvocationPart.self] = newValue }
    }
    package var botAncestry: Set<UUID> {
        get { self[BotAncestryInvocationPart.self] }
        set { self[BotAncestryInvocationPart.self] = newValue }
    }
    package var deskContinuation: DeskContinuationTurn? {
        get { self[DeskContinuationInvocationPart.self] }
        set { self[DeskContinuationInvocationPart.self] = newValue }
    }
    /// The authored primitive this call runs: its name and the ability run's own body.
    package var authoredCall: (tool: String, perform: @Sendable () async throws -> JSONValue)? {
        get { self[AuthoredCallInvocationPart.self] }
        set { self[AuthoredCallInvocationPart.self] = newValue }
    }
    package var macOperation: MacOperationContext? {
        get { self[MacOperationInvocationPart.self] }
        set { self[MacOperationInvocationPart.self] = newValue }
    }
    package var senseRead: SenseReadOperation? {
        get { self[SenseReadInvocationPart.self] }
        set { self[SenseReadInvocationPart.self] = newValue }
    }
    package var senseReads: SenseTurnReads? {
        get { self[SenseReadsInvocationPart.self] }
        set { self[SenseReadsInvocationPart.self] = newValue }
    }
    package var deadlines: OperationDeadlines {
        get { self[DeadlinesInvocationPart.self] }
        set { self[DeadlinesInvocationPart.self] = newValue }
    }

    package var expired: Bool { waitDeadline.map { ContinuousClock.now >= $0 } ?? false }
    package var cancellationError: any Error { expired ? OperationWaitBudget.Exceeded() : CancellationError() }
    package func with<Value>(_ path: WritableKeyPath<Self, Value>, _ value: Value) -> Self {
        var invocation = self
        invocation[keyPath: path] = value
        return invocation
    }

    package func macContext(dataRoot: URL) -> MacOperationContext {
        var context = macOperation ?? MacOperationContext(dataRoot: dataRoot)
        context.deadline = waitDeadline
        context.observationMode = observationMode
        context.frameSource = frameSource
        context.handsBack = handsBack
        context.appCapture = readCapture
        return context
    }

    package func serving(mac context: MacOperationContext) -> Self {
        var invocation = self
        invocation.macOperation = context
        invocation.waitDeadline = context.deadline
        invocation.observationMode = context.observationMode
        invocation.frameSource = context.frameSource
        invocation.handsBack = context.handsBack
        return invocation
    }

    package var conversation: AgentConversationContext {
        var context = AgentConversationContext()
        context.isInternalRead = internalRead
        context.dryRun = dryRun
        context.liveTarget = liveTarget
        context.helperDoor = helperDoor
        context.returnsHistory = returnsHistory
        return context
    }

    package func serving(conversation: AgentConversationContext) -> Self {
        with(\.internalRead, conversation.isInternalRead).with(\.dryRun, conversation.dryRun)
            .with(\.liveTarget, conversation.liveTarget).with(\.helperDoor, conversation.helperDoor)
            .with(\.returnsHistory, conversation.returnsHistory)
    }

    package func senseOperation(turn: Turn) -> SenseReadOperation {
        var operation = senseRead ?? SenseReadOperation(turn: turn)
        operation.options.raw = readingRaw
        operation.appCapture = readCapture
        operation.senseReads = senseReads
        operation.readContent = readContent
        operation.passive = passiveObservation
        operation.deadline = waitDeadline
        return operation
    }

    package func serving(sense operation: SenseReadOperation) -> Self {
        with(\.senseRead, operation).with(\.readingRaw, operation.options.raw).with(\.readCapture, operation.appCapture)
            .with(\.senseReads, operation.senseReads).with(\.readContent, operation.readContent)
            .with(\.passiveObservation, operation.passive).with(\.waitDeadline, operation.deadline)
    }

    package func partInvocation(turn: Turn?, surface: String) -> Parts.Invocation {
        .init(host: programHost, execution: .init(turn: turn, surface: surface, deadlines: deadlines, wake: wake,
            options: .init(handsBack: handsBack), readContent: readContent, valueIdentity: valueCall, deadline: waitDeadline,
            onActivity: { deadlines.progressed() }), progressed: { deadlines.progressed() })
    }
}

public protocol ChatToolExecuting: ToolExecutor {
    func execute(tool: String, input: [String: JSONValue], surface: String,
                 turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue
}

extension ChatToolExecuting {
    public func execute(tool: String, input: [String: JSONValue], surface: String, turn: Turn) async throws -> JSONValue {
        try await execute(tool: tool, input: input, surface: surface, turn: turn, invocation: .init())
    }
}
public extension ToolDispatchClient {
    func withToolArguments(
        turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue], surface: String,
        body: ([String: JSONValue], ChatToolInvocation) async throws -> JSONValue
    ) async throws -> JSONValue {
        let canonical = CanonicalToolNameDispatcher.canonical(tool)
        let identity = canonical
        if let current = invocation.admittedArguments, current.tool == identity, current.input == input { return try await body(input, invocation) }
        // Registered native contracts exist independently of whether Trust currently offers their actions. Admission must still reach the action's
        // permission/remedy owner, rather than treat a hidden action as a missing schema. Authored contracts come from their live catalog.
        let schema: LLMToolSchema?
        if let declared = AppActionBinding.declaredSchema(canonical) { schema = declared }
        else { schema = try await listAvailableToolSchemas(named: [canonical], turn: turn, surface: surface).first { $0.name == canonical } }
        let normalized = try ToolArguments.admitted(input, tool: canonical, schema: schema, wake: invocation.wake)
        return try await body(normalized, invocation.with(\.admittedArguments, (identity, normalized)))
    }
}
