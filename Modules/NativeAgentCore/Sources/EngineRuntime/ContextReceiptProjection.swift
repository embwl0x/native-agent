import Foundation
import ChatTurnRuntime
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting
import NativeAgentShared
// Blueprint: | `ContextReceiptProjection.swift` | `ComposerContextReceiptRow`, `ComposerContextReceipt`, `ComposerContextReceiptState`, `ContextReceipts` |

/// Use accepted context sizes and provider counts; split token shares by bytes and use the selected-model window.
public struct ComposerContextReceiptRow: Identifiable, Equatable, Sendable {
    public let kind: ContextReceiptFace.Part.ID
    public let label: String
    /// Absent counts mean untraced evidence, never zero.
    public let detail: String?
    /// Untraced size leaves the row visible without a share.
    public let bytes: Int?
    /// Split provider tokens by bytes unless the component has a measured provider count.
    public var tokens: Int? = nil
    public var measured = false
    public var count: Int? = nil

    public var id: String { label }
}

public struct ComposerContextReceipt: Equatable, Sendable {
    public var turnId: String? = nil
    public let model: String?
    public let ranAt: Date
    public let rows: [ComposerContextReceiptRow]
    /// The complete assembled size; nil when any component is unmeasured or
    /// the sum overflows. A partial sum cannot calibrate token shares.
    public let assembledBytes: Int?
    /// Use this turn’s final request counters, never another turn’s receipt.
    public let lastRequestTokens: Int?
    /// Calibrate only a request with provider counts and byte-based input; image tokens are not bytes.
    public let bytesPerToken: Double?
    public var windowTokens: Int? = nil
    public var nativeWindowTokens: Int? = nil
    /// The selected model’s window may differ from the model that ran the turn.
    public var windowModelName: String? = nil

    public func share(_ row: ComposerContextReceiptRow) -> Double? { share(tokens: row.tokens) }

    public func share(tokens: Int?) -> Double? {
        guard let tokens, let windowTokens, windowTokens > 0 else { return nil }
        return Double(tokens) / Double(windowTokens)
    }
}

public enum ComposerContextReceiptState: Equatable, Sendable {
    case loading
    case noTurn
    case outsideSearch
    case unavailable(String)
    case receipt(ComposerContextReceipt)
}

// MARK: - Reading the trace

public enum ContextReceipts {
    private static let snapshotKind = "context.snapshot"
    private static let callKind = "llm.call"
    public static let rowLimit = 20_000
    public static let nearRowLimit = 2_000

    /// Use the selected-model window, or the resolved model when unselected, and name its native window.
    public static func load(sessionId: String, selectedModel: String, dataRoot: URL) async throws -> ComposerContextReceiptState {
        // Read newest rows first to bound parsing while favoring the latest turn.
        let near = try await load(sessionId: sessionId, reader: TurnTraceRecentReader(dataRootOverride: dataRoot, rowLimit: nearRowLimit))
        let loaded: ComposerContextReceiptState
        if case .outsideSearch = near {
            loaded = try await load(sessionId: sessionId, reader: TurnTraceRecentReader(dataRootOverride: dataRoot, rowLimit: rowLimit))
        } else { loaded = near }
        guard case .receipt(var receipt) = loaded else { return loaded }
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowModel = selected.isEmpty ? receipt.model : selected else {
            return .unavailable("context.snapshot has no valid model")
        }
        // Share the composer’s selected model; absent catalog windows stay unknown.
        let route = try await SwiftNativeProviderRouting(dataRoot: dataRoot).chatRouteProvider()
        receipt.nativeWindowTokens = ProviderRouting.verifiedContextLength(forModel: windowModel, providerID: route, dataRoot: dataRoot)
        receipt.windowTokens = receipt.nativeWindowTokens
        receipt.windowModelName = windowModel.isEmpty
            ? nil
            : route.flatMap { FirstPartyModelCatalog.descriptor(for: windowModel, providerID: $0, dataRoot: dataRoot) }?.name
                ?? FirstPartyModelCatalog.descriptor(for: windowModel)?.name ?? windowModel
        return .receipt(receipt)
    }

