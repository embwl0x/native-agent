import Foundation
import ChatTurnRuntime
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ProviderRouting
// Blueprint: | `ContextReceiptProjection.swift` | `ComposerContextReceiptRow`, `ComposerContextReceipt`, `ComposerContextReceiptState`, `ContextReceipts`; shared context trace/receipt facts and checked Composer receipt reader using the caller engine's root for trace and provider/window reads; sizes are nonnegative whole counts, checked totals and estimates stay unavailable when unrepresentable |

/// The composer's receipt reads the session's last accepted `context.snapshot`.
/// Rows use traced sizes and split the provider's first-request input tokens by byte share.
/// Tool rounds use the provider's difference; percentages use her selected-model window.
public struct ComposerContextReceiptRow: Identifiable, Equatable, Sendable {
    public let label: String
    /// The count that makes the row legible — tools on the wire, messages
    /// kept, recall hits. Absent when the trace records none.
    public let detail: String?
    /// Bytes as assembled. `nil` means "this component's size is not traced",
    /// which is why the row still appears but carries no share.
    public let bytes: Int?
    /// Tokens: the provider's count split by byte share, or — when `measured`
    /// — the provider's own count for this component.
    public var tokens: Int? = nil
    public var measured = false

    public var id: String { label }
}

public struct ComposerContextReceipt: Equatable, Sendable {
    public let model: String?
    public let ranAt: Date
    public let rows: [ComposerContextReceiptRow]
    /// The sum of the rows that HAVE a size; nil when that sum overflows.
    public let assembledBytes: Int?
    /// The provider's input tokens for the turn's LAST request, from the same
    /// turn's `llm.call` rows — never from another turn's receipt file.
    public let lastRequestTokens: Int?
    /// Bytes per token of the split: assembled bytes ÷ the provider's count
    /// for the request those bytes built. nil when there is nothing to split
    /// by (no provider count, or an image turn, whose tokens are not bytes).
    public let bytesPerToken: Double?
    /// Her selected-model window, derived from the same native window shown beside it.
    public var windowTokens: Int? = nil
    /// The selected model's own window, named beside hers in the caption.
    public var nativeWindowTokens: Int? = nil
    /// Whose window that is, named in the caption — the selected model can
    /// differ from the one the provenance line says ran the turn.
    public var windowModelName: String? = nil

    public func share(_ row: ComposerContextReceiptRow) -> Double? { share(tokens: row.tokens) }

    public func share(tokens: Int?) -> Double? {
        guard let tokens, let windowTokens, windowTokens > 0 else { return nil }
        return Double(tokens) / Double(windowTokens)
    }
}

public enum ComposerContextReceiptState: Equatable, Sendable {
    case loading
    /// A fresh conversation, or a turn that has not reached its context yet.
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

    /// Percentages use her selected-model window (resolved model if unselected), with the native window named.
    public static func load(sessionId: String, selectedModel: String, dataRoot: URL) async throws -> ComposerContextReceiptState {
        // The newest rows first: her latest turn is almost always in them, and
        // parsing the whole day's trace on every open made the popover slow.
        let near = try await load(sessionId: sessionId, reader: TurnTraceRecentReader(dataRootOverride: dataRoot, rowLimit: nearRowLimit))
        let loaded: ComposerContextReceiptState
        if case .outsideSearch = near {
            loaded = try await load(sessionId: sessionId, reader: TurnTraceRecentReader(dataRootOverride: dataRoot, rowLimit: rowLimit))
        } else { loaded = near }
        guard case .receipt(var receipt) = loaded else { return loaded }
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowModel = selected.isEmpty ? (receipt.model ?? "") : selected
        // The selected model on the Chat route, as the ring reads it; a window
        // no catalog row states stays nil, and the card says so.
        let route = await SwiftNativeProviderRouting(dataRoot: dataRoot).chatRouteProvider()
        receipt.nativeWindowTokens = ProviderRouting.verifiedContextLength(forModel: windowModel, providerID: route, dataRoot: dataRoot)
        receipt.windowTokens = ChatSessionAutocompactionConfig.productionDefault().effectiveWindowTokens(nativeWindowTokens: receipt.nativeWindowTokens)
        receipt.windowModelName = windowModel.isEmpty
            ? nil
            : FirstPartyModelCatalog.descriptor(for: windowModel)?.name ?? windowModel
        return .receipt(receipt)
    }

