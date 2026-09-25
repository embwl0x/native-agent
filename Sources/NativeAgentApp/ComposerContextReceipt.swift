import SwiftUI
import Foundation
import ChatOrchestration
import PersistenceCore
import ProviderRouting

/// The composer's context receipt: what the last turn of THIS conversation
/// actually put on the wire, component by component.
///
/// 2026-09-16 removed the old "Context receipt" link because nothing had
/// produced a receipt since the Python daemon. The producer exists now — the
/// turn traces — so the ring's card reads `context.snapshot` for the session's
/// last accepted turn and shows only what that row records.
///
/// 2026-09-24 (User): every row speaks in TOKENS and every percent is of the
/// model's whole window. The provider's own input count for the turn's first
/// request is split across the rows by their measured byte share — so the
/// rows add up to the provider's number, not to a guess — and the tool rounds
/// after it are the provider's own difference. A component whose size the
/// trace does not record still has no size here.
struct ComposerContextReceiptRow: Identifiable, Equatable, Sendable {
    let label: String
    /// The count that makes the row legible — tools on the wire, messages
    /// kept, recall hits. Absent when the trace records none.
    let detail: String?
    /// Bytes as assembled. `nil` means "this component's size is not traced",
    /// which is why the row still appears but carries no share.
    let bytes: Int?
    /// Tokens: the provider's count split by byte share, or — when `measured`
    /// — the provider's own count for this component.
    var tokens: Int? = nil
    var measured = false

    var id: String { label }
}

struct ComposerContextReceipt: Equatable, Sendable {
    let model: String?
    let ranAt: Date
    let rows: [ComposerContextReceiptRow]
    /// The sum of the rows that HAVE a size.
    let assembledBytes: Int
    /// The provider's input tokens for the turn's LAST request, from the same
    /// turn's `llm.call` rows — never from another turn's receipt file.
    let lastRequestTokens: Int?
    /// Bytes per token of the split: assembled bytes ÷ the provider's count
    /// for the request those bytes built. nil when there is nothing to split
    /// by (no provider count, or an image turn, whose tokens are not bytes).
    let bytesPerToken: Double?
    /// The window every percent is of: HER window on the selected model
    /// (`ContextBudgetPolicy.windowTokens`), set by the card.
    var windowTokens: Int? = nil
    /// The selected model's own window, named beside hers in the caption.
    var nativeWindowTokens: Int? = nil
    /// Whose window that is, named in the caption — the selected model can
    /// differ from the one the provenance line says ran the turn.
    var windowModelName: String? = nil

    func share(_ row: ComposerContextReceiptRow) -> Double? { share(tokens: row.tokens) }

    func share(tokens: Int?) -> Double? {
        guard let tokens, let windowTokens, windowTokens > 0 else { return nil }
        return Double(tokens) / Double(windowTokens)
    }
}

enum ComposerContextReceiptState: Equatable, Sendable {
    case loading
    /// A fresh conversation, or a turn that has not reached its context yet.
    case noTurn
    case unavailable(String)
    case receipt(ComposerContextReceipt)
}

// MARK: - Reading the trace

enum ComposerContextReceiptReader {
    private static let snapshotKind = "context.snapshot"
    private static let callKind = "llm.call"
    private static let maxErrorChars = 160
    /// The default 2,000-row tail ends before a session's latest turn on a
    /// busy day (live 09-24: the card showed a turn five hours old beside the
    /// footer of the newest one).
    private static let rowLimit = 20_000

    /// The receipt with its window. User, 2026-09-24: every percent is of HER
    /// window on the SELECTED model — the one the ring also reads — with the
    /// model's own window named beside it. No pick of its own means the turn
    /// ran on the resolved model; that one is used.
    static func load(sessionId: String, selectedModel: String) async -> ComposerContextReceiptState {
        let loaded = await load(sessionId: sessionId)
        guard case .receipt(var receipt) = loaded else { return loaded }
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowModel = selected.isEmpty ? (receipt.model ?? "") : selected
        let native = ProviderRouting.contextLength(forModel: windowModel)
        // An unknown model: 60% of the gauge default, as the ring reads it.
        receipt.windowTokens = ContextBudgetPolicy.windowTokens(forModel: windowModel)
            ?? ChatSessionAutocompactionConfig.productionDefault().effectiveWindowTokens(nativeWindowTokens: native)
            ?? native
        receipt.nativeWindowTokens = native
        receipt.windowModelName = windowModel.isEmpty
            ? nil
            : FirstPartyModelCatalog.descriptor(for: windowModel)?.name ?? windowModel
        return .receipt(receipt)
    }

