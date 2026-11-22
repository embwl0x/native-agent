import Foundation
import NativeAgentCore

// Blueprint: | `TelegramTurnCoordinator.swift` | `TelegramTurns`: retain ownership through receipt and ingress settlement |

public struct TelegramLastUserMessage: Sendable, Equatable {
    public let chatId: Int
    public let text: String
    public let message: TelegramMessage?
    public let sessionId: String?

    public init(chatId: Int, text: String, message: TelegramMessage? = nil, sessionId: String? = nil) {
        self.chatId = chatId
        self.text = text
        self.message = message
        self.sessionId = sessionId
    }
}

public struct TelegramTurnSnapshot: Sendable, Equatable {
    public let isRunning: Bool
    public let promptPreview: String?

    public init(isRunning: Bool, promptPreview: String?) {
        self.isRunning = isRunning
        self.promptPreview = promptPreview
    }
}

public actor TelegramTurns {
    private var approvalWaiters: [Int: ScopedWaiter] = [:]
    private var approvalResults: [Int: Result<Void, Error>] = [:]

    private func completeApproval(_ id: Int, _ result: Result<Void, Error>) {
        guard let done = approvalWaiters[id], approvalResults[id] == nil else { return }
        approvalResults[id] = result
        done.resume()
    }


    public static let shared = TelegramTurns()

    private struct ActiveTurn: Sendable {
        let id: UUID
        let task: Task<TelegramTurnProgressCardDriver?, Never>
        let promptPreview: String
        var card: TelegramTurnProgressCardDriver?
        var continuationID: Int? = nil
        var stopRequested = false
        var stopConfirmed = false
        var stopSettlement: Task<StopOutcome, Never>?
    }

    /// An approval continuation waiting for its destination's turn to end.
    private struct QueuedTurn: Sendable {
        let updateId: Int
        let text: String
        let operation: @Sendable (_ turnId: UUID) async -> Void
        let onDiscard: @Sendable () -> Void
    }

    private var activeTurns: [TelegramDestination: ActiveTurn] = [:]
    private var commandTasks: [UUID: Task<TelegramTurnProgressCardDriver?, Never>] = [:]
    private var commandDestinations: [UUID: TelegramDestination] = [:]
    private enum WaitingTurnState: Equatable { case admitted, stopRequested }
    private var waitingTurns: [UUID: WaitingTurnState] = [:]
    /// Work cards of arrivals that wait in the agent's turn admission while their destination is busy, by turn id.
    private var commandCards: [UUID: TelegramTurnProgressCardDriver] = [:]
    private var isShuttingDown = false
    private var queuedTurns: [TelegramDestination: [QueuedTurn]] = [:]
    private var pausedQueueDestinations: Set<TelegramDestination> = []
    private var lastMessages: [TelegramDestination: TelegramLastUserMessage] = [:]
    private var claimedCallbackIds: Set<String> = []
    private var callbackClaimOrder: [String] = []
    private let callbackClaimLimit = 512
    private var nextInternalUpdateID = Int.min
    /// Live in-process update IDs exclude their `.processing` claims from orphan recovery.
    private var inFlightUpdateIds: Set<Int> = []

    public init() {}

    public func beginUpdateProcessing(_ updateId: Int) {
        inFlightUpdateIds.insert(updateId)
    }

    func claimUpdateProcessing(_ updateId: Int) -> Bool {
        inFlightUpdateIds.insert(updateId).inserted
    }

    public func endUpdateProcessing(_ updateId: Int) {
        inFlightUpdateIds.remove(updateId)
    }

    public func isUpdateProcessing(_ updateId: Int) -> Bool {
        inFlightUpdateIds.contains(updateId)
    }

    public func recordLastUserMessage(destination: TelegramDestination, text: String, message: TelegramMessage? = nil,
                                      sessionId: String? = nil, updatingCurrent: Bool = false) {
        if updatingCurrent, lastMessages[destination]?.message != message
            || lastMessages[destination]?.sessionId != sessionId { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastMessages[destination] = TelegramLastUserMessage(
            chatId: destination.chatId,
            text: trimmed,
            message: message,
            sessionId: sessionId
        )
    }

    public func lastUserMessage(destination: TelegramDestination) -> TelegramLastUserMessage? {
        lastMessages[destination]
    }

    /// Bind callbacks to an immutable turn ID; completion releases that exact generation without a separate cleanup watcher.
    public func startTrackedTurn(
        id: UUID = UUID(),
        destination: TelegramDestination,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void
    ) -> Bool {
        guard !isShuttingDown, !Task.isCancelled else { return false }
        if activeTurns[destination] != nil {
            // A busy destination's arrival starts now and waits in the agent's turn admission, where its turn in progress may read it.
            commandDestinations[id] = destination
            waitingTurns[id] = .admitted
            commandTasks[id] = Task(priority: priority) {
                await operation(id)
                let card = commandCards[id]
                await card?.close()
                commandCards[id] = nil
                commandTasks[id] = nil
                commandDestinations[id] = nil
                waitingTurns[id] = nil
                return card
            }
            return true
        }
        pausedQueueDestinations.remove(destination)
        launchTurn(
            id: id,
            destination: destination,
            text: text,
            priority: priority,
            operation: operation
        )
        return true
    }

    private func launchTurn(
        id: UUID = UUID(),
        destination: TelegramDestination,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void,
        continuationID: Int? = nil
    ) {
        let task = Task(priority: priority) { [weak self] in
            await operation(id)
            return await self?.finishTurn(destination: destination, turnId: id)
        }
        activeTurns[destination] = ActiveTurn(
            id: id,
            task: task,
            promptPreview: Self.preview(text),
            card: nil,
            continuationID: continuationID
        )
    }

    /// Await an internal follow-up after its destination's turn ends. The slot includes delivery; shutdown/cancellation settles waiters.
    public func runApprovalContinuation(
        destination: TelegramDestination,
        text: String,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        let updateID = nextInternalUpdateID
        let (next, overflow) = updateID.addingReportingOverflow(1)
        guard !overflow else { throw TelegramBotError.underlying("Telegram approval continuation IDs are exhausted") }
        nextInternalUpdateID = next
        let done = ScopedWaiter()
        approvalWaiters[updateID] = done
        defer { approvalWaiters[updateID] = nil; approvalResults[updateID] = nil }
        try await withTaskCancellationHandler {
            let queued = QueuedTurn(
                updateId: updateID, text: text,
                operation: { _ in
                    do {
                        try Task.checkCancellation()
                        try await operation()
                        await self.completeApproval(updateID, .success(()))
                    } catch {
                        await self.completeApproval(updateID, .failure(error))
                    }
                },
                onDiscard: { Task { await self.completeApproval(updateID, .failure(CancellationError())) } }
            )
            queuedTurns[destination, default: []].append(queued)
            startNextQueuedTurn(destination: destination)
            await Task { await done.park() }.value
            guard let result = approvalResults[updateID] else {
                throw TelegramBotError.underlying("Telegram approval continuation ended without a settlement record")
            }
            try result.get()
        } onCancel: {
            Task { await self.cancelApprovalContinuation(destination: destination, updateID: updateID) }
        }
    }

    private func cancelApprovalContinuation(destination: TelegramDestination, updateID: Int) {
        if let index = queuedTurns[destination]?.firstIndex(where: { $0.updateId == updateID }),
           let queued = queuedTurns[destination]?.remove(at: index) {
            if queuedTurns[destination]?.isEmpty == true { queuedTurns[destination] = nil }
            queued.onDiscard()
        } else if let active = activeTurns[destination], active.continuationID == updateID {
            active.task.cancel()
        }
    }

    @discardableResult
    func attachCard(
        _ card: TelegramTurnProgressCardDriver,
        destination: TelegramDestination,
        turnId: UUID
    ) -> Bool {
        if commandDestinations[turnId] == destination {
            commandCards[turnId] = card
            return true
        }
        guard var active = activeTurns[destination], active.id == turnId else {
            return false
        }
        active.card = card
        activeTurns[destination] = active
        return true
    }

    func activeCard(destination: TelegramDestination) -> TelegramTurnProgressCardDriver? {
        activeTurns[destination]?.card
    }

    func requestControlHandoff(destination: TelegramDestination) -> (Task<StopOutcome, Never>, TelegramTurnProgressCardDriver?) {
        pausedQueueDestinations.insert(destination)
        let active = activeTurns[destination]
        let waiting = waitingTurns.keys.filter { commandDestinations[$0] == destination }
        let tasks = [active?.task].compactMap { $0 } + waiting.compactMap { commandTasks[$0] }
        let card = active?.card ?? waiting.compactMap { commandCards[$0] }.first
        for id in waiting { cancelCommand(id) }
        _ = requestActiveStop(destination: destination, turnId: nil)
        let settlement = Task<StopOutcome, Never> {
            var outcome: StopOutcome = .notRunning
            for task in tasks {
                let card = await task.value
                if await card?.waitForTerminal() != .canceled { outcome = .outcomeUnknown }
                else if outcome == .notRunning { outcome = .confirmed }
            }
            return outcome
        }
        return (settlement, card)
    }

    func controlCard(destination: TelegramDestination, turnId: UUID) -> TelegramTurnProgressCardDriver? {
        if commandDestinations[turnId] == destination { return commandCards[turnId] }
        guard let active = activeTurns[destination], active.id == turnId else {
            return nil
        }
        return active.card
    }

    @discardableResult
    func claimCallback(_ callbackId: String) -> Bool {
        let bounded = String(callbackId.prefix(160))
        guard !bounded.isEmpty, !claimedCallbackIds.contains(bounded) else {
            return false
        }
        claimedCallbackIds.insert(bounded)
        callbackClaimOrder.append(bounded)
        if callbackClaimOrder.count > callbackClaimLimit {
            let overflow = callbackClaimOrder.count - callbackClaimLimit
            let evicted = callbackClaimOrder.prefix(overflow)
            claimedCallbackIds.subtract(evicted)
            callbackClaimOrder.removeFirst(overflow)
        }
        return true
    }

    private func finishTurn(destination: TelegramDestination, turnId: UUID) async -> TelegramTurnProgressCardDriver? {
        guard activeTurns[destination]?.id == turnId else { return nil }
        let card = activeTurns[destination]?.card
        await card?.close()
        if let settlement = activeTurns[destination]?.stopSettlement { _ = await settlement.value }
        guard activeTurns[destination]?.id == turnId else { return card }
        activeTurns[destination] = nil
        startNextQueuedTurn(destination: destination)
        return card
    }

    private func startNextQueuedTurn(destination: TelegramDestination) {
        guard !isShuttingDown, activeTurns[destination] == nil,
              !pausedQueueDestinations.contains(destination),
              var queue = queuedTurns[destination],
              !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queuedTurns[destination] = queue.isEmpty ? nil : queue
        launchTurn(
            destination: destination,
            text: next.text,
            priority: .userInitiated,
            operation: next.operation,
            continuationID: next.updateId
        )
    }

    enum StopOutcome: Sendable, Equatable {
        case notRunning
        case confirmed
        case outcomeUnknown
    }

    func shutdownInterruptedTurn(destination: TelegramDestination, turnId: UUID) -> Bool {
        if isShuttingDown, commandDestinations[turnId] == destination { return waitingTurns[turnId] != .stopRequested }
        guard isShuttingDown, let active = activeTurns[destination], active.id == turnId else { return false }
        return !active.stopRequested
    }

    func requestStop(
        destination: TelegramDestination,
        turnId: UUID? = nil
    ) -> Task<StopOutcome, Never> {
        // A turn's own Stop reaches it while it waits in admission; a destination Stop reaches every one.
        let commands = commandDestinations.compactMap {
            $0.value == destination && (turnId == nil || $0.key == turnId) ? $0.key : nil
        }
        for id in commands { cancelCommand(id) }
        guard let stop = requestActiveStop(destination: destination, turnId: turnId) else {
            return Task { commands.isEmpty ? .notRunning : .outcomeUnknown }
        }
        return Task {
            let outcome = await stop.value
            return commands.contains(where: { commandTasks[$0] != nil }) ? .outcomeUnknown : outcome
        }
    }

    private func cancelCommand(_ id: UUID) {
        if waitingTurns[id] != nil { waitingTurns[id] = .stopRequested }
        commandTasks[id]?.cancel()
    }

    private func requestActiveStop(destination: TelegramDestination, turnId: UUID?) -> Task<StopOutcome, Never>? {
        guard let active = activeTurns[destination],
              turnId == nil || active.id == turnId else { return nil }
        activeTurns[destination]?.stopRequested = true
        active.task.cancel()
        if let settlement = active.stopSettlement { return settlement }
        let settlement = Task<StopOutcome, Never> {
            guard let card = active.card else { return .outcomeUnknown }
            await card.transition(.blocked(reason: "Stop requested; waiting on turn settlement"))
            if let phase = await card.waitForTerminal() {
                guard phase == .canceled else { return .outcomeUnknown }
                // Stopped presentation does not release ownership. Quit and idle waiters still join the turn's receipt/ingress tail.
                if activeTurns[destination]?.id == active.id {
                    activeTurns[destination]?.stopConfirmed = true
                }
                return .confirmed
            }
            await card.transition(
                .outcomeUnknown(reason: "Stop requested, but cancellation was not confirmed")
            )
            return .outcomeUnknown
        }
        activeTurns[destination]?.stopSettlement = settlement
        return settlement
    }

    public func waitUntilAllIdle() async {
        while let task = activeTurns.values.first?.task {
            _ = await task.value
        }
    }

    /// Waiting arrivals' cards count as live, so restart repair never marks them interrupted.
    func activeTurnIDs() -> Set<UUID> {
        Set(activeTurns.values.map(\.id)).union(commandCards.keys)
    }

    func waitUntilIdle(excluding turnIds: Set<UUID>) async {
        while let task = activeTurns.values.first(where: {
            !turnIds.contains($0.id)
        })?.task {
            _ = await task.value
        }
    }

    // Register commands atomically with shutdown; admission releases intake before replies finish.
    @discardableResult
    func runCommandUntilAdmitted(
        destination: TelegramDestination? = nil,
        operation: @escaping @Sendable (@escaping @Sendable () -> Void) async -> Void
    ) async -> Bool {
        guard !isShuttingDown else { return false }
        let id = UUID()
        let done = ScopedWaiter()
        commandDestinations[id] = destination
        commandTasks[id] = Task {
            await operation { done.resume() }
            commandTasks.removeValue(forKey: id)
            commandDestinations.removeValue(forKey: id)
            return nil
        }
        await Task { await done.park() }.value
        return true
    }

    public func shutdown() async {
        isShuttingDown = true
        for queued in queuedTurns.values.flatMap({ $0 }) { queued.onDiscard() }
        queuedTurns.removeAll()
        pausedQueueDestinations.removeAll()
        let tasks = activeTurns.values.map(\.task) + Array(commandTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        activeTurns.removeAll()
        commandTasks.removeAll()
        commandDestinations.removeAll()
        commandCards.removeAll()
        queuedTurns.removeAll()
        // Clear live ownership so orphaned claims remain recoverable after shutdown.
        inFlightUpdateIds.removeAll()
        isShuttingDown = false
    }

    public func snapshot(destination: TelegramDestination) -> TelegramTurnSnapshot {
        let active = activeTurns[destination]
        return TelegramTurnSnapshot(
            isRunning: active.map { !$0.stopConfirmed } ?? false,
            promptPreview: active?.promptPreview
        )
    }

    private static func preview(_ text: String, limit: Int = 120) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "..."
    }
}