    /// Read the retained record because a turn may cross midnight.
    public static func load(
        sessionId: String,
        reader: TurnTraceRecentReader = TurnTraceRecentReader(rowLimit: rowLimit),
        now: Date = Date()
    ) async throws -> ComposerContextReceiptState {
        guard !sessionId.isEmpty else { return .noTurn }
        // A bounded tail limits coverage, not validity: acceptance within the tail proves its remaining turn rows are covered.
        let accepted = TurnLifecycleMilestone.turnAccepted.rawValue
        func holdsTurn(_ read: TurnTraceRecentReader.Snapshot) -> Bool {
            read.events.contains { $0.kind == accepted && $0.sessionId == sessionId }
        }
        // A detail that no longer decodes names no turn; it cannot void this session's readable evidence.
        let read = try await reader.read(now: now, history: true)
        guard holdsTurn(read) else { return .outsideSearch }
        return project(events: read.events, sessionId: sessionId)
    }

    /// Append order is earliest-first, so the last matching event is latest.
    public static func project(
        events: [TurnTraceEvent],
        sessionId: String
    ) -> ComposerContextReceiptState {
        let accepted = TurnLifecycleMilestone.turnAccepted.rawValue
        guard let turnId = events.last(where: {
            $0.kind == accepted && $0.sessionId == sessionId
        })?.turnId else { return .noTurn }

        // The first snapshot describes initial context; provider counters account for subsequent tool rounds.
        guard let first = events.firstIndex(where: {
            $0.kind == snapshotKind && $0.turnId == turnId
        }) else { return .noTurn }
        guard case .object(let payload) = events[first].payload else {
            return .unavailable("context.snapshot has no valid payload object")
        }
        let snapshot = events[first]

        // Match turn and surface, excluding auxiliary requests marked `requestShape: unmeasured` without a tool contract or prefix shape.
        var calls: [[String: JSONValue]] = []
        for event in events[first...] where event.kind == callKind && event.turnId == turnId && event.surface == snapshot.surface {
            guard case .object(let call) = event.payload else {
                return .unavailable("llm.call has no valid payload object")
            }
            if let shape = call["requestShape"], shape != .null {
                guard case .string = shape else { return .unavailable("llm.call has no valid requestShape") }
            }
            guard string(call, "requestShape") != "unmeasured",
                  call["tools.wireSchemaBytes"] != nil || call["shapeVersion"] != nil else { continue }
            calls.append(call)
        }
        let previousHistoryBytes = events[..<first].last(where: {
            $0.kind == snapshotKind && $0.sessionId == sessionId && $0.turnId != turnId
        }).flatMap { event -> Int? in
            guard case .object(let previous) = event.payload else { return nil }
            return int(previous, "historyMessageBytes")
        }
        let pointed = events.contains {
            $0.kind == "context.tool_result.pointer"
                && $0.turnId == turnId
        }
        if let failure = string(payload, "toolCatalogMeasurementError") {
            return .unavailable("Tool catalog measurement is unavailable: " + failure)
        }
        do {
            var reading = try receipt(
                payload: payload,
                ranAt: snapshot.ts,
                pointedMidTurn: pointed,
                calls: calls,
                previousHistoryBytes: previousHistoryBytes
            )
            reading.turnId = turnId
            return .receipt(reading)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public static func receipt(
        payload: [String: JSONValue],
        ranAt: Date,
        pointedMidTurn: Bool,
        calls: [[String: JSONValue]] = [],
        previousHistoryBytes: Int? = nil
    ) throws -> ComposerContextReceipt {
        let source = try JSONRow(.object(payload))
        for key in ["systemTotalBytes", "dynamicBytes", "userMessageBytes", "imagePayloadBytes",
                    "toolSchemaMaterialBytes", "personaSourceBytes", "toolSchemaCount"] {
            guard let count = try source.optionalInt(key), count >= 0 else {
                throw JSONRow.Malformed.field(key)
            }
        }
        for key in ["toolCatalogSystemBytes", "toolCatalogBriefBytes", "volatileBlockBytes",
                    "historyMessageBytes", "historyMessageCount", "imageBlockCount"] {
            if let count = try source.optionalInt(key), count < 0 { throw JSONRow.Malformed.field(key) }
        }
        let model = try source.string("model")
        guard !model.isEmpty else { throw JSONRow.Malformed.field("model") }
        _ = try source.optionalString("historyDelivery")
        _ = try source.optionalString("toolCatalogMeasurementError")
        guard let raw = source.optionalValue("memoryRecall") else { throw JSONRow.Malformed.field("memoryRecall") }
        let recall = try JSONRow(raw)
        let recallOutcome = try recall.string("outcome")
        guard let count = try recall.optionalInt("injectedHitCount"), count >= 0 else {
            throw JSONRow.Malformed.field("memoryRecall.injectedHitCount")
        }
        for call in calls {
            let row = try JSONRow(.object(call))
            _ = try row.string("provider")
            _ = try row.optionalBool("additiveInputCounters")
            for key in ["inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "tools.wireSchemaBytes"] {
                if let count = try row.optionalInt(key), count < 0 { throw JSONRow.Malformed.field(key) }
            }
        }
        // Text-tool schemas never reach the provider: move measured prose bytes from their containing prompt rows to avoid double counting.
        let catalogInSystem = int(payload, "toolCatalogSystemBytes")
        let catalogInBrief = int(payload, "toolCatalogBriefBytes")
        let toolsAsText = catalogInSystem != nil
            || calls.first.flatMap { int($0, "tools.wireSchemaBytes") } == 0
        if toolsAsText {
            guard catalogInSystem != nil else { throw JSONRow.Malformed.field("toolCatalogSystemBytes") }
            guard catalogInBrief != nil else { throw JSONRow.Malformed.field("toolCatalogBriefBytes") }
        }
        let toolBytes = toolsAsText
            ? catalogInSystem.flatMap { system in catalogInBrief.flatMap { sum(system, $0) } }
            : int(payload, "toolSchemaMaterialBytes")
        let systemBytes = int(payload, "systemTotalBytes").flatMap { total in
            toolsAsText ? catalogInSystem.flatMap { difference(total, $0) } : total
        }
        let briefBytes = int(payload, "volatileBlockBytes").flatMap { total in
            toolsAsText ? catalogInBrief.flatMap { difference(total, $0) } : total
        }
        // When dynamic context travels as the brief, its bytes belong to the brief rather than the system prompt.
        let dynamicBytes = int(payload, "dynamicBytes")
        let ridesBrief = int(payload, "volatileBlockBytes").map { $0 > 0 && $0 == dynamicBytes } == true
        let personaBytes = ridesBrief ? systemBytes
            : dynamicBytes.flatMap { dynamic in systemBytes.flatMap { difference($0, dynamic) } }
        let fedBytes = ridesBrief ? briefBytes
            : dynamicBytes.flatMap { dynamic in briefBytes.flatMap { sum(dynamic, $0) } }
        let historyBytes = int(payload, "historyMessageBytes")
        let userBytes = int(payload, "userMessageBytes")
        let imagePayloadBytes = int(payload, "imagePayloadBytes")
        // Measured image payload bytes are the request's image size; zero bytes means no image tokens to account for.
        let imageFree = imagePayloadBytes == 0
        let imageBytes = imagePayloadBytes.flatMap { $0 > 0 ? $0 : nil }
        let assembled = [systemBytes, briefBytes, toolBytes, historyBytes, userBytes, imagePayloadBytes]
            .reduce(Optional(0)) { total, bytes in total.flatMap { total in bytes.flatMap { sum(total, $0) } } }

        let firstTokens = calls.first.flatMap(inputTokens)
        let lastTokens = calls.last.flatMap(inputTokens)
        let tokensPerByte: Double? = {
            guard let firstTokens, let assembled, assembled > 0, imageFree else { return nil }
            return Double(firstTokens) / Double(assembled)
        }()
        func tokens(_ bytes: Int?) -> Int? {
            guard let bytes, let tokensPerByte else { return nil }
            return Int(exactly: (Double(bytes) * tokensPerByte).rounded())
        }
        // Only persisted history measures per-turn growth; tool rounds do not persist into it.
        let historyGrowth: Int? = {
            guard let historyBytes, let previousHistoryBytes,
                  previousHistoryBytes >= 0, historyBytes > previousHistoryBytes else { return nil }
            return tokens(historyBytes - previousHistoryBytes)
        }()

        var rows = [
            ComposerContextReceiptRow(
                kind: .system,
                label: "System and persona",
                detail: personaDetail(payload, tokens: tokens),
                bytes: personaBytes
            ),
            ComposerContextReceiptRow(
                kind: .fed,
                label: "Fed this turn",
                detail: fedBytes == nil ? "volatileBlockBytes unavailable" : "pinned facts, recalled memories, inner state and the clock",
                bytes: fedBytes
            ),
            ComposerContextReceiptRow(
                kind: .memory,
                label: "Memory recall",
                detail: recallDetail(payload),
                bytes: nil,
                count: ["hits", "contextFlow", "zeroHits"].contains(recallOutcome) ? count : nil
            ),
            ComposerContextReceiptRow(
                kind: .tools,
                label: "Tools",
                detail: toolDetail(payload, asText: toolsAsText, measured: toolBytes != nil),
                bytes: toolBytes
            ),
            ComposerContextReceiptRow(
                kind: .history,
                label: "Conversation history",
                detail: historyDetail(payload, pointedMidTurn: pointedMidTurn, growth: historyGrowth),
                bytes: historyBytes
            ),
            ComposerContextReceiptRow(
                kind: .message,
                label: "Your message",
                detail: nil,
                bytes: userBytes
            ),
            ComposerContextReceiptRow(
                kind: .images,
                label: "Images",
                detail: imageDetail(payload),
                bytes: imageBytes
            ),
        ].filter { $0.bytes != nil || $0.detail != nil }

        let partitionBytes = [personaBytes, fedBytes, toolBytes, historyBytes, userBytes]
            .reduce(Optional(0)) { total, bytes in total.flatMap { total in bytes.flatMap { sum(total, $0) } } }
        // The provider's measured total is split by each part's share of the parts' own bytes; cumulative integer shares keep the
        // parts summing to that total without rounding drift. Parts stay estimates: the provider reports only the total.
        if let firstTokens, let partitionBytes, partitionBytes > 0, imageFree {
            var prefix = 0
            var assigned = 0
            rows = rows.map { row in
                var row = row
                guard let bytes = row.bytes, let next = sum(prefix, bytes), next <= partitionBytes else { return row }
                prefix = next
                let product = UInt(firstTokens).multipliedFullWidth(by: UInt(prefix))
                let cumulative = UInt(partitionBytes).dividingFullWidth(product).quotient
                if let boundary = Int(exactly: cumulative) {
                    row.tokens = boundary - assigned
                    assigned = boundary
                }
                return row
            }
        }

        if let firstTokens, let lastTokens, lastTokens > firstTokens, calls.count > 1 {
            let more = calls.count - 1
            rows.append(ComposerContextReceiptRow(
                kind: .toolRounds,
                label: "Tool rounds this turn",
                detail: more == 1 ? "1 more request, provider count" : "\(more) more requests, provider count",
                bytes: nil,
                tokens: lastTokens - firstTokens,
                measured: true
            ))
        }

        return ComposerContextReceipt(
            model: string(payload, "model"),
            ranAt: ranAt,
            rows: rows,
            assembledBytes: assembled,
            lastRequestTokens: lastTokens,
            bytesPerToken: tokensPerByte.flatMap { $0 > 0 ? 1 / $0 : nil }
        )
    }

    /// Use `LLMUsage` logical input: Anthropic’s disjoint counters sum, while OpenAI already reports a total.
    private static func inputTokens(_ call: [String: JSONValue]) -> Int? {
        guard let provider = string(call, "provider"),
              case .bool(let additive)? = call["additiveInputCounters"] else { return nil }
        return LLMUsage(
            inputTokens: int(call, "inputTokens"),
            cacheReadInputTokens: int(call, "cacheReadInputTokens"),
            cacheCreationInputTokens: int(call, "cacheCreationInputTokens"),
            additiveInputCounters: additive
        ).logicalInputTokens(provider: provider)
    }

    // MARK: Details

    /// Persona is already in the system prompt; show its share without double counting bytes.
    private static func personaDetail(
        _ payload: [String: JSONValue],
        tokens: (Int?) -> Int?
    ) -> String? {
        guard let bytes = int(payload, "personaSourceBytes"), bytes > 0 else { return nil }
        let size = tokens(bytes).map {
            "\(formatTokens($0, approximate: true)) tokens"
        } ?? "\(ComposerContextReceiptPresentation.exact(bytes)) bytes"
        return "including \(size) of persona"
    }

    /// Count advertised tools only; actions are discovered through the always-on `app` tool.
    private static func toolDetail(
        _ payload: [String: JSONValue],
        asText: Bool,
        measured: Bool
    ) -> String? {
        guard let count = int(payload, "toolSchemaCount") else { return nil }
        let tools = count == 1 ? "1 tool" : "\(count) tools"
        guard asText else { return "\(tools) on the wire" }
        return measured ? "\(tools), one text line each; no schemas sent" : "\(tools) as text lines, inside the rows above"
    }

    /// Recall traces record outcomes and hits, not size; do not invent a byte count.
    private static func recallDetail(_ payload: [String: JSONValue]) -> String? {
        guard case .object(let recall)? = payload["memoryRecall"] else { return nil }
        let injected = int(recall, "injectedHitCount")
        switch string(recall, "outcome") {
        case "notConfigured": return "not configured"
        case "error": return "recall failed"
        case "unknown": return "not recorded"
        case "zeroHits": return "no hits"
        case "hits", "contextFlow":
            guard let injected else { return "injectedHitCount unavailable" }
            return injected == 1 ? "1 memory injected" : "\(injected) memories injected"
        default: return nil
        }
    }

    /// Always retain the history row: unrecorded counts are unknown, never zero; `historyDelivery` identifies where history was carried.
    private static func historyDetail(
        _ payload: [String: JSONValue],
        pointedMidTurn: Bool,
        growth: Int?
    ) -> String {
        var kept = count(payload, "historyMessageCount", one: "message kept", many: "messages kept")
            ?? deliveryDetail(payload)
        if let kept0 = kept, let growth {
            kept = "\(kept0) · grew \(formatTokens(growth, approximate: true)) last turn"
        }
        guard let kept else { return pointedMidTurn ? "older result bodies kept as pointers" : "not recorded" }
        return pointedMidTurn ? "\(kept), older result bodies kept as pointers" : kept
    }

    private static func deliveryDetail(_ payload: [String: JSONValue]) -> String? {
        switch string(payload, "historyDelivery") {
        // This delivery embeds history in the system prompt, so a separate size would double count it.
        case "systemPrompt": "this lane carries history inside the system prompt"
        case "none": "no earlier turns"
        default: nil
        }
    }

    private static func imageDetail(_ payload: [String: JSONValue]) -> String? {
        guard let images = int(payload, "imageBlockCount"), images > 0 else { return nil }
        return images == 1 ? "1 image" : "\(images) images"
    }

    private static func count(
        _ payload: [String: JSONValue],
        _ key: String,
        one: String,
        many: String
    ) -> String? {
        guard let value = int(payload, key) else { return nil }
        return value == 1 ? "1 \(one)" : "\(value) \(many)"
    }

    // MARK: Payload access

    private static func int(_ payload: [String: JSONValue], _ key: String) -> Int? {
        guard let value = payload[key]?.exactIntegerValue, value >= 0 else { return nil }
        return value
    }

    private static func sum(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func difference(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= rhs else { return nil }
        return lhs - rhs
    }

    private static func string(_ payload: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = payload[key], !value.isEmpty else { return nil }
        return value
    }

    public static func formatTokens(_ count: Int, approximate: Bool) -> String {
        let text: String
        if count < 1_000 {
            text = "\(count)"
        } else if count < 100_000 {
            text = String(format: "%.1fk", Double(count) / 1_000)
        } else {
            text = "\(Int((Double(count) / 1_000).rounded()))k"
        }
        return approximate ? "~" + text : text
    }
}

extension ContextReceipts {
    public static func read(sessionId: String, selectedModel: String, dataRoot: URL) async -> ComposerContextReceiptState {
        do {
            return try await ContextReceipts.load(sessionId: sessionId, selectedModel: selectedModel, dataRoot: dataRoot)
        } catch {
            return .unavailable(UserFacingError.cause(error, action: "read the turn trace"))
        }
    }
}

// MARK: - Presentation

public enum ComposerContextReceiptPresentation {
    public static func exact(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    /// Use one decimal below 10% so shares remain legible on large windows.
    public static func share(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite, fraction >= 0 else { return nil }
        let percent = fraction * 100
        if percent <= 0 { return "0%" }
        if percent < 0.1 { return "<0.1%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        guard let whole = Int(exactly: percent.rounded()) else { return nil }
        return "\(whole)%"
    }

    /// Use assembled bytes when provider token counts cannot be split, including image turns.
    public static func value(_ row: ComposerContextReceiptRow) -> String? {
        if let count = row.tokens { return ContextReceipts.formatTokens(count, approximate: !row.measured) }
        return row.bytes.map { "\(exact($0)) bytes" }
    }

    public static func ranAt(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Use this turn’s final provider count, or assembled bytes when that count is unrecorded.
    public static func total(_ receipt: ComposerContextReceipt) -> (label: String, value: String, share: String?) {
        guard let last = receipt.lastRequestTokens else {
            return ("Assembled", receipt.assembledBytes.map { "\(exact($0)) bytes" } ?? "Size unavailable", nil)
        }
        return ("Last request", exact(last), share(receipt.share(tokens: last)))
    }

    public static func window(_ receipt: ComposerContextReceipt) -> String? {
        guard let window = receipt.windowTokens, window > 0 else { return nil }
        var line = "of your \(exact(window))-token window"
        if let native = receipt.nativeWindowTokens, native != window {
            line += " · \(receipt.windowModelName ?? "the model") allows \(exact(native))"
        }
        if let perToken = receipt.bytesPerToken {
            line += String(format: " · ~ split by size at %.1f B/token", perToken)
        }
        return line
    }

    public static func totalAccessibility(_ receipt: ComposerContextReceipt) -> String {
        let total = total(receipt)
        var parts = [total.label, receipt.lastRequestTokens == nil ? total.value : "\(total.value) tokens"]
        if let share = total.share { parts.append("\(share) of your window") }
        return parts.joined(separator: ", ")
    }

    /// Share the card’s row order and wording with the context page read.
    public static func lines(_ state: ComposerContextReceiptState) -> [(id: String, label: String)] {
        switch state {
        case .loading: return [("loading", "Reading the last turn…")]
        case .noTurn: return [("no-turn", "No turn yet")]
        case .outsideSearch: return [("outside-search", "No receipt found in the newest trace rows. Older turns are outside this search.")]
        case .unavailable(let reason): return [("unavailable", "The turn trace could not be read: \(reason)")]
        case .receipt(let receipt):
            var lines = receipt.rows.map { ($0.id, rowAccessibility($0, share: receipt.share($0))) }
            lines.append(("assembled", totalAccessibility(receipt)))
            if let window = window(receipt) { lines.append(("window", window)) }
            let ran = ranAt(receipt.ranAt)
            lines.append(("ran", receipt.model.map { "\($0) · \(ran)" } ?? ran))
            return lines
        }
    }

    public static func rowAccessibility(
        _ row: ComposerContextReceiptRow,
        share fraction: Double?
    ) -> String {
        var parts = [row.label]
        if let tokens = row.tokens {
            parts.append(row.measured ? "\(exact(tokens)) tokens" : "about \(exact(tokens)) tokens")
        } else if let bytes = row.bytes {
            parts.append("\(exact(bytes)) bytes")
        }
        if let percent = share(fraction) { parts.append("\(percent) of your window") }
        if let detail = row.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}
