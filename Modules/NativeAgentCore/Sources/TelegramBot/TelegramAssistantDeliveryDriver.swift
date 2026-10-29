import Foundation
import NativeAgentCore
// Blueprint: | `TelegramAssistantDeliveryDriver.swift` | `TelegramAssistantDeliveryDriver` actor; `onDelta`, `finalize` |

enum TelegramAssistantDeliveryOutcome: Sendable, Equatable {
    case delivered(messageId: Int?)
    case held
    case failed(reason: String)
    case outcomeUnknown(reason: String)
}

struct TelegramAssistantDeliveryState: Sendable, Equatable, Codable {
    struct Rejection: Sendable, Equatable, Codable {
        let reason: String
        let reply: String
        let imagePaths: [String]?
    }

    let reply: String
    var confirmedMessageIds: [Int] = []
    var outcomeUnknown = false
    var imagePaths: [String]? = nil
    var confirmedImageCount: Int? = nil
    var silent: Bool? = nil
    var lastRejection: Rejection? = nil

    var rejectionReason: String? {
        lastRejection?.reply == reply && lastRejection?.imagePaths == imagePaths ? lastRejection?.reason : nil
    }

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
    typealias FailureRecorder = @Sendable (_ redactedError: String) async -> Void
    typealias PersistDelivery = @Sendable (TelegramAssistantDeliveryState) async throws -> Void

    private let token: String
    private let destination: TelegramDestination
    private let draftId: Int
    private let sendRichDraft: SendRichDraft
    private let sendRichFinal: SendRichFinal
    private let richDraftInterval: TimeInterval = 1.0 // Telegram allows ~1 edit/s per chat.
    private let recordFailure: FailureRecorder
    private let persistDelivery: PersistDelivery
    private let sendGeneratedImage: @Sendable (String, Data) async throws -> Void
    private let holdDelivery: @Sendable () async throws -> Bool

    private var terminal = false
    private var draftsUnavailable = false
    private var lastRichDraftAt = Date.distantPast
    private var pendingRichText: String?
    private var accumulatedText = ""
    private var richDraftFlush: Task<Void, Never>?

    init(
        token: String,
        destination: TelegramDestination,
        turnId: UUID,
        sendRichDraft: @escaping SendRichDraft,
        sendRichFinal: @escaping SendRichFinal,
        recordFailure: @escaping FailureRecorder = { _ in },
        persistDelivery: @escaping PersistDelivery,
        holdDelivery: @escaping @Sendable () async throws -> Bool,
        sendGeneratedImage: @escaping @Sendable (String, Data) async throws -> Void
    ) {
        self.token = token
        self.destination = destination
        self.draftId = Self.draftId(for: turnId)
        self.sendRichDraft = sendRichDraft
        self.sendRichFinal = sendRichFinal
        self.recordFailure = recordFailure
        self.persistDelivery = persistDelivery
        self.holdDelivery = holdDelivery
        self.sendGeneratedImage = sendGeneratedImage
    }

