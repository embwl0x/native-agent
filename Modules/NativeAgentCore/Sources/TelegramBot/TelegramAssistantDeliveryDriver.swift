import Foundation

enum TelegramAssistantDeliveryOutcome: Sendable, Equatable {
    case delivered(messageId: Int?)
    case failed(reason: String)
    case outcomeUnknown(reason: String)
}

/// Owns exactly one assistant-response lane for a turn. Rich drafts are
/// ephemeral, so any draft failure can safely move to the ordinary streamer.
/// A final rich send falls back only when Telegram supplied evidence that no
/// rich message was accepted; ambiguous final transport is never replayed.
actor TelegramAssistantDeliveryDriver {
    typealias SendRichDraft = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ draftId: Int,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Void
    typealias SendRichFinal = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Int
    typealias SendOrdinary = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ text: String
    ) async throws -> Void
    typealias Clock = @Sendable () -> Date
    typealias FailureRecorder = @Sendable (_ redactedError: String) async -> Void

    private enum Lane: Sendable, Equatable {
        case rich
        case ordinary
        case terminal
    }

    private let token: String
    private let chatId: Int
    private let draftId: Int
    private let ordinary: TelegramDraftStreamer
    private let sendOrdinary: SendOrdinary
    private let sendRichDraft: SendRichDraft?
    private let sendRichFinal: SendRichFinal?
    private let clock: Clock
    private let richDraftInterval: TimeInterval
    private let recordFailure: FailureRecorder

    private var lane: Lane
    private var lastRichDraftAt = Date.distantPast
    private var latestAccumulatedText = ""

    init(
        token: String,
        chatId: Int,
        turnId: UUID,
        ordinary: TelegramDraftStreamer,
        sendOrdinary: @escaping SendOrdinary,
        sendRichDraft: SendRichDraft?,
        sendRichFinal: SendRichFinal?,
        richDraftInterval: TimeInterval = 2,
        clock: @escaping Clock = Date.init,
        recordFailure: @escaping FailureRecorder = { _ in }
    ) {
        self.token = token
        self.chatId = chatId
        self.draftId = Self.draftId(for: turnId)
        self.ordinary = ordinary
        self.sendOrdinary = sendOrdinary
        self.sendRichDraft = sendRichDraft
        self.sendRichFinal = sendRichFinal
        self.richDraftInterval = max(0, richDraftInterval)
        self.clock = clock
        self.recordFailure = recordFailure
        self.lane = sendRichDraft != nil && sendRichFinal != nil ? .rich : .ordinary
    }

    func onDelta(_ accumulated: String) async {
        guard lane != .terminal else { return }
        let safeAccumulated = TelegramRichMessageRenderer.sanitize(accumulated)
        guard !safeAccumulated.isEmpty else { return }
        latestAccumulatedText = safeAccumulated
        switch lane {
        case .ordinary:
            await ordinary.onDelta(safeAccumulated)
        case .rich:
            // Bot API rich drafts are private-chat only. Group/supergroup ids
            // are negative; keep the rich final lane without manufacturing a
            // predictable draft rejection and false health error.
            guard chatId > 0 else { return }
            let now = clock()
            guard now.timeIntervalSince(lastRichDraftAt) >= richDraftInterval else {
                return
            }
            guard let rich = TelegramRichMessageRenderer.render(safeAccumulated),
                  let sendRichDraft else {
                await fallBackToOrdinary(reason: "rich draft was not safely representable")
                return
            }
            do {
                try await sendRichDraft(token, chatId, draftId, rich)
                lastRichDraftAt = now
            } catch {
                // A rich draft is only a 30-second preview, never the durable
                // assistant reply. Switching lanes cannot duplicate a reply.
                await reportFailure(step: "rich draft", error: error)
                await fallBackToOrdinary(reason: nil)
            }
        case .terminal:
            return
        }
    }

    func finalize(reply: String) async -> TelegramAssistantDeliveryOutcome {
        guard lane != .terminal else {
            return .outcomeUnknown(reason: "assistant delivery was already terminal")
        }
        let safeReply = TelegramRichMessageRenderer.sanitize(reply)
        guard !safeReply.isEmpty else {
            lane = .terminal
            return .failed(reason: "reply contained no safe user-visible content")
        }
        switch lane {
        case .ordinary:
            return await finalizeOrdinary(reply: safeReply)
        case .rich:
            guard let rich = TelegramRichMessageRenderer.render(safeReply),
                  let sendRichFinal else {
                return await finalizeOrdinary(reply: safeReply)
            }
            do {
                let messageId = try await sendRichFinal(token, chatId, rich)
                lane = .terminal
                return .delivered(messageId: messageId)
            } catch {
                await reportFailure(step: "rich final", error: error)
                guard Self.isKnownNotDelivered(error) else {
                    lane = .terminal
                    return .outcomeUnknown(reason: Self.safeReason(error))
                }
                // Telegram explicitly rejected the method/request. No rich
                // reply exists, so the ordinary path is safe and lossless.
                lane = .ordinary
                return await finalizeOrdinary(reply: safeReply)
            }
        case .terminal:
            return .outcomeUnknown(reason: "assistant delivery was already terminal")
        }
    }

    func abortDelivering(notice: String) async -> Bool {
        guard lane != .terminal else { return false }
        switch lane {
        case .ordinary:
            return await ordinary.abortDelivering(notice: notice)
        case .rich:
            // Ephemeral rich drafts expire by themselves. Do not manufacture a
            // new message when the durable work card already states terminal.
            lane = .terminal
            return false
        case .terminal:
            return false
        }
    }

    private func fallBackToOrdinary(reason: String?) async {
        guard lane == .rich else { return }
        lane = .ordinary
        if let reason {
            await recordFailure("Telegram \(reason) for chat \(chatId); using ordinary draft")
        }
        if !latestAccumulatedText.isEmpty {
            await ordinary.onDelta(latestAccumulatedText)
        }
    }

    private func finalizeOrdinary(reply: String) async -> TelegramAssistantDeliveryOutcome {
        lane = .ordinary
        do {
            for chunk in await ordinary.finalize(reply: reply) {
                try await sendOrdinary(token, chatId, chunk)
            }
            lane = .terminal
            return .delivered(messageId: nil)
        } catch {
            lane = .terminal
            await reportFailure(step: "ordinary final", error: error)
            if TelegramTurnReplyDeliveryFailure.isAmbiguous(error) {
                return .outcomeUnknown(reason: Self.safeReason(error))
            }
            return .failed(reason: Self.safeReason(error))
        }
    }

    private func reportFailure(step: String, error: Error) async {
        await recordFailure(
            "Telegram assistant \(step) failed for chat \(chatId): \(Self.safeReason(error))"
        )
    }

    static func isKnownNotDelivered(_ error: Error) -> Bool {
        guard let failure = error as? TelegramAPIFailure else { return false }
        switch failure.kind {
        case .rejected:
            return true
        case .httpStatus:
            if let status = failure.httpStatus { return (400..<500).contains(status) }
            return false
        case .malformedResponse, .malformedResult:
            return false
        }
    }

    private static func safeReason(_ error: Error) -> String {
        TelegramTurnPresentationReducer.sanitized(String(describing: error))
            ?? "delivery failed"
    }

    private static func draftId(for turnId: UUID) -> Int {
        let compact = turnId.uuidString.replacingOccurrences(of: "-", with: "")
        let suffix = compact.suffix(8)
        let value = UInt32(suffix, radix: 16) ?? 1
        return max(1, Int(value & 0x7FFF_FFFF))
    }
}
