import Foundation
import CryptoKit
import NativeAgentCore
import TurnTrace
import ChatTurnContracts
// Blueprint: | `TelegramAssistantDeliveryDriver.swift` | `TelegramAssistantDeliveryDriver`, `onDelta`, `finalize`: join before final send |

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

    var reply: String
    var confirmedMessageIds: [Int] = []
    var outcomeUnknown = false
    var imagePaths: [String]? = nil
    var confirmedImageCount: Int? = nil
    var silent: Bool? = nil
    var lastRejection: Rejection? = nil
    var previewMessageIds: [Int]? = nil
    var previewPending: Bool? = nil

    var rejectionReason: String? {
        lastRejection?.reply == reply && lastRejection?.imagePaths == imagePaths ? lastRejection?.reason : nil
    }

    var isDelivered: Bool {
        previewPending != true && (previewMessageIds?.isEmpty ?? true)
            && confirmedMessageIds.count == TelegramRichMessageRenderer.render(reply).count
            && (confirmedImageCount ?? 0) == (imagePaths?.count ?? 0) && !outcomeUnknown
    }
}

/// Private chats use native drafts; groups grow durable rich messages in place. Finals retain confirmed progress; an ambiguous chunk needs explicit resend.
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
    typealias EditRichMessage = @Sendable (String, TelegramDestination, Int, TelegramInputRichMessage) async throws -> Void
    typealias DeleteMessage = @Sendable (String, Int, Int) async throws -> Void
    typealias FailureRecorder = @Sendable (_ redactedError: String) async -> Void
    typealias PersistDelivery = @Sendable (TelegramAssistantDeliveryState) async throws -> Void

    private let token: String
    private let turn: Turn?
    private let destination: TelegramDestination
    private let draftId: Int
    private let sendRichDraft: SendRichDraft
    private let sendRichFinal: SendRichFinal
    private let editRichMessage: EditRichMessage
    private let deleteMessage: DeleteMessage
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
    private var draftSpacing: Task<Void, Error>?
    private var groupDelivery: TelegramAssistantDeliveryState?

    init(
        token: String,
        destination: TelegramDestination,
        draftKey: String,
        turn: Turn?,
        savedDelivery: TelegramAssistantDeliveryState? = nil,
        sendRichDraft: @escaping SendRichDraft,
        sendRichFinal: @escaping SendRichFinal,
        editRichMessage: @escaping EditRichMessage,
        deleteMessage: @escaping DeleteMessage,
        recordFailure: @escaping FailureRecorder = { _ in },
        persistDelivery: @escaping PersistDelivery,
        holdDelivery: @escaping @Sendable () async throws -> Bool,
        sendGeneratedImage: @escaping @Sendable (String, Data) async throws -> Void
    ) {
        self.token = token
        self.turn = turn
        self.destination = destination
        self.draftId = Self.draftId(for: draftKey)
        self.groupDelivery = savedDelivery
        self.draftsUnavailable = savedDelivery?.outcomeUnknown == true
        self.sendRichDraft = sendRichDraft
        self.sendRichFinal = sendRichFinal
        self.editRichMessage = editRichMessage
        self.deleteMessage = deleteMessage
        self.recordFailure = recordFailure
        self.persistDelivery = persistDelivery
        self.holdDelivery = holdDelivery
        self.sendGeneratedImage = sendGeneratedImage
    }

    func onDelta(_ chunk: String) async {
        guard !terminal, !draftsUnavailable, !chunk.isEmpty else { return }
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
                    let delay = Task { try await Task.sleep(for: .seconds(wait)) }
                    draftSpacing = delay
                    try await delay.value
                    draftSpacing = nil
                } catch {
                    break
                }
                continue
            }
            guard let text = pendingRichText else { break }
            pendingRichText = nil
            let safeText = TelegramRichMessageRenderer.sanitize(TelegramRichMessageRenderer.stripBoldMarkers(text))
            // An opening fence has no visible block; let the next delta complete it before disabling the preview.
            let packets = TelegramRichMessageRenderer.render(safeText)
            guard let rich = packets.last else { continue }
            // One task owns the wire and claims this window before the send.
            lastRichDraftAt = Date()
            do {
                if try await holdDelivery() { draftsUnavailable = true; break }
                guard !terminal else { break }
                if destination.chatId > 0 {
                    try await sendRichDraft(token, destination, draftId, rich)
                    tracePreviewAccepted(characters: safeText.count)
                } else {
                    try await publishGroupPreview(safeText, packets: packets)
                }
            } catch {
                guard !terminal, !Task.isCancelled else { break }
                draftsUnavailable = true
                await reportFailure(step: "rich draft", error: error)
                break
            }
        }
        richDraftFlush = nil
    }

    private func finishRichDrafts() async {
        pendingRichText = nil
        draftSpacing?.cancel()
        // Private drafts have no durable identity and cannot overwrite a final.
        if destination.chatId > 0 { richDraftFlush?.cancel() }
        // A group create must retain its result before final delivery chooses between editing it and posting. Never abandon/cancel that wire call.
        await richDraftFlush?.value
        richDraftFlush = nil
    }

    private func publishGroupPreview(_ text: String, packets: [TelegramInputRichMessage]) async throws {
        var delivery = groupDelivery ?? TelegramAssistantDeliveryState(reply: text)
        delivery.reply = text
        delivery.previewPending = true
        for (index, packet) in packets.enumerated() {
            guard !terminal else { break }
            if try await holdDelivery() { break }
            guard !terminal else { break }
            if let id = delivery.previewMessageIds?.dropFirst(index).first {
                try await editRichMessage(token, destination, id, packet)
                tracePreviewAccepted(characters: text.count)
            } else {
                delivery.outcomeUnknown = true
                groupDelivery = delivery
                try await persistDelivery(delivery)
                if terminal {
                    // Settlement started while the pre-dispatch row was saving; no create was attempted, so there is no unknown send.
                    delivery.outcomeUnknown = false
                    groupDelivery = delivery
                    try await persistDelivery(delivery)
                    break
                }
                let id: Int
                do { id = try await sendRichFinal(token, destination, packet) }
                catch {
                    if Self.isKnownNotDelivered(error) {
                        delivery.outcomeUnknown = false
                        groupDelivery = delivery
                        try await persistDelivery(delivery)
                    }
                    throw error
                }
                tracePreviewAccepted(characters: text.count)
                delivery.previewMessageIds = (delivery.previewMessageIds ?? []) + [id]
                delivery.outcomeUnknown = false
                // Keep the known ID even if persistence throws: this process can still edit it; the saved unknown boundary protects a restart.
                groupDelivery = delivery
                try await persistDelivery(delivery)
            }
        }
        groupDelivery = delivery
    }

    private func tracePreviewAccepted(characters: Int) {
        guard let turn else { return }
        TurnTraceBus.fire(TurnTraceEvent(turnId: turn.id, kind: "surface.previewAccepted",
            sessionId: turn.verifiedSessionID, surface: "telegram", payload: .object([
                "characters": .int(Int64(characters)),
                "previewKind": .string(destination.chatId > 0 ? "private_draft" : "group_message")
            ]), turn: turn))
    }

    func finalize(
        reply: String,
        imagePaths: [String] = [],
        savedDelivery: TelegramAssistantDeliveryState? = nil,
        resendUnknown: Bool = false
    ) async -> TelegramAssistantDeliveryOutcome {
        guard !terminal else {
            return .outcomeUnknown(reason: "assistant delivery was already terminal")
        }
        // Claim the final before the wire: reentrant finalize/abort cannot send it again while Telegram is accepting a chunk.
        terminal = true
        await finishRichDrafts()
        // A recovery containing only live prose is not a completed model reply.
        if savedDelivery?.previewPending == true { return .held }
        let safeReply = savedDelivery?.reply ?? TelegramRichMessageRenderer.sanitize(
            TelegramRichMessageRenderer.stripBoldMarkers(reply)
        )
        let messages = TelegramRichMessageRenderer.render(safeReply)
        guard !messages.isEmpty || !(savedDelivery?.imagePaths ?? imagePaths).isEmpty else {
            return .failed(reason: "reply contained no safe user-visible content")
        }
        var delivery = savedDelivery ?? groupDelivery ?? TelegramAssistantDeliveryState(reply: safeReply, imagePaths: imagePaths)
        if savedDelivery == nil {
            delivery.reply = safeReply
            delivery.imagePaths = imagePaths
            delivery.previewPending = false
        }
        guard delivery.reply == safeReply, delivery.confirmedMessageIds.count <= messages.count,
              (0...(delivery.imagePaths?.count ?? 0)).contains(delivery.confirmedImageCount ?? 0) else {
            return .failed(reason: "saved reply delivery is inconsistent; check the Mac error log")
        }
        do {
            try await persistDelivery(delivery)
            // Final words replace unfinished previews; unknown creation never authorizes another send, but recovery must retain the words.
            if !resendUnknown, let reason = delivery.rejectionReason { return .failed(reason: reason) }
            guard !delivery.outcomeUnknown || resendUnknown else {
                return .outcomeUnknown(reason: "use /retry resend to resend the unconfirmed part; it may arrive twice")
            }
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
            for index in delivery.confirmedMessageIds.count..<messages.count {
                let message = messages[index]
                // A crash after acceptance but before confirmation is uncertain, too. Persist that boundary before touching the wire.
                delivery.outcomeUnknown = true
                try await persistDelivery(delivery)
                if try await holdDelivery() {
                    delivery.outcomeUnknown = false
                    try await persistDelivery(delivery)
                    return .held
                }
                let messageId: Int
                do {
                    if let previewId = delivery.previewMessageIds?.dropFirst(index).first {
                        try await editRichMessage(token, destination, previewId, message)
                        messageId = previewId
                    } else {
                        messageId = try await sendRichFinal(token, destination, message)
                    }
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
            // Parsing an unfinished fence/table may have used more packets than the completed reply. Remove only those superseded preview packets.
            for id in (delivery.previewMessageIds ?? []).dropFirst(messages.count) {
                try await deleteMessage(token, destination.chatId, id)
            }
            delivery.previewMessageIds = nil
            try await persistDelivery(delivery)
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

    private func deliverGeneratedImages(_ delivery: inout TelegramAssistantDeliveryState,
        preparedImages: [Data]) async throws -> TelegramAssistantDeliveryOutcome {
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
        terminal = true
        await finishRichDrafts()
        // Private previews expire; group words remain beside the stopped work card.
    }

    private func reportFailure(step: String, error: Error) async {
        await recordFailure(
            "Telegram assistant \(step) failed for chat \(destination.chatId): "
                + (TurnPresentationReducer.sanitized(String(describing: error)) ?? "delivery failed")
        )
    }

    static func isKnownNotDelivered(_ error: Error) -> Bool {
        TelegramAPIFailure.isKnownNotDelivered(error)
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

    private static func draftId(for key: String) -> Int {
        let value = SHA256.hash(data: Data(key.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return max(1, Int(value & 0x7FFF_FFFF))
    }
}
