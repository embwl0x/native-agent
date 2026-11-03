import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Transcripts
import TurnTrace
// Blueprint: | `SessionContextMeasurement.swift` | One actual-request-builder sizing owner for foreground compaction and aging, with matching provider-observed input usage exposed separately for presentation; absent/model-switched receipts leave observed usage unavailable; sizing estimates stay explicitly labelled; damaged evidence throws |

/// The real request builder supplies the numerator. Only the same provider
/// request's characters/input tokens calibrate its token estimate. The selected
/// adapter supplies the output allowance for both thresholds and final admission.
public struct SessionContextMeasurement: Sendable {

    public let tokens: Int
    /// The matching provider's recorded input usage, never a rebuilt estimate.
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

    /// Ask the admitted request owner, including its instance overrides and
    /// remaining turn budget. Unbound readouts use the same resident assembly.
    static func outputAllowance(model: String, providerID: String?, dataRoot: URL) async throws -> Int {
        guard let providerID, !providerID.isEmpty else {
            throw ProviderRoutingError.configurationFailed("The request's provider is unavailable; its output allowance cannot be measured.")
        }
        let client = LLMCallContext.client ?? makeResidentProviderLLMClient(dataRoot: dataRoot)
        return try await LLMCallContext.$admittedModel.withValue(model) {
            try await LLMCallContext.$providerId.withValue(providerID) {
                let output = try await client.requestOutputTokens(model: model, surface: LLMCallContext.surface ?? "chat")
                guard output >= 0 else {
                    throw ProviderRoutingError.configurationFailed("The request adapter reported an invalid output allowance.")
                }
                return output
            }
        }
    }

    /// Last admission check on the exact request after folding and any late
    /// additions. Uses the same receipt calibration as the ring and selector.
    /// A request that still exceeds its detected room is refused, never cut.
    public static func requireFits(_ request: SessionContextRequest, sessionId: String,
                                   model: String, providerID: String?, dataRoot: URL,
                                   windowTokens: Int?) async throws {
        guard let windowTokens, windowTokens > 0 else {
            throw ProviderRoutingError.configurationFailed("The selected model's context window is unavailable. Refresh its catalog in Providers before sending this request.")
        }
        let measurement = try await read(rows: [], sessionId: sessionId, model: model,
            providerID: providerID, dataRoot: dataRoot, windowTokens: windowTokens,
            requestBuilder: { _, _, _ in request })
        let (total, overflow) = measurement.tokens.addingReportingOverflow(measurement.outputTokens)
        let fits = !overflow && total <= windowTokens
        TurnTraceBus.fireFromContext(kind: "context.request.fit", sessionId: sessionId,
            surface: LLMCallContext.surface, payload: .object([
                "status": .string(fits ? "ready" : "refused"),
                "inputTokens": .int(Int64(measurement.tokens)),
                "outputTokens": .int(Int64(measurement.outputTokens)),
                "windowTokens": .int(Int64(windowTokens)),
                "requestCharacters": .int(Int64(request.characters)),
                "source": .string(measurement.source)
            ]))
        guard fits else {
            throw ToolFailureError("The built request still exceeds the selected model's context window after fitting (\(measurement.tokens) measured input + \(measurement.outputTokens) output allowance; \(windowTokens) available). This request was not sent; replay was not truncated. Reduce the current input or repair the blocked recollection before continuing.",
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
                            dataRoot: URL, windowTokens: Int,
                            requestBuilder: SessionContextRequest.Builder? = nil) async throws -> Self {
        let rows = try await readRows(sessionId: sessionId, dataRoot: dataRoot)
        return try await read(rows: rows, sessionId: sessionId, model: model,
                              providerID: providerID, dataRoot: dataRoot, windowTokens: windowTokens, requestBuilder: requestBuilder)
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
                     dataRoot: URL, windowTokens: Int,
                     requestBuilder: SessionContextRequest.Builder? = nil) async throws -> Self {
        let path = dataRoot.appendingPathComponent("chat/session_state/\(sessionId)/provider_usage.json")
        let receipt: Receipt?
        do { receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: path)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { receipt = nil }
        let matching = receipt?.model.caseInsensitiveCompare(model) == .orderedSame && receipt?.provider == providerID
        if let receipt {
            guard receipt.lastRequestInputTokens >= 0,
                  receipt.requestCharacters.map({ $0 >= 0 }) != false else {
                throw ProviderRoutingError.configurationFailed("The provider usage receipt at \(path.path) has invalid counts. Repair it before measuring context.")
            }
        }
        let ratio: Double
        let calibrated: Bool
        // Calibration sizes a built request. Without a live builder or saved
        // plan, rendered history uses its own explicitly estimated ratio.
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
            let request = try await plan.build(rows, sessionId: sessionId, dataRoot: dataRoot, windowTokens: windowTokens)
            characters = request.characters
            historyCharacters = request.historyCharacters
            rowCharacters = request.rowCharacters
            source = "provider_calibrated_request"
        } else {
            let history = try rendered(rows, windowTokens: windowTokens)
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
        let output = try await outputAllowance(model: model, providerID: providerID, dataRoot: dataRoot)
        return Self(tokens: tokens, observedInputTokens: matching ? receipt?.lastRequestInputTokens : nil,
            outputTokens: output, requestCharacters: characters, renderedCharacters: historyCharacters, messageCount: rows.count,
            charactersPerToken: ratio, source: source,
            previousTurnTokens: calibrated ? receipt?.previousTurnInputTokens : nil,
            turnDeltaTokens: calibrated ? receipt?.turnInputDeltaTokens : nil,
            rowCharacters: rowCharacters)
    }

    private static func rendered(_ rows: [JSONValue], windowTokens: Int) throws -> (characters: Int, rows: [String: Int]) {
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
            // A new user's words are the current request, not a capped prior
            // user row. Once sent, SentTurnContext owns their exact replay.
            if role == "user", rendered.sentContext == nil,
               index == latestUser {
                unbounded.insert(rendered.historyIdentity)
                rendered.structuredContent = ChatSecretRedactor.redactText(content)
            }
            return rendered
        }
        guard let admission = try SessionHistoryMessages.admission(renderables: renderables, historyLimit: 1,
            windowTokens: windowTokens, unboundedUserIdentities: unbounded) else { return (0, [:]) }
        let projected = SessionHistoryMessages.project(admission)
        var byID: [String: Int] = [:]
        for (row, body) in admission.renderables where projected.historyIdentities.contains(row.historyIdentity) {
            byID[row.historyIdentity] = body.count + (row.sentContext?.block.count ?? 0)
        }
        return (projected.characters, byID)
    }

    func characters(in rows: [JSONValue]) -> Int {
        rows.reduce(0) { total, row in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { return total }
            return total + (rowCharacters["id\u{1F}\(id)"] ?? 0)
        }
    }
}
