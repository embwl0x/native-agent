import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Transcripts
import TurnTrace
import ChatTurnContracts
// Blueprint: | `SessionContextMeasurement.swift` | SessionContextMeasurement owner. |

/// Calibrate only from the same provider request's measured input; the selected adapter owns output allowance and admission.
public struct SessionContextMeasurement: Sendable {

    public let tokens: Int
    public let observedInputTokens: Int?
    public let outputTokens: Int
    public let requestCharacters: Int
    public let renderedCharacters: Int
    public let messageCount: Int
    public let charactersPerToken: Double
    public let source: String
    public let previousTurnTokens: Int?
    public let turnDeltaTokens: Int?
    public var hasReceipt: Bool { source != "rendered_history_estimate" }
    let rowCharacters: [String: Int]

    /// Ask the admitted request owner for overrides and remaining budget; unbound readouts use the same resident assembly.
    static func outputAllowance(model: String, providerID: String?, dataRoot: URL, call: LLMCall) async throws -> Int {
        guard let providerID, !providerID.isEmpty else {
            throw ProviderRoutingError.configurationFailed("The request's provider is unavailable; its output allowance cannot be measured.")
        }
        // Readouts outside a turn have their own sizing act; a live request keeps its budget and client.
        let client: any LLMClient
        if let turn = call.turn {
            guard let admitted = turn.client else {
                throw ProviderRoutingError.configurationFailed("The turn's admitted model client is unavailable; its output allowance cannot be measured.")
            }
            client = admitted
        } else {
            client = makeResidentProviderLLMClient(dataRoot: dataRoot)
        }
        var sizingTurn = call.turn ?? Turn().with(\.envelope, TurnEnvelope.native("context_measurement", surface: call.surface))
        sizingTurn.admission = ModelAdmission(provider: providerID, model: model,
            reasoningEffort: call.admission?.reasoningEffort, serviceTier: call.admission?.serviceTier)
        var sizingCall = call
        sizingCall.turn = sizingTurn
        let output = try await client.requestOutputTokens(model: model, call: sizingCall)
        guard output >= 0 else {
            throw ProviderRoutingError.configurationFailed("The request adapter reported an invalid output allowance.")
        }
        return output
    }

    public static func measure(_ request: SessionContextRequest, sessionId: String,
                               model: String, providerID: String?, dataRoot: URL,
                               windowTokens: Int, call: LLMCall) async throws -> Self {
        try await read(rows: [], sessionId: sessionId, model: model, providerID: providerID,
            dataRoot: dataRoot, windowTokens: windowTokens, call: call, requestBuilder: { _, _, _ in request })
    }

    /// Check the exact request after tail selection and late additions.
    public static func requireFits(_ request: SessionContextRequest, sessionId: String,
                                   model: String, providerID: String?, dataRoot: URL,
                                   windowTokens: Int?, call: LLMCall) async throws {
        guard let windowTokens, windowTokens > 0 else {
            throw ProviderRoutingError.configurationFailed(
                "The selected model's context window is unavailable. Refresh its catalog in Providers before sending this request.")
        }
        let measurement = try await read(rows: [], sessionId: sessionId, model: model,
            providerID: providerID, dataRoot: dataRoot, windowTokens: windowTokens, call: call,
            requestBuilder: { _, _, _ in request })
        let (total, overflow) = measurement.tokens.addingReportingOverflow(measurement.outputTokens)
        let fits = !overflow && total <= windowTokens
        TurnTraceBus.fireFromContext(kind: "context.request.fit", sessionId: sessionId,
            surface: call.surface, payload: .object([
                "status": .string(fits ? "ready" : "refused"),
                "inputTokens": .int(Int64(measurement.tokens)),
                "outputTokens": .int(Int64(measurement.outputTokens)),
                "windowTokens": .int(Int64(windowTokens)),
                "requestCharacters": .int(Int64(request.characters)),
                "source": .string(measurement.source)
            ]), turn: call.turn)
        guard fits else {
            throw ToolFailureError(
                """
                    The built request still exceeds the selected model's context window after fitting (\(measurement.tokens) measured input + \
                    \(measurement.outputTokens) output allowance; \(windowTokens) available). This request was not sent; replay was not truncated. Reduce the \
                    current input or inspect its retained tool results before continuing.
                    """,
                effects: .none, owner: "chat/messages/\(sessionId).jsonl", code: "context_window_exceeded", status: .refused, recovery: .repair)
        }
    }