    /// Reads yesterday and today, the same way the Observatory does: the trace
    /// ledger is day-keyed, so a today-only read goes blind at midnight and
    /// would report "no turn yet" on a conversation that ran at 23:59.
    public static func load(
        sessionId: String,
        reader: TurnTraceRecentReader = TurnTraceRecentReader(rowLimit: rowLimit),
        now: Date = Date()
    ) async throws -> ComposerContextReceiptState {
        guard !sessionId.isEmpty else { return .noTurn }
        // A tail read is bounded by design, and a bound is coverage, not a fault: the newest
        // rows are always in the tail, so the session's latest acceptance in today's window is
        // its latest turn, and that turn's rows run unbroken to the end of the window. Only a
        // turn that is not in a window cut short is unknown, and then it is older than the search.
        let accepted = TurnLifecycleMilestone.turnAccepted.rawValue
        func holdsTurn(_ read: TurnTraceRecentReader.Snapshot) -> Bool {
            read.events.contains { $0.kind == accepted && $0.sessionId == sessionId }
        }
        let today = try await reader.read(now: now)
        if holdsTurn(today) { return project(events: today.events, sessionId: sessionId) }
        if today.truncated { return .outsideSearch }
        // Yesterday too: the ledger is day-keyed, and a turn accepted at 23:59 runs on past midnight.
        let earlier = try await reader.read(now: now.addingTimeInterval(-86_400))
        guard holdsTurn(earlier) else { return .outsideSearch }
        return project(events: earlier.events + today.events, sessionId: sessionId)
    }

    /// Pure projection, so the rows can be reasoned about without touching a
    /// file. Events arrive earliest-first (append order), so "last" is latest.
    public static func project(
        events: [TurnTraceEvent],
        sessionId: String
    ) -> ComposerContextReceiptState {
        let accepted = TurnLifecycleMilestone.turnAccepted.rawValue
        guard let turnId = events.last(where: {
            $0.kind == accepted && $0.sessionId == sessionId
        })?.turnId else { return .noTurn }

        // The FIRST snapshot is the context the turn's first request carried;
        // the tool rounds after it are counted from the provider's numbers.
        guard let first = events.firstIndex(where: {
            $0.kind == snapshotKind && $0.turnId == turnId
        }), case .object(let payload) = events[first].payload else { return .noTurn }
        let snapshot = events[first]

        // Same turn AND surface, and only the turn's own loop: auxiliary lanes
        // (memory, moments) run under the parent turn id and are stamped
        // `requestShape: unmeasured` with no tool contract or prefix shape;
        // every main-loop request carries one of those two.
        let calls: [[String: JSONValue]] = events[first...].compactMap {
            guard $0.kind == callKind, $0.turnId == turnId, $0.surface == snapshot.surface,
                  case .object(let call) = $0.payload,
                  string(call, "requestShape") != "unmeasured",
                  call["tools.wireSchemaBytes"] != nil || call["shapeVersion"] != nil
            else { return nil }
            return call
        }
        let previousHistoryBytes = events[..<first].last(where: {
            $0.kind == snapshotKind && $0.sessionId == sessionId && $0.turnId != turnId
        }).flatMap { event -> Int? in
            guard case .object(let previous) = event.payload else { return nil }
            return int(previous, "historyMessageBytes")
        }
        let compacted = events.contains {
            $0.kind == TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue
                && $0.turnId == turnId
        }
        return .receipt(receipt(
            payload: payload,
            ranAt: snapshot.ts,
            compactedMidTurn: compacted,
            calls: calls,
            previousHistoryBytes: previousHistoryBytes
        ))
    }