    func onDelta(_ chunk: String) async {
        guard !terminal, !draftsUnavailable else { return }
        // Native drafts are private-chat previews; groups retain rich finals.
        guard destination.chatId > 0 else { return }
        accumulatedText += chunk
        pendingRichText = accumulatedText
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
            let wait = richDraftInterval - Date().timeIntervalSince(lastRichDraftAt)
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
            let safeText = TelegramRichMessageRenderer.sanitize(TelegramRichMessageRenderer.stripBoldMarkers(text))
            // An opening code fence alone has no visible block yet. The next
            // delta can complete it without disabling the native preview.
            guard let rich = TelegramRichMessageRenderer.render(safeText).last else { continue }
            // One task owns the wire and claims this window before the send.
            lastRichDraftAt = Date()
            do {
                if try await holdDelivery() { draftsUnavailable = true; break }
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
        guard !messages.isEmpty || !(savedDelivery?.imagePaths ?? imagePaths).isEmpty else {
            return .failed(reason: "reply contained no safe user-visible content")
        }
        var delivery = savedDelivery ?? TelegramAssistantDeliveryState(reply: safeReply, imagePaths: imagePaths)
        if !resendUnknown, let reason = delivery.rejectionReason { return .failed(reason: reason) }
        guard !delivery.outcomeUnknown || resendUnknown else {
            return .outcomeUnknown(reason: "use /retry resend to resend the unconfirmed part; it may arrive twice")
        }
        guard delivery.reply == safeReply, delivery.confirmedMessageIds.count <= messages.count,
              (0...(delivery.imagePaths?.count ?? 0)).contains(delivery.confirmedImageCount ?? 0) else {
            return .failed(reason: "saved reply delivery is inconsistent; check the Mac error log")
        }
        do {
            if resendUnknown, delivery.outcomeUnknown || delivery.lastRejection != nil {
                delivery.outcomeUnknown = false
                delivery.lastRejection = nil
                try await persistDelivery(delivery)
            }
            if try await holdDelivery() { return .held }
            var preparedImages: [Data] = []
            for path in (delivery.imagePaths ?? []).dropFirst(delivery.confirmedImageCount ?? 0) {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                guard !bytes.isEmpty else {
                    return .failed(reason: "Saved Telegram image is empty; restore it before delivering the answer.")
                }
                preparedImages.append(bytes)
            }
            if messages.isEmpty { return try await deliverGeneratedImages(&delivery, preparedImages: preparedImages) }
            for message in messages.dropFirst(delivery.confirmedMessageIds.count) {
                // A crash after acceptance but before confirmation is uncertain,
                // too. Persist that boundary before touching the wire.
                delivery.outcomeUnknown = true
                try await persistDelivery(delivery)
                if try await holdDelivery() {
                    delivery.outcomeUnknown = false
                    try await persistDelivery(delivery)
                    return .held
                }
                let messageId: Int
                do {
                    messageId = try await sendRichFinal(token, destination, message)
                } catch {
                    try await recordRejection(error, delivery: &delivery)
                    throw error
                }
                var confirmed = delivery
                confirmed.confirmedMessageIds.append(messageId)
                confirmed.outcomeUnknown = false
                try await persistDelivery(confirmed)
                delivery = confirmed
            }
            return try await deliverGeneratedImages(&delivery, preparedImages: preparedImages)
        } catch {
            await reportFailure(step: "rich final", error: error)
            if let reason = delivery.rejectionReason { return .failed(reason: reason) }
            if !delivery.outcomeUnknown {
                return .failed(reason: "reply delivery failed; use /retry to deliver the saved answer")
            }
            return .outcomeUnknown(reason: "\(Self.safeReason(error)); use /retry resend to resend the unconfirmed part; it may arrive twice")
        }
    }

    private func deliverGeneratedImages(_ delivery: inout TelegramAssistantDeliveryState, preparedImages: [Data]) async throws -> TelegramAssistantDeliveryOutcome {
        for (path, bytes) in zip((delivery.imagePaths ?? []).dropFirst(delivery.confirmedImageCount ?? 0), preparedImages) {
            delivery.outcomeUnknown = true
            try await persistDelivery(delivery)
            if try await holdDelivery() {
                delivery.outcomeUnknown = false
                try await persistDelivery(delivery)
                return .held
            }
            do {
                try await sendGeneratedImage(path, bytes)
            } catch {
                try await recordRejection(error, delivery: &delivery)
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

    private func recordRejection(_ error: Error, delivery: inout TelegramAssistantDeliveryState) async throws {
        guard Self.isKnownNotDelivered(error) else { return }
        var rejected = delivery
        rejected.outcomeUnknown = false
        if let failure = error as? TelegramAPIFailure,
           failure.httpStatus != 429, failure.errorCode != 429,
           (failure.httpStatus ?? 0) < 500, (failure.errorCode ?? 0) < 500 {
            let reason = TurnPresentationReducer.sanitized(String(describing: failure)) ?? "delivery failed"
            rejected.lastRejection = .init(
                reason: "Reply rejected before acceptance: \(reason). Use /retry resend to deliver the saved answer.",
                reply: rejected.reply, imagePaths: rejected.imagePaths)
        }
        try await persistDelivery(rejected)
        delivery = rejected
    }

    func stop() async {
        cancelRichDrafts()
        terminal = true
        // Native previews expire. The durable work card owns the stop notice.
    }

    private func reportFailure(step: String, error: Error) async {
        await recordFailure(
            "Telegram assistant \(step) failed for chat \(destination.chatId): "
                + (TurnPresentationReducer.sanitized(String(describing: error)) ?? "delivery failed")
        )
    }

    static func isKnownNotDelivered(_ error: Error) -> Bool {
        guard let failure = error as? TelegramAPIFailure else { return false }
        switch failure.kind {
        case .rejected, .invalidDuration:
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