    private struct Receipt: Decodable {
        let provider: String
        let model: String
        let lastRequestInputTokens: Int
        let requestCharacters: Int?
        let requestPlan: Data?
        let previousTurnInputTokens: Int?
        let turnInputDeltaTokens: Int?
    }

    public static func read(sessionId: String, model: String, providerID: String?,
                            dataRoot: URL, windowTokens: Int, call: LLMCall,
                            requestBuilder: SessionContextRequest.Builder? = nil) async throws -> Self {
        let rows = try await readRows(sessionId: sessionId, dataRoot: dataRoot)
        return try await read(rows: rows, sessionId: sessionId, model: model,
                              providerID: providerID, dataRoot: dataRoot, windowTokens: windowTokens, call: call, requestBuilder: requestBuilder)
    }

    static func readRows(sessionId: String, dataRoot: URL) async throws -> [JSONValue] {
        let messages = try await SessionHistoryReader(dataRoot: dataRoot)
            .messagesWithStats(forSessionId: sessionId, strictEvidence: true).checkedMessages()
        return try messages.map { message in
            guard let row = message.extras, case .object = row else { throw CocoaError(.fileReadCorruptFile) }
            return row
        }
    }

    static func read(rows: [JSONValue], sessionId: String, model: String, providerID: String?,
                     dataRoot: URL, windowTokens: Int, call: LLMCall,
                     requestBuilder: SessionContextRequest.Builder? = nil) async throws -> Self {
        let path = dataRoot.appendingPathComponent("chat/session_state/\(sessionId)/provider_usage.json")
        let receipt: Receipt?
        do { receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: path)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { receipt = nil }
        let matching = receipt?.model.caseInsensitiveCompare(model) == .orderedSame && receipt?.provider == providerID
        if let receipt {
            guard receipt.lastRequestInputTokens >= 0,
                  receipt.requestCharacters.map({ $0 >= 0 }) != false else {
                throw ProviderRoutingError.configurationFailed(
                    "The provider usage receipt at \(path.path) has invalid counts. Repair it before measuring context.")
            }
        }
        let ratio: Double
        let calibrated: Bool
        // Without a live builder or saved plan, rendered history uses an explicitly estimated ratio rather than request calibration.
        if matching, let receipt, requestBuilder != nil || receipt.requestPlan != nil,
           receipt.lastRequestInputTokens > 0,
           let characters = receipt.requestCharacters, characters > 0 {
            ratio = Double(characters) / Double(receipt.lastRequestInputTokens)
            calibrated = true
        } else {
            ratio = ContextBudgetPolicy.transcriptCharactersPerToken
            calibrated = false
        }
        let characters: Int
        let historyCharacters: Int
        let rowCharacters: [String: Int]
        let source: String
        let output = try await outputAllowance(model: model, providerID: providerID, dataRoot: dataRoot, call: call)
        if let requestBuilder {
            let request = try await requestBuilder(rows, windowTokens, matching ? receipt?.requestPlan : nil)
            characters = request.characters
            historyCharacters = request.historyCharacters
            rowCharacters = request.rowCharacters
            source = calibrated ? "provider_calibrated_request" : "rendered_history_estimate"
        } else if calibrated, let data = receipt?.requestPlan {
            let plan = try JSONDecoder().decode(SessionContextPlan.self, from: data)
            guard plan.model.caseInsensitiveCompare(model) == .orderedSame, plan.provider == providerID else {
                throw ProviderRoutingError.configurationFailed("The provider receipt and its request builder disagree on the selected route.")
            }
            let request = try plan.build(rows, sessionId: sessionId, dataRoot: dataRoot,
                windowTokens: windowTokens, outputTokens: output, charactersPerToken: ratio)
            characters = request.characters
            historyCharacters = request.historyCharacters
            rowCharacters = request.rowCharacters
            source = "provider_calibrated_request"
        } else {
            let history = try rendered(rows, windowTokens: windowTokens, outputTokens: output)
            characters = history.characters
            historyCharacters = history.characters
            rowCharacters = history.rows
            source = "rendered_history_estimate"
        }
        let value = Double(characters) / ratio
        guard characters >= 0, historyCharacters >= 0,
              let tokens = Int(exactly: value.rounded(.up)), tokens >= 0 else {
            throw ProviderRoutingError.configurationFailed("The built request size is not representable; repair its context measurement.")
        }
        return Self(tokens: tokens, observedInputTokens: matching ? receipt?.lastRequestInputTokens : nil,
            outputTokens: output, requestCharacters: characters, renderedCharacters: historyCharacters, messageCount: rows.count,
            charactersPerToken: ratio, source: source,
            previousTurnTokens: calibrated ? receipt?.previousTurnInputTokens : nil,
            turnDeltaTokens: calibrated ? receipt?.turnInputDeltaTokens : nil,
            rowCharacters: rowCharacters)
    }

