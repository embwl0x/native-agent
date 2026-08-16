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
    }

    private var activeTurns: [Int: ActiveTurn] = [:]
    private var lastMessages: [Int: TelegramLastUserMessage] = [:]

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
            promptPreview: Self.preview(text)
        )
        return id
    }

    public func startTurn(
        chatId: Int,
        text: String,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> (id: UUID, task: Task<Void, Never>)? {
        guard activeTurns[chatId] == nil else { return nil }
        let id = UUID()
        let task = Task(priority: priority) {
            await operation()
        }
        activeTurns[chatId] = ActiveTurn(
            id: id,
            task: task,
            startedAt: _tgNowString(),
            promptPreview: Self.preview(text)
        )
        return (id, task)
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