    /// Reads yesterday and today, the same way the Observatory does: the trace
    /// ledger is day-keyed, so a today-only read goes blind at midnight and
    /// would report "no turn yet" on a conversation that ran at 23:59.
    static func load(
        sessionId: String,
        reader: TurnTraceRecentReader = TurnTraceRecentReader(rowLimit: rowLimit),
        now: Date = Date()
    ) async -> ComposerContextReceiptState {
        guard !sessionId.isEmpty else { return .noTurn }
        do {
            let earlier = try await reader.read(now: now.addingTimeInterval(-86_400))
            let today = try await reader.read(now: now)
            return project(events: earlier.events + today.events, sessionId: sessionId)
        } catch {
            return .unavailable(String("\(error)".prefix(maxErrorChars)))
        }
    }

    /// Pure projection, so the rows can be reasoned about without touching a
    /// file. Events arrive earliest-first (append order), so "last" is latest.
    static func project(
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

    static func receipt(
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
            ? catalogInSystem.map { $0 + (catalogInBrief ?? 0) }
            : int(payload, "toolSchemaMaterialBytes")
        let systemBytes = int(payload, "systemTotalBytes").map { max(0, $0 - (catalogInSystem ?? 0)) }
        let briefBytes = int(payload, "volatileBlockBytes").map { max(0, $0 - (catalogInBrief ?? 0)) }
        let historyBytes = int(payload, "historyMessageBytes")
        let userBytes = int(payload, "userMessageBytes")
        let imageBytes = int(payload, "imagePayloadBytes").flatMap { $0 > 0 ? $0 : nil }
        let assembled = [systemBytes, briefBytes, toolBytes, historyBytes, userBytes, imageBytes]
            .reduce(0) { $0 + ($1 ?? 0) }

        let firstTokens = calls.first.flatMap(inputTokens)
        let lastTokens = calls.last.flatMap(inputTokens)
        let tokensPerByte: Double? = {
            guard let firstTokens, assembled > 0, imageBytes == nil else { return nil }
            return Double(firstTokens) / Double(assembled)
        }()
        func tokens(_ bytes: Int?) -> Int? {
            guard let bytes, let tokensPerByte else { return nil }
            return Int((Double(bytes) * tokensPerByte).rounded())
        }
        // What the last exchange added to the history she carries — tool
        // rounds never persist into it, so this is the per-turn growth.
        let historyGrowth: Int? = {
            guard let historyBytes, let previousHistoryBytes,
                  historyBytes > previousHistoryBytes else { return nil }
            return tokens(historyBytes - previousHistoryBytes)
        }()

        var rows = [
            ComposerContextReceiptRow(
                label: "System and persona",
                detail: personaDetail(payload, tokens: tokens),
                bytes: systemBytes,
                tokens: tokens(systemBytes)
            ),
            ComposerContextReceiptRow(
                label: "Turn brief",
                detail: briefBytes == nil ? nil : "recall, capsule and clock, as one block",
                bytes: briefBytes,
                tokens: tokens(briefBytes)
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
            // Sol, 2026-09-17: the trace measures the image blocks and the
            // receipt spent them silently — on a multimodal turn the bytes
            // that dominate the context were missing from the total.
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
        LLMUsage(
            inputTokens: int(call, "inputTokens"),
            cacheReadInputTokens: int(call, "cacheReadInputTokens"),
            cacheCreationInputTokens: int(call, "cacheCreationInputTokens")
        ).logicalInputTokens(provider: string(call, "provider") ?? "")
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
            "\(ComposerContextReceiptPresentation.tokens($0, approximate: true)) tokens"
        } ?? "\(ComposerContextReceiptPresentation.tokens(ComposerContextReceiptPresentation.estimatedTokens(bytes), approximate: true)) tokens"
        return "including \(size) of persona"
    }

    /// The count is everything advertised this turn: the always-on core, the
    /// session's loaded set (capped at 40) and pinned MCP tools.
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
            let retrieved = int(recall, "retrievedHitCount") ?? injected
            let hits = max(retrieved, injected)
            return hits == 1 ? "1 memory injected" : "\(hits) memories injected"
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
            kept = "\(kept0) · grew \(ComposerContextReceiptPresentation.tokens(growth, approximate: true)) last turn"
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
        switch payload[key] {
        case .int(let value): Int(value)
        case .double(let value) where value.isFinite && abs(value) < 1e15: Int(value)
        default: nil
        }
    }

    private static func string(_ payload: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = payload[key], !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Presentation

enum ComposerContextReceiptPresentation {
    static func size(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) B" }
        let formatted = NumberFormatter.localizedString(
            from: NSNumber(value: Double(bytes) / 1_000), number: .decimal
        )
        return "\(formatted) kB"
    }

    /// Bytes → tokens at the rate her real calls measure (~2.8 B/token).
    static func estimatedTokens(_ bytes: Int) -> Int { Int((Double(bytes) / 2.8).rounded()) }

    static func exact(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    /// Compact token count; `~` marks a share of the provider's count split by
    /// size rather than a count the provider gave for that part alone.
    static func tokens(_ count: Int, approximate: Bool) -> String {
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

    /// Percent of the whole window: one decimal below 10%, because on a 1M
    /// window every row lives there.
    static func share(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        let percent = fraction * 100
        if percent <= 0 { return "0%" }
        if percent < 0.1 { return "<0.1%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return "\(Int(percent.rounded()))%"
    }

    /// The row's value column: tokens when the turn has a provider count to
    /// split, bytes as assembled otherwise (image turns, older traces).
    static func value(_ row: ComposerContextReceiptRow) -> String? {
        if let count = row.tokens { return tokens(count, approximate: !row.measured) }
        // No provider count to split (an old or image turn): still tokens, estimated.
        return row.bytes.map { tokens(estimatedTokens($0), approximate: true) }
    }

    static func ranAt(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The total line: the provider's own count for the turn's last request —
    /// what the window actually held — or the assembled bytes when the trace
    /// has no provider count for this turn.
    static func total(_ receipt: ComposerContextReceipt) -> (label: String, value: String, share: String?) {
        guard let last = receipt.lastRequestTokens else {
            return ("Assembled", tokens(estimatedTokens(receipt.assembledBytes), approximate: true), nil)
        }
        return ("Last request", exact(last), share(receipt.share(tokens: last)))
    }

    /// What every percent is of, and how the rows were split.
    static func window(_ receipt: ComposerContextReceipt) -> String? {
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

    static func totalAccessibility(_ receipt: ComposerContextReceipt) -> String {
        let total = total(receipt)
        var parts = [total.label, receipt.lastRequestTokens == nil ? total.value : "\(total.value) tokens"]
        if let share = total.share { parts.append("\(share) of your window") }
        return parts.joined(separator: ", ")
    }

    /// The receipt in words, one line per row, in the order the card draws
    /// it: what the composer pane's page read lists and what
    /// `app_page_read page=context` returns, so the two say the same thing.
    static func lines(_ state: ComposerContextReceiptState) -> [(id: String, label: String)] {
        switch state {
        case .loading: return [("loading", "Reading the last turn…")]
        case .noTurn: return [("no-turn", "No turn yet")]
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

    static func rowAccessibility(
        _ row: ComposerContextReceiptRow,
        share fraction: Double?
    ) -> String {
        var parts = [row.label]
        if let tokens = row.tokens {
            parts.append(row.measured ? "\(exact(tokens)) tokens" : "about \(exact(tokens)) tokens")
        } else if let bytes = row.bytes {
            parts.append("about \(exact(estimatedTokens(bytes))) tokens")
        }
        if let percent = share(fraction) { parts.append("\(percent) of your window") }
        if let detail = row.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The receipt body, shared by the composer card and the classic panel

struct ComposerContextReceiptBody: View {
    let state: ComposerContextReceiptState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .loading:
                caption("Reading the last turn…")
            case .noTurn:
                caption("No turn yet. Send a message and the receipt lands here.")
            case .unavailable(let reason):
                caption("The turn trace could not be read: \(reason)")
            case .receipt(let receipt):
                rows(receipt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer.context.card")
        .accessibilityLabel("Context receipt")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func rows(_ receipt: ComposerContextReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(receipt.rows) { row in
                componentRow(row, share: receipt.share(row))
            }
        }

        Rectangle()
            .fill(NativeAgentShell.hairline)
            .frame(height: 1)
            .padding(.vertical, 2)
            .accessibilityHidden(true)

        let total = ComposerContextReceiptPresentation.total(receipt)
        let window = ComposerContextReceiptPresentation.window(receipt)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(total.label)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
            Spacer(minLength: 8)
            Text(total.value)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
                .monospacedDigit()
            Text(total.share ?? "—")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
                .frame(width: Self.shareWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ComposerContextReceiptPresentation.totalAccessibility(receipt)
                + (window.map { ", \($0)" } ?? "")
        )

        if let window {
            Text(window)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }

        let ran = ComposerContextReceiptPresentation.ranAt(receipt.ranAt)
        let provenance = receipt.model.map { "\($0) · \(ran)" } ?? ran
        Text(provenance)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(
                receipt.model.map { "Last turn ran on \($0), \(ran)" } ?? "Last turn ran \(ran)"
            )
    }

    private static let shareWidth: CGFloat = 40

    private func componentRow(
        _ row: ComposerContextReceiptRow,
        share: Double?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                if let detail = row.detail {
                    Text(detail)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let value = ComposerContextReceiptPresentation.value(row) {
                Text(value)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                    .monospacedDigit()
            }
            // A component with no traced size has no share either; the column
            // stays empty rather than printing a number nobody measured.
            Text(ComposerContextReceiptPresentation.share(share) ?? "—")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
                .frame(width: Self.shareWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ComposerContextReceiptPresentation.rowAccessibility(row, share: share)
        )
    }
}

/// The card the composer's context ring opens. It owns only its own read.
struct ComposerContextReceiptCard: View {
    let sessionId: String
    /// The shell this card is a pane of, when it is one. The card publishes
    /// what it loaded here so a page read of the open pane lists the same
    /// rows; nil for the classic panel, which nothing reads that way.
    var shell: ComposerShellState? = nil
    /// A bot conversation's own model; nil is the chat model.
    var model: String? = nil
    @Environment(AppModel.self) private var appModel
    @State private var state: ComposerContextReceiptState = .loading
    private var windowModel: String { model ?? appModel.chatModel }
    // Settings › Context window: a change re-sizes the window at once.
    @AppStorage("nativeagent.contextWindowMode") private var windowMode = ""
    @AppStorage("nativeagent.compactionThresholdTokens") private var windowSize = 0
    /// Bumped by a completed turn, so a receipt that is already open moves on
    /// to the turn that just finished instead of standing still (Sol).
    @State private var refreshToken = 0

    var body: some View {
        ComposerContextReceiptBody(state: state)
            // `quietReadTask`, not `.task`: this only fetches and assigns, and
            // the offscreen copy a quiet page read mounts must WAIT for it —
            // otherwise the screenshot of an open context pane is a picture of
            // the word "Reading the last turn…". The selected model is in the
            // id so a model pick re-scales every percent at once.
            .quietReadTask(id: "\(sessionId):\(refreshToken):\(windowModel):\(windowMode):\(windowSize)") {
                // Sol, 2026-09-17: switching conversations used to leave the
                // previous one's receipt on screen for the length of two
                // reads, and a fresh conversation showed the old turn. The
                // card empties FIRST; what replaces it belongs to this id.
                state = .loading
                shell?.contextReceipt = .loading
                let loaded = await ComposerContextReceiptReader.load(
                    sessionId: sessionId, selectedModel: windowModel
                )
                guard !Task.isCancelled else { return }
                state = loaded
                shell?.contextReceipt = loaded
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
                if let completed = note.object as? String, completed != sessionId { return }
                refreshToken += 1
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .nativeAgentSessionProviderUsageDidChange)
            ) { note in
                guard let updated = note.object as? String, updated == sessionId else { return }
                refreshToken += 1
            }
    }
}
