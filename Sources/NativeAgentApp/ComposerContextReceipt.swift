import SwiftUI
import Foundation
import ChatOrchestration
import PersistenceCore

/// The composer's context receipt: what the last turn of THIS conversation
/// actually put on the wire, component by component.
///
/// 2026-09-16 removed the old "Context receipt" link because nothing had
/// produced a receipt since the Python daemon. The producer exists now — the
/// turn traces — so the ring's card reads `context.snapshot` for the session's
/// last accepted turn and shows only what that row records.
///
/// The instrument's rule holds throughout: a component whose size the trace
/// does not record has no size here. It is never estimated from characters,
/// never inferred from a neighbour, and never rendered as a confident zero.
struct ComposerContextReceiptRow: Identifiable, Equatable, Sendable {
    let label: String
    /// The count that makes the row legible — tools on the wire, messages
    /// kept, recall hits. Absent when the trace records none.
    let detail: String?
    /// Bytes as assembled. `nil` means "this component's size is not traced",
    /// which is why the row still appears but carries no share.
    let bytes: Int?

    var id: String { label }
}

struct ComposerContextReceipt: Equatable, Sendable {
    let model: String?
    let ranAt: Date
    let rows: [ComposerContextReceiptRow]
    /// The sum of the rows that HAVE a size. Untraced components are outside
    /// it, so the shares add to 100% of what was measured, not of a guess.
    let assembledBytes: Int