    public static func receipt(
        payload: [String: JSONValue],
        ranAt: Date,
        compactedMidTurn: Bool,
        calls: [[String: JSONValue]] = [],
        previousHistoryBytes: Int? = nil
    ) -> ComposerContextReceipt {
        // Text tool lane: no tools array goes to the provider (the call row
        // says `tools.wireSchemaBytes: 0`); each tool is one prose line inside
        // the system prompt or the turn brief. The schema JSON is never sent,
        // so it must not be counted — it read as 40% of a request it was not
        // in. Newer snapshots measure the lines; they move out of the two rows
        // that carry them into the tool row, so nothing is counted twice.
        let catalogInSystem = int(payload, "toolCatalogSystemBytes")
        let catalogInBrief = int(payload, "toolCatalogBriefBytes")
        let toolsAsText = catalogInSystem != nil
            || calls.first.flatMap { int($0, "tools.wireSchemaBytes") } == 0
        let toolBytes = toolsAsText
            ? catalogInSystem.flatMap { sum($0, catalogInBrief ?? 0) }
            : int(payload, "toolSchemaMaterialBytes")
        let systemBytes = int(payload, "systemTotalBytes").flatMap { difference($0, catalogInSystem ?? 0) }
        let briefBytes = int(payload, "volatileBlockBytes").flatMap { difference($0, catalogInBrief ?? 0) }
        // What this turn fed her rides in the system prompt's changing part
        // (pinned facts, recalled memories, inner state, clock), plus any brief.
        // When the per-turn part rides as the brief, the snapshot's dynamic IS
        // the brief and the system prompt holds none of it.
        let dynamicBytes = int(payload, "dynamicBytes")
        let ridesBrief = (int(payload, "volatileBlockBytes") ?? 0) > 0 && int(payload, "volatileBlockBytes") == dynamicBytes
        let personaBytes = ridesBrief ? systemBytes
            : dynamicBytes.flatMap { dynamic in systemBytes.flatMap { difference($0, dynamic) } } ?? systemBytes
        let fedBytes = ridesBrief ? briefBytes : dynamicBytes.map { $0 + max(briefBytes ?? 0, 0) } ?? briefBytes
        let historyBytes = int(payload, "historyMessageBytes")
        let userBytes = int(payload, "userMessageBytes")
        let imageBytes = int(payload, "imagePayloadBytes").flatMap { $0 > 0 ? $0 : nil }
        let assembled = [systemBytes, briefBytes, toolBytes, historyBytes, userBytes, imageBytes]
            .reduce(Optional(0)) { total, bytes in total.flatMap { sum($0, bytes ?? 0) } }

        let firstTokens = calls.first.flatMap(inputTokens)
        let lastTokens = calls.last.flatMap(inputTokens)
        let tokensPerByte: Double? = {
            guard let firstTokens, let assembled, assembled > 0, imageBytes == nil else { return nil }
            return Double(firstTokens) / Double(assembled)
        }()
        func tokens(_ bytes: Int?) -> Int? {
            guard let bytes, let tokensPerByte else { return nil }
            return Int(exactly: (Double(bytes) * tokensPerByte).rounded())
        }
        // What the last exchange added to the history she carries — tool
        // rounds never persist into it, so this is the per-turn growth.
        let historyGrowth: Int? = {
            guard let historyBytes, let previousHistoryBytes,
                  previousHistoryBytes >= 0, historyBytes > previousHistoryBytes else { return nil }
            return tokens(historyBytes - previousHistoryBytes)
        }()

        var rows = [
            ComposerContextReceiptRow(
                label: "System and persona",
                detail: personaDetail(payload, tokens: tokens),
                bytes: personaBytes,
                tokens: tokens(personaBytes)
            ),
            ComposerContextReceiptRow(
                label: "Fed this turn",
                detail: fedBytes == nil ? nil : "pinned facts, recalled memories, inner state and the clock",
                bytes: fedBytes,
                tokens: tokens(fedBytes)
            ),
            ComposerContextReceiptRow(
                label: "Memory recall",
                detail: recallDetail(payload),
                bytes: nil
            ),
            ComposerContextReceiptRow(
                label: "Tools",
                detail: toolDetail(payload, asText: toolsAsText, measured: toolBytes != nil),
                bytes: toolBytes,
                tokens: tokens(toolBytes)
            ),
            ComposerContextReceiptRow(
                label: "Conversation history",
                detail: historyDetail(payload, compactedMidTurn: compactedMidTurn, growth: historyGrowth),
                bytes: historyBytes,
                tokens: tokens(historyBytes)
            ),
            ComposerContextReceiptRow(
                label: "Your message",
                detail: nil,
                bytes: userBytes,
                tokens: tokens(userBytes)
            ),
            ComposerContextReceiptRow(
                label: "Images",
                detail: imageDetail(payload),
                bytes: imageBytes
            ),
        ].filter { $0.bytes != nil || $0.detail != nil }

        // Tool calls and results inside this turn: the provider's own
        // difference between the turn's first and last request.
        if let firstTokens, let lastTokens, lastTokens > firstTokens, calls.count > 1 {
            let more = calls.count - 1
            rows.append(ComposerContextReceiptRow(
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

    /// The provider's logical input for one request — Anthropic's three
    /// disjoint counters summed, OpenAI's total as is (`LLMUsage` owns that).
    private static func inputTokens(_ call: [String: JSONValue]) -> Int? {
        let provider = string(call, "provider") ?? ""
        return LLMUsage(
            inputTokens: int(call, "inputTokens"),
            cacheReadInputTokens: int(call, "cacheReadInputTokens"),
            cacheCreationInputTokens: int(call, "cacheCreationInputTokens"),
            additiveInputCounters: LLMUsage.persistedAdditiveInputCounters(call["additiveInputCounters"], provider: provider)
        ).logicalInputTokens(provider: provider)
    }

    // MARK: Details

    /// Persona is compiled INTO the system prompt, so it is named as a share of
    /// that row rather than given a row of its own — two rows would count the
    /// same bytes twice.
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

    /// The count is everything advertised this turn: the always-on core, the
    /// session's loaded set (capped at 40).
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

    /// The recall lane records an OUTCOME and hit counts, never a size, so this
    /// row says what was recalled and stays silent about how big it was.
    private static func recallDetail(_ payload: [String: JSONValue]) -> String? {
        guard case .object(let recall)? = payload["memoryRecall"] else { return nil }
        let injected = int(recall, "injectedHitCount") ?? 0
        switch string(recall, "outcome") {
        case "notConfigured": return "not configured"
        case "error": return "recall failed"
        case "unknown": return "not recorded"
        case "zeroHits": return "no hits"
        case "hits", "contextFlow":
            return injected == 1 ? "1 memory injected" : "\(injected) memories injected"
        default: return nil
        }
    }

    /// The history row is NEVER dropped. It used to fall out of the receipt
    /// whenever the trace recorded no count — which is every turn of the lane
    /// that renders prior turns as text into the system prompt — so a
    /// multi-turn conversation read as if it had been sent with no history.
    /// `historyDelivery` says where the lane put it; absent that, the row says
    /// "not recorded", which is a different claim from zero.
    private static func historyDetail(
        _ payload: [String: JSONValue],
        compactedMidTurn: Bool,
        growth: Int?
    ) -> String {
        var kept = count(payload, "historyMessageCount", one: "message kept", many: "messages kept")
            ?? deliveryDetail(payload)
        if let kept0 = kept, let growth {
            kept = "\(kept0) · grew \(formatTokens(growth, approximate: true)) last turn"
        }
        guard let kept else { return compactedMidTurn ? "compacted this turn" : "not recorded" }
        return compactedMidTurn ? "\(kept), compacted this turn" : kept
    }

    private static func deliveryDetail(_ payload: [String: JSONValue]) -> String? {
        switch string(payload, "historyDelivery") {
        // A statement about the LANE, not about this turn: this delivery puts
        // prior turns inside the system prompt, so whatever history the turn
        // had is already counted in the row above and has no size of its own.
        case "systemPrompt": "this lane carries history inside the system prompt"
        case "none": "no earlier turns"
        default: nil
        }
    }

    /// Silent on a turn that carried no image, rather than a row saying zero.
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

    /// Percent of the whole window: one decimal below 10%, because on a 1M
    /// window every row lives there.
    public static func share(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite, fraction >= 0 else { return nil }
        let percent = fraction * 100
        if percent <= 0 { return "0%" }
        if percent < 0.1 { return "<0.1%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        guard let whole = Int(exactly: percent.rounded()) else { return nil }
        return "\(whole)%"
    }

    /// The row's value column: tokens when the turn has a provider count to
    /// split, bytes as assembled otherwise (image turns, older traces).
    public static func value(_ row: ComposerContextReceiptRow) -> String? {
        if let count = row.tokens { return ContextReceipts.formatTokens(count, approximate: !row.measured) }
        return row.bytes.map { "\(exact($0)) bytes" }
    }

    public static func ranAt(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The total line: the provider's own count for the turn's last request —
    /// what the window actually held — or the assembled bytes when the trace
    /// has no provider count for this turn.
    public static func total(_ receipt: ComposerContextReceipt) -> (label: String, value: String, share: String?) {
        guard let last = receipt.lastRequestTokens else {
            return ("Assembled", receipt.assembledBytes.map { "\(exact($0)) bytes" } ?? "Size unavailable", nil)
        }
        return ("Last request", exact(last), share(receipt.share(tokens: last)))
    }

    /// What every percent is of, and how the rows were split.
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

    /// The receipt in words, one line per row, in the order the card draws
    /// it: what the composer pane's page read lists and what
    /// `app_page_read page=context` returns, so the two say the same thing.
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
