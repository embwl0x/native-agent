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

public actor TelegramTurnCoordinator {
    public static let shared = TelegramTurnCoordinator()

    private struct ActiveTurn: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        let startedAt: String
        let promptPreview: String
        var card: TelegramTurnProgressCardDriver?
    }

    private var activeTurns: [Int: ActiveTurn] = [:]
    private var lastMessages: [Int: TelegramLastUserMessage] = [:]
    private var claimedCallbackIds: Set<String> = []
    private var callbackClaimOrder: [String] = []
    private let callbackClaimLimit = 512

    public init() {}

    public func recordLastUserMessage(chatId: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastMessages[chatId] = TelegramLastUserMessage(
            chatId: chatId,
            text: trimmed,
            recordedAt: _tgNowString()
        )
    }

    public func lastUserMessage(chatId: Int) -> TelegramLastUserMessage? {
        lastMessages[chatId]
    }

    public func beginTurn(chatId: Int, text: String, task: Task<Void, Never>) -> UUID? {
        guard activeTurns[chatId] == nil else { return nil }
        let id = UUID()
        activeTurns[chatId] = ActiveTurn(
            id: id,
            task: task,
            startedAt: _tgNowString(),
            promptPreview: Self.preview(text),
            card: nil
        )
        return id
    }

    public func startTurn(
        chatId: Int,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        startTrackedTurn(
            chatId: chatId,
            text: text,
            priority: priority,
            operation: { _ in await operation() }
        )
    }

    /// Starts and owns a turn whose body needs its immutable turn id (for
    /// callback binding). Completion removes the exact generation
    /// automatically, so ingress never needs an unstructured cleanup watcher.
    public func startTrackedTurn(
        chatId: Int,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ turnId: UUID) async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        guard activeTurns[chatId] == nil else { return nil }
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            await operation(id)
            await self?.finishTurn(chatId: chatId, turnId: id)
        }
        activeTurns[chatId] = ActiveTurn(
            id: id,
            task: task,
            startedAt: _tgNowString(),
            promptPreview: Self.preview(text),
            card: nil
        )
        return (id, task)
    }

    @discardableResult
    func attachCard(
        _ card: TelegramTurnProgressCardDriver,
        chatId: Int,
        turnId: UUID
    ) -> Bool {
        guard var active = activeTurns[chatId], active.id == turnId else {
            return false
        }
        active.card = card
        activeTurns[chatId] = active
        return true
    }

    func activeCard(chatId: Int) -> TelegramTurnProgressCardDriver? {
        activeTurns[chatId]?.card
    }

    func controlCard(chatId: Int, turnId: UUID) -> TelegramTurnProgressCardDriver? {
        guard let active = activeTurns[chatId], active.id == turnId else {
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

    public func finishTurn(chatId: Int, turnId: UUID) {
        guard activeTurns[chatId]?.id == turnId else { return }
        activeTurns[chatId] = nil
    }

    @discardableResult
    public func cancelTurn(chatId: Int) -> Bool {
        guard let active = activeTurns[chatId] else { return false }
        active.task.cancel()
        return true
    }

    enum StopOutcome: Sendable, Equatable {
        case notRunning
        case confirmed
        case outcomeUnknown
    }

    func requestStop(
        chatId: Int,
        turnId: UUID? = nil,
        confirmationTimeoutNanoseconds: UInt64,
        sleeper: @escaping @Sendable (_ nanoseconds: UInt64) async throws -> Void
    ) async -> StopOutcome {
        guard let active = activeTurns[chatId],
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
            return phase == .canceled ? .confirmed : .outcomeUnknown
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

    func waitUntilIdle(excluding turnIds: Set<UUID>) async {
        while let task = activeTurns.values.first(where: {
            !turnIds.contains($0.id)
        })?.task {
            await task.value
        }
    }

    public func shutdown() async {
        let tasks = activeTurns.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        activeTurns.removeAll()
    }

    public func snapshot(chatId: Int) -> TelegramTurnSnapshot {
        let active = activeTurns[chatId]
        let last = lastMessages[chatId]
        return TelegramTurnSnapshot(
            chatId: chatId,
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
