import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ChatTurnRuntime

// Blueprint: | `TelegramTurnProgressCardDriver.swift` | `TelegramTurnProgressCardDriver`: persist terminal identity before release |

struct TelegramTurnProgressCardDriverSnapshot: Sendable, Equatable {
    let state: TelegramTurnPresentationState
    let messageId: Int?
}

/// One event-driven card writer; the ledger owns terminal delivery repair.
actor TelegramTurnProgressCardDriver {
    typealias SendCard = @Sendable (
        _ token: String,
        _ destination: TelegramDestination,
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
    typealias DeleteCard = @Sendable (_ token: String, _ chatId: Int, _ messageId: Int) async throws -> Void
    typealias FailureRecorder = @Sendable (_ redactedError: String) async -> Void
    typealias PersistCard = @Sendable (_ record: TelegramPersistedTurnCard) async throws -> Void
    typealias RemovePersistedCard = @Sendable (_ turnId: UUID) async throws -> Void

    private let token: String
    private let destination: TelegramDestination
    private let turnId: UUID
    private let face: TelegramProgressFace
    private let sendCard: SendCard
    private let editCard: EditCard
    private let deleteCard: DeleteCard
    private let recordFailure: FailureRecorder
    private let persistCard: PersistCard
    private let removePersistedCard: RemovePersistedCard
    private var closed = false

    private var state: TelegramTurnPresentationState
    private var replyTextSettled = false
    private var accumulatedUTF16Length = 0
    private var messageId: Int?
    private var initialSendAttempted = false
    private var transportFailed = false
    private var lastRenderedText: String?
    private var progressFlushTask: Task<Void, Never>?
    private var progressFlushRequested = false
    private var untrackedCardSettlementRequested = false
    private var terminalLedgerRowRemoved = false
    private var detailsVisible = false
    private var terminalProjection: Task<String, Never>?
    /// Nil while terminal identity is unsettled; false records persistence failure.
    private var terminalIdentityPersisted: Bool?
    private final class TerminalWait {
        let done = ScopedWaiter()
        var phase: TelegramTurnPresentationPhase?
    }
    private var terminalWaiters: [UUID: TerminalWait] = [:]

    init(
        token: String,
        face: TelegramProgressFace,
        destination: TelegramDestination,
        turnId: UUID,
        sendCard: @escaping SendCard,
        editCard: @escaping EditCard,
        deleteCard: @escaping DeleteCard,
        recordFailure: @escaping FailureRecorder = { _ in },
        persistCard: @escaping PersistCard = { _ in },
        removePersistedCard: @escaping RemovePersistedCard = { _ in }
    ) {
        self.token = token
        self.face = face
        self.destination = destination
        self.turnId = turnId
        self.sendCard = sendCard
        self.editCard = editCard
        self.deleteCard = deleteCard
        self.recordFailure = recordFailure
        self.persistCard = persistCard
        self.removePersistedCard = removePersistedCard
        self.state = TurnPresentationReducer.initialState(at: Date())
    }

    /// Sends the acknowledged card exactly once. A failed first send is final for this card: later progress never creates a replacement message.
    func start() async {
        guard !closed, !initialSendAttempted else { return }
        initialSendAttempted = true
        let now = Date()
        let rendered = await renderedText(at: now)
        do {
            try Task.checkCancellation()
            let sentMessageId = try await sendCard(
                token,
                destination,
                rendered,
                TelegramTurnControlCallback.replyMarkup(turnId: turnId)
            )
            messageId = sentMessageId
            lastRenderedText = rendered
            guard await persistIdentity(at: now, terminalText: nil) else {
                transportFailed = true
                untrackedCardSettlementRequested = true
                scheduleProgressFlush()
                await progressFlushTask?.value
                return
            }
        } catch {
            transportFailed = true
            await reportFailure(step: "initial send", error: error)
        }
    }

    func record(progress event: TurnStreamEvent) {
        guard !closed, !state.isTerminal else { return }
        if case .replyTextSettled(let settled) = event {
            guard replyTextSettled != settled else { return }
            replyTextSettled = settled
            if !settled {
                state = TurnPresentationReducer.reduce(
                    state, lifecycle: .working(action: nil), at: Date()
                )
            }
            scheduleProgressFlush()
            return
        }
        replyTextSettled = false
        if case .delta(let chunk) = event {
            let (length, overflow) = accumulatedUTF16Length.addingReportingOverflow(chunk.utf16.count)
            if !overflow { accumulatedUTF16Length = length }
        }
        let next = TelegramTurnPresentationReducer.reduce(
            state,
            progress: event,
            accumulatedUTF16Length: accumulatedUTF16Length,
            at: Date()
        )
        guard next != state else { return }
        state = next
        guard !transportFailed else { return }
        scheduleProgressFlush()
    }

    private func scheduleProgressFlush() {
        progressFlushRequested = true
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            await self?.flushRecordedProgress()
        }
    }

    private func flushRecordedProgress() async {
        while progressFlushRequested {
            progressFlushRequested = false
            if untrackedCardSettlementRequested {
                untrackedCardSettlementRequested = false
                await flushUntrackedCard()
                continue
            }
            guard !transportFailed else { break }
            if !state.isTerminal { _ = await persistIdentity(at: Date(), terminalText: nil) }
            guard !state.isTerminal || terminalIdentityPersisted == true else { break }
            await flush()
        }
        progressFlushTask = nil
    }

    func transition(_ event: TelegramTurnPresentationLifecycleEvent) async {
        guard !closed, !state.isTerminal else { return }
        replyTextSettled = false
        let next = TurnPresentationReducer.reduce(
            state,
            lifecycle: event,
            at: Date()
        )
        guard next != state else { return }
        state = next
        if state.isTerminal {
            detailsVisible = false
            // Let an edit already on the wire finish; terminal repair belongs to the ledger after this turn releases its driver.
            let terminal = terminalTextTask(at: Date())
            let now = Date()
            let terminalText = await settle { await terminal.value }
            guard await persistIdentity(at: now, terminalText: terminalText) else {
                // Preserve active identity until terminal evidence is durable so restart can repair uncertainty.
                transportFailed = true
                resolveTerminalWaiters(nil)
                untrackedCardSettlementRequested = true
                scheduleProgressFlush()
                await progressFlushTask?.value
                return
            }
            resolveTerminalWaiters(state.phase)
            scheduleProgressFlush()
        } else {
            guard !transportFailed else { return }
            scheduleProgressFlush()
        }
        await progressFlushTask?.value
    }

    func snapshot() -> TelegramTurnProgressCardDriverSnapshot {
        TelegramTurnProgressCardDriverSnapshot(
            state: state,
            messageId: messageId
        )
    }

    func showStatus() async {
        guard !closed, !state.isTerminal else { return }
        detailsVisible = false
        scheduleProgressFlush()
        await progressFlushTask?.value
    }

    func showDetails() async {
        guard !closed, !state.isTerminal else { return }
        detailsVisible = true
        scheduleProgressFlush()
        await progressFlushTask?.value
    }

    func waitForTerminal() async -> TelegramTurnPresentationPhase? {
        if let terminalIdentityPersisted { return terminalIdentityPersisted ? state.phase : nil }
        guard !closed, !Task.isCancelled else { return nil }
        let id = UUID(), response = TerminalWait()
        terminalWaiters[id] = response
        await response.done.park()
        terminalWaiters.removeValue(forKey: id)
        return response.phase
    }

    /// The turn releases its card only after its remaining wire/projection work settles. Closing the derived face also drains version refreshes.
    func close() async {
        closed = true
        if terminalIdentityPersisted == nil { resolveTerminalWaiters(nil) }
        let pending = [progressFlushTask].compactMap { $0 }
        if !state.isTerminal {
            progressFlushRequested = false
            for task in pending { task.cancel() }
        }
        let face = self.face
        let terminal = terminalProjection
        await settle {
            for task in pending { await task.value }
            if let terminal { _ = await terminal.value }
            await face.close()
        }
    }

    private func flush() async {
        guard !transportFailed, let messageId else { return }
        let now = Date()
        guard !transportFailed, !state.isTerminal || terminalIdentityPersisted == true else { return }
        let renderedState = state
        let renderedReplySettled = replyTextSettled
        // Capture terminal identity with rendered text: state may become terminal while an earlier edit is in flight.
        let renderedIsTerminal = renderedState.isTerminal
        let rendered = await renderedText(at: now)
        guard rendered != lastRenderedText
                || (renderedIsTerminal && renderedState.phase == .completed) else {
            await removeTerminalLedgerRow(ifSentTerminal: renderedIsTerminal)
            return
        }

        let markup = renderedIsTerminal || renderedReplySettled
            ? TelegramTurnControlCallback.clearedReplyMarkup
            : TelegramTurnControlCallback.replyMarkup(turnId: turnId)

        let deleting = renderedIsTerminal && renderedState.phase == .completed
        do {
            if deleting {
                do {
                    try await deleteCard(token, destination.chatId, messageId)
                } catch let failure as TelegramAPIFailure
                    where failure.telegramDescription?.localizedCaseInsensitiveContains("message to delete not found") == true {}
            } else {
                try await editCard(token, destination.chatId, messageId, rendered, markup)
            }
            lastRenderedText = rendered
        } catch {
            transportFailed = true
            await reportFailure(step: deleting ? "delete" : "edit", error: error)
            return
        }
        await removeTerminalLedgerRow(ifSentTerminal: renderedIsTerminal)
    }

    /// Keep restart-repair evidence until the terminal card update succeeds.
    private func removeTerminalLedgerRow(ifSentTerminal sentTerminal: Bool) async {
        guard sentTerminal,
              !terminalLedgerRowRemoved,
              !transportFailed,
              messageId != nil else { return }
        do {
            try await removePersistedCard(turnId)
            terminalLedgerRowRemoved = true
        } catch {
            await reportFailure(step: "terminal persistence cleanup", error: error)
        }
    }

    private func renderedText(at instant: Date) async -> String {
        if state.isTerminal {
            let terminal = terminalTextTask(at: instant)
            return await settle { await terminal.value }
        }
        let input = TelegramProgressFace.input(state, at: instant, replyTextSettled: replyTextSettled)
        let row = detailsVisible ? "details" : "summary"
        return await face.text(input: input, row: row)
    }

    private func terminalTextTask(at instant: Date) -> Task<String, Never> {
        if let terminalProjection { return terminalProjection }
        let face = self.face
        let input = TelegramProgressFace.input(state, at: instant, replyTextSettled: false)
        let task = Task { await settle { await face.text(input: input, row: "summary") } }
        terminalProjection = task
        return task
    }

    private func resolveTerminalWaiters(_ phase: TelegramTurnPresentationPhase?) {
        terminalIdentityPersisted = phase != nil
        let waiting = terminalWaiters.values
        terminalWaiters.removeAll()
        for response in waiting {
            response.phase = phase
            response.done.resume()
        }
    }

    private func reportFailure(step: String, error: Error) async {
        let safe = TurnTraceRedactor.redactText(String(describing: error))
        let detail = "Telegram turn card \(step) failed for chat \(destination.chatId): \(safe)"
        FileHandle.standardError.write(Data("\(detail)\n".utf8))
        await recordFailure(detail)
    }

    private func persistIdentity(at instant: Date, terminalText: String?) async -> Bool {
        guard let messageId else { return true }
        let safeTerminalText = terminalText.flatMap {
            TurnPresentationReducer.sanitized($0)
        }
        do {
            try await persistCard(TelegramPersistedTurnCard(
                turnId: turnId,
                chatId: destination.chatId,
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

    private func flushUntrackedCard() async {
        guard let messageId else { return }
        let notice = """
        Outcome unknown · status persistence unavailable
        Reply work may continue, but this card can no longer report it durably.
        """
        do {
            try await editCard(
                token,
                destination.chatId,
                messageId,
                notice,
                TelegramTurnControlCallback.clearedReplyMarkup
            )
            lastRenderedText = notice
        } catch {
            await reportFailure(step: "persistence failure notice", error: error)
        }
    }
}