    private static func rendered(_ rows: [JSONValue], windowTokens: Int, outputTokens: Int) throws -> (characters: Int, rows: [String: Int]) {
        let latestUser = rows.lastIndex { $0.objectValue?["role"] == .string("user") }
        var unbounded = Set<String>()
        let renderables = try rows.enumerated().compactMap { index, row -> SessionHistoryPromptRenderer.Renderable? in
            guard case .object(let fields) = row,
                  case .string(let id)? = fields["id"], !id.isEmpty,
                  ContactThread.Line(fields).provenanceFailure == nil,
                  case .string(let role)? = fields["role"],
                  case .string(let content)? = fields["content"] else { throw CocoaError(.fileReadCorruptFile) }
            if fields["metadata"]?.objectValue?["awaitingConsumption"] == .bool(true) { return nil }
            let createdAt = try JSONRow(row).string("createdAt")
            let message = ChatMessage(role: role, content: content, timestamp: createdAt, extras: row)
            guard var rendered = SessionHistoryPromptRenderer.renderable(message) else { return nil }
            // Current user words are not capped prior history; SentTurnContext owns exact replay after sending.
            if role == "user", rendered.sentContext == nil,
               index == latestUser {
                unbounded.insert(rendered.historyIdentity)
                rendered.structuredContent = ChatSecretRedactor.redactText(content)
            }
            return rendered
        }
        guard let admission = try SessionHistoryMessages.admission(renderables: renderables, historyLimit: 1,
            budget: ContextBudgetPolicy.resolve(windowTokens: windowTokens), unboundedUserIdentities: unbounded) else { return (0, [:]) }
        var projected = SessionHistoryMessages.project(admission)
        let inputBudget = Double(max(0, windowTokens - outputTokens)) * ContextBudgetPolicy.transcriptCharactersPerToken
        if Double(projected.characters) > inputBudget {
            let tail = SessionHistoryTail(admission, rowCharacters: projected.rowCharacters)
            let halfBudget = SessionHistoryTail.halfBudgetCharacters(windowTokens: windowTokens, outputTokens: outputTokens)
            for checkpoint in tail.checkpoints(halfBudgetCharacters: halfBudget) {
                projected = tail.project(after: checkpoint)
                if Double(projected.characters) <= inputBudget { break }
            }
        }
        return (projected.characters, projected.rowCharacters)
    }

    func characters(in rows: [JSONValue]) -> Int {
        rows.reduce(0) { total, row in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { return total }
            return total + (rowCharacters["id\u{1F}\(id)"] ?? 0)
        }
    }
}
