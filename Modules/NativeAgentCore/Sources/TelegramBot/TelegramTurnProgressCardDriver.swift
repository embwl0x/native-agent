import Foundation
import NativeAgentCore
import PersistenceCore

struct TelegramTurnProgressCardDriverSnapshot: Sendable, Equatable {
    let state: TelegramTurnPresentationState
    let messageId: Int?
    let initialSendAttempted: Bool
    let transportFailed: Bool
    let heartbeatRunning: Bool
    let detailsVisible: Bool
}

/// Owns the single ordinary Telegram message used to present one accepted
/// turn's lifecycle. Card transport is deliberately best-effort: failures are
/// recorded and presentation stops without affecting the assistant reply.
actor TelegramTurnProgressCardDriver {
    static let defaultMinimumEditInterval: TimeInterval = 5
    static let defaultHeartbeatNanoseconds: UInt64 = 7_000_000_000

    typealias Clock = @Sendable () -> Date
    typealias Sleeper = @Sendable (_ nanoseconds: UInt64) async throws -> Void
    typealias SendCard = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ text: String,
        _ replyMarkup: JSONValue
    ) async throws -> Int
    typealias EditCard = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ messageId: Int,
        _ text: String,
        _ replyMarkup: JSONValue
    ) async throws -> Void
    typealias FailureRecorder = @Sendable (_ redactedError: String) async -> Void
    typealias PersistCard = @Sendable (_ record: TelegramPersistedTurnCard) async throws -> Void
    typealias RemovePersistedCard = @Sendable (_ turnId: UUID) async throws -> Void

    private let token: String
    private let chatId: Int
    private let turnId: UUID
    private let minimumEditInterval: TimeInterval
    private let heartbeatNanoseconds: UInt64
    private let stalledAfter: TimeInterval
    private let clock: Clock
    private let sleeper: Sleeper
    private let sendCard: SendCard
    private let editCard: EditCard
    private let recordFailure: FailureRecorder
    private let persistCard: PersistCard
    private let removePersistedCard: RemovePersistedCard

    private var state: TelegramTurnPresentationState
    private var messageId: Int?
    private var initialSendAttempted = false
    private var transportFailed = false
    private var lastRenderedText: String?
    private var lastEditAt: Date?
    private var heartbeatTask: Task<Void, Never>?
    private var editInFlight = false
    private var pendingFlush = false
    private var pendingForcedFlush = false
    private var detailsVisible = false
    private var terminalWaiters: [
        UUID: CheckedContinuation<TelegramTurnPresentationPhase?, Never>
    ] = [:]

    init(
        token: String,
        chatId: Int,
        turnId: UUID,
        minimumEditInterval: TimeInterval = defaultMinimumEditInterval,
        heartbeatNanoseconds: UInt64 = defaultHeartbeatNanoseconds,
        stalledAfter: TimeInterval = TelegramTurnPresentationRenderer.defaultStalledAfter,
        clock: @escaping Clock = Date.init,
        sleeper: @escaping Sleeper,
        sendCard: @escaping SendCard,
        editCard: @escaping EditCard,
        recordFailure: @escaping FailureRecorder = { _ in },
        persistCard: @escaping PersistCard = { _ in },
        removePersistedCard: @escaping RemovePersistedCard = { _ in }
    ) {
        self.token = token
        self.chatId = chatId
        self.turnId = turnId
        self.minimumEditInterval = max(0, minimumEditInterval)
        self.heartbeatNanoseconds = heartbeatNanoseconds
        self.stalledAfter = max(0, stalledAfter)
        self.clock = clock
        self.sleeper = sleeper
        self.sendCard = sendCard
        self.editCard = editCard
        self.recordFailure = recordFailure
        self.persistCard = persistCard
        self.removePersistedCard = removePersistedCard
        self.state = TelegramTurnPresentationReducer.initialState(at: clock())
    }

    /// Sends the acknowledged card exactly once. A failed first send is final
    /// for this card: later progress never creates a replacement message.
    func start() async {
        guard !initialSendAttempted else { return }
        initialSendAttempted = true
        let now = clock()
        let rendered = renderedText(at: now)
        do {
            let sentMessageId = try await sendCard(
                token,
                chatId,
                rendered,
                TelegramTurnControlCallback.replyMarkup(turnId: turnId)
            )
            messageId = sentMessageId
            lastRenderedText = rendered
            lastEditAt = now
            guard await persistIdentity(at: now, terminalText: nil) else {
                transportFailed = true
                await settleUntrackedCard()
                return
            }
            startHeartbeatIfNeeded()
        } catch {
            transportFailed = true
            await reportFailure(step: "initial send", error: error)
        }
    }

    func record(progress event: TelegramChatProgressEvent) async {
        guard !state.isTerminal else { return }
        let next = TelegramTurnPresentationReducer.reduce(
            state,
            progress: event,
            at: clock()
        )
        guard next != state else { return }
        state = next
        guard !transportFailed else { return }
        _ = await persistIdentity(at: clock(), terminalText: nil)
        await flushIfDue(force: false)
    }

    func transition(_ event: TelegramTurnPresentationLifecycleEvent) async {
        guard !state.isTerminal else { return }
        let next = TelegramTurnPresentationReducer.reduce(
            state,
            lifecycle: event,
            at: clock()
        )
        guard next != state else { return }
        state = next
        if state.isTerminal {
            detailsVisible = false
            stopHeartbeat()
            resolveTerminalWaiters(state.phase)
            let now = clock()
            let terminalText = renderedText(at: now)
            guard await persistIdentity(at: now, terminalText: terminalText) else {
                // Without durable terminal evidence a restart must be allowed
                // to settle the old active identity as outcome-unknown. Do not
                // paint an unrepairable terminal card over that evidence.
                transportFailed = true
                await settleUntrackedCard()
                return
            }
            await flushIfDue(force: true, bypassThrottle: true)
            if !transportFailed, messageId != nil {
                do {
                    try await removePersistedCard(turnId)
                } catch {
                    await reportFailure(step: "terminal persistence cleanup", error: error)
                }
            }
        } else {
            guard !transportFailed else { return }
            _ = await persistIdentity(at: clock(), terminalText: nil)
            await flushIfDue(force: false)
        }
    }

    /// Explicit seam used by the automatic heartbeat and deterministic tests.
    /// It refreshes elapsed/stall presentation without manufacturing movement.
    @discardableResult
    func heartbeat() async -> Bool {
        guard !state.isTerminal, !transportFailed, messageId != nil else {
            return false
        }
        await flushIfDue(force: false)
        return !state.isTerminal && !transportFailed
    }

    func snapshot() -> TelegramTurnProgressCardDriverSnapshot {
        TelegramTurnProgressCardDriverSnapshot(
            state: state,
            messageId: messageId,
            initialSendAttempted: initialSendAttempted,
            transportFailed: transportFailed,
            heartbeatRunning: heartbeatTask != nil,
            detailsVisible: detailsVisible
        )
    }

    func showStatus() async {
        guard !state.isTerminal else { return }
        detailsVisible = false
        await flushIfDue(force: true)
    }

    func showDetails() async {
        guard !state.isTerminal else { return }
        detailsVisible = true
        await flushIfDue(force: true)
    }

    func waitForTerminal() async -> TelegramTurnPresentationPhase? {
        if state.isTerminal { return state.phase }
        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                terminalWaiters[waiterId] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelTerminalWaiter(waiterId)
            }
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatNanoseconds > 0, heartbeatTask == nil, !state.isTerminal else {
            return
        }
        let delay = heartbeatNanoseconds
        let sleeper = self.sleeper
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                guard await self.heartbeat() else { return }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func flushIfDue(force: Bool, bypassThrottle: Bool = false) async {
        guard !transportFailed, let messageId else { return }
        if editInFlight {
            pendingFlush = true
            pendingForcedFlush = pendingForcedFlush || force
            return
        }
        var now = clock()
        if !force, let lastEditAt,
           now.timeIntervalSince(lastEditAt) < minimumEditInterval {
            return
        }
        // Claim the edit lane before any throttle suspension. Actor methods
        // are reentrant across `await`; without this, a progress event could
        // start a second edit while a control refresh was sleeping.
        editInFlight = true
        if force, !bypassThrottle, let lastEditAt {
            let remaining = minimumEditInterval - now.timeIntervalSince(lastEditAt)
            if remaining > 0 {
                let nanoseconds = UInt64(
                    min(remaining, minimumEditInterval) * 1_000_000_000
                )
                try? await sleeper(nanoseconds)
                now = clock()
            }
        }
        let rendered = renderedText(at: now)
        guard rendered != lastRenderedText else {
            editInFlight = false
            pendingFlush = false
            pendingForcedFlush = false
            return
        }

        let markup = state.isTerminal
            ? TelegramTurnControlCallback.clearedReplyMarkup
            : TelegramTurnControlCallback.replyMarkup(turnId: turnId)

        do {
            try await editCard(token, chatId, messageId, rendered, markup)
            lastRenderedText = rendered
            lastEditAt = now
        } catch {
            // Editing an existing message is idempotent, so one delayed
            // transport retry is safe. A semantic Telegram rejection is not a
            // transient transport miss and is left unreplayed.
            guard Self.shouldRetryEdit(after: error) else {
                transportFailed = true
                stopHeartbeat()
                editInFlight = false
                await reportFailure(step: "edit", error: error)
                return
            }
            do {
                try await sleeper(1_000_000_000)
            } catch {
                transportFailed = true
                stopHeartbeat()
                editInFlight = false
                await reportFailure(step: "edit", error: error)
                return
            }
            do {
                try await editCard(token, chatId, messageId, rendered, markup)
                lastRenderedText = rendered
                lastEditAt = clock()
            } catch {
                transportFailed = true
                stopHeartbeat()
                editInFlight = false
                await reportFailure(step: "edit retry", error: error)
                return
            }
        }
        editInFlight = false
        guard pendingFlush else { return }
        let forcePending = pendingForcedFlush || state.isTerminal
        pendingFlush = false
        pendingForcedFlush = false
        await flushIfDue(force: forcePending)
    }

    private func renderedText(at instant: Date) -> String {
        if detailsVisible {
            return TelegramTurnPresentationRenderer.renderDetails(
                state,
                at: instant,
                stalledAfter: stalledAfter
            )
        }
        return TelegramTurnPresentationRenderer.render(
            state,
            at: instant,
            stalledAfter: stalledAfter
        )
    }

    private func resolveTerminalWaiters(_ phase: TelegramTurnPresentationPhase) {
        let waiters = terminalWaiters.values
        terminalWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: phase) }
    }

    private func cancelTerminalWaiter(_ waiterId: UUID) {
        guard let waiter = terminalWaiters.removeValue(forKey: waiterId) else {
            return
        }
        waiter.resume(returning: nil)
    }

    private static func shouldRetryEdit(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is TelegramAPIFailure { return false }
        return true
    }

    private func reportFailure(step: String, error: Error) async {
        let safe = TelegramPollLoop._tgRedactToken(
            TurnTraceRedactor.redactText(String(describing: error))
        )
        let detail = "Telegram turn card \(step) failed for chat \(chatId): \(safe)"
        FileHandle.standardError.write(Data("\(detail)\n".utf8))
        await recordFailure(detail)
    }

    private func persistIdentity(at instant: Date, terminalText: String?) async -> Bool {
        guard let messageId else { return true }
        let safeTerminalText = terminalText.flatMap {
            TelegramTurnPresentationReducer.sanitized($0)
        }
        do {
            try await persistCard(TelegramPersistedTurnCard(
                turnId: turnId,
                chatId: chatId,
                messageId: messageId,
                phase: state.phase,
                updatedAt: instant.timeIntervalSince1970,
                terminalText: safeTerminalText
            ))
            return true
        } catch {
            await reportFailure(step: "persistence", error: error)
            return false
        }
    }

    private func settleUntrackedCard() async {
        guard let messageId else { return }
        let notice = """
        Outcome unknown · status persistence unavailable
        Reply work may continue, but this card can no longer report it durably.
        """
        do {
            try await editCard(
                token,
                chatId,
                messageId,
                notice,
                TelegramTurnControlCallback.clearedReplyMarkup
            )
            lastRenderedText = notice
            lastEditAt = clock()
        } catch {
            await reportFailure(step: "persistence fallback edit", error: error)
        }
    }
}

enum TelegramTurnReplyDeliveryFailure {
    static func lifecycleEvent(for error: Error) -> TelegramTurnPresentationLifecycleEvent {
        let safe = TelegramTurnPresentationReducer.sanitized(String(describing: error))
            ?? "delivery failed"
        if isAmbiguous(error) {
            return .outcomeUnknown(reason: "Reply delivery could not be confirmed: \(safe)")
        }
        return .failed(reason: "Reply delivery failed: \(safe)")
    }

    static func isAmbiguous(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == URLError.timedOut.rawValue
                || nsError.code == URLError.networkConnectionLost.rawValue
        }
        let lower = String(describing: error).lowercased()
        return lower.contains("timed out")
            || lower.contains("network connection was lost")
            || lower.contains("connection reset")
    }
}
