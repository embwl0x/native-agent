import Foundation

public struct TelegramLastUserMessage: Sendable, Equatable {
    public let chatId: Int
    public let text: String
    public let recordedAt: String

    public init(chatId: Int, text: String, recordedAt: String) {
        self.chatId = chatId
        self.text = text
        self.recordedAt = recordedAt
    }
}

public struct TelegramTurnSnapshot: Sendable, Equatable {
    public let chatId: Int
    public let isRunning: Bool
    public let startedAt: String?
    public let promptPreview: String?
    public let lastUserMessagePreview: String?
    public let lastUserMessageAt: String?

    public init(
        chatId: Int,
        isRunning: Bool,
        startedAt: String?,
        promptPreview: String?,
        lastUserMessagePreview: String?,
        lastUserMessageAt: String?
    ) {
        self.chatId = chatId
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.promptPreview = promptPreview
        self.lastUserMessagePreview = lastUserMessagePreview
        self.lastUserMessageAt = lastUserMessageAt
    }
}

struct TelegramQueuedTurnSnapshot: Sendable, Equatable {
    let updateId: Int
    let chatId: Int
    let position: Int
    let promptPreview: String
    let acknowledgementMessageId: Int?
}

public actor TelegramTurnCoordinator {
    public static let shared = TelegramTurnCoordinator()
    static let maximumQueuedTurnsPerChat = 20

    private struct ActiveTurn: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        let startedAt: String
        let promptPreview: String
        var card: TelegramTurnProgressCardDriver?
    }

    private struct QueuedTurn: Sendable {
        let updateId: Int
        let text: String
        let acknowledgementMessageId: Int?
        let operation: @Sendable (_ turnId: UUID) async -> Void
        let onStart: @Sendable (_ acknowledgementMessageId: Int?) async -> Void
    }

    private var activeTurns: [TelegramDestination: ActiveTurn] = [:]
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false
    private var shutdownGeneration: UInt64 = 0
    private var queuedTurns: [TelegramDestination: [QueuedTurn]] = [:]
    private var lastMessages: [TelegramDestination: TelegramLastUserMessage] = [:]
    private var claimedCallbackIds: Set<String> = []
    private var callbackClaimOrder: [String] = []
    private let callbackClaimLimit = 512
    private var nextInternalUpdateID = Int.min
    /// 2026-09-06: the update ids whose turn is running IN THIS PROCESS.
    /// A durable claim now stays `.processing` for the whole turn (so a crash
    /// leaves recoverable ingress), and the every-tick recovery pass settles
    /// `.processing` claims as outcome-unknown. Without this set that pass
    /// would quarantine a turn that is still running two seconds after it
    /// started. The set dies with the process, which is exactly when a
    /// `.processing` claim really is orphaned.
    private var inFlightUpdateIds: Set<Int> = []

    public init() {}

    // MARK: - Chat-only convenience
    //
    // 2026-09-06: the coordinator now keys on (chat, forum topic) so two
    // topics in one supergroup are two conversations. These take the whole
    // chat, which is what a caller with no topic in hand means.

    public func recordLastUserMessage(chatId: Int, text: String) {
        recordLastUserMessage(destination: .chat(chatId), text: text)
    }

    public func lastUserMessage(chatId: Int) -> TelegramLastUserMessage? {
        lastUserMessage(destination: .chat(chatId))
    }

    public func beginTurn(chatId: Int, text: String, task: Task<Void, Never>) -> UUID? {
        beginTurn(destination: .chat(chatId), text: text, task: task)
    }

    public func startTurn(
        chatId: Int,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        startTurn(destination: .chat(chatId), text: text, priority: priority, operation: operation)
    }

    public func startTrackedTurn(
        chatId: Int,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        startTrackedTurn(destination: .chat(chatId), text: text, priority: priority, operation: operation)
    }

    @discardableResult
    func enqueueTrackedTurn(
        updateId: Int,
        chatId: Int,
        text: String,
        acknowledgementMessageId: Int?,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void,
        onStart: @escaping @Sendable (_ acknowledgementMessageId: Int?) async -> Void
    ) -> Int? {
        enqueueTrackedTurn(
            updateId: updateId,
            destination: .chat(chatId),
            text: text,
            acknowledgementMessageId: acknowledgementMessageId,
            operation: operation,
            onStart: onStart
        )
    }

    @discardableResult
    func enqueueApprovalContinuation(
        chatId: Int,
        text: String,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void
    ) -> Int {
        enqueueApprovalContinuation(destination: .chat(chatId), text: text, operation: operation)
    }

    func queuedTurn(chatId: Int, updateId: Int) -> TelegramQueuedTurnSnapshot? {
        queuedTurn(destination: .chat(chatId), updateId: updateId)
    }

    @discardableResult
    func promoteQueuedTurn(chatId: Int, updateId: Int) -> TelegramQueuedTurnSnapshot? {
        promoteQueuedTurn(destination: .chat(chatId), updateId: updateId)
    }

    @discardableResult
    func attachCard(
        _ card: TelegramTurnProgressCardDriver,
        chatId: Int,
        turnId: UUID
    ) -> Bool {
        attachCard(card, destination: .chat(chatId), turnId: turnId)
    }

    func activeTurnID(chatId: Int) -> UUID? {
        activeTurnID(destination: .chat(chatId))
    }

    public func finishTurn(chatId: Int, turnId: UUID) {
        finishTurn(destination: .chat(chatId), turnId: turnId)
    }

    public func snapshot(chatId: Int) -> TelegramTurnSnapshot {
        snapshot(destination: .chat(chatId))
    }

    public func beginUpdateProcessing(_ updateId: Int) {
        inFlightUpdateIds.insert(updateId)
    }

    public func endUpdateProcessing(_ updateId: Int) {
        inFlightUpdateIds.remove(updateId)
    }

    public func isUpdateProcessing(_ updateId: Int) -> Bool {
        inFlightUpdateIds.contains(updateId)
    }

    public func recordLastUserMessage(destination: TelegramDestination, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastMessages[destination] = TelegramLastUserMessage(
            chatId: destination.chatId,
            text: trimmed,
            recordedAt: _tgNowString()
        )
    }

    public func lastUserMessage(destination: TelegramDestination) -> TelegramLastUserMessage? {
        lastMessages[destination]
    }

    public func beginTurn(destination: TelegramDestination, text: String, task: Task<Void, Never>) -> UUID? {
        guard !isShuttingDown, activeTurns[destination] == nil else { return nil }
        let id = UUID()
        activeTurns[destination] = ActiveTurn(
            id: id,
            task: task,
            startedAt: _tgNowString(),
            promptPreview: Self.preview(text),
            card: nil
        )
        return id
    }

    public func startTurn(
        destination: TelegramDestination,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        startTrackedTurn(
            destination: destination,
            text: text,
            priority: priority,
            operation: { _ in await operation() }
        )
    }

    /// Starts and owns a turn whose body needs its immutable turn id (for
    /// callback binding). Completion removes the exact generation
    /// automatically, so ingress never needs an unstructured cleanup watcher.
    public func startTrackedTurn(
        destination: TelegramDestination,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        guard !isShuttingDown, activeTurns[destination] == nil else { return nil }
        return launchTurn(
            destination: destination,
            text: text,
            priority: priority,
            operation: operation
        )
    }

    private func launchTurn(
        destination: TelegramDestination,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void,
        onStart: (@Sendable () async -> Void)? = nil
    ) -> (id: UUID, task: Task<Void, Never>) {
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            await onStart?()
            await operation(id)
            await self?.finishTurn(destination: destination, turnId: id)
        }
        activeTurns[destination] = ActiveTurn(
            id: id,
            task: task,
            startedAt: _tgNowString(),
            promptPreview: Self.preview(text),
            card: nil
        )
        return (id, task)
    }

    func canEnqueue(destination: TelegramDestination) -> Bool {
        !isShuttingDown && (queuedTurns[destination]?.count ?? 0) < Self.maximumQueuedTurnsPerChat
    }

    @discardableResult
    func enqueueTrackedTurn(
        updateId: Int,
        destination: TelegramDestination,
        text: String,
        acknowledgementMessageId: Int?,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void,
        onStart: @escaping @Sendable (_ acknowledgementMessageId: Int?) async -> Void
    ) -> Int? {
        guard !isShuttingDown, (queuedTurns[destination]?.count ?? 0) < Self.maximumQueuedTurnsPerChat else {
            return nil
        }
        let queued = QueuedTurn(
            updateId: updateId,
            text: text,
            acknowledgementMessageId: acknowledgementMessageId,
            operation: operation,
            onStart: onStart
        )
        queuedTurns[destination, default: []].append(queued)
        if activeTurns[destination] == nil {
            startNextQueuedTurn(destination: destination)
            return 0
        }
        return queuedTurns[destination]?.firstIndex(where: { $0.updateId == updateId }).map { $0 + 1 }
    }

    /// Schedules a verified internal continuation behind the active turn.
    /// Approval continuations are not Telegram updates and therefore have no
    /// durable update id or queue card. They take the next serial slot so the
    /// result of an interrupted request cannot be dropped behind later user
    /// messages merely because the original provider turn is still unwinding.
    @discardableResult
    func enqueueApprovalContinuation(
        destination: TelegramDestination,
        text: String,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void
    ) -> Int {
        guard !isShuttingDown else { return -1 }
        let updateId = nextInternalUpdateID
        nextInternalUpdateID &+= 1
        let queued = QueuedTurn(
            updateId: updateId,
            text: text,
            acknowledgementMessageId: nil,
            operation: operation,
            onStart: { _ in }
        )
        queuedTurns[destination, default: []].insert(queued, at: 0)
        if activeTurns[destination] == nil {
            startNextQueuedTurn(destination: destination)
            return 0
        }
        return 1
    }

    func queuedTurn(
        destination: TelegramDestination,
        updateId: Int
    ) -> TelegramQueuedTurnSnapshot? {
        guard let queue = queuedTurns[destination],
              let index = queue.firstIndex(where: { $0.updateId == updateId }) else {
            return nil
        }
        let item = queue[index]
        return TelegramQueuedTurnSnapshot(
            updateId: item.updateId,
            chatId: destination.chatId,
            position: index + 1,
            promptPreview: Self.preview(item.text),
            acknowledgementMessageId: item.acknowledgementMessageId
        )
    }

    func removeQueuedTurn(destination: TelegramDestination, updateId: Int) -> TelegramQueuedTurnSnapshot? {
        guard var queue = queuedTurns[destination],
              let index = queue.firstIndex(where: { $0.updateId == updateId }) else {
            return nil
        }
        let item = queue.remove(at: index)
        queuedTurns[destination] = queue.isEmpty ? nil : queue
        return TelegramQueuedTurnSnapshot(
            updateId: item.updateId,
            chatId: destination.chatId,
            position: index + 1,
            promptPreview: Self.preview(item.text),
            acknowledgementMessageId: item.acknowledgementMessageId
        )
    }

    @discardableResult
    func promoteQueuedTurn(destination: TelegramDestination, updateId: Int) -> TelegramQueuedTurnSnapshot? {
        guard var queue = queuedTurns[destination],
              let index = queue.firstIndex(where: { $0.updateId == updateId }) else {
            return nil
        }
        let item = queue.remove(at: index)
        queue.insert(item, at: 0)
        queuedTurns[destination] = queue
        if activeTurns[destination] == nil {
            startNextQueuedTurn(destination: destination)
        }
        return TelegramQueuedTurnSnapshot(
            updateId: item.updateId,
            chatId: destination.chatId,
            position: 1,
            promptPreview: Self.preview(item.text),
            acknowledgementMessageId: item.acknowledgementMessageId
        )
    }

    @discardableResult
    func attachCard(
        _ card: TelegramTurnProgressCardDriver,
        destination: TelegramDestination,
        turnId: UUID
    ) -> Bool {
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

    func controlCard(destination: TelegramDestination, turnId: UUID) -> TelegramTurnProgressCardDriver? {
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

    public func finishTurn(destination: TelegramDestination, turnId: UUID) {
        guard activeTurns[destination]?.id == turnId else { return }
        activeTurns[destination] = nil
        startNextQueuedTurn(destination: destination)
    }

    private func startNextQueuedTurn(destination: TelegramDestination) {
        guard !isShuttingDown, activeTurns[destination] == nil,
              var queue = queuedTurns[destination],
              !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queuedTurns[destination] = queue.isEmpty ? nil : queue
        _ = launchTurn(
            destination: destination,
            text: next.text,
            priority: .userInitiated,
            operation: next.operation,
            onStart: { await next.onStart(next.acknowledgementMessageId) }
        )
    }

    enum StopOutcome: Sendable, Equatable {
        case notRunning
        case confirmed
        case outcomeUnknown
    }

    func requestStop(
        destination: TelegramDestination,
        turnId: UUID? = nil,
        confirmationTimeoutNanoseconds: UInt64,
        sleeper: @escaping @Sendable (_ nanoseconds: UInt64) async throws -> Void
    ) async -> StopOutcome {
        guard let active = activeTurns[destination],
              turnId == nil || active.id == turnId else {
            return .notRunning
        }
        active.task.cancel()
        guard let card = active.card else { return .outcomeUnknown }
        if let phase = await Self.waitForTerminal(
            card,
            timeoutNanoseconds: confirmationTimeoutNanoseconds,
            sleeper: sleeper
        ) {
            guard phase == .canceled else { return .outcomeUnknown }
            // The card's .canceled phase IS the cooperative-cancellation
            // evidence. Release the chat slot now instead of waiting for the
            // task's receipt-writing tail — a confirmed stop must never leave
            // snapshot(destination:).isRunning true. The task's own finishTurn call
            // becomes a no-op (same-id guard).
            finishTurn(destination: destination, turnId: active.id)
            return .confirmed
        }
        await card.transition(
            .outcomeUnknown(reason: "Stop requested, but cancellation was not confirmed")
        )
        return .outcomeUnknown
    }

    private static func waitForTerminal(
        _ card: TelegramTurnProgressCardDriver,
        timeoutNanoseconds: UInt64,
        sleeper: @escaping @Sendable (_ nanoseconds: UInt64) async throws -> Void
    ) async -> TelegramTurnPresentationPhase? {
        await withTaskGroup(of: TelegramTurnPresentationPhase?.self) { group in
            group.addTask {
                await card.waitForTerminal()
            }
            group.addTask {
                do {
                    try await sleeper(timeoutNanoseconds)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public func waitUntilAllIdle() async {
        while let task = activeTurns.values.first?.task {
            await task.value
        }
    }

    func activeTurnIDs() -> Set<UUID> {
        Set(activeTurns.values.map(\.id))
    }

    func activeTurnID(destination: TelegramDestination) -> UUID? {
        activeTurns[destination]?.id
    }

    func waitUntilIdle(excluding turnIds: Set<UUID>) async {
        while let task = activeTurns.values.first(where: {
            !turnIds.contains($0.id)
        })?.task {
            await task.value
        }
    }

    // 2026-09-06: command creation and registration are atomic with shutdown.
    // Admission still releases ingress before the command's reply send finishes.
    func runCommandUntilAdmitted(
        operation: @escaping @Sendable (@escaping @Sendable () -> Void) async -> Void
    ) async {
        guard !isShuttingDown else { return }
        let id = UUID()
        let generation = shutdownGeneration
        await withCheckedContinuation { (admission: CheckedContinuation<Void, Never>) in
            // 2026-09-06: admission accepted before shutdown cannot register
            // in a replacement lifecycle, even after the shutdown flag resets.
            guard !isShuttingDown, shutdownGeneration == generation else {
                admission.resume()
                return
            }
            commandTasks[id] = Task {
                await operation { admission.resume() }
                commandTasks.removeValue(forKey: id)
            }
        }
    }

    public func shutdown() async {
        shutdownGeneration &+= 1
        isShuttingDown = true
        queuedTurns.removeAll()
        let tasks = activeTurns.values.map(\.task) + Array(commandTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        activeTurns.removeAll()
        commandTasks.removeAll()
        queuedTurns.removeAll()
        // 2026-09-06: nothing is running after shutdown, so no update id may
        // stay marked in-flight — a leftover mark would keep the recovery pass
        // off a claim that really is orphaned.
        inFlightUpdateIds.removeAll()
        isShuttingDown = false
    }

    public func snapshot(destination: TelegramDestination) -> TelegramTurnSnapshot {
        let active = activeTurns[destination]
        let last = lastMessages[destination]
        return TelegramTurnSnapshot(
            chatId: destination.chatId,
            isRunning: active != nil,
            startedAt: active?.startedAt,
            promptPreview: active?.promptPreview,
            lastUserMessagePreview: last.map { Self.preview($0.text) },
            lastUserMessageAt: last?.recordedAt
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
