import Foundation

enum TelegramAssistantDeliveryOutcome: Sendable, Equatable {
    case delivered(messageId: Int?)
    case failed(reason: String)
    case outcomeUnknown(reason: String)
}

struct TelegramAssistantDeliveryState: Sendable, Equatable, Codable {
    let reply: String
    var confirmedMessageIds: [Int] = []
    var outcomeUnknown = false
    var imagePaths: [String]? = nil
    var confirmedImageCount: Int? = nil

    var isDelivered: Bool {
        confirmedMessageIds.count == TelegramRichMessageRenderer.render(reply).count
            && (confirmedImageCount ?? 0) == (imagePaths?.count ?? 0) && !outcomeUnknown
    }
}

/// Native rich drafts preview the reply without creating durable messages.
/// Finals retain confirmed progress; an ambiguous chunk needs explicit resend.
actor TelegramAssistantDeliveryDriver {
    typealias SendRichDraft = @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ draftId: Int,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Void
    typealias SendRichFinal = @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
        _ richMessage: TelegramInputRichMessage
    ) async throws -> Int
    typealias Clock = @Sendable () -> Date
    typealias FailureRecorder = @Sendable (_ redactedError: String) async -> Void
    typealias PersistDelivery = @Sendable (TelegramAssistantDeliveryState) async throws -> Void

    private let token: String
    private let destination: TelegramDestination
    private let draftId: Int
    private let sendRichDraft: SendRichDraft?
    private let sendRichFinal: SendRichFinal?
    private let clock: Clock
    private let richDraftInterval: TimeInterval
    private let recordFailure: FailureRecorder
    private let persistDelivery: PersistDelivery
    private let sendGeneratedImage: @Sendable (String) async throws -> Void

    private var terminal = false
    private var draftsUnavailable = false
    private var lastRichDraftAt = Date.distantPast
    private var pendingRichText: String?
    private var richDraftFlush: Task<Void, Never>?

    init(
        token: String,
        destination: TelegramDestination,
        turnId: UUID,
        sendRichDraft: SendRichDraft?,
        sendRichFinal: SendRichFinal?,
        richDraftInterval: TimeInterval = 2,
        clock: @escaping Clock = Date.init,
        recordFailure: @escaping FailureRecorder = { _ in },
        persistDelivery: @escaping PersistDelivery,
        sendGeneratedImage: @escaping @Sendable (String) async throws -> Void
    ) {
        self.token = token
        self.destination = destination
        self.draftId = Self.draftId(for: turnId)
        self.sendRichDraft = sendRichDraft
        self.sendRichFinal = sendRichFinal
        self.richDraftInterval = max(0, richDraftInterval)
        self.clock = clock
        self.recordFailure = recordFailure
        self.persistDelivery = persistDelivery
        self.sendGeneratedImage = sendGeneratedImage
    }

    func onDelta(_ accumulated: String) async {
        guard !terminal, !draftsUnavailable else { return }
        let safeAccumulated = TelegramRichMessageRenderer.sanitize(
            TelegramRichMessageRenderer.stripBoldMarkers(accumulated)
        )
        guard !safeAccumulated.isEmpty else { return }
        // Native drafts are private-chat previews; groups retain rich finals.
        guard destination.chatId > 0 else { return }
        pendingRichText = safeAccumulated
        scheduleRichDraftFlush()
    }

    private func scheduleRichDraftFlush() {
        guard richDraftFlush == nil else { return }
        richDraftFlush = Task { [weak self] in
            await self?.flushRichDrafts()
        }
    }

    private func flushRichDrafts() async {
        while pendingRichText != nil, !terminal, !draftsUnavailable {
            let wait = richDraftInterval - clock().timeIntervalSince(lastRichDraftAt)
            if wait > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch {
                    break
                }
                continue
            }
            guard let text = pendingRichText else { break }
            pendingRichText = nil
            guard let sendRichDraft else {
                draftsUnavailable = true
                await recordFailure("Telegram native draft delivery is unavailable for chat \(destination.chatId)")
                break
            }
            // An opening code fence alone has no visible block yet. The next
            // delta can complete it without disabling the native preview.
            guard let rich = TelegramRichMessageRenderer.render(text).last else { continue }
            // One task owns the wire and claims this window before the send.
            lastRichDraftAt = clock()
            do {
                try await sendRichDraft(token, destination, draftId, rich)
            } catch {
                guard !terminal, !Task.isCancelled else { break }
                draftsUnavailable = true
                await reportFailure(step: "rich draft", error: error)
                break
            }
        }
        richDraftFlush = nil
    }

    private func cancelRichDrafts() {
        pendingRichText = nil
        richDraftFlush?.cancel()
        richDraftFlush = nil
    }

    func finalize(
        reply: String,
        imagePaths: [String] = [],
        savedDelivery: TelegramAssistantDeliveryState? = nil,
        resendUnknown: Bool = false
    ) async -> TelegramAssistantDeliveryOutcome {
        cancelRichDrafts()
        guard !terminal else {
            return .outcomeUnknown(reason: "assistant delivery was already terminal")
        }
        // Claim the final before the wire: reentrant finalize/abort cannot send
        // it again while Telegram is accepting a chunk.
        terminal = true
        let safeReply = savedDelivery?.reply ?? TelegramRichMessageRenderer.sanitize(
            TelegramRichMessageRenderer.stripBoldMarkers(reply)
        )
        let messages = TelegramRichMessageRenderer.render(safeReply)
        guard !messages.isEmpty else {
            return .failed(reason: "reply contained no safe user-visible content")
        }
        var delivery = savedDelivery ?? TelegramAssistantDeliveryState(reply: safeReply, imagePaths: imagePaths)
        guard !delivery.outcomeUnknown || resendUnknown else {
            return .outcomeUnknown(reason: "use /retry resend to resend the unconfirmed part; it may arrive twice")
        }
        guard delivery.reply == safeReply, delivery.confirmedMessageIds.count <= messages.count,
              (0...(delivery.imagePaths?.count ?? 0)).contains(delivery.confirmedImageCount ?? 0) else {
            return .failed(reason: "saved reply delivery is inconsistent; check the Mac error log")
        }
        do {
            try await persistDelivery(delivery)
            guard let sendRichFinal else {
                return .failed(reason: "native Telegram reply delivery is unavailable; use /retry after fixing the connection")
            }
            for message in messages.dropFirst(delivery.confirmedMessageIds.count) {
                // A crash after acceptance but before confirmation is uncertain,
                // too. Persist that boundary before touching the wire.
                delivery.outcomeUnknown = true
                try await persistDelivery(delivery)
                let messageId: Int
                do {
                    messageId = try await sendRichFinal(token, destination, message)
                } catch {
                    if Self.isKnownNotDelivered(error) {
                        var rejected = delivery
                        rejected.outcomeUnknown = false
                        try await persistDelivery(rejected)
                        delivery = rejected
                    }
                    throw error
                }
                var confirmed = delivery
                confirmed.confirmedMessageIds.append(messageId)
                confirmed.outcomeUnknown = false
                try await persistDelivery(confirmed)
                delivery = confirmed
            }
            return try await deliverGeneratedImages(&delivery)
        } catch {
            await reportFailure(step: "rich final", error: error)
            if !delivery.outcomeUnknown {
                return .failed(reason: "reply delivery failed; use /retry to deliver the saved answer")
            }
            return .outcomeUnknown(reason: "\(Self.safeReason(error)); use /retry resend to resend the unconfirmed part; it may arrive twice")
        }
    }

    private func deliverGeneratedImages(_ delivery: inout TelegramAssistantDeliveryState) async throws -> TelegramAssistantDeliveryOutcome {
        for path in (delivery.imagePaths ?? []).dropFirst(delivery.confirmedImageCount ?? 0) {
            delivery.outcomeUnknown = true
            try await persistDelivery(delivery)
            do {
                try await sendGeneratedImage(path)
            } catch {
                if Self.isKnownNotDelivered(error) {
                    var rejected = delivery
                    rejected.outcomeUnknown = false
                    try await persistDelivery(rejected)
                    delivery = rejected
                }
                throw error
            }
            var confirmed = delivery
            confirmed.confirmedImageCount = (confirmed.confirmedImageCount ?? 0) + 1
            confirmed.outcomeUnknown = false
            try await persistDelivery(confirmed)
            delivery = confirmed
        }
        return .delivered(messageId: delivery.confirmedMessageIds.last)
    }

    func stop() async {
        cancelRichDrafts()
        terminal = true
        // Native previews expire. The durable work card owns the stop notice.
    }

    private func reportFailure(step: String, error: Error) async {
        await recordFailure(
            "Telegram assistant \(step) failed for chat \(destination.chatId): "
                + (TelegramTurnPresentationReducer.sanitized(String(describing: error)) ?? "delivery failed")
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

    /// Person-facing: this lands on the work card, so no raw Swift/NSError text.
    private static func safeReason(_ error: Error) -> String {
        let dropped: Set<Int> = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
        ]
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && dropped.contains(nsError.code)
            ? "the connection dropped"
            : "Telegram didn't confirm it"
    }

    private static func draftId(for turnId: UUID) -> Int {
        let compact = turnId.uuidString.replacingOccurrences(of: "-", with: "")
        let suffix = compact.suffix(8)
        let value = UInt32(suffix, radix: 16) ?? 1
        return max(1, Int(value & 0x7FFF_FFFF))
    }
}