    func share(_ row: ComposerContextReceiptRow) -> Double? {
        guard let bytes = row.bytes, assembledBytes > 0 else { return nil }
        return Double(bytes) / Double(assembledBytes)
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
    private static let maxErrorChars = 160

    /// Reads yesterday and today, the same way the Observatory does: the trace
    /// ledger is day-keyed, so a today-only read goes blind at midnight and
    /// would report "no turn yet" on a conversation that ran at 23:59.
    static func load(
        sessionId: String,
        reader: TurnTraceRecentReader = TurnTraceRecentReader(),
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

        // One user turn can rebuild its context per tool loop; the last
        // snapshot is the one the turn finished on.
        guard let snapshot = events.last(where: {
            $0.kind == snapshotKind && $0.turnId == turnId
        }), case .object(let payload) = snapshot.payload else { return .noTurn }

        let compacted = events.contains {
            $0.kind == TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue
                && $0.turnId == turnId
        }
        return .receipt(receipt(
            payload: payload,
            ranAt: snapshot.ts,
            compactedMidTurn: compacted
        ))
    }

    static func receipt(
        payload: [String: JSONValue],
        ranAt: Date,
        compactedMidTurn: Bool
    ) -> ComposerContextReceipt {
        let rows = [
            ComposerContextReceiptRow(
                label: "System and persona",
                detail: personaDetail(payload),
                bytes: int(payload, "systemTotalBytes")
            ),
            ComposerContextReceiptRow(
                label: "Turn brief",
                detail: int(payload, "volatileBlockBytes") == nil ? nil : "recall, capsule and clock, as one block",
                bytes: int(payload, "volatileBlockBytes")
            ),
            ComposerContextReceiptRow(
                label: "Memory recall",
                detail: recallDetail(payload),
                bytes: nil
            ),
            ComposerContextReceiptRow(
                label: "Tool schemas",
                detail: count(payload, "toolSchemaCount", one: "tool on the wire", many: "tools on the wire"),
                bytes: int(payload, "toolSchemaMaterialBytes")
            ),
            ComposerContextReceiptRow(
                label: "Conversation history",
                detail: historyDetail(payload, compactedMidTurn: compactedMidTurn),
                bytes: int(payload, "historyMessageBytes")
            ),
            ComposerContextReceiptRow(
                label: "Your message",
                detail: nil,
                bytes: int(payload, "userMessageBytes")
            ),
            // Sol, 2026-09-17: the trace measures the image blocks and the
            // receipt spent them silently — on a multimodal turn the bytes
            // that dominate the context were missing from the total while the
            // rows still added to 100%.
            ComposerContextReceiptRow(
                label: "Images",
                detail: imageDetail(payload),
                bytes: int(payload, "imagePayloadBytes").flatMap { $0 > 0 ? $0 : nil }
            ),
        ].filter { $0.bytes != nil || $0.detail != nil }

        return ComposerContextReceipt(
            model: string(payload, "model"),
            ranAt: ranAt,
            rows: rows,
            assembledBytes: rows.reduce(0) { $0 + ($1.bytes ?? 0) }
        )
    }

    // MARK: Details

    /// Persona is compiled INTO the system prompt, so it is named as a share of
    /// that row rather than given a row of its own — two rows would count the
    /// same bytes twice and inflate every other component's share.
    private static func personaDetail(_ payload: [String: JSONValue]) -> String? {
        guard let bytes = int(payload, "personaSourceBytes"), bytes > 0 else { return nil }
        return "including \(ComposerContextReceiptPresentation.size(bytes)) of persona"
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
    /// multi-turn conversation showed System, Tools, Your message and nothing
    /// between them, reading as if it had been sent with no history at all.
    /// `historyDelivery` says where the lane put it; absent that, the row says
    /// "not recorded", which is a different claim from zero.
    private static func historyDetail(
        _ payload: [String: JSONValue],
        compactedMidTurn: Bool
    ) -> String {
        let kept = count(payload, "historyMessageCount", one: "message kept", many: "messages kept")
            ?? deliveryDetail(payload)
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
        case .double(let value): Int(value)
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

    static func share(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        let percent = fraction * 100
        return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    static func ranAt(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The one line that can honestly speak in TOKENS: the provider's own count
    /// for the last request, against THAT REQUEST'S model window — the caller
    /// loads the status with the model the receipt names, never the one that
    /// happens to be selected now (Sol, 2026-09-17), so a numerator and a
    /// denominator can never come from two different models. The rows above
    /// are bytes as assembled, which is a different measurement, so the two are
    /// never summed or converted into each other.
    static func window(_ status: SessionContextStatus?) -> String? {
        guard let status, status.budget > 0 else { return nil }
        let used = NumberFormatter.localizedString(
            from: NSNumber(value: status.used_tokens), number: .decimal
        )
        let budget = NumberFormatter.localizedString(
            from: NSNumber(value: status.budget), number: .decimal
        )
        let percent = Int((Double(status.used_tokens) / Double(status.budget) * 100).rounded())
        let source = status.context_loaded == true ? "last request" : "estimate"
        return "\(source) \(used) of \(budget) tokens · \(percent)%"
    }

    static func rowAccessibility(
        _ row: ComposerContextReceiptRow,
        share fraction: Double?
    ) -> String {
        var parts = [row.label]
        if let bytes = row.bytes { parts.append(size(bytes)) }
        if let percent = share(fraction) { parts.append("\(percent) of the assembled context") }
        if let detail = row.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The receipt body, shared by the composer card and the classic panel

struct ComposerContextReceiptBody: View {
    let state: ComposerContextReceiptState
    let status: SessionContextStatus?

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

        let assembled = ComposerContextReceiptPresentation.size(receipt.assembledBytes)
        let window = ComposerContextReceiptPresentation.window(status)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Assembled")
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
            Spacer(minLength: 8)
            Text(assembled)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assembled \(assembled)\(window.map { ", \($0)" } ?? "")")

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
            if let bytes = row.bytes {
                Text(ComposerContextReceiptPresentation.size(bytes))
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
                .frame(width: 34, alignment: .trailing)
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
    @Environment(AppModel.self) private var appModel
    @State private var state: ComposerContextReceiptState = .loading
    @State private var status: SessionContextStatus?
    /// Bumped by a completed turn, so a receipt that is already open moves on
    /// to the turn that just finished instead of standing still (Sol).
    @State private var refreshToken = 0

    var body: some View {
        ComposerContextReceiptBody(state: state, status: status)
            // `quietReadTask`, not `.task`: this only fetches and assigns, and
            // the offscreen copy a quiet page read mounts must WAIT for it —
            // otherwise the screenshot of an open context pane is a picture of
            // the word "Reading the last turn…".
            .quietReadTask(id: "\(sessionId):\(refreshToken)") {
                // Sol, 2026-09-17: switching conversations used to leave the
                // previous one's receipt on screen for the length of two
                // reads, and a fresh conversation showed the old turn. The
                // card empties FIRST; what replaces it belongs to this id.
                state = .loading
                status = nil
                shell?.contextReceipt = .loading
                shell?.contextWindowLine = nil
                let loaded = await ComposerContextReceiptReader.load(sessionId: sessionId)
                guard !Task.isCancelled else { return }
                state = loaded
                shell?.contextReceipt = loaded
                // The token line is measured against the model that RAN the
                // turn, not the one selected now: a model change keeps the
                // provider's last count but recomputes the window, which
                // would pair one model's numerator with another's budget.
                guard case .receipt(let receipt) = loaded else { return }
                let measured = try? await appModel.getSessionContext(
                    sessionId: sessionId,
                    model: receipt.model ?? appModel.chatModel
                )
                guard !Task.isCancelled else { return }
                status = measured
                shell?.contextWindowLine = ComposerContextReceiptPresentation.window(measured)
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
